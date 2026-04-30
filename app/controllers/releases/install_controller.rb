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

  def token
    @release = Release.version_by_channel(params[:channel_id], params[:release_id])
    unless helpers.logged_in_or_without_auth?(@release)
      return respond_to_unauthorized_token_request
    end

    install_url = @release.install_url(token: install_manifest_download_token)
    respond_to do |format|
      format.html { redirect_to install_url, allow_other_host: true }
      format.json { render json: { install_url: install_url } }
    end
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

  def respond_to_unauthorized_token_request
    redirect_url = channel_release_url(@release.channel, @release, back_url: @release.release_url)
    respond_to do |format|
      format.html { redirect_to redirect_url }
      format.json do
        render json: {
          error: t('releases.messages.errors.invalid_password'),
          redirect_url: redirect_url
        }, status: :unauthorized
      end
    end
  end

  def render_not_found_entity_response
    render xml: { error: t('.not_found') }, status: :not_found
  end
end
