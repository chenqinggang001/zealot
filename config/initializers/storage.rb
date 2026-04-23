# frozen_string_literal: true

Rails.configuration.to_prepare do
  next unless defined?(CarrierWave::Storage::AWS)

  cloud = begin
    Zealot::Storage::Manager.cloud_enabled?
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError, PG::ConnectionBad
    false
  end

  ApplicationUploader.class_eval do
    storage(cloud ? :aws : :file)

    def aws_bucket
      Zealot::Storage::Manager.config[:bucket]
    end

    def aws_acl
      Zealot::Storage::Manager.config[:object_acl]
    end

    def aws_attributes
      { expires: 1.week.from_now.httpdate }
    end
  end

  CarrierWave.configure do |c|
    c.aws_credentials = -> {
      Zealot::Storage::Manager.aws_credentials.merge(Zealot::Storage::Manager.aws_options)
    }
  end
end
