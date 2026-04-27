# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AppFileUploader do
  let(:app) { instance_double(App, id: 1) }
  let(:release) { instance_double(Release, id: 2, app: app) }

  describe '#store_dir' do
    it 'prepends the S3 path prefix when cloud storage is enabled' do
      allow(Zealot::Storage::Manager).to receive(:cloud_enabled?).and_return(true)
      allow(Zealot::Storage::Manager).to receive(:config).and_return(path_prefix: '/tenant/prod/')

      expect(described_class.new(release, :file).store_dir).to eq('tenant/prod/uploads/apps/a1/r2/binary')
    end

    it 'keeps the local uploads path when cloud storage is disabled' do
      allow(Zealot::Storage::Manager).to receive(:cloud_enabled?).and_return(false)

      expect(described_class.new(release, :file).store_dir).to eq('uploads/apps/a1/r2/binary')
    end
  end
end
