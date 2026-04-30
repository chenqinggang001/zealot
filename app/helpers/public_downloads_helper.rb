# frozen_string_literal: true

module PublicDownloadsHelper
  PLATFORM_ORDER = %w[android ios harmonyos macos windows linux].freeze
  PLATFORM_NAMES = {
    'android' => 'Android',
    'ios' => 'iOS',
    'harmonyos' => 'HarmonyOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux'
  }.freeze

  def public_download_catalog_sections(sections)
    Array(sections).select { |section| public_download_section_entries(section).any? }
                   .sort_by { |section| PLATFORM_ORDER.index(public_download_section_key(section)) || PLATFORM_ORDER.size }
  end

  def public_download_section_key(section)
    key = public_downloads_fetch(section, :key).presence || public_downloads_fetch(section, :name)
    key.to_s.parameterize
  end

  def public_download_section_name(section)
    key = public_download_section_key(section)
    public_downloads_fetch(section, :name).presence || PLATFORM_NAMES.fetch(key, key.to_s.titleize)
  end

  def public_download_section_entries(section)
    Array(public_downloads_fetch(section, :apps)).select do |entry|
      public_download_entry_environments(entry).any? { |environment| public_download_environment_release(environment).present? }
    end
  end

  def public_download_entry_app(entry)
    public_downloads_fetch(entry, :app)
  end

  def public_download_entry_environments(entry)
    Array(public_downloads_fetch(entry, :environments))
  end

  def public_download_environment_scheme(environment)
    public_downloads_fetch(environment, :scheme)
  end

  def public_download_environment_channel(environment)
    public_downloads_fetch(environment, :channel)
  end

  def public_download_environment_release(environment)
    public_downloads_fetch(environment, :latest_release)
  end

  def public_download_environment_name(environment)
    scheme = public_download_environment_scheme(environment)
    public_download_scheme_name(scheme)
  end

  def public_download_scheme_name(scheme)
    public_downloads_fetch(scheme, :name).presence || '默认环境'
  end

  def public_download_entry_release(entry)
    release = public_downloads_fetch(entry, :latest_release)
    return release if release.present?

    public_download_entry_environments(entry).filter_map { |environment| public_download_environment_release(environment) }
                                          .max_by { |release| public_downloads_fetch(release, :id).to_i }
  end

  def public_download_app_name(app)
    public_downloads_fetch(app, :name).presence || 'Unknown App'
  end

  def public_download_release_app(release)
    public_downloads_fetch(release, :app)
  end

  def public_download_release_channel(release)
    public_downloads_fetch(release, :channel)
  end

  def public_download_release_scheme(release)
    public_downloads_fetch(release, :scheme) || public_downloads_fetch(public_download_release_channel(release), :scheme)
  end

  def public_download_app_archived?(app)
    public_downloads_fetch(app, :archived) == true
  end

  def public_download_release_archived?(release)
    public_download_app_archived?(public_download_release_app(release))
  end

  def public_download_platform_label(value)
    raw = if value.respond_to?(:platform)
            value.platform
          else
            public_downloads_fetch(value, :device_type).presence || public_downloads_fetch(value, :name)
          end

    key = raw.to_s.parameterize
    PLATFORM_NAMES.fetch(key, raw.to_s.presence || 'Unknown')
  end

  def public_download_access_label(channel)
    public_download_channel_requires_password?(channel) ? '需密码' : '公开'
  end

  def public_download_access_pill_class(channel)
    if public_download_channel_requires_password?(channel)
      'public-downloads__canvas-pill--lock'
    else
      'public-downloads__canvas-pill--success'
    end
  end

  def public_download_channel_requires_password?(channel)
    public_downloads_fetch(channel, :password).present?
  end

  def public_download_release_icon(release, app:, size: nil)
    classes = ['public-downloads__canvas-app-icon']
    classes << "public-downloads__canvas-app-icon--#{size}" if size.present?

    if (icon_url = public_download_release_icon_url(release))
      content_tag(:div, class: classes.join(' ')) do
        image_tag icon_url,
                  alt: public_download_app_name(app),
                  class: 'public-downloads__canvas-app-icon-image'
      end
    else
      classes << public_download_icon_variant(app)
      content_tag(:div, public_download_app_initial(app), class: classes.join(' '), aria: { hidden: true })
    end
  end

  def public_download_release_icon_url(release)
    return if release.blank?

    icon = public_downloads_fetch(release, :icon)
    return icon.url if icon.respond_to?(:url) && icon.url.present?
    return release.icon_url if release.respond_to?(:icon_url) && release.icon_url.present?
  end

  def public_download_app_initial(app)
    public_download_app_name(app).strip[0].to_s.upcase.presence || '?'
  end

  def public_download_icon_variant(app)
    variants = %w[
      public-downloads__canvas-app-icon--a
      public-downloads__canvas-app-icon--b
      public-downloads__canvas-app-icon--c
    ]
    id = public_downloads_fetch(app, :id).to_i
    variants[id % variants.size]
  end

  def public_download_version_label(release, prefix: false)
    version = public_downloads_fetch(release, :release_version)
    return "#{prefix ? 'v' : ''}#{version}" if version.present?

    fallback = public_downloads_fetch(release, :version)
    fallback.present? ? "版本 #{fallback}" : '未知版本'
  end

  def public_download_build_label(release, prefix: true)
    build = public_downloads_fetch(release, :build_version).presence || public_downloads_fetch(release, :version)
    return '未知构建' if build.blank?

    prefix ? "Build ##{build}" : "##{build}"
  end

  def public_download_compact_version_label(release)
    [public_download_version_label(release, prefix: true), public_download_build_label(release, prefix: false)].compact.join(' · ')
  end

  def public_download_time_ago(time)
    return '未知时间' if time.blank?

    t('public_downloads.time_ago', time: time_ago_in_words(time), default: '%{time}前')
  end

  def public_download_datetime_label(time)
    return '未知时间' if time.blank?

    time.in_time_zone.strftime('%Y-%m-%d %H:%M:%S')
  end

  def public_download_published_label(release)
    "发布于 #{public_download_datetime_label(public_downloads_fetch(release, :created_at))}"
  end

  def public_download_release_has_file?(release)
    return false if release.blank?
    return release.file? if release.respond_to?(:file?)

    public_downloads_fetch(release, :file).present?
  end

  def public_download_ios_release?(release)
    return release.ios? if release.respond_to?(:ios?)

    public_download_platform_label(release) == 'iOS'
  end

  def public_download_cert_expired?(release)
    release.respond_to?(:cert_expired?) && release.cert_expired? == true
  end

  def public_download_install_disabled?(release)
    public_download_release_archived?(release) ||
      !public_download_release_has_file?(release) ||
      public_download_cert_expired?(release)
  end

  def public_download_download_disabled?(release)
    public_download_release_archived?(release) || !public_download_release_has_file?(release)
  end

  def public_download_install_button_label(release)
    return '证书已过期' if public_download_cert_expired?(release)
    return '无法安装' if public_download_install_disabled?(release)

    '立即安装'
  end

  def public_download_download_button_label(release)
    extname = public_download_file_extname(release)
    extname.present? ? "下载 #{extname} 文件" : '下载文件'
  end

  def public_download_release_notices(release)
    notices = []
    notices << 'App 已归档，无法安装或下载。' if public_download_release_archived?(release)
    notices << 'Release 文件不存在，无法安装或下载。' unless public_download_release_has_file?(release)
    notices << 'iOS 证书已过期，无法直接安装。' if public_download_cert_expired?(release)
    notices
  end

  def public_download_file_meta(release)
    parts = [public_download_platform_label(release)]

    if (size = public_downloads_fetch(release, :file_size) || public_downloads_fetch(release, :size)).present?
      parts << number_to_human_size(size)
    end

    parts << public_download_file_extname(release)
    parts.compact_blank.join(' · ')
  end

  def public_download_file_extname(release)
    extname = if release.respond_to?(:file_extname)
                release.file_extname
              else
                File.extname(public_downloads_fetch(release, :file).to_s)
              end

    extname.to_s.delete_prefix('.').upcase.presence
  end

  def public_download_release_path(release, channel = nil)
    channel ||= public_download_release_channel(release)
    public_download_app_release_path(channel_id: channel, id: release)
  end

  def public_download_auth_path(release, channel = nil)
    channel ||= public_download_release_channel(release)
    auth_public_download_app_release_path(channel_id: channel, id: release)
  end

  def public_download_qrcode_path(release, channel = nil)
    channel ||= public_download_release_channel(release)
    public_download_app_release_qrcode_path(channel_id: channel, id: release, size: 'lg', theme: 'public_download')
  end

  def public_download_install_url(release)
    return '#' if release.blank?
    return release.install_url if release.respond_to?(:install_url)

    public_downloads_fetch(release, :install_url).presence || '#'
  end

  def public_download_download_url(release)
    return '#' if release.blank?
    return release.download_url if release.respond_to?(:download_url)

    public_downloads_fetch(release, :download_url).presence || '#'
  end

  def public_download_history_scope_label(channel, release)
    app = public_download_release_app(release)
    scheme = public_download_release_scheme(release)
    [public_download_platform_label(channel), public_download_app_name(app), public_download_scheme_name(scheme)].compact_blank.join(' · ')
  end

  def public_download_current_release?(release, current_release)
    public_downloads_fetch(release, :id).to_s == public_downloads_fetch(current_release, :id).to_s
  end

  def public_download_changelog_items(release)
    return [] unless release.respond_to?(:array_changelog)

    changelog = release.array_changelog
    changelog.is_a?(Hash) ? [changelog] : Array(changelog)
  end

  def public_download_changelog_message(changelog)
    public_downloads_fetch(changelog, :message).to_s
  end

  private

  def public_downloads_fetch(object, key)
    return if object.nil?

    if public_downloads_key_lookup?(object)
      return object[key] if object.key?(key)
      return object[key.to_s] if object.key?(key.to_s)
    end

    return object.public_send(key) if object.respond_to?(key)

    object[key]
  rescue KeyError, NoMethodError, ActiveModel::MissingAttributeError
    nil
  end

  def public_downloads_key_lookup?(object)
    return false unless object.respond_to?(:key?) && object.respond_to?(:[])

    object.method(:key?).arity != 0
  end
end
