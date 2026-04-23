# 华为云 OBS 存储扩展重构计划（精简版）

## Context

Zealot 是 Ruby on Rails 8.1 应用（App 分发平台），当前所有上传文件（安装包、图标、调试文件）仅支持本地磁盘。需求：

- 服务器带宽/存储受限，安装包上传/下载走云存储
- 插件式扩展，**对现有源文件的修改最小化**，便于后续代码升级合并

用户有一份 C 语言 WinHTTP 上传库仅作逻辑参考，用 Ruby 重写。

## 核心方案

**使用 `carrierwave-aws` gem + 运行时切换 `storage` 类方法。**

华为 OBS 完全兼容 S3 协议；`carrierwave-aws` 是成熟官方库，原生支持 S3 任意 endpoint，**无需自写 CarrierWave 存储引擎、无需实现伪文件对象**。所有新增代码放在 `lib/zealot/storage/`，对现有源文件修改控制到最小。

---

## 实施步骤

### 第 1 步：添加依赖

**`Gemfile`**（carrierwave 相邻位置）

```ruby
gem 'carrierwave-aws', '>= 1.7', '< 2.0'
```

`carrierwave-aws` 内部依赖 `aws-sdk-s3`，无需单独加。约束放宽到 `< 2.0` 而非 `~> 1.6`，允许吸收 1.7+（2024 发布）的 bugfix。gemspec 声明 `carrierwave >= 1.0, < 4`，与本项目 CW 3.1.2 兼容。

---

### 第 2 步：Setting 扩展

**`app/models/setting.rb`**（在第 165 行 `scope :misc` 的 `end` 之后插入）

```ruby
scope :storage do
  field :storage_s3, type: :hash, display: true, restart_required: true, default: {
    enabled:           to_bool(ENV['STORAGE_S3_ENABLED'] || 'false'),
    endpoint:          ENV['STORAGE_S3_ENDPOINT'],            # https://obs.cn-north-4.myhuaweicloud.com
    region:            ENV['STORAGE_S3_REGION'] || 'cn-north-4',
    bucket:            ENV['STORAGE_S3_BUCKET'],
    access_key_id:     ENV['STORAGE_S3_ACCESS_KEY_ID'],
    secret_access_key: ENV['STORAGE_S3_SECRET_ACCESS_KEY'],
    force_path_style:  to_bool(ENV['STORAGE_S3_FORCE_PATH_STYLE'] || 'false'),
    path_prefix:       ENV['STORAGE_S3_PATH_PREFIX'],
    object_acl:        ENV['STORAGE_S3_OBJECT_ACL'] || 'private',
    presign_expires_in:(ENV['STORAGE_S3_PRESIGN_EXPIRES_IN'] || 3600).to_i
  }, validates: { json: { format: :hash } }
end
```

> 跟随现有 `third_party_auth` / `misc` 的 hash + ENV 默认值模式。`restart_required: true` 会在保存后提示重启（CarrierWave storage 在 mount 时缓存）。

**ENV / DB 优先级**：DB 有值则覆盖 ENV；Reset 回落 ENV（`rails-settings-cached` 原生行为）。

**敏感字段 mask**：`app/helpers/admin_helper.rb:12` 的 `secure_key?` 只在 `Setting.demo_mode` 下生效，且匹配 `Rails.application.config.filter_parameters`。**需在 `config/initializers/filter_parameter_logging.rb` 追加 `:secret_access_key, :access_key_id`**。

**字段必填校验**：`rails-settings-cached` 原生 `validates: { json: { format: :hash } }` 仅校验 JSON 结构。本期不加强校验（避免 `setting_validate.rb` 改动——该 concern 仅负责表单文案渲染，无 `validate` 回调入口），由管理员保证配置完整，错误在首次上传时抛出。

---

### 第 3 步：Storage Manager（唯一新业务文件）

**`lib/zealot/storage/manager.rb`**

