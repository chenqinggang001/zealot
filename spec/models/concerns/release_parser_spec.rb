# frozen_string_literal: true

require 'base64'

require 'rails_helper'

RSpec.describe ReleaseParser do
  let(:path_available) { { value: false } }
  let(:png_data) do
    Base64.decode64(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lN0cJQAAAABJRU5ErkJggg=='
    )
  end
  let(:release_class) do
    Class.new do
      include ReleaseParser

      attr_accessor :file, :icon, :name, :bundle_id, :source, :device_type,
                    :release_version, :build_version, :release_type

      def initialize(file)
        @file = file
      end

      def logger
        Rails.logger
      end
    end
  end
  let(:file) do
    flag = path_available

    Class.new do
      define_method(:with_local_path) do |&block|
        flag[:value] = true
        block.call('/tmp/app.apk')
      ensure
        flag[:value] = false
      end
    end.new
  end
  let(:parser) do
    flag = path_available

    Class.new do
      define_method(:name) do
        raise Android::NotFoundError, '/tmp/app.apk' unless flag[:value]

        'Demo'
      end

      def bundle_id
        'com.example.demo'
      end

      def device
        AppInfo::Device::Google::PHONE
      end

      def release_version
        '1.0.0'
      end

      def build_version
        '1'
      end

      def platform
        AppInfo::Platform::ANDROID
      end

      def icons(*)
        []
      end

      def clear!; end
    end.new
  end

  it 'reads parser metadata before the local path block is released' do
    allow(AppInfo).to receive(:parse).with('/tmp/app.apk').and_return(parser)

    release = release_class.new(file)
    release.parse!(nil, 'web')

    expect(release.name).to eq('Demo')
    expect(release.bundle_id).to eq('com.example.demo')
  end

  it 'falls back to HarmonyOS module icon media names' do
    Dir.mktmpdir do |dir|
      write_harmonyos_icon_fixture(dir, 'icon.png')
      parser = harmonyos_parser(dir, 'icon')

      release = release_class.new(file)
      release.parse!(parser, 'web')

      expect(release.icon).to be_present
      expect(File.basename(release.icon.path)).to eq('icon.png')
    ensure
      release&.icon&.close
    end
  end

  it 'matches HarmonyOS start icon filenames case-insensitively' do
    Dir.mktmpdir do |dir|
      write_harmonyos_icon_fixture(dir, 'starticon.png')
      parser = harmonyos_parser(dir, 'startIcon')

      release = release_class.new(file)
      release.parse!(parser, 'web')

      expect(release.icon).to be_present
      expect(File.basename(release.icon.path)).to eq('starticon.png')
    ensure
      release&.icon&.close
    end
  end

  it 'extracts Windows PNG icons directly from PE resources' do
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'app.exe')
      group_icon_data = [0, 1, 1].pack('v3') +
                        [0, 0, 0, 0, 1, 32, png_data.bytesize, 10].pack('C4v2Vv')
      icon_offset = group_icon_data.bytesize
      File.binwrite(file, group_icon_data + png_data)

      parser = windows_parser(file, [
        resource('GROUP_ICON', 1, 0, group_icon_data.bytesize),
        resource('ICON', 10, icon_offset, png_data.bytesize)
      ])

      release = release_class.new(file)
      release.parse!(parser, 'web')

      expect(release.icon).to be_present
      expect(File.binread(release.icon.path, 8)).to eq(ReleaseParser::PNG_SIGNATURE)
    ensure
      release&.icon&.close
    end
  end

  def write_harmonyos_icon_fixture(dir, icon_filename)
    media_dir = File.join(dir, 'resources', 'base', 'media')
    FileUtils.mkdir_p(media_dir)
    File.binwrite(File.join(media_dir, icon_filename), png_data)
  end

  def harmonyos_parser(dir, icon_name)
    Class.new do
      attr_reader :contents

      def initialize(contents, icon_name)
        @contents = contents
        @icon_name = icon_name
      end

      def name
        'Harmony Demo'
      end

      def bundle_id
        'com.example.harmony'
      end

      def source; end

      def device
        AppInfo::Device::Huawei::DEFAULT
      end

      def release_version
        '1.0.0'
      end

      def build_version
        '1'
      end

      def platform
        AppInfo::Platform::HARMONYOS
      end

      def icons
        raise Errno::ENOENT, File.join(contents, 'resources', 'base', 'media', 'app_icon.png')
      end

      def module_info
        {
          'module' => {
            'abilities' => [
              {
                'name' => 'AppAbility',
                'icon' => "$media:#{@icon_name}",
                'startWindowIcon' => "$media:#{@icon_name}"
              }
            ]
          }
        }
      end

      def clear!; end
    end.new(dir, icon_name)
  end

  def resource(type, id, file_offset, size)
    Struct.new(:type, :id, :file_offset, :size).new(type, id, file_offset, size)
  end

  def windows_parser(file, resources)
    Class.new do
      def initialize(file, resources)
        @io = File.open(file, 'rb')
        @resources = resources
      end

      def name
        'Windows Demo'
      end

      def device
        AppInfo::Device::Microsoft::WINDOWS
      end

      def release_version
        '1.0.0'
      end

      def build_version; end

      def platform
        AppInfo::Platform::WINDOWS
      end

      def icons
        []
      end

      def pe
        Struct.new(:resources).new(@resources)
      end

      def clear!
        @io.close
      end

      private

      attr_reader :io
    end.new(file, resources)
  end
end
