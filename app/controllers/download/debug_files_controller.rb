# frozen_string_literal: true

class Download::DebugFilesController < ApplicationController
  include CloudStorageDownload

  before_action :set_debug_file

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response

  def show
    return render_not_found_entity_response unless file_exists?(@debug_file.file)

    redirect_to filename_download_debug_file_url(@debug_file, @debug_file.download_filename)
  end

  def download
    send_file_or_redirect(@debug_file.file, filename: @debug_file.download_filename)
  end

  private

  def render_not_found_entity_response
    render json: {
      error: t('.not_found')
    }, status: :not_found
  end

  def set_debug_file
    authorize @debug_file = DebugFile.find(params[:id])
  end
end
