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

      def aws_credentials
        { access_key_id: config[:access_key_id], secret_access_key: config[:secret_access_key] }
      end

      def aws_options
        {
          endpoint:         config[:endpoint],
          region:           config[:region],
          force_path_style: config[:force_path_style]
        }.compact
      end

      def s3_client
        Aws::S3::Client.new(credentials: Aws::Credentials.new(**aws_credentials), **aws_options)
      end

      def verify!
        s3_client.head_bucket(bucket: config[:bucket])
        :ok
      rescue => e
        { error: e.class.name, message: e.message }
      end
    end
  end
end