```ruby
module Zealot::Storage
  module Manager
    module_function

    def cloud_enabled?
      config[:enabled] == true
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError, PG::ConnectionBad
      false
    end

    def config
      Setting.storage_s3.deep_symbolize_keys
    end

    def aws_credentials
      { access_key_id: config[:access_key_id], secret_access_key: config[:secret_access_key] }
    end

    def aws_options
      {
        endpoint:         config[:endpoint],
        region:           config[:region],
        force_path_style: config[:force_path_style]
      }.compact
    end

    # 连通性自检（供 rake 或初次启用时手动调用）
    def verify!
      client = Aws::S3::Client.new(credentials: Aws::Credentials.new(**aws_credentials), **aws_options)
      client.head_bucket(bucket: config[:bucket])
      :ok
    rescue => e
      { error: e.class.name, message: e.message }
    end
  end
end
```

> 不抽象 Provider 接口、不实现 LocalProvider—— CarrierWave 本身处理本地存储；仅在启用时切到 `:aws`。

---

### 第 4 步：初始化器

**`config/initializers/storage.rb`**

```ruby
# frozen_string_literal: true

Rails.configuration.to_prepare do
  next unless defined?(CarrierWave::Storage::AWS)

  cloud = begin
    Zealot::Storage::Manager.cloud_enabled?
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError, PG::ConnectionBad
    false
  end

  ApplicationUploader.class_eval do
    # 走官方 storage_engine= 解析：Symbol -> Class
    # CarrierWave 3.x 的 self.storage reader 期望返回已解析的存储类，
    # 实例侧调用链是 self.class.storage.new(self)；若只覆盖 reader 返回
    # Symbol 会触发 `:aws.new(self)` 异常。用 DSL 形式 storage(...) 最稳。
    storage(cloud ? :aws : :file)

    def aws_bucket
      Zealot::Storage::Manager.config[:bucket]
    end

    def aws_acl
      Zealot::Storage::Manager.config[:object_acl]
    end

    def aws_attributes
      { expires: 1.week.from_now.httpdate }
    end
  end

  CarrierWave.configure do |c|
    c.aws_credentials = -> { Zealot::Storage::Manager.aws_credentials.merge(Zealot::Storage::Manager.aws_options) }
  end
end
```

> `ApplicationUploader` 源文件**保持不变**（保留 `storage :file`），运行时被 `class_eval` 通过 DSL `storage(:aws|:file)` 覆盖，方便合并上游。
>
> **为什么用 `storage(:aws)` 而不是覆盖 `self.storage` 方法？** CarrierWave 3.1.2 中 `storage_engine=` setter 负责 `Symbol → Class` 解析（`CarrierWave::Storage.const_get`），而 `storage`（无参 reader）返回已解析的类。调用 `storage(:aws)` 走 setter 路径，与 `class ApplicationUploader; storage :aws; end` 等效；直接覆盖 reader 返回 Symbol 会破坏 `self.class.storage.new(self)` 调用。
>
> **切换时机**：`restart_required: true`，Setting 在 UI/DB 改动后需重启容器，启动一次性绑定足够；`to_prepare` 在生产环境仅 boot 跑，开发环境每次 reload 跑。
>
> `path_prefix`（可选）通过在 `ApplicationUploader#base_store_dir` 里读 `config[:path_prefix]` 实现——若 bucket 专用则不必。

---

### 第 5 步：下载控制器适配

**`app/controllers/concerns/cloud_storage_download.rb`**（新建）

```ruby
module CloudStorageDownload
  extend ActiveSupport::Concern

  private

  def send_file_or_redirect(carrierwave_file, filename:, disposition: 'attachment')
    if Zealot::Storage::Manager.cloud_enabled?
      redirect_to carrierwave_file.url(
        response_content_disposition: %Q(#{disposition}; filename="#{filename}"),
        expires_in: Zealot::Storage::Manager.config[:presign_expires_in]
      ), allow_other_host: true
    else
      headers['Content-Length'] = carrierwave_file.size.to_s
      send_file carrierwave_file.path, filename: filename, disposition: disposition
    end
  end

  def file_exists?(carrierwave_file)
    Zealot::Storage::Manager.cloud_enabled? ? carrierwave_file.file&.exists? : File.exist?(carrierwave_file.path.to_s)
  end
end
```

