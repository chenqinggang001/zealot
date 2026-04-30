# frozen_string_literal: true

module PublicDownloads
  class CatalogBuilder
    SYSTEMS = [
      { key: 'android', name: 'Android' },
      { key: 'ios', name: 'iOS' },
      { key: 'harmonyos', name: 'HarmonyOS' },
      { key: 'macos', name: 'macOS' },
      { key: 'windows', name: 'Windows' },
      { key: 'linux', name: 'Linux' },
    ].freeze

    SYSTEM_KEYS = SYSTEMS.map { |system| system[:key] }.freeze

    def self.call
      new.call
    end

    def call
      grouped_apps = latest_releases.each_with_object({}) do |latest_release, groups|
        channel = latest_release.channel
        next unless channel

        system_key = system_key_for(channel)
        next unless SYSTEM_KEYS.include?(system_key)

        app = channel.scheme.app
        groups[system_key] ||= {}
        groups[system_key][app.id] ||= { app: app, environments: [] }
        groups[system_key][app.id][:environments] << {
          scheme: channel.scheme,
          channel: channel,
          latest_release: latest_release,
        }
      end

      SYSTEMS.filter_map do |system|
        apps = sorted_apps(grouped_apps[system[:key]])
        next if apps.blank?

        {
          key: system[:key],
          name: system[:name],
          apps: apps,
        }
      end
    end

    private

    def latest_releases
      @latest_releases ||= Release
        .where(id: latest_release_ids)
        .includes(channel: { scheme: :app })
    end

    def latest_release_ids
      Release
        .where.not(channel_id: nil)
        .select('MAX(id)')
        .group(:channel_id)
    end

    def system_key_for(channel)
      channel.device_type.to_s.downcase
    end

    def sorted_apps(apps_by_id)
      return [] if apps_by_id.blank?

      apps_by_id.values.map do |app_entry|
        environments = sorted_environments(app_entry[:environments])
        {
          app: app_entry[:app],
          latest_release: environments.first[:latest_release],
          environments: environments,
        }
      end.sort_by { |app_entry| release_sort_key(app_entry[:latest_release]) }
    end

    def sorted_environments(environments)
      environments.sort_by { |environment| release_sort_key(environment[:latest_release]) }
    end

    def release_sort_key(release)
      [
        -release.created_at.to_f,
        -release.id,
      ]
    end
  end
end
