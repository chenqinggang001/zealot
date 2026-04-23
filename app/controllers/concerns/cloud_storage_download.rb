# frozen_string_literal: true

module CloudStorageDownload
  extend ActiveSupport::Concern

  private

  def send_file_or_redirect(carrierwave_file, filename:, disposition: 'attachment')
    if Zealot::Storage::Manager.cloud_enabled?
      redirect_to carrierwave_file.url(
        response_content_disposition: %Q(#{disposition}; filename="#{filename}"),
        expires_in: Zealot::Storage::Manager.config[:presign_expires_in]
      ), allow_other_host: true
    else
      headers['Content-Length'] = carrierwave_file.size.to_s
      send_file carrierwave_file.path, filename: filename, disposition: disposition
    end
  end

  def file_exists?(carrierwave_file)
    if Zealot::Storage::Manager.cloud_enabled?
      carrierwave_file.file&.exists?
    else
      File.exist?(carrierwave_file.path.to_s)
    end
  end
end