> `carrierwave-aws` 的 `file.url` 在私有 ACL 时自动生成预签名 URL；`file.exists?` 在云端走 HEAD 请求。

**修改 3 个控制器**（每处 3 行以内改动）：

| 文件 | 精确改动 |
|------|----------|
| `app/controllers/download/releases_controller.rb` | 第 3 行后 `include CloudStorageDownload`；第 14 行 `File.exist?(@release.file.path.to_s)` → `file_exists?(@release.file)`；第 23-26 行 `headers['Content-Length']... send_file ...` → `send_file_or_redirect(@release.file, filename: @release.download_filename)` |
| `app/controllers/download/debug_files_controller.rb` | 同上模式；第 9 行 `File.exist?` → `file_exists?(@debug_file.file)`；第 15-18 行 → `send_file_or_redirect(@debug_file.file, filename: @debug_file.download_filename)` |
| `app/controllers/api/debug_files/download_controller.rb` | 同上；第 21 行 `File.exist?(@debug_file.file.path)` → `file_exists?(@debug_file.file)`；第 23 行 `@debug_file.file_url` **无需改动**（`DebugFile#file_url` 返回的是 Rails 路由 `download_debug_file_url(id)`，由上面改造过的下载控制器自动走 302 到预签名 URL，与 CarrierWave 无关） |

---

### 第 6 步：磁盘空间检查守护

**`app/models/release.rb` 第 291 行** `determine_disk_space` 开头加一行：

```ruby
def determine_disk_space
  return if Zealot::Storage::Manager.cloud_enabled?
  # 原有代码不变
end
```

---

### 第 7 步：App 删除清理云端对象

**`app/controllers/apps_controller.rb:108-113`** 的 `destroy_app_data` 目前只 `FileUtils.rm_rf` 本地目录。云模式下 OBS 对象不会被清理会产生垃圾，需补云端分支：

```ruby
def destroy_app_data
  require 'fileutils'

  if Zealot::Storage::Manager.cloud_enabled?
    destroy_cloud_app_data
  else
    app_binary_path = Rails.root.join('public', 'uploads', 'apps', "a#{@app.id}")
    FileUtils.rm_rf(app_binary_path) if Dir.exist?(app_binary_path)
  end
end

def destroy_cloud_app_data
  cfg    = Zealot::Storage::Manager.config
  client = Aws::S3::Client.new(
    credentials: Aws::Credentials.new(**Zealot::Storage::Manager.aws_credentials),
    **Zealot::Storage::Manager.aws_options
  )
  prefix = [cfg[:path_prefix], 'uploads', 'apps', "a#{@app.id}"].compact.join('/')

  continuation = nil
  loop do
    resp = client.list_objects_v2(bucket: cfg[:bucket], prefix: prefix, continuation_token: continuation)
    break if resp.contents.empty?

    client.delete_objects(
      bucket: cfg[:bucket],
      delete: { objects: resp.contents.map { |o| { key: o.key } }, quiet: true }
    )

    break unless resp.is_truncated
    continuation = resp.next_continuation_token
  end
rescue => e
  Rails.logger.error("[Storage] destroy_cloud_app_data failed app=#{@app.id}: #{e.class}: #{e.message}")
  # 不抛异常：业务删除本身不应被存储清理失败阻断；残留对象可通过 bucket 生命周期兜底
end
```

> 也可选择更保守的策略：**不做批删**，改为"依赖 bucket lifecycle rule 按 tag/prefix 过期"，代码零改动。若采用 lifecycle 方案，文档需明确列出 prefix 规范和建议的过期天数。

---

### 第 8 步：i18n

**`config/locales/zealot/zh-CN.yml` / `en.yml`** 在 settings 区域各加 3 条：

