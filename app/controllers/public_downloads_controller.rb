# frozen_string_literal: true

class PublicDownloadsController < ApplicationController
  layout 'public_download'

  before_action :set_channel, only: %i[show auth]
  before_action :set_release, only: %i[show auth]
  before_action :set_release_context, only: %i[show auth]

  def index
    @title = t('public_downloads.title', default: 'App 下载中心')
    @catalog_sections = PublicDownloads::CatalogBuilder.call
  end

  def show
    @authorized = @release.cookie_password_matched?(cookies)
  end

  def auth
    unless @release.password_match?(cookies, params[:password])
      @authorized = false
      @error_message = t('releases.messages.errors.invalid_password')
      return render :show, status: :unprocessable_entity
    end

    redirect_to public_download_app_release_path(channel_id: @channel, id: @release), status: :see_other
  end

  private

  def set_channel
    @channel = Channel.friendly.find(params[:channel_id])
  end

  def set_release
    @release = @channel.releases.find(params[:id])
  end

  def set_release_context
    @title = @release.app.name
    @history_releases = @channel.releases.order(id: :desc).limit(20)
  end
end
