# 公开 App 下载模块开发计划

## 目标

新增一个公开访问模块，提供固定地址展示所有可下载应用。用户点击应用后进入对应下载页。

下载页支持：

- 有访问密码：先输入密码，通过后展示下载内容
- 无访问密码：直接展示下载内容
- 展示 App 图标、名称、版本、构建号、二维码、安装按钮、下载按钮、更新说明、历史记录
- 历史记录可点击跳转到对应版本下载页

## 技术判断

当前项目不是独立 SPA 前端，而是 Rails + Slim 服务端渲染页面，前端资源由 `app/frontend` 通过 Vite 管理。

因此这个功能需要同时改：

- Rails 路由和控制器：提供固定公开地址
- Rails 视图：渲染应用列表页和下载详情页
- `app/frontend`：新增样式和少量交互 JS

## 已确认路由

```ruby
GET  /download_apps
GET  /download_apps/:channel_id/releases/:id
POST /download_apps/:channel_id/releases/:id/auth
GET  /download_apps/:channel_id/releases/:id/qrcode(/:size)(/:theme)
```

说明：

- `/download_apps`：固定公开地址，展示所有应用
- `/download_apps/:channel_id/releases/:id`：公开下载详情页
- `auth`：密码访问提交接口
- `qrcode`：公开下载详情页二维码，二维码内容指向 `/download_apps/:channel_id/releases/:id`

## 页面结构

### 1. 应用列表页

地址：

```text
/download_apps
```

聚合页先按系统类型分区，再展示该系统下所有可下载 App。每个 App 如果存在多个环境，需要为每个环境提供独立入口：

- iOS
- Android
- HarmonyOS
- macOS
- Windows
- Linux

展示内容：

- App 图标
- App 名称
- 平台类型
- 最新版本号
- 最新构建号
- 更新时间
- 访问状态：公开 / 需要密码
- 环境入口：例如测试环境、正式环境、预发布环境
- 点击某个环境入口后，跳转到该系统、该 App、该环境对应的最新 Release 下载页
- 列表页每个环境入口只展示并跳转到该 Channel 的最新 Release

示例：

```text
Android
  xx app
    测试环境    -> Android / xx app / 测试环境 最新包详情页
    正式环境    -> Android / xx app / 正式环境 最新包详情页
    预发布环境  -> Android / xx app / 预发布环境 最新包详情页
```

展示规则：

- 每个系统类型作为一个独立分区
- 每个分区展示该系统下存在最新 Release 的 App
- 同一个 App 在同一个系统下存在多个环境时，需要展示多个入口
- 每个环境入口对应一个 `App + Scheme + Channel` 组合
- 没有应用的系统分区默认不展示，避免空区块占位
- 分区内 App 默认按最新发布时间倒序排列
- App 内环境入口默认按最新发布时间倒序排列
- 底层使用 Channel 的 `device_type` 作为系统类型来源
- 底层使用 Scheme 表示环境，例如测试环境、正式环境、预发布环境
- 环境名称直接使用 Scheme 名称
- 列表页不展开展示历史 Release，历史 Release 只在下载详情页中展示
- 已归档 App 不隐藏，仍然在聚合页展示；详情页中按归档状态禁用安装/下载按钮或展示归档提示

数据来源：

- `App`
- `Scheme`
- `Channel`
- `Release`

用户界面展示为系统分区下的 App 和环境入口；实现上以 Channel 作为下载入口的数据边界，因为当前密码、系统类型和 Release 历史都绑定在 Channel 上。

## Channel 概念说明

`Channel` 在这个项目里可以理解为 App 的一个分发通道或下载渠道。

当前数据关系是：

```text
App -> Scheme -> Channel -> Release
```

各层含义：

- `App`：应用本身，例如某个业务 App
- `Scheme`：应用的构建类型或环境，例如测试环境、正式环境、预发布环境
- `Channel`：某个环境下的具体系统分发通道，记录平台类型、访问密码、下载链接标识、包名匹配规则等
- `Release`：某一次上传的具体安装包版本

这次公开下载页里，`Channel` 主要负责：

- 判断系统类型：`iOS`、`Android`、`HarmonyOS`、`macOS`、`Windows`、`Linux`
- 判断是否需要访问密码
- 找到该通道下的最新版本和历史版本
- 生成对应 Release 的下载页地址

所以用户看到的是“按系统分组后的 App + 环境入口”，代码实现会通过 `Scheme + Channel` 找到每个 App 在对应系统、对应环境下的可下载版本。

### 2. 下载详情页

地址：

```text
/download_apps/:channel_id/releases/:id
```