```yaml
zh-CN:
  storage: 存储
  storage_s3: S3 兼容对象存储
  storage_s3_hint: |
    配置 S3 兼容对象存储（华为云 OBS / MinIO / 阿里云 OSS / 腾讯云 COS / AWS S3）。
    必填：endpoint、region、bucket、access_key_id、secret_access_key。
    MinIO 需将 force_path_style 设为 true。修改后需重启生效。
```

现有 `admin/settings/index.html.slim` 按 scope 动态渲染，**无需改视图**。

---

### 第 9 步：过滤敏感参数

**`config/initializers/filter_parameter_logging.rb`**（已有文件，增量追加）

```ruby
Rails.application.config.filter_parameters += [:secret_access_key, :access_key_id]
```

> 现有过滤器含 `_key`、`secret`，已能部分匹配，但显式声明更保险（`access_key_id` 以 `id` 结尾不会被 `_key` 匹配到前缀）。

---

## 兼容性审查

### CarrierWave 三阶段

| 阶段 | 时机 | file.path 指向 | 云影响 |
|------|------|---------------|--------|
| Cache | 上传后 `save!` 前 | `public/uploads/tmp/*` 本地 | 无 |
| Store | `save!` 时 | 存储引擎接管 | 是（写云） |
| Retrieve | 已保存再加载 | 存储引擎返回对象 | 是（读云） |

**所有"上传当下"的解析（`AppInfo.parse`、MiniMagick convert）都在 cache 阶段，与云存储无关。**

### 逐点核查

| 调用点 | 阶段 | 本方案处理 |
|--------|------|-----------|
| `app/controllers/api/apps/upload_controller.rb:144` `AppInfo.parse(params[:file].path)` | 上传 tempfile | 零改动 |
| `app/models/concerns/release_parser.rb:15` `AppInfo.parse(self.file.path)` | Cache（`before_create`） | 零改动 |
| `app/uploaders/app_icon_uploader.rb:6,24` MiniMagick + not_png? | Cache | 零改动 |
| `app/models/release.rb` `Release#file?` / `#file_extname`, `app/models/debug_file.rb` `DebugFile#file?` | Retrieve | **必须改动**：`File.exist?` 在云模式下永远 false（list 页/install 页会把所有 release 标记为"文件缺失"）；且 CarrierWave 不会因 `File.exist?` 懒下载。改为零 IO：`file.file.present?`（基于 DB 字段，上传完成 store 成功后总为真），`File.extname(file.path.to_s)`（纯字符串，S3 key 也能取后缀）。避免每次列表渲染打 HEAD。 |
| `app/jobs/teardown_job.rb` `release.file.file` + `File.exist?(file.path)` | Retrieve | **必须改动**：云模式下 `file.path` 是 S3 key，`File.exist?` 永远 false（触发"File was not found"），且 `TeardownService.new(path)` 会把 S3 key 误喂给 `AppInfo.parse`。使用 `release.file.file.exists?`（HEAD）+ `uploader#with_local_path`（流式下载到 tempfile） |
| `app/jobs/debug_file_teardown_job.rb` | Retrieve | **必须改动**：同上，`AppInfo.parse(path)` 需用 `uploader#with_local_path` 包裹 |
| `app/helpers/apps_helper.rb:24` `release.icon.file.exists?` | Retrieve | **必须改动**：功能上 `exists?` 响应，但每次 app 列表渲染都会对每个 release 打一次 S3 HEAD（N 项列表 → N 次请求），延迟+费用不可接受。改为 `release&.icon&.file.present?`（基于 uploader 状态，零 IO） |
| `release.icon_url` | Retrieve | 零改动（由 `mount_uploader :icon` 自动生成的 uploader 方法，走 `carrierwave-aws` 的 `url`，私有 ACL 下自动返回预签名 URL） |
| `debug_file.file_url` | N/A（Rails 路由） | 零改动（`DebugFile#file_url` 返回 `download_debug_file_url(id)`，由第 5 步改造的下载控制器统一 302 到预签名 URL，与 CarrierWave 无关） |
| `app/models/debug_file.rb:22,105-107` `generate_checksum`（`before_validation`） | Cache（create 时） | 零改动（`before_validation` 仅在 `save!` 前触发，此时文件仍在 cache 目录；**不要在其他时机调用 `file.checksum`**，否则云模式下会全量下载） |
| `app/controllers/apps_controller.rb:108-113` `destroy_app_data` | 本地 `FileUtils.rm_rf` | **云模式分支**（第 7 步） |
| `app/models/release.rb:291` `determine_disk_space` | 本地 stat | **显式守护**（第 6 步） |
| `app/models/release.rb:285` `determine_file_exist` | Cache | 零改动 |

