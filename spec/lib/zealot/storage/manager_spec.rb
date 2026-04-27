# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zealot::Storage::Manager do
  describe '.path_prefix' do
    it 'normalizes the configured path prefix' do
      allow(described_class).to receive(:config).and_return(path_prefix: ' /tenant//prod/ ')

      expect(described_class.path_prefix).to eq('tenant/prod')
    end
  end

  describe '.object_key' do
    it 'prepends the normalized path prefix to object keys' do
      allow(described_class).to receive(:config).and_return(path_prefix: '/tenant/prod/')

      expect(described_class.object_key('/uploads/', 'apps', 'a1/')).to eq('tenant/prod/uploads/apps/a1')
    end

    it 'does not add a leading slash when the path prefix is blank' do
      allow(described_class).to receive(:config).and_return(path_prefix: nil)

      expect(described_class.object_key('uploads', 'apps', 'a1')).to eq('uploads/apps/a1')
    end
  end
end