展示内容：

- App 图标
- App 名称
- 版本号 `release_version`
- 构建号 `build_version`
- 二维码，二维码扫描后进入公开下载详情页
- 安装按钮
- 下载按钮
- 更新说明 `changelog`
- 历史记录

历史记录：

- 只展示同一个 Channel 下的最近版本
- 也就是只展示同一个系统、同一个 App、同一个环境下的历史包
- 当前版本高亮
- 点击历史记录跳转到对应 Release 下载页

示例：

- 用户从 `Android / xx app / 测试环境` 入口进入详情页
- 页面只展示 `Android / xx app / 测试环境` 下的最新包
- 历史记录也只展示 `Android / xx app / 测试环境` 下的历史 Release
- 不混入 `Android / xx app / 正式环境` 或其他系统的 Release

### 3. 密码访问页

如果 Channel 设置了 `password`，且当前浏览器没有通过校验：

- 只展示 App 基本信息和密码输入框
- 提交密码后写入现有 cookie
- 校验成功后跳回下载详情页
- 校验失败展示错误信息

复用现有逻辑：

- `ReleaseAuth`
- `release.password_match?`
- `release.cookie_password_matched?`

## 低耦合设计原则

公开下载模块尽量独立出来，不直接改造现有后台发布页、渠道页和下载页。

核心原则：

- 公开页面使用独立 controller、layout、views、helper、service 和 CSS
- 只复用稳定的领域模型和通用方法，例如 `App`、`Scheme`、`Channel`、`Release`、`ReleaseAuth`、`Release#download_url`、`Release#install_url`
- 不复用现有 `app/views/releases/*` 页面结构，避免把后台管理页的导航、权限、面包屑和管理按钮带入公开页
- 二维码使用公开下载页专用 controller，二维码内容指向 `/download_apps/...`，不改现有发布页二维码
- 查询聚合逻辑放到独立 service，避免 controller 和 view 直接堆复杂查询
- 样式使用独立命名空间，避免污染现有后台页面样式
- 路由和前端样式入口是必要修改，其余尽量新增文件

## 文件改动计划

### 新增控制器

```text
app/controllers/public_downloads_controller.rb
app/controllers/public_downloads/qrcodes_controller.rb
```

职责：

- `index`：展示所有可下载应用，先按系统类型分组，再显示对应系统下的 App 和环境入口
- `show`：展示单个 Release 下载页
- `auth`：处理访问密码
- `public_downloads/qrcodes#show`：生成公开下载页二维码，二维码内容指向公开下载详情页

`index` 查询结果建议按以下系统类型聚合：

```ruby
%w[ios android harmonyos macos windows linux]
```

页面展示名称使用：

```text
iOS
Android
HarmonyOS
macOS
Windows
Linux
```

每个系统分区内的数据结构建议按以下层级组织：

```text
system_type
  app
    environment/scheme
      channel
      latest_release
```

其中详情页路由里的 `channel_id` 可以唯一定位到某个系统、某个 App、某个环境的下载入口。

### 新增 Service

```text
app/services/public_downloads/catalog_builder.rb
```

职责：

- 查询存在 Release 的 Channel
- 按 `iOS`、`Android`、`HarmonyOS`、`macOS`、`Windows`、`Linux` 聚合
- 每个系统下按 App 分组
- 每个 App 下按 Scheme 名称展示环境入口
- 每个环境入口只取当前 Channel 的最新 Release
- 保留已归档 App

建议输出结构：

```text
[
  {
    key: "android",
    name: "Android",
    apps: [
      {
        app: app,
        environments: [
          {
            scheme: scheme,
            channel: channel,
            latest_release: release
          }
        ]
      }
    ]
  }
]
```

### 新增 Helper

```text
app/helpers/public_downloads_helper.rb
```

职责：

- 公开页平台名称、环境入口文案、访问状态文案
- 下载按钮和安装按钮状态判断
- 归档 App 提示展示
- 更新说明和历史记录展示辅助方法

不把这些展示辅助逻辑放进 `ApplicationHelper` 或 `AppsHelper`，避免扩大共享 helper 的职责。

### 新增 Layout

```text
app/views/layouts/public_download.html.slim
```

职责：

- 加载 Vite CSS / JS
- 加载 favicon、csrf、viewport 等基础标签
- 渲染公开页面主体
- 保留必要的 flash / modal frame
- 不渲染后台导航、侧边栏、面包屑、footer 管理入口

### 新增视图

