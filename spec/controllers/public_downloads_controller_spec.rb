# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PublicDownloadsController, type: :controller do
  include Devise::Test::ControllerHelpers

  before do
    allow(RetainedBuildsJob).to receive(:perform_later)
  end

  def create_public_release(channel, release_version: '1.0.0', build_version: '1', created_at: Time.current)
    release = channel.releases.build(
      release_version: release_version,
      build_version: build_version,
      changelog: [],
      custom_fields: []
    )
    release.save!(validate: false)
    release.update_columns(created_at: created_at, updated_at: created_at)
    release
  end

  def create_public_channel(password: nil)
    app = App.create!(name: 'Public App')
    scheme = app.schemes.create!(name: '测试环境')

    scheme.channels.create!(name: 'Android', device_type: :android, password: password)
  end

  describe 'GET #index' do
    it 'renders without requiring a login' do
      builder = class_double('PublicDownloads::CatalogBuilder', call: [])
      stub_const('PublicDownloads::CatalogBuilder', builder)

      get :index

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@catalog_sections)).to eq([])
    end
  end

  describe 'GET #show' do
    it 'allows channels without a password' do
      channel = create_public_channel
      release = create_public_release(channel)

      get :show, params: { channel_id: channel.to_param, id: release.id }

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@authorized)).to be(true)
    end

    it 'requires password validation when the channel has a password' do
      channel = create_public_channel(password: 'secret')
      release = create_public_release(channel)

      get :show, params: { channel_id: channel.to_param, id: release.id }

      expect(response).to have_http_status(:ok)
      expect(controller.instance_variable_get(:@authorized)).to be(false)
    end

    it 'loads history from the current channel only' do
      channel = create_public_channel
      other_channel = create_public_channel
      older_release = create_public_release(channel, release_version: '1.0.0', build_version: '1')
      current_release = create_public_release(channel, release_version: '1.0.1', build_version: '2')
      create_public_release(other_channel, release_version: '9.9.9', build_version: '9')

      get :show, params: { channel_id: channel.to_param, id: current_release.id }

      expect(controller.instance_variable_get(:@history_releases)).to eq([current_release, older_release])
    end
  end

  describe 'POST #auth' do
    it 'renders the password page when the password is invalid' do
      channel = create_public_channel(password: 'secret')
      release = create_public_release(channel)

      post :auth, params: { channel_id: channel.to_param, id: release.id, password: 'bad' }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(controller.instance_variable_get(:@authorized)).to be(false)
      expect(controller.instance_variable_get(:@error_message)).to be_present
    end

    it 'stores the existing channel auth cookie and redirects back to the public page' do
      channel = create_public_channel(password: 'secret')
      release = create_public_release(channel)

      post :auth, params: { channel_id: channel.to_param, id: release.id, password: 'secret' }

      expect(response).to redirect_to(public_download_app_release_path(channel_id: channel, id: release))
      expect(response).to have_http_status(:see_other)
      expect(cookies["zealot_app_channel_auth_#{channel.id}"]).to eq(channel.encode_password)
    end
  end
end
