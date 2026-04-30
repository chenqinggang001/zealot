# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Releases::InstallController, type: :controller do
  render_views

  describe 'GET #show' do
    let(:channel) { instance_double(Channel, password: nil) }

    it 'uses the direct package download URL in the manifest' do
      release = instance_double(
        Release,
        id: 7,
        to_param: '7',
        channel: channel,
        download_filename: 'demo.ipa',
        icon: nil,
        bundle_id: 'com.example.demo',
        release_version: '1.0.0',
        app_name: 'Demo',
        cookie_password_matched?: true
      )

      allow(Release).to receive(:version_by_channel).with('ios', '7').and_return(release)

      get :show, params: { channel_id: 'ios', release_id: '7' }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/xml')
      expect(response.body).to include(filename_download_release_url(release, 'demo.ipa'))
      expect(response.body).not_to include(download_release_url(release))
    end

    it 'keeps the signed download token in protected iOS manifests' do
      token = 'signed-token'
      channel = instance_double(Channel, password: 'secret')
      release = instance_double(
        Release,
        id: 7,
        to_param: '7',
        channel: channel,
        download_filename: 'demo.ipa',
        icon: nil,
        bundle_id: 'com.example.demo',
        release_version: '1.0.0',
        app_name: 'Demo',
        cookie_password_matched?: false
      )

      allow(release).to receive(:valid_download_token?).with(token).and_return(true)
      allow(Release).to receive(:version_by_channel).with('ios', '7').and_return(release)

      get :show, params: { channel_id: 'ios', release_id: '7', token: token }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(filename_download_release_url(release, 'demo.ipa', token: token))
    end

    it 'redirects protected manifests without a password cookie or token' do
      channel = instance_double(Channel, password: 'secret', to_param: 'ios')
      release = instance_double(
        Release,
        id: 7,
        to_param: '7',
        channel: channel,
        release_url: 'http://test.host/channels/ios/releases/7',
        cookie_password_matched?: false
      )

      allow(release).to receive(:valid_download_token?).with(nil).and_return(false)
      allow(Release).to receive(:version_by_channel).with('ios', '7').and_return(release)

      get :show, params: { channel_id: 'ios', release_id: '7' }

      expect(response).to redirect_to(channel_release_path(channel, release, back_url: release.release_url))
    end
  end

  describe 'GET #token' do
    it 'redirects authorized protected releases to a fresh install URL' do
      token = 'fresh-token'
      channel = instance_double(Channel, password: 'secret')
      release = instance_double(
        Release,
        id: 7,
        channel: channel,
        cookie_password_matched?: true
      )

      allow(release).to receive(:valid_download_token?).with(nil).and_return(false)
      allow(release).to receive(:download_token).and_return(token)
      allow(release).to receive(:install_url).with(token: token).and_return('itms-services://download')
      allow(Release).to receive(:version_by_channel).with('ios', '7').and_return(release)

      get :token, params: { channel_id: 'ios', release_id: '7' }

      expect(response).to redirect_to('itms-services://download')
    end

    it 'returns a fresh install URL as JSON' do
      token = 'fresh-token'
      channel = instance_double(Channel, password: 'secret')
      release = instance_double(
        Release,
        id: 7,
        channel: channel,
        cookie_password_matched?: true
      )

      allow(release).to receive(:valid_download_token?).with(nil).and_return(false)
      allow(release).to receive(:download_token).and_return(token)
      allow(release).to receive(:install_url).with(token: token).and_return('itms-services://download')
      allow(Release).to receive(:version_by_channel).with('ios', '7').and_return(release)

      get :token, params: { channel_id: 'ios', release_id: '7', format: :json }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq('install_url' => 'itms-services://download')
    end

    it 'redirects unauthorized HTML token requests back to the release page' do
      channel = instance_double(Channel, password: 'secret', to_param: 'ios')
      release = instance_double(
        Release,
        id: 7,
        to_param: '7',
        channel: channel,
        release_url: 'http://test.host/channels/ios/releases/7',
        cookie_password_matched?: false
      )

      allow(Release).to receive(:version_by_channel).with('ios', '7').and_return(release)

      get :token, params: { channel_id: 'ios', release_id: '7' }

      expect(response).to redirect_to(channel_release_url(channel, release, back_url: release.release_url))
    end
  end
end