```text
app/views/public_downloads/index.html.slim
app/views/public_downloads/show.html.slim
app/views/public_downloads/_password_auth.html.slim
app/views/public_downloads/_release_history.html.slim
app/views/public_downloads/_app_card.html.slim
app/views/public_downloads/_environment_entry.html.slim
app/views/public_downloads/_download_actions.html.slim
app/views/public_downloads/_changelog.html.slim
```

职责：

- `index`：公开聚合列表页
- `show`：公开下载详情页
- `_password_auth`：公开页专用密码输入
- `_release_history`：当前 Channel 下的历史记录
- `_app_card`：系统分区内的 App 卡片
- `_environment_entry`：Scheme 环境入口
- `_download_actions`：安装 / 下载按钮
- `_changelog`：更新说明

不直接渲染 `app/views/releases/*` 下的 partial。

### 新增前端样式

```text
app/frontend/stylesheets/public_downloads.css
```

并在：

```text
app/frontend/stylesheets/application.tailwind.css
```

引入新样式。

样式要求：

- 所有选择器统一挂在 `.public-downloads` 命名空间下
- 不覆盖 `.card`、`.app-detail`、`.action-buttons` 等现有后台页面通用类
- 移动端优先，桌面端增强布局密度
- 前端实现需要参考 `docs/public-downloads-static/styles.css` 的视觉变量、组件尺寸、圆角、阴影、按钮、标签、表格和响应式规则
- 生产代码可以复用静态稿里的 class 命名方向，例如 `.public-downloads__catalog-*`、`.public-downloads__canvas-app-*`、`.public-downloads__canvas-btn-*`
- 静态稿中的示例数据只用于说明视觉效果，生产页面所有文案、版本、时间、密码状态、历史记录和下载链接都来自 Rails 数据

### JS 复用策略

优先不新增 JS controller，复用现有：

```text
app/frontend/javascript/controllers/release_download_controller.js
```

用途：

- iOS / macOS 下安装按钮显示
- iOS 下隐藏直接下载按钮
- 安装中状态切换

只有在公开页需要独立交互且现有 controller 无法表达时，才新增：

```text
app/frontend/javascript/controllers/public_download_controller.js
```

如果新增，也只服务 `.public-downloads` 页面，不改现有 `release_download_controller.js`。

### 必要修改文件

```text
config/routes.rb
app/frontend/stylesheets/application.tailwind.css
```

修改内容：

- `config/routes.rb`：新增 `/download_apps`、详情页、密码提交、公开二维码路由
- `application.tailwind.css`：引入 `public_downloads.css`

### 尽量不修改的文件

以下文件不作为本功能的主要修改对象，除非发现必须修复的兼容问题：

```text
app/controllers/releases_controller.rb
app/controllers/channels_controller.rb
app/controllers/download/releases_controller.rb
app/controllers/releases/qrcode_controller.rb
app/views/releases/*
app/views/channels/*
app/views/layouts/application.html.slim
app/helpers/application_helper.rb
app/helpers/apps_helper.rb
app/models/app.rb
app/models/scheme.rb
app/models/channel.rb
app/models/release.rb
```

原因：

- 这些文件承载现有后台页面或核心领域模型
- 公开下载模块通过新增文件和稳定接口接入即可
- 避免让公开页面需求影响后台发布管理流程

## 依赖边界

允许复用：

- `ReleaseAuth`：复用现有 Channel 密码 cookie 逻辑
- `Release#download_url`：复用现有下载入口
- `Release#install_url`：复用现有 iOS 安装入口
- `Release#array_changelog`：复用更新说明解析
- `AppsHelper#app_icon`：如公开页图标展示需求一致，可以复用；如样式差异明显，则在 `PublicDownloadsHelper` 中封装
- `release-download` Stimulus controller：复用安装按钮状态
- `Qrcode` concern：公开二维码 controller 可以 include 该 concern，但二维码内容必须由公开详情页 URL 生成

禁止直接依赖：

- 不调用 `ReleasesController`、`ChannelsController` 的 action 或 before_action
- 不渲染 `app/views/releases/*` 和 `app/views/channels/*` 下的 partial
- 不复用后台 layout `application.html.slim`
- 不把公开页专用展示逻辑写入 `ApplicationHelper`
- 不修改 `ReleaseUrl#release_url` 或现有二维码 URL 生成逻辑
- 不修改现有下载控制器的密码跳转逻辑；公开页 auth 只负责公开页面自己的访问流程

## 权限和访问规则

公开模块不要求登录。

访问规则：


