# frozen_string_literal: true

module ReleaseUrl
  extend ActiveSupport::Concern

  included do
    include Rails.application.routes.url_helpers
  end

  def download_url
    download_release_url(id)
  end

  def install_url(token: nil)
    return download_url unless platform == 'iOS'

    options = {}
    options[:token] = token if token.present?
    ios_url = channel_release_install_url(channel.slug, id, **options)
    encoded_ios_url = ERB::Util.url_encode(ios_url)
    "itms-services://?action=download-manifest&url=#{encoded_ios_url}"
  end

  def release_url
    friendly_channel_release_url(channel, self)
  end

  def qrcode_url(**options)
    channel_release_qrcode_url(channel, self, **options)
  end
end
