# frozen_string_literal: true

require 'rails_helper'
require 'nokogiri'

RSpec.describe 'public_downloads/_release_history', type: :view do
  it 'renders every cell in non-current history rows as a link to that release' do
    channel = instance_double('Channel')
    current_release = instance_double('Release')
    history_release = instance_double('Release', created_at: Time.zone.local(2026, 4, 27, 16, 20, 34))

    allow(view).to receive(:public_download_history_scope_label).with(channel, current_release).and_return('Android · App · Env')
    allow(view).to receive(:public_download_current_release?).with(history_release, current_release).and_return(false)
    allow(view).to receive(:public_download_release_path).with(history_release, channel).and_return('/download_apps/channel/releases/1')
    allow(view).to receive(:public_download_version_label).with(history_release).and_return('1.0.0')
    allow(view).to receive(:public_download_build_label).with(history_release, prefix: false).and_return('#1')
    allow(view).to receive(:public_download_datetime_label).with(history_release.created_at).and_return('2026-04-27 16:20:34')

    render partial: 'public_downloads/release_history',
           locals: { release: current_release, channel: channel, releases: [history_release] }

    links = Nokogiri::HTML.fragment(rendered).css('tbody tr td a.public-downloads__canvas-table-row-link')

    expect(links.size).to eq(4)
    expect(links.map { |link| link['href'] }.uniq).to eq(['/download_apps/channel/releases/1'])
    expect(links.map(&:text)).to include('1.0.0', '#1', '2026-04-27 16:20:34')
  end
end
