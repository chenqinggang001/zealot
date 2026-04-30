# frozen_string_literal: true

class PublicDownloads::QrcodesController < ApplicationController
  include Qrcode

  before_action :set_channel
  before_action :set_release

  def show
    render_qrcode(public_download_app_release_url(channel_id: @channel, id: @release))
  end

  private

  def set_channel
    @channel = Channel.friendly.find(params[:channel_id])
  end

  def set_release
    @release = @channel.releases.find(params[:id])
  end
end
