# frozen_string_literal: true

RSpec.describe Punkauto::Client do
  let(:catalogapi) { "https://www.rockauto.com/catalog/catalogapi.php" }

  describe "#get_tool_categories" do
    before do
      stub_request(:get, "https://www.rockauto.com/en/tools/")
        .to_return(status: 200, body: fixture("tools/categories.html"), headers: { "Content-Type" => "text/html" })
    end

    it "parses only category links" do
      result = subject.get_tool_categories
      expect(result).to be_a(Punkauto::ToolCategories)
      expect(result.categories.map(&:name)).to eq(["Engine", "Brake & Wheel Hub"])
    end

    it "does not treat tools query links as categories" do
      result = subject.get_tool_categories
      expect(result.categories.map(&:href)).not_to include(
        "/en/tools/?mobilemenu=show&amp;langmenu=show",
        "/en/tools/?language=es",
        "/en/tools/?newcurrency=USD"
      )
      expect(result.count).to eq(2)
    end
  end

  describe "#get_tools_by_category" do
    let(:category_page) { fixture("tools/category.html") }
    let(:listing_html) { fixture("tools/listing.html") }

    before do
      stub_request(:get, "https://www.rockauto.com/en/tools/engine")
        .to_return(status: 200, body: category_page, headers: { "Content-Type" => "text/html" })
      stub_request(:post, catalogapi)
        .to_return(status: 200,
                   body: JSON.generate("html_fill_sections" => { "navchildren[3]" => listing_html }),
                   headers: { "Content-Type" => "application/json" })
    end

    it "fetches tool listings via the extras tab and parses them" do
      result = subject.get_tools_by_category("engine")
      expect(result).to be_a(Punkauto::ToolsResult)
      expect(result.count).to eq(1)
      tool = result.tools.first
      expect(tool).to be_a(Punkauto::ToolInfo)
      expect(tool.brand).to eq("ACME")
      expect(tool.part_number).to eq("TOOL-123")
      expect(tool.price).to eq("$12.99")
      expect(tool.name).to eq("Oil Filter Plug")
    end
  end
end
