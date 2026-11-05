# frozen_string_literal: true

RSpec.describe Punkauto::PartExtractor do
  let(:doc) { Nokogiri::HTML('<a href="/en/catalog">BOSCH Brake Pads 12345AB $49.99</a>') }
  let(:link) { doc.at_css("a") }

  it "extracts a PartInfo from an element" do
    part = described_class.extract_from_element(link)
    expect(part).to be_a(Punkauto::PartInfo)
    expect(part.brand).to eq("Bosch")
    expect(part.url).to eq("https://www.rockauto.com/en/catalog")
  end

  it "returns nil for navigation elements" do
    nav = Nokogiri::HTML('<a href="/show">Show all</a>').at_css("a")
    expect(described_class.extract_from_element(nav)).to be_nil
  end

  it "formats relative, absolute, and bare URLs" do
    expect(described_class.format_url("/x")).to eq("https://www.rockauto.com/x")
    expect(described_class.format_url("https://example.com/x")).to eq("https://example.com/x")
    expect(described_class.format_url("x")).to eq("https://www.rockauto.com/x")
    expect(described_class.format_url(nil)).to be_nil
  end

  it "extracts part info from a table row" do
    row_html = '<tr><td>DENSO</td><td>Ignition Coil 90919-02230</td><td>$59.99</td></tr>'
    row = Nokogiri::HTML(row_html).at_css("tr")
    cells = row.css("td")

    part = described_class.extract_from_table_row(row, cells)
    expect(part).to be_a(Punkauto::PartInfo)
    expect(part.brand).to eq("DENSO")
  end
end
