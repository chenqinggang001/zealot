# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Download::ReleasesController, type: :controller do
  describe 'HEAD #download' do
    it 'returns file metadata without redirecting HEAD requests to object storage' do
      carrierwave_file = instance_double(AppFileUploader, size: 123, url: 'https://storage.example/demo.ipa')
      channel = instance_double(Channel, perform_web_hook: true)
      release = instance_double(
        Release,
        id: 7,
        file: carrierwave_file,
        download_filename: 'demo.ipa',
        channel: channel,
        cookie_password_matched?: true
      )

      allow(Release).to receive(:find).with('7').and_return(release)
      allow(Zealot::Storage::Manager).to receive(:cloud_enabled?).and_return(true)
      expect(channel).not_to receive(:perform_web_hook)
      expect(carrierwave_file).not_to receive(:url)

      head :download, params: { id: '7', filename: 'demo.ipa' }

      expect(response).to have_http_status(:ok)
      expect(response.headers['Location']).to be_blank
      expect(response.headers['Content-Length']).to eq('123')
      expect(response.headers['Content-Disposition']).to eq('attachment; filename="demo.ipa"')
    end

    it 'redirects protected direct file requests without a password cookie or token' do
      carrierwave_file = instance_double(AppFileUploader)
      channel = instance_double(Channel, perform_web_hook: true, to_param: 'ios')
      release = instance_double(
        Release,
        id: 7,
        to_param: '7',
        file: carrierwave_file,
        download_filename: 'demo.ipa',
        download_url: download_release_url(7),
        channel: channel,
        cookie_password_matched?: false
      )

      allow(release).to receive(:valid_download_token?).with(nil).and_return(false)
      allow(Release).to receive(:find).with('7').and_return(release)

      get :download, params: { id: '7', filename: 'demo.ipa' }

      expect(response).to redirect_to(channel_release_path(channel, release, back_url: release.download_url))
    end

    it 'allows protected direct file requests with a valid signed token' do
      token = 'signed-token'
      carrierwave_file = instance_double(AppFileUploader, size: 123, url: 'https://storage.example/demo.ipa')
      channel = instance_double(Channel, perform_web_hook: true)
      release = instance_double(
        Release,
        id: 7,
        file: carrierwave_file,
        download_filename: 'demo.ipa',
        channel: channel,
        cookie_password_matched?: false
      )

      allow(release).to receive(:valid_download_token?).with(token).and_return(true)
      allow(Release).to receive(:find).with('7').and_return(release)
      allow(Zealot::Storage::Manager).to receive(:cloud_enabled?).and_return(true)

      head :download, params: { id: '7', filename: 'demo.ipa', token: token }

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Length']).to eq('123')
    end
  end
end
