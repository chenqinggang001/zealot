# frozen_string_literal: true

require 'rails_helper'
require 'nokogiri'

RSpec.describe 'public_downloads/_download_actions', type: :view do
  let(:release) { instance_double('Release') }
  let(:channel) { instance_double('Channel') }

  before do
    allow(view).to receive(:public_download_release_notices).with(release).and_return([])
    allow(view).to receive(:public_download_install_disabled?).with(release).and_return(false)
    allow(view).to receive(:public_download_download_disabled?).with(release).and_return(false)
    allow(view).to receive(:public_download_qrcode_path).with(release, channel).and_return('/qrcode.png')
    allow(view).to receive(:public_download_file_meta).with(release).and_return('Android · 10 MB · APK')
    allow(view).to receive(:public_download_download_button_label).with(release).and_return('下载 APK 文件')
    allow(view).to receive(:public_download_download_url).with(release).and_return('/download.apk')
  end

  it 'renders the iOS primary action with the install Stimulus action' do
    allow(view).to receive(:public_download_ios_release?).with(release).and_return(true)
    allow(view).to receive(:public_download_install_url).with(release).and_return('itms-services://download')
    allow(view).to receive(:public_download_install_token_url).with(release).and_return('/install_token')
    allow(view).to receive(:public_download_install_button_label).with(release).and_return('立即安装')

    render partial: 'public_downloads/download_actions', locals: { release: release, channel: channel }

    fragment = Nokogiri::HTML.fragment(rendered)
    primary_action = fragment.at_css('.public-downloads__canvas-btn--primary')

    expect(fragment.at_css('[data-controller="release-download"]')).to be_present
    expect(fragment.at_css('[data-release-download-install-token-url-value]')['data-release-download-install-token-url-value']).to eq('/install_token')
    expect(primary_action.name).to eq('button')
    expect(primary_action['data-action']).to eq('release-download#install')
    expect(fragment.at_css('[data-release-download-target="installIssue"] [data-action="release-download#showQA"]')).to be_present
  end

  it 'renders non-iOS primary action as a plain download link' do
    allow(view).to receive(:public_download_ios_release?).with(release).and_return(false)
    expect(view).not_to receive(:public_download_install_url)
    expect(view).not_to receive(:public_download_install_token_url)

    render partial: 'public_downloads/download_actions', locals: { release: release, channel: channel }

    fragment = Nokogiri::HTML.fragment(rendered)
    primary_action = fragment.at_css('.public-downloads__canvas-btn--primary')

    expect(fragment.at_css('[data-controller="release-download"]')).to be_nil
    expect(primary_action.name).to eq('a')
    expect(primary_action['href']).to eq('/download.apk')
    expect(primary_action['data-action']).to be_nil
    expect(fragment.at_css('[data-release-download-target="installIssue"]')).to be_nil
  end
end