| 场景               | 行为               |
| ---------------- | ---------------- |
| Channel 无密码      | 直接进入下载页          |
| Channel 有密码，未验证  | 展示密码输入页          |
| Channel 有密码，密码正确 | 写 cookie 并进入下载页  |
| Channel 有密码，密码错误 | 留在密码页并提示错误       |
| Release 文件不存在    | 展示不可下载状态         |
| App 已归档          | 不隐藏，继续展示；下载详情页禁用安装/下载按钮或展示归档提示 |


## 设计稿参考说明

本功能前端界面以以下静态稿为主要参考：

```text
docs/public-downloads-static/index.html
docs/public-downloads-static/detail.html
docs/public-downloads-static/password.html
docs/public-downloads-static/spec.html
docs/public-downloads-static/styles.css
docs/public-downloads-static/canvas-qrcode.svg
```

静态稿用途：

- `index.html`：应用列表页视觉参考，对应 `/download_apps`
- `detail.html`：下载详情页视觉参考，对应 `/download_apps/:channel_id/releases/:id`
- `password.html`：密码访问页视觉参考，对应有密码 Channel 的访问验证状态
- `spec.html`：设计规范说明，不需要做成生产页面
- `styles.css`：公开下载页 CSS 的主要视觉来源
- `canvas-qrcode.svg`：二维码占位图，生产页面必须改为公开二维码接口生成的真实二维码

实现时应遵循静态稿的整体风格：现代、简洁、企业级 App 下载中心，不出现后台侧边栏、管理按钮、面包屑、上传入口、删除入口等管理界面元素。

静态稿中的顶部导航是为了在设计稿之间切换，生产页面不需要渲染“应用列表 / 下载详情 / 密码访问 / 设计规范”这些设计稿导航链接。生产页面 layout 只保留公开下载中心所需的最小品牌信息、页面标题或返回列表入口。

## 静态稿到视图映射

| 静态稿 | 生产视图 | 说明 |
| --- | --- | --- |
| `index.html` | `app/views/public_downloads/index.html.slim` | 渲染系统 Tab、App 卡片、环境入口 |
| App 卡片片段 | `_app_card.html.slim` | 展示图标、名称、平台、版本、构建号、更新时间、访问状态 |
| 环境按钮片段 | `_environment_entry.html.slim` | 每个 Scheme + Channel 的最新 Release 入口 |
| `detail.html` | `app/views/public_downloads/show.html.slim` | 渲染 App 头部、二维码、操作按钮、更新说明、历史记录 |
| 二维码与按钮区域 | `_download_actions.html.slim` | 二维码指向公开详情页；安装 / 下载按钮按状态禁用 |
| 更新说明区域 | `_changelog.html.slim` | 使用 `Release#array_changelog` |
| 历史版本表格 | `_release_history.html.slim` | 仅展示当前 Channel 下的历史 Release |
| `password.html` | `_password_auth.html.slim` | 密码输入、错误提示、基本 App 信息 |
| `spec.html` | 不落地为生产页面 | 只作为视觉规范参考 |

## 前端界面落地要求

### 列表页

列表页需要按照静态稿的“系统 Tab + App 卡片 + 环境入口按钮”组织信息。

实现要求：

- 页面根节点使用 `.public-downloads.public-downloads--catalog`
- 外层内容宽度参考静态稿，最大宽度约 `960px`，移动端左右留出安全间距
- 系统分区展示顺序固定为 Android、iOS、HarmonyOS、macOS、Windows、Linux
- 静态稿包含空平台示例，生产页面默认不展示没有 Release 的系统；如果所有系统都没有可下载应用，再展示全页空状态
- Tab 列表只输出存在可下载应用的系统，避免点击后出现空面板
- App 卡片需要包含图标、App 名称、平台标签、最新版本号、构建号、更新时间、公开 / 需密码状态
- 同一 App 在同一系统下有多个环境时，在卡片底部展示多个环境按钮
- 环境按钮文案直接使用 Scheme 名称，例如“正式环境”“测试环境”“预发布环境”
- 点击环境按钮进入该 Channel 最新 Release 的公开下载详情页
- 已归档 App 仍显示，但卡片需要有“已归档”状态标签或弱化状态

### 下载详情页

详情页需要按照静态稿的“App 信息头部 + 二维码与操作按钮 + 更新说明 + 历史版本表格”组织。

实现要求：

