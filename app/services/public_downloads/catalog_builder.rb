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
      grouped_apps = channels.each_with_object({}) do |channel, groups|
        system_key = system_key_for(channel)
        next unless SYSTEM_KEYS.include?(system_key)

        scheme = channel.scheme
        app = scheme&.app
        next unless app

        groups[system_key] ||= {}
        groups[system_key][app.id] ||= { app: app, environments: [] }
        groups[system_key][app.id][:environments] << {
          scheme: scheme,
          channel: channel,
          latest_release: latest_releases_by_channel[channel.id],
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

    def channels
      @channels ||= Channel
        .where(device_type: supported_device_types)
        .includes(scheme: :app)
    end

    def supported_device_types
      @supported_device_types ||= Channel.device_types.slice(*SYSTEM_KEYS).values
    end

    def latest_releases_by_channel
      @latest_releases_by_channel ||= Release
        .where(id: latest_release_ids)
        .index_by(&:channel_id)
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

      apps_by_id.values.filter_map do |app_entry|
        environments = sorted_environments(app_entry[:environments])
        latest_release = latest_release_for(environments)
        next if latest_release.blank?

        {
          app: app_entry[:app],
          latest_release: latest_release,
          environments: environments,
        }
      end.sort_by { |app_entry| release_sort_key(app_entry[:latest_release]) }
    end

    def sorted_environments(environments)
      environments.sort_by do |environment|
        release = environment[:latest_release]
        scheme = environment[:scheme]
        channel = environment[:channel]

        [
          release.blank? ? 1 : 0,
          *release_sort_key(release),
          scheme&.name.to_s,
          channel&.id.to_i,
        ]
      end
    end

    def latest_release_for(environments)
      environments.filter_map { |environment| environment[:latest_release] }
                  .min_by { |release| release_sort_key(release) }
    end

    def release_sort_key(release)
      return [0, 0] if release.blank?

      [
        -release.created_at.to_f,
        -release.id,
      ]
    end
  end
end
