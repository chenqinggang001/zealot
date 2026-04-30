# frozen_string_literal: true

class Download::ReleasesController < ApplicationController
  include CloudStorageDownload

  before_action :set_release

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    # password protected check
    unless authorized_download_request?
      return redirect_to channel_release_path(@release.channel, @release, back_url: @release.download_url)
    end

    return render_not_found_entity_response unless file_exists?(@release.file)

    redirect_to filename_download_release_url(@release, @release.download_filename, **download_token_params)
  end

  def download
    unless authorized_download_request?
      return redirect_to channel_release_path(@release.channel, @release, back_url: @release.download_url)
    end

    # 触发 web_hook
    @release.channel.perform_web_hook('download_events', current_user&.id) unless request.head?

    send_file_or_redirect(@release.file, filename: @release.download_filename)
  end

  private

  def render_not_found_entity_response
    render json: {
      error: t('.not_found')
    }, status: :not_found
  end

  def set_release
    @release = Release.find(params[:id])
  end

  def authorized_download_request?
    helpers.logged_in_or_without_auth?(@release) || valid_download_token?
  end

  def valid_download_token?
    return @valid_download_token if defined?(@valid_download_token)

    @valid_download_token = @release.valid_download_token?(params[:token])
  end

  def download_token_params
    valid_download_token? ? { token: params[:token] } : {}
  end
end
