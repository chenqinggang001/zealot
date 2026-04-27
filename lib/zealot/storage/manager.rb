# frozen_string_literal: true

module Zealot
  module Storage
    module Manager
      module_function

      def cloud_enabled?
        config[:enabled] == true
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError, PG::ConnectionBad
        false
      end

      def config
        Setting.storage_s3.deep_symbolize_keys
      end

      def path_prefix
        config[:path_prefix].to_s.strip.split('/').map(&:strip).reject(&:blank?).join('/')
      end

      def object_key(*parts)
        key_parts = parts.flatten.compact.map { |part| part.to_s.gsub(%r{\A/+|/+\z}, '') }.reject(&:empty?)
        ([path_prefix].reject(&:empty?) + key_parts).join('/')
      end

      def aws_credentials
        { access_key_id: config[:access_key_id], secret_access_key: config[:secret_access_key] }
      end

      def aws_credentials_provider
        Aws::Credentials.new(config[:access_key_id], config[:secret_access_key])
      end

      def aws_options
        {
          endpoint:         config[:endpoint],
          region:           config[:region],
          force_path_style: config[:force_path_style]
        }.compact
      end

      def s3_client
        Aws::S3::Client.new(credentials: aws_credentials_provider, **aws_options)
      end

      def verify!
        s3_client.head_bucket(bucket: config[:bucket])
        :ok
      rescue StandardError => e
        { error: e.class.name, message: e.message }
      end
    end
  end
end
