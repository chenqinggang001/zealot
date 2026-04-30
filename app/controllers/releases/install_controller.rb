# frozen_string_literal: true

class Releases::InstallController < ApplicationController

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    @release = Release.version_by_channel(params[:channel_id], params[:release_id])
    unless authorized_install_manifest?
      return redirect_to channel_release_path(@release.channel, @release, back_url: @release.release_url)
    end

    @download_token = install_manifest_download_token
    render content_type: 'text/xml', layout: false
  end

  private

  def authorized_install_manifest?
    helpers.logged_in_or_without_auth?(@release) || valid_download_token?
  end

  def install_manifest_download_token
    return if @release.channel.password.blank?

    valid_download_token? ? params[:token] : @release.download_token
  end

  def valid_download_token?
    return @valid_download_token if defined?(@valid_download_token)

    @valid_download_token = @release.valid_download_token?(params[:token])
  end

  def render_not_found_entity_response
    render xml: { error: t('.not_found') }, status: :not_found
  end
end