- 页面根节点使用 `.public-downloads.public-downloads--canvas-detail`
- 顶部展示 App 图标、App 名称、平台标签、环境标签、版本号、构建号、发布时间
- 二维码区域展示公开详情页 URL 生成的二维码，不使用后台 Release 二维码
- 操作区展示文件元信息，例如平台、文件大小、文件扩展名
- 安装按钮复用现有 `release-download` controller，保持 iOS / macOS 的安装行为
- iOS 下直接下载按钮按现有逻辑隐藏；其他平台保留下载文件按钮
- App 已归档或 Release 文件不存在时，安装 / 下载按钮禁用，并展示明确提示
- 更新说明使用静态稿中的圆点列表视觉
- 历史版本使用静态稿中的表格视觉，当前版本高亮，其他版本可点击跳转
- 历史版本只取当前 Channel，不混入其他系统或环境

### 密码访问页

密码访问页需要按照静态稿的居中验证卡片实现。

实现要求：

- 页面根节点使用 `.public-downloads.public-downloads--canvas-password`
- 顶部展示 App 图标、App 名称、平台标签、环境标签、版本号、构建号
- 验证卡片包含标题、说明、密码输入框和确认按钮
- 密码错误时在卡片内展示错误提示，不跳到后台页面
- 密码正确后写入现有 Channel 认证 cookie，并跳回公开下载详情页

### 视觉规范

实现时优先复用静态稿的视觉规则：

- 页面背景使用浅灰，内容面使用白色
- 卡片圆角保持 6 到 8px，不使用后台页面的卡片组件
- 主色使用静态稿中的蓝紫强调色，成功状态使用绿色，警告 / 密码 / 归档状态使用黄色系
- App 图标优先展示 Release 上传的真实 icon；没有 icon 时使用静态稿中的字母占位图标样式
- 按钮分 primary / secondary / ghost 三类，主操作使用 primary
- 移动端按钮和输入框触控高度不小于 40px，关键操作尽量接近 44px
- 桌面端详情页二维码与操作按钮左右并列；移动端上下堆叠并居中
- 历史版本表格移动端允许横向滚动，不能挤压文字导致重叠

## UI 方向

列表页：

- 简洁应用商店风格
- 卡片式 App 列表
- 适配移动端扫码和手机直接访问

下载页：

- 顶部突出 App 图标、名称、版本
- 中间展示二维码和操作按钮
- 下方展示更新说明和历史记录
- 不展示后台导航、侧边栏、管理入口

## 实施步骤

1. 新增公开路由
2. 新增 `PublicDownloadsController`
3. 实现应用列表查询逻辑，先按系统类型聚合，再展示对应系统下的 App 和环境入口
4. 实现下载详情查询逻辑，并限定在当前 Channel 范围内
5. 接入现有密码校验逻辑
6. 新增 `PublicDownloads::CatalogBuilder`，隔离聚合查询
7. 新增公开页面专用 layout 和 Slim 模板
8. 新增公开下载页专用二维码 controller
9. 新增 `app/frontend` 样式模块并用 `.public-downloads` 命名空间隔离
10. 复用安装/下载按钮现有行为
11. 增加历史记录跳转
12. 补充控制器或系统测试

## 测试重点

- 无密码 Channel 可以直接访问下载页
- 有密码 Channel 首次访问会进入密码页
- 密码错误会提示错误
- 密码正确后可以访问下载页和下载文件
- 历史记录跳转后仍遵守密码访问规则
- `/download_apps` 不需要登录
- 聚合页按 iOS、Android、HarmonyOS、macOS、Windows、Linux 分区展示，并在每个系统分区下显示对应 App 和环境入口
- 同一个系统、同一个 App 有测试环境、正式环境、预发布环境时，应展示 3 个独立入口
- 点击测试环境入口后，只进入该系统、该 App、该测试环境的详情页
- 详情页历史记录只展示当前系统、当前 App、当前环境下的 Release
- 没有 Release 的 Channel 不出现在聚合页中
- 已归档 App 仍然出现在聚合页中
- 环境入口名称直接使用 Scheme 名称
- 二维码扫描后进入公开下载详情页，而不是现有后台发布页
- 移动端页面布局正常
- iOS 安装按钮仍能使用现有 plist 安装逻辑

## 测试文件建议

```text
spec/controllers/public_downloads_controller_spec.rb
spec/controllers/public_downloads/qrcodes_controller_spec.rb
spec/services/public_downloads/catalog_builder_spec.rb
```

测试边界：

- controller spec 验证访问、密码、跳转和页面状态
- qrcode controller spec 验证二维码响应成功，内容来源为公开详情页 URL
- service spec 验证系统分组、App 分组、Scheme 环境入口、最新 Release 选择、已归档 App 保留

## 建议

建议聚合页用户界面按“系统 -> App -> 环境入口”展示；实现层以 Channel 作为下载入口边界，因为当前密码、平台和 Release 都绑定在 Channel 上，且 Channel 能唯一约束详情页和历史记录范围。
