# frozen_string_literal: true

RSpec.describe Punkauto::Client do
  let(:catalogapi) { "https://www.rockauto.com/catalog/catalogapi.php" }

  describe "#get_tool_categories" do
    before do
      stub_request(:get, "https://www.rockauto.com/en/tools/")
        .to_return(status: 200, body: <<~HTML, headers: { "Content-Type" => "text/html" })
          <html><body>
            <a class="navlabellink" href="/en/tools/engine">Engine</a>
            <a class="navlabellink" href="/en/tools/brake+&amp;+wheel+hub">Brake &amp; Wheel Hub</a>
            <a class="navlabellink" href="/en/tools/?mobilemenu=show&amp;langmenu=show">Language [English]</a>
            <a class="navlabellink" href="/en/tools/?language=es">Español</a>
            <a class="navlabellink" href="/en/tools/?newcurrency=USD">US Dollars ($)</a>
            <a class="navlabellink" href="/en/tools/?mobilemenu=show&amp;curmenu=show">Show Prices In</a>
            <a href="/help/?page=1" class="nodeflag-a"><img alt="the USA flag"></a>
          </body></html>
        HTML
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
    let(:jsn) do
      { "groupindex" => "3", "tab" => "extras", "idepth" => 2, "groupname" => "Engine",
        "subgroupname" => "Oil Filter", "parttype" => "1002109", "nodetype" => "parttype",
        "parentgroupindex" => "2" }
    end
    let(:category_page) do
      %(<html><body><input id="jsn[3]" value="#{JSON.generate(jsn).gsub('"', '&quot;')}"></body></html>)
    end
    let(:listing_html) do
      '<div class="listing-inner">' \
        '<span class="listing-final-manufacturer">ACME</span>' \
        '<span class="listing-final-partnumber">TOOL-123</span>' \
        '<span class="listing-footnote-text">Category: Oil Filter Plug</span>' \
        '<span class="listing-price">$12.99</span>' \
        '<a href="https://www.rockauto.com/en/moreinfo.php?pk=1">Info</a>' \
        '</div>'
    end

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
