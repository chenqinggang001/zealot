# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PublicDownloadsHelper, type: :helper do
  describe '#public_download_section_entries' do
    it 'keeps entries with a released environment and removes fully empty entries' do
      release = instance_double('Release')
      released_entry = { environments: [{ latest_release: release }, { latest_release: nil }] }
      empty_entry = { environments: [{ latest_release: nil }] }

      expect(helper.public_download_section_entries(apps: [released_entry, empty_entry])).to eq([released_entry])
    end
  end

  describe '#public_download_entry_environments' do
    it 'keeps environments without releases so the view can render them disabled' do
      release = instance_double('Release')
      released_environment = { latest_release: release }
      empty_environment = { latest_release: nil }

      expect(
        helper.public_download_entry_environments(environments: [released_environment, empty_environment])
      ).to eq([released_environment, empty_environment])
    end
  end

  describe '#public_download_access_label' do
    it 'reads Active Record model attributes without treating key? as Hash lookup' do
      channel = Channel.new(password: nil)

      expect { helper.public_download_access_label(channel) }.not_to raise_error
      expect(helper.public_download_access_label(channel)).to eq('公开')
    end

    it 'still reads Hash values by symbol or string keys' do
      expect(helper.public_download_access_label({ password: 'secret' })).to eq('需密码')
      expect(helper.public_download_access_label({ 'password' => 'secret' })).to eq('需密码')
    end
  end

  describe '#public_download_datetime_label' do
    it 'formats the full publication timestamp' do
      time = Time.zone.local(2026, 4, 27, 16, 20, 34)

      expect(helper.public_download_datetime_label(time)).to eq('2026-04-27 16:20:34')
    end
  end

  describe '#public_download_qrcode_path' do
    it 'uses the public download dark gray QR theme' do
      release = instance_double('Release', to_param: '12')
      channel = instance_double('Channel', to_param: 'android')

      expect(helper.public_download_qrcode_path(release, channel)).to eq(
        '/download_apps/android/releases/12/qrcode/lg/public_download.svg'
      )
    end
  end
end