### 性能注意（非破坏，但需文档说明）

1. **`ApplicationUploader#checksum`** 会 `.read` 整个文件。当前仅由 `DebugFile#generate_checksum`（`before_validation`，cache 阶段本地文件）调用，云模式下无额外代价。**若未来为 `Release` 或其他模型加类似回调，务必避免在 retrieve 阶段调用**，否则触发全量云端下载。可选优化：上传时落库 ETag / 流式 `Digest::MD5` 读取。
2. **Teardown Job** 云模式下首次访问 `file.path` 会懒下载整个安装包到 worker 本地——是可接受代价（任务本身就要解析完整文件）。生产建议 worker 与 OBS 同 VPC。
3. **`file_extname` / `File.file?(file.path)`** 每次调用都会触发下载探测。若成为热点，改为基于文件名后缀判断。
4. **iOS `install/show.html.erb` 的 `@release.icon_url`** 云模式下是预签名 URL（默认 1h）。iOS 解析 plist 时会立即拉取，几秒内完成，超时风险极低；但若后续把 plist 渲染结果缓存到 CDN，需显式禁用或缩短 `presign_expires_in`。
5. **`admin/system_info_controller.rb:8` 健康检查** 仍会探测 `public/uploads` 目录的可写性。云模式下该目录仅做 CarrierWave cache，仍需存在并可写，保留即可；不需要改动，但运维报告中的"uploads"含义从"数据盘"退化为"临时 cache"。

---

## 本地 / 云 存储共存策略

**不做"按记录检测后端"的脆弱逻辑**（文件系统探测在容器/NFS 场景不可靠）。策略：

- **切换是单向的**：启用云存储前，管理员选择：
  - 方案 A：**手动迁移**（`aws s3 sync public/uploads s3://bucket/prefix`）
  - 方案 B：**保留本地只读目录**，下载走 nginx `try_files` fallback（运维层配置，代码不感知）
- 文档明确说明；不在业务代码里做双后端探测
- 如有强需求，后续版本加 `releases.storage_backend` 字段做 per-record 标记（Phase 2）

---

## 文件变更汇总

### 修改（共 9 个，每处极小）

| 文件 | 改动量 |
|------|--------|
| `Gemfile` | +1 行（`carrierwave-aws`） |
| `app/models/setting.rb` | +11 行（`scope :storage`） |
| `app/controllers/download/releases_controller.rb` | ~3 行 |
| `app/controllers/download/debug_files_controller.rb` | ~3 行 |
| `app/controllers/api/debug_files/download_controller.rb` | ~2 行 |
| `app/controllers/apps_controller.rb` | +20 行（`destroy_app_data` 云模式分支 + `destroy_cloud_app_data`） |
| `app/models/release.rb` | +1 行（`determine_disk_space` 守护） |
| `config/locales/zealot/zh-CN.yml` + `en.yml` | +3 条 / 文件 |
| `config/initializers/filter_parameter_logging.rb` | +1 行 |

### 新建（共 3 个）

| 文件 | 说明 |
|------|------|
| `lib/zealot/storage/manager.rb` | cloud_enabled? / config / verify! |
| `config/initializers/storage.rb` | ApplicationUploader.class_eval 运行时切换 |
| `app/controllers/concerns/cloud_storage_download.rb` | 下载分支 concern |

### 相对第一版计划砍掉的

