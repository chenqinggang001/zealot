# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Releases::InstallController, type: :controller do
  render_views

  describe 'GET #show' do
    it 'uses the direct package download URL in the manifest' do
      release = instance_double(
        Release,
        id: 7,
        to_param: '7',
        download_filename: 'demo.ipa',
        icon: nil,
        bundle_id: 'com.example.demo',
        release_version: '1.0.0',
        app_name: 'Demo'
      )

      allow(Release).to receive(:version_by_channel).with('ios', '7').and_return(release)

      get :show, params: { channel_id: 'ios', release_id: '7' }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/xml')
      expect(response.body).to include(filename_download_release_url(release, 'demo.ipa'))
      expect(response.body).not_to include(download_release_url(release))
    end
  end
end
