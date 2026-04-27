# frozen_string_literal: true

require 'find'
require 'marcel'
require 'set'

namespace :zealot do
  namespace :storage do
    desc 'Zealot | Storage | Migrate local public/uploads files to S3-compatible storage'
    task migrate_uploads: :environment do
      unless Zealot::Storage::Manager.cloud_enabled?
        puts 'S3-compatible storage is not enabled.'
        next
      end

      uploads_root = Rails.root.join('public', 'uploads')
      unless Dir.exist?(uploads_root)
        puts "Uploads directory does not exist: #{uploads_root}"
        next
      end

      cfg = Zealot::Storage::Manager.config
      client = Zealot::Storage::Manager.s3_client
      dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch('DRY_RUN', false))
      force = ActiveModel::Type::Boolean.new.cast(ENV.fetch('FORCE', false))
      counters = Hash.new(0)
      updated_app_ids = Set.new

      object_exists = lambda do |key|
        client.head_object(bucket: cfg[:bucket], key: key)
        true
      rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
        false
      end

      upload_file = lambda do |path|
        counters[:total] += 1
        key = Zealot::Storage::Manager.object_key(Pathname.new(path).relative_path_from(uploads_root.parent).to_s)

        if !force && object_exists.call(key)
          counters[:skipped] += 1
          return
        end

        counters[:uploaded] += 1
        puts "#{dry_run ? '[dry-run] ' : ''}upload #{path} -> s3://#{cfg[:bucket]}/#{key}"
        return if dry_run

        File.open(path, 'rb') do |file|
          options = {
            bucket: cfg[:bucket],
            key: key,
            body: file,
            content_type: Marcel::MimeType.for(Pathname.new(path), name: File.basename(path))
          }
          options[:acl] = cfg[:object_acl] if cfg[:object_acl].present?

          client.put_object(**options)
        end
      end

      find_local_file = lambda do |directory, stored_filename|
        next unless Dir.exist?(directory)

        files = Dir.children(directory)
                   .map { |name| File.join(directory, name) }
                   .select { |path| File.file?(path) }
                   .sort
        next if files.empty?

        if stored_filename.present?
          exact_path = File.join(directory, stored_filename)
          next exact_path if File.file?(exact_path)

          stored_basename = File.basename(stored_filename, '.*')
          basename_match = files.find { |path| File.basename(path, '.*') == stored_basename }
          next basename_match if basename_match
        end

        files.first
      end

      update_column_from_local_file = lambda do |record, column, directory|
        local_file = find_local_file.call(directory, record[column])
        next unless local_file

        filename = File.basename(local_file)
        next if record[column] == filename

        counters[:db_updated] += 1
        puts [
          "#{dry_run ? '[dry-run] ' : ''}update",
          "#{record.class.name}##{record.id}",
          "#{column}:",
          "#{record[column].inspect} -> #{filename.inspect}"
        ].join(' ')
        next if dry_run

        record.update_columns(column => filename, updated_at: Time.current)
        if record.respond_to?(:app_id)
          updated_app_ids << record.app_id
        elsif record.respond_to?(:app)
          updated_app_ids << record.app.id
        end
      end

      Find.find(uploads_root.to_s) do |path|
        next unless File.file?(path)

        upload_file.call(path)
      end

      Release.find_each do |release|
        app_id = release.app.id
        release_root = uploads_root.join('apps', "a#{app_id}", "r#{release.id}")

        update_column_from_local_file.call(release, :file, release_root.join('binary').to_s)
        update_column_from_local_file.call(release, :icon, release_root.join('icons').to_s)
      end

      DebugFile.find_each do |debug_file|
        debug_file_root = uploads_root.join('debug_files', "a#{debug_file.app_id}", "d#{debug_file.id}")
        update_column_from_local_file.call(debug_file, :file, debug_file_root.to_s)
      end

      updated_app_ids.each { |app_id| Rails.cache.delete("app_#{app_id}_recently_release") } unless dry_run

      puts [
        'Done.',
        "total=#{counters[:total]}",
        "uploaded=#{counters[:uploaded]}",
        "skipped=#{counters[:skipped]}",
        "db_updated=#{counters[:db_updated]}",
        "cache_cleared=#{dry_run ? 0 : updated_app_ids.size}"
      ].join(' ')
    end
  end
end
