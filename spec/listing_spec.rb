# frozen_string_literal: true

RSpec.describe Punkauto::PartExtractor do
  describe ".extract_from_listing" do
    let(:html) do
      <<~HTML
        <div class="listing-inner">
          <span class="listing-final-manufacturer no-text-select">ULTRA-POWER</span>
          <span class="listing-final-partnumber no-text-select">550173</span>
          <span class="ra-formatted-amount listing-price listing-amount-bold"><span>$49.99</span></span>
          <img class="listing-inline-image" src="/info/873/873_PS2102C_1__ra_m.jpg" alt="Part image">
          <a href="https://www.rockauto.com/en/moreinfo.php?pk=16291129&amp;cc=3445240&amp;pt=1684">Info</a>
        </div>
      HTML
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
      empty = Nokogiri::HTML('<div class="listing-inner"></div>').at_css(".listing-inner")
      expect(described_class.extract_from_listing(empty, name: "X")).to be_nil
    end
  end
end

RSpec.describe Punkauto::Client do
  let(:catalogapi) { "https://www.rockauto.com/catalog/catalogapi.php" }

  describe "#get_part_categories" do
    let(:category_html) do
      '<div>' \
        '<a class="navlabellink nvoffset nnormal" href="/en/catalog/honda,2020,civic,1.5l+l4+turbocharged,3445240,brake+&amp;+wheel+hub">Brake &amp; Wheel Hub</a>' \
        '<a class="navlabellink nvoffset nnormal" href="/en/catalog/honda,2020,civic,1.5l+l4+turbocharged,3445240,engine">Engine</a>' \
        '<a href="/help/?page=1" class="nodeflag-a"><img alt="the USA flag"></a>' \
        '</div>'
    end

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
    let(:subcategory_html) do
      '<a class="navlabellink" href="/en/catalog/honda,2020,civic,1.5l+l4+turbocharged,3445240,brake+&amp;+wheel+hub,brake+pad,1684">Brake Pad</a>'
    end

    let(:listing_html) do
      '<div class="listing-inner">' \
        '<span class="listing-final-manufacturer">ULTRA-POWER</span>' \
        '<span class="listing-final-partnumber">550173</span>' \
        '<span class="listing-price">$49.99</span>' \
        '<a href="https://www.rockauto.com/en/moreinfo.php?pk=1&amp;cc=3445240&amp;pt=1684">Info</a>' \
        '</div>'
    end

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
end
