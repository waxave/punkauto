# frozen_string_literal: true

RSpec.describe Punkauto::PartExtractor do
  describe ".extract_from_listing" do
    let(:html) do
      fixture("listings/part.html")
    end
    let(:node) { Nokogiri::HTML(html).at_css(".listing-inner") }

    it "extracts brand, part number, price, image and info url" do
      part = described_class.extract_from_listing(node, name: "Brake Pad")
      expect(part).to be_a(Punkauto::PartInfo)
      expect(part.name).to eq("Brake Pad")
      expect(part.brand).to eq("ULTRA-POWER")
      expect(part.part_number).to eq("550173")
      expect(part.price).to eq("$49.99")
      expect(part.image_url).to eq("https://www.rockauto.com/info/873/873_PS2102C_1__ra_m.jpg")
      expect(part.info_url).to eq("https://www.rockauto.com/en/moreinfo.php?pk=16291129&cc=3445240&pt=1684")
    end

    it "returns nil when a listing has no meaningful data" do
      empty = Nokogiri::HTML(fixture("listings/empty.html")).at_css(".listing-inner")
      expect(described_class.extract_from_listing(empty, name: "X")).to be_nil
    end

    it "extracts the name from the footnote when no name is given" do
      html = fixture("listings/search-results.html")
      node = Nokogiri::HTML(html).at_css(".listing-inner")

      part = described_class.extract_from_listing(node)
      expect(part.name).to eq("Caliper Repair Kit")
      expect(part.brand).to eq("BETTER BRAKE PARTS")
      expect(part.part_number).to eq("41488K")
      expect(part.price).to eq("$46.37")
    end
  end
end

RSpec.describe Punkauto::Client do
  let(:catalogapi) { "https://www.rockauto.com/catalog/catalogapi.php" }

  describe "#get_part_categories" do
    let(:category_html) { fixture("catalog/part-categories.html") }

    before do
      json = JSON.generate("html_fill_sections" => { "navchildren[]" => category_html })
      stub_request(:post, catalogapi).to_return(status: 200, body: json,
                                                headers: { "Content-Type" => "application/json" })
    end

    it "parses only category links (not flag/help anchors)" do
      result = subject.get_part_categories("Honda", 2020, "Civic", "3445240")
      expect(result).to be_a(Punkauto::VehiclePartCategories)
      expect(result.count).to eq(2)
      expect(result.categories.map(&:name)).to eq(["Brake & Wheel Hub", "Engine"])
    end

    it "uses the human-readable name as the group_name" do
      result = subject.get_part_categories("Honda", 2020, "Civic", "3445240")
      expect(result.categories.first.group_name).to eq("Brake & Wheel Hub")
    end
  end

  describe "#get_parts_by_category" do
    let(:subcategory_html) { fixture("catalog/subcategories.html") }

    let(:listing_html) { fixture("listings/part.html") }

    before do
      subcat_json = JSON.generate("html_fill_sections" => { "navchildren[]" => subcategory_html })
      listing_json = JSON.generate("html_fill_sections" => { "navchildren[]" => listing_html })
      stub_request(:post, catalogapi).to_return(
        { status: 200, body: subcat_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: listing_json, headers: { "Content-Type" => "application/json" } }
      )
    end

    it "drills into subcategories and parses the div listings" do
      result = subject.get_parts_by_category("Honda", 2020, "Civic", "3445240", "Brake & Wheel Hub")
      expect(result).to be_a(Punkauto::VehiclePartsResult)
      expect(result.count).to eq(1)
      part = result.parts.first
      expect(part.brand).to eq("ULTRA-POWER")
      expect(part.part_number).to eq("550173")
      expect(part.price).to eq("$49.99")
    end
  end

  describe "#search_parts_by_number" do
    let(:listing_html) { fixture("listings/search-results.html") }

    before do
      stub_request(:get, "https://www.rockauto.com/en/partsearch/")
        .to_return(status: 200, body: fixture("partsearch/token.html"),
                   headers: { "Content-Type" => "text/html" })
      stub_request(:post, "https://www.rockauto.com/en/partsearch/")
        .to_return(status: 200, body: listing_html, headers: { "Content-Type" => "text/html" })
    end

    it "parses search results into PartInfo objects" do
      result = subject.search_parts_by_number("121g")
      expect(result).to be_a(Punkauto::PartSearchResult)
      expect(result.count).to eq(1)
      part = result.parts.first
      expect(part.brand).to eq("BETTER BRAKE PARTS")
      expect(part.part_number).to eq("41488K")
      expect(part.name).to eq("Caliper Repair Kit")
      expect(part.price).to eq("$46.37")
      expect(part.info_url).to eq("https://www.rockauto.com/en/moreinfo.php?pk=15762661")
    end
  end
end
