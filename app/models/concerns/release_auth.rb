# frozen_string_literal: true

module ReleaseAuth
  extend ActiveSupport::Concern

  COOKIE_KEY_PREFIX = 'zealot_app_channel_auth_'
  DOWNLOAD_TOKEN_PURPOSE = :release_download
  DOWNLOAD_TOKEN_EXPIRES_IN = 30.minutes

  def cookie_password_matched?(cookies)
    channel.password.blank? || cookies[cache_key] == channel.encode_password
  end

  def download_token(expires_in: DOWNLOAD_TOKEN_EXPIRES_IN)
    signed_id(purpose: download_token_purpose, expires_in: expires_in)
  end

  def valid_download_token?(token)
    return false if token.blank?

    self.class.find_signed(token, purpose: download_token_purpose) == self
  end

  def password_match?(cookies, password)
    if channel.password == password
      store_cookie_auth(cookies)
      return true
    end

    false
  end

  private

  def store_cookie_auth(cookies)
    cookies[cache_key] = channel.encode_password
  end

  def cache_key
    @cache_key ||= "#{COOKIE_KEY_PREFIX}#{channel.id}"
  end

  def download_token_purpose
    password_digest = channel.password.present? ? channel.encode_password : 'public'
    "#{DOWNLOAD_TOKEN_PURPOSE}:#{password_digest}"
  end
end
