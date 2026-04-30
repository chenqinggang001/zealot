# frozen_string_literal: true

namespace :zealot do
  namespace :releases do
    desc 'Zealot | Releases | Reparse release packages and backfill metadata/icon'
    task reparse: :environment do
      dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch('DRY_RUN', false))
      sync = ActiveModel::Type::Boolean.new.cast(ENV.fetch('SYNC', false))
      only_missing_icon = ActiveModel::Type::Boolean.new.cast(ENV.fetch('ONLY_MISSING_ICON', true))
      user_id = ENV['USER_ID'].presence
      platforms = ENV.fetch('PLATFORMS', '').split(',').map { |value| value.strip.downcase }.reject(&:blank?)
      ids = ENV.fetch('IDS', '').split(',').filter_map { |value| Integer(value.strip, exception: false) }
      limit = Integer(ENV.fetch('LIMIT', 0), exception: false).to_i

      scope = Release.includes(channel: { scheme: :app })
      scope = scope.where(id: ids) if ids.present?
      scope = scope.where(icon: [nil, '']) if only_missing_icon
      scope = scope.limit(limit) if limit.positive?

      counters = Hash.new(0)
      scope.find_each do |release|
        counters[:seen] += 1

        platform = release.platform.to_s.downcase
        if platforms.present? && platforms.exclude?(platform)
          counters[:skipped_platform] += 1
          next
        end

        unless release.file&.file&.exists?
          counters[:missing_file] += 1
          puts "skip Release##{release.id}: file missing"
          next
        end

        puts [
          dry_run ? '[dry-run]' : nil,
          sync ? 'perform' : 'enqueue',
          "Release##{release.id}",
          "app=#{release.app.name.inspect}",
          "platform=#{release.platform}",
          "file=#{release.file.identifier.inspect}",
          "icon=#{release.icon.identifier.inspect}"
        ].compact.join(' ')
        counters[:matched] += 1
        next if dry_run

        if sync
          TeardownJob.perform_now(release.id, user_id)
          counters[:performed] += 1
        else
          TeardownJob.perform_later(release.id, user_id)
          counters[:enqueued] += 1
        end
      rescue StandardError => e
        counters[:failed] += 1
        warn "failed Release##{release.id}: #{e.class}: #{e.message}"
      end

      puts [
        'Done.',
        "seen=#{counters[:seen]}",
        "matched=#{counters[:matched]}",
        "enqueued=#{counters[:enqueued]}",
        "performed=#{counters[:performed]}",
        "missing_file=#{counters[:missing_file]}",
        "skipped_platform=#{counters[:skipped_platform]}",
        "failed=#{counters[:failed]}"
      ].join(' ')
    end
  end
end
