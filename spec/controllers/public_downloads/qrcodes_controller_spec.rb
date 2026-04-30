# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PublicDownloads::QrcodesController, type: :controller do
  include Devise::Test::ControllerHelpers

  before do
    allow(RetainedBuildsJob).to receive(:perform_later)
  end

  def create_public_release
    app = App.create!(name: 'Public App')
    scheme = app.schemes.create!(name: '正式环境')
    channel = scheme.channels.create!(name: 'Android', device_type: :android)
    release = channel.releases.build(
      release_version: '1.0.0',
      build_version: '1',
      changelog: [],
      custom_fields: []
    )

    release.save!(validate: false)
    [channel, release]
  end

  it 'builds the QR code from the public release URL' do
    channel, release = create_public_release
    expected_url = public_download_app_release_url(channel_id: channel, id: release)

    allow(controller).to receive(:render_qrcode) do |content|
      controller.render plain: content
    end

    get :show, params: { channel_id: channel.to_param, id: release.id, format: :png }

    expect(response.body).to eq(expected_url)
  end
end
