# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AppsController, type: :controller do
  describe '#destroy_cloud_app_data' do
    it 'lists objects with an app-id-delimited prefix' do
      app = instance_double(App, id: 1)
      client = double('s3_client')
      response = double('list_objects_response', contents: [], is_truncated: false)

      controller.instance_variable_set(:@app, app)
      allow(Zealot::Storage::Manager).to receive(:config).and_return(bucket: 'bucket', path_prefix: 'tenant')
      allow(Zealot::Storage::Manager).to receive(:s3_client).and_return(client)

      expect(client).to receive(:list_objects_v2).with(
        bucket: 'bucket',
        prefix: 'tenant/uploads/apps/a1/',
        continuation_token: nil
      ).and_return(response)

      controller.send(:destroy_cloud_app_data)
    end
  end
end
