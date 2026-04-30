# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PublicDownloads::CatalogBuilder do
  before do
    allow(RetainedBuildsJob).to receive(:perform_later)
  end

  describe '.call' do
    it 'returns the same catalog as an instance call' do
      expect(described_class.call).to eq(described_class.new.call)
    end
  end

  describe '#call' do
    it 'uses the static system order for every supported system' do
      base_time = Time.zone.local(2026, 1, 1, 12, 0, 0)

      %i[linux windows macos harmonyos ios android].each_with_index do |device_type, index|
        create_released_channel(device_type: device_type, created_at: base_time + index.minutes)
      end

      expect(described_class.new.call.map { |section| section[:key] }).to eq(
        %w[android ios harmonyos macos windows linux]
      )
    end

    it 'groups released channels by system and keeps every app environment entry' do
      base_time = Time.zone.local(2026, 1, 1, 12, 0, 0)

      android_app = create_app_record(name: 'Android App')
      production_scheme = create_scheme(android_app, name: 'Production')
      beta_scheme = create_scheme(android_app, name: 'Beta')
      production_channel = create_channel(production_scheme, name: 'Enterprise', device_type: :android)
      beta_channel = create_channel(beta_scheme, name: 'Internal', device_type: :android)
      empty_scheme = create_scheme(android_app, name: 'Empty')
      empty_channel = create_channel(empty_scheme, name: 'No Releases', device_type: :android)
      create_channel(create_scheme(android_app, name: 'Linux'), name: 'Linux Empty', device_type: :linux)

      old_production_release = create_release(
        production_channel,
        release_version: '1.0.0',
        build_version: '10',
        created_at: base_time - 4.hours
      )
      latest_production_release = create_release(
        production_channel,
        release_version: '1.1.0',
        build_version: '11',
        created_at: base_time - 1.hour
      )
      beta_release = create_release(
        beta_channel,
        release_version: '1.0.0',
        build_version: '20',
        created_at: base_time - 2.hours
      )

      archived_app = create_app_record(name: 'Archived App', archived: true)
      archived_scheme = create_scheme(archived_app, name: 'Production')
      archived_channel = create_channel(archived_scheme, name: 'Enterprise', device_type: :android)
      archived_release = create_release(
        archived_channel,
        release_version: '9.0.0',
        build_version: '90',
        created_at: base_time
      )

      ios_app = create_app_record(name: 'iOS App')
      ios_channel = create_channel(create_scheme(ios_app, name: 'Production'), name: 'App Store', device_type: :ios)
      ios_release = create_release(
        ios_channel,
        release_version: '2.0.0',
        build_version: '200',
        created_at: base_time - 3.hours
      )

      harmonyos_app = create_app_record(name: 'HarmonyOS App')
      harmonyos_scheme = create_scheme(harmonyos_app, name: 'Production')
      harmonyos_channel = create_channel(harmonyos_scheme, name: 'App Gallery', device_type: :harmonyos)
      harmonyos_release = create_release(
        harmonyos_channel,
        release_version: '3.0.0',
        build_version: '300',
        created_at: base_time - 5.hours
      )

      catalog = described_class.new.call

      expect(catalog.map { |section| section[:key] }).to eq(%w[android ios harmonyos])
      expect(catalog.map { |section| section[:name] }).to eq(['Android', 'iOS', 'HarmonyOS'])

      android_section = find_section(catalog, 'android')
      expect(android_section[:apps].map { |entry| entry[:app] }).to eq([archived_app, android_app])
      expect(android_section[:apps].map { |entry| entry[:latest_release] }).to eq(
        [archived_release, latest_production_release]
      )

      archived_entry = find_app_entry(android_section, archived_app)
      expect(archived_entry[:app]).to be_archived
      expect(archived_entry[:environments].pluck(:channel)).to eq([archived_channel])

      android_entry = find_app_entry(android_section, android_app)
      expect(android_entry[:latest_release]).to eq(latest_production_release)
      expect(android_entry[:environments].map { |environment| environment[:scheme] }).to eq(
        [production_scheme, beta_scheme]
      )
      expect(android_entry[:environments].map { |environment| environment[:channel] }).to eq(
        [production_channel, beta_channel]
      )
      expect(android_entry[:environments].map { |environment| environment[:latest_release] }).to eq(
        [latest_production_release, beta_release]
      )
      expect(android_entry[:environments].map { |environment| environment[:latest_release] }).not_to include(
        old_production_release
      )
      expect(android_entry[:environments].map { |environment| environment[:channel] }).not_to include(empty_channel)

      expect(find_section(catalog, 'ios')[:apps].first).to include(app: ios_app, latest_release: ios_release)
      expect(find_section(catalog, 'harmonyos')[:apps].first).to include(
        app: harmonyos_app,
        latest_release: harmonyos_release
      )
      expect(find_section(catalog, 'linux')).to be_nil
    end

    it 'selects the latest release by id to match Channel#latest_release' do
      base_time = Time.zone.local(2026, 1, 1, 12, 0, 0)
      app = create_app_record(name: 'Latest By Id')
      channel = create_channel(create_scheme(app, name: 'Production'), name: 'Enterprise', device_type: :android)
      create_release(channel, release_version: '1.0.0', build_version: '10', created_at: base_time)
      newest_by_id = create_release(
        channel,
        release_version: '1.1.0',
        build_version: '11',
        created_at: base_time - 1.day
      )

      environment = described_class.new.call.dig(0, :apps, 0, :environments, 0)

      expect(channel.latest_release).to eq(newest_by_id)
      expect(environment[:latest_release]).to eq(newest_by_id)
    end

    it 'does not instantiate historical releases while selecting channel latest releases' do
      base_time = Time.zone.local(2026, 1, 1, 12, 0, 0)
      app = create_app_record(name: 'Bounded Latest')
      channel = create_channel(create_scheme(app, name: 'Production'), name: 'Enterprise', device_type: :android)
      create_release(channel, release_version: '1.0.0', build_version: '10', created_at: base_time)
      create_release(channel, release_version: '1.1.0', build_version: '11', created_at: base_time + 1.hour)

      instantiated_release_count = 0
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        instantiated_release_count += payload[:record_count] if payload[:class_name] == 'Release'
      end

      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(callback, 'instantiation.active_record') do
          described_class.new.call
        end
      end

      expect(instantiated_release_count).to eq(1)
    end
  end

  def find_section(catalog, key)
    catalog.find { |section| section[:key] == key }
  end

  def find_app_entry(section, app)
    section[:apps].find { |entry| entry[:app] == app }
  end

  def create_app_record(name:, archived: false)
    App.create!(name: name, archived: archived)
  end

  def create_scheme(app, name:)
    app.schemes.create!(name: name)
  end

  def create_channel(scheme, name:, device_type:)
    scheme.channels.create!(name: name, device_type: device_type, bundle_id: '*')
  end

  def create_release(channel, release_version:, build_version:, created_at:)
    release = channel.releases.build(
      release_version: release_version,
      build_version: build_version,
      bundle_id: 'com.example.app',
      changelog: [],
      created_at: created_at,
      updated_at: created_at
    )
    release.save!(validate: false)
    release
  end

  def create_released_channel(device_type:, created_at:)
    app = create_app_record(name: "#{device_type} App")
    scheme = create_scheme(app, name: 'Production')
    channel = create_channel(scheme, name: "#{device_type} Channel", device_type: device_type)
    create_release(channel, release_version: '1.0.0', build_version: '1', created_at: created_at)
    channel
  end
end
