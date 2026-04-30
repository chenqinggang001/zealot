# frozen_string_literal: true

require 'tmpdir'

module ReleaseParser
  extend ActiveSupport::Concern

  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze
  HARMONYOS_ICON_KEYS = %w[icon startWindowIcon].freeze
  HARMONYOS_FALLBACK_ICON_NAMES = %w[
    app_icon
    icon
    startIcon
    starticon
    start_icon
    app_default_icon
    default_app_icon
  ].freeze
  HARMONYOS_ICON_EXTENSIONS = %w[png webp jpg jpeg bmp].freeze

  def parse!(parser, default_source)
    parse_app(parser, default_source)

    self
  end

  private

  def parse_app(parser, default_source)
    parser ||= AppInfo.parse(self.file.path)
    build_metadata(parser, default_source)
    relates_to_devices(parser)
  rescue AppInfo::UnknownFormatError
    # ignore
  rescue StandardError => e
    logger.error e.full_message
  ensure
    parser&.clear! if parser&.respond_to?(:clear!)
  end

  def build_metadata(parser, default_source)
    # iOS, Android only
    self.name ||= parser.name
    self.bundle_id = parser.bundle_id if parser.respond_to?(:bundle_id)
    self.source = default_source if self.source.blank?
    self.device_type = parser.device
    self.release_version = parser.release_version
    self.build_version = parser.build_version
    self.release_type = parser.release_type if release_type.blank? && parser.respond_to?(:release_type)

    icon_file = fetch_icon(parser)
    self.icon = icon_file if icon_file
  end

  def relates_to_devices(parser)
    # Parse UDID list for iOS adhoc app
    if parser.platform == AppInfo::Platform::IOS &&
       parser.release_type == AppInfo::IPA::ExportType::ADHOC && 
       parser.devices.present?

      parser.devices.each do |udid|
        self.devices.find_or_initialize_by(udid: udid)
      end
    end
  end

  def fetch_icon(parser)
    file = case parser.platform
           when AppInfo::Platform::IOS
            return if parser.icons.blank?

            # NOTE: uncrushed_file may be return nil (#1196)
            biggest_icon(parser.icons, file_key: :uncrushed_file) ||
              biggest_icon(parser.icons, file_key: :file)
           when AppInfo::Platform::MACOS
             return if parser.icons.blank?

             biggest_icon(parser.icons[:sets])
           when AppInfo::Platform::ANDROID
            return if parser.icons.blank?

            biggest_icon(parser.icons(exclude: :xml))
           when AppInfo::Platform::WINDOWS
             windows_icon_file(parser)
           when AppInfo::Platform::HARMONYOS
             harmonyos_icon_file(parser)
           end

    File.open(file, 'rb') if file
  end

  def biggest_icon(icons, file_key: :file)
    return if icons.blank?

    icons.max_by { |icon| icon[:dimensions][0] }
         .try(:[], file_key)
  end

  def windows_icon_file(parser)
    file = windows_app_info_icon_file(parser)
    return file if file.present? && File.exist?(file)

    windows_png_icon_file(parser)
  end

  def windows_app_info_icon_file(parser)
    icons = parser.icons
    return if icons.blank?

    biggest_icon(icons)
  rescue StandardError => e
    logger.warn("Unable to fetch Windows icon from app-info: #{e.class}: #{e.message}")
    nil
  end

  def windows_png_icon_file(parser)
    resources = parser.pe.resources || []
    icons = resources.select { |resource| resource.type == 'ICON' }
    return if icons.blank?

    sorted_windows_icon_resources(parser, resources, icons).each do |resource|
      data = windows_resource_data(parser, resource)
      next unless data&.start_with?(PNG_SIGNATURE)

      file = write_temp_icon(data, resource.id, 'png')
      return file if image_file?(file)
    end
  rescue StandardError => e
    logger.warn("Unable to fetch Windows PNG icon from PE resources: #{e.class}: #{e.message}")
    nil
  end

  def sorted_windows_icon_resources(parser, resources, icons)
    icon_by_id = icons.index_by(&:id)
    entries = windows_group_icon_entries(parser, resources)
    return icons.sort_by(&:size).reverse if entries.blank?

    ordered_icons = entries
      .sort_by { |entry| [entry[:width] * entry[:height], entry[:bit_count], entry[:size]] }
      .reverse
      .filter_map { |entry| icon_by_id[entry[:id]] }
    ordered_icons.presence || icons.sort_by(&:size).reverse
  end

  def windows_group_icon_entries(parser, resources)
    resources.select { |resource| resource.type == 'GROUP_ICON' }.flat_map do |resource|
      windows_group_icon_resource_entries(parser, resource)
    end
  end

  def windows_group_icon_resource_entries(parser, resource)
    data = windows_resource_data(parser, resource)
    return [] if data.blank? || data.bytesize < 6

    _reserved, type, count = data.unpack('v3')
    return [] unless type == 1

    count.times.filter_map do |index|
      offset = 6 + (index * 14)
      next if offset + 14 > data.bytesize

      width, height, _colors, _reserved, _planes, bit_count, bytes, id =
        data.byteslice(offset, 14).unpack('C4v2Vv')
      {
        id: id,
        width: width.zero? ? 256 : width,
        height: height.zero? ? 256 : height,
        bit_count: bit_count,
        size: bytes
      }
    end
  end

  def windows_resource_data(parser, resource)
    io = parser.send(:io)
    io.seek(resource.file_offset)
    io.read(resource.size)
  end

  def write_temp_icon(data, id, extension)
    dir = Dir.mktmpdir('zealot-icon-')
    path = File.join(dir, "icon-#{id}.#{extension}")
    File.binwrite(path, data)
    path
  end

  def harmonyos_icon_file(parser)
    file = harmonyos_app_info_icon_file(parser)
    return file if file.present? && File.exist?(file)

    harmonyos_fallback_icon_file(parser)
  end

  def harmonyos_app_info_icon_file(parser)
    icons = parser.icons
    return if icons.blank?

    biggest_icon(icons)
  rescue StandardError => e
    logger.warn("Unable to fetch HarmonyOS icon from app-info: #{e.class}: #{e.message}")
    nil
  end

  def harmonyos_fallback_icon_file(parser)
    parser = harmonyos_entry_parser(parser)
    media_dir = File.join(parser.contents, 'resources', 'base', 'media')
    return unless Dir.exist?(media_dir)

    candidates = harmonyos_icon_names(parser).map(&:downcase)
    media_files = Dir.glob(File.join(media_dir, '*')).select do |file|
      File.file?(file) && HARMONYOS_ICON_EXTENSIONS.include?(File.extname(file).delete_prefix('.').downcase)
    end
    indexed_files = media_files.group_by { |file| File.basename(file, File.extname(file)).downcase }

    candidates.each do |candidate|
      file = indexed_files[candidate]&.find { |entry| image_file?(entry) }
      return file if file
    end
  end

  def harmonyos_entry_parser(parser)
    return parser.default_entry if parser.respond_to?(:default_entry)

    parser
  end

  def harmonyos_icon_names(parser)
    (harmonyos_module_icon_names(parser) + HARMONYOS_FALLBACK_ICON_NAMES).uniq
  end

  def harmonyos_module_icon_names(parser)
    return [] unless parser.respond_to?(:module_info)

    harmonyos_media_names(parser.module_info)
  rescue StandardError => e
    logger.warn("Unable to read HarmonyOS module icon metadata: #{e.class}: #{e.message}")
    []
  end

  def harmonyos_media_names(value, parent_key = nil)
    case value
    when Hash
      value.flat_map { |key, child| harmonyos_media_names(child, key.to_s) }
    when Array
      value.flat_map { |child| harmonyos_media_names(child, parent_key) }
    else
      return [] unless HARMONYOS_ICON_KEYS.include?(parent_key)

      harmonyos_media_name(value)
    end
  end

  def harmonyos_media_name(value)
    name = value.to_s
    name = name.delete_prefix('$media:')
    name = File.basename(name, File.extname(name))
    name.present? ? [name] : []
  end

  def image_file?(file)
    ImageSize.path(file).size.present?
  rescue StandardError
    false
  end
end