- ❌ `provider.rb` / `local_provider.rb` / `obs_provider.rb`（`carrierwave-aws` 替代）
- ❌ `carrierwave_storage.rb` 自写存储引擎 + 伪文件 duck-typing（`carrierwave-aws` 原生提供）
- ❌ `lib/zealot/backup/cloud_uploads.rb` + `backup/manager.rb` 改动（云端用 bucket 生命周期/版本化，备份跳过 uploads，文档说明）
- ❌ `admin/storage_verify_controller.rb` + Stimulus controller + 路由 + `_setting.html.slim` 改动（改为 `rake zealot:storage:verify`）
- ❌ `setting_validate.rb` 改动（定位错误）
- ❌ 图标 `public?` / `domain` / `AppIconUploader` 覆写（统一预签名 URL + HTTP 缓存头）
- ❌ `cloud_backed?` 按记录探测共存逻辑（改为运维层迁移）
- ❌ `lib/tasks/zealot/storage.rake` stat 任务

---

## 关键设计决策

1. **最小侵入**：业务代码零改动（teardown_job、release_parser、apps_helper、install plist、serializer、AppIconUploader 全部不动），靠 `carrierwave-aws` 的 `storage :aws` 和 uploader.url 自动适配。
2. **`ApplicationUploader` 源码不变**：`class_eval` 在初始化器运行时覆盖 `storage` 类方法。
3. **使用成熟 gem（`carrierwave-aws`）**：华为 OBS 兼容 S3 协议，aws-sdk-s3 自带签名/重试/流式/预签名 URL。
4. **单向切换 + 运维层迁移**：避免 per-request 探测后端的复杂度。
5. **下载重定向预签名 URL**：大文件不过 Rails，用户直连 OBS。
6. **双入口（ENV + UI）**：沿用 rails-settings-cached 原生行为。

---

## 验证方案

### 自动化测试

| 文件 | 覆盖 |
|------|------|
| `spec/lib/zealot/storage/manager_spec.rb` | cloud_enabled? / config / DB 未就绪回落 |
| `spec/controllers/download/releases_controller_spec.rb` | 本地 send_file vs 云 redirect 分支（stub cloud_enabled?） |
| `spec/controllers/download/debug_files_controller_spec.rb` | 同上 |

`carrierwave-aws` 有自身测试，不重复覆盖。

### 手工验收

1. **本地回归**：不启用云，完整跑一遍上传/下载/备份/图标/teardown
2. **ENV 入口**：`config.env` 配置 `STORAGE_S3_*` 启动即生效
3. **UI 入口**：后台修改覆盖 ENV；Reset 回落
4. **云模式核心路径**：
   - 安装包上传，OBS bucket 中出现
   - iOS itms-services 安装（manifest.plist 的预签名 URL 能被 iOS 解析）
   - Android APK 下载（302 到预签名 URL）
   - 图标显示（私有 ACL + 预签名）
   - Teardown 后台任务解析云端文件
5. **MinIO 兼容**：`force_path_style=true` 跑一遍
6. **连通性**：`rails runner 'p Zealot::Storage::Manager.verify!'`
7. **`bundle exec rspec`** 全量回归

---

## 架构图

```
     ┌─────────────┐    ┌──────────────────┐
     │ config.env  │    │  Admin UI (DB)   │
     │ STORAGE_S3_*│───▶│ Setting.storage_s3│
     └─────────────┘    └────────┬─────────┘
                                 │
                    ┌────────────▼────────────┐
                    │ Zealot::Storage::Manager │
                    │ cloud_enabled? / config  │
                    └────┬───────────────┬─────┘
                enabled  │               │  disabled
                         ▼               ▼
            ┌─────────────────┐   ┌──────────────┐
            │ carrierwave-aws │   │ CarrierWave  │
            │  (:aws)         │   │  (:file)     │
            └────────┬────────┘   └──────┬───────┘
                     │                   │
                     └─────────┬─────────┘
                               ▼
                    ApplicationUploader
                    (storage 运行时切换)

下载流程:
  请求 → CloudStorageDownload concern
          ├─ cloud_enabled? NO → send_file (本地)
          └─ cloud_enabled? YES → redirect → 预签名 URL → 用户直连 OBS
```
