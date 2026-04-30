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
        channel: channel
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
  end
end
