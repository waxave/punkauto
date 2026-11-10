# frozen_string_literal: true

RSpec.describe Punkauto::Client do
  describe "language" do
    it "defaults to English" do
      expect(described_class.new.language).to eq("en")
    end

    it "normalizes the language code to lowercase" do
      expect(described_class.new(language: "ES").language).to eq("es")
    end

    it "builds language-scoped URLs" do
      client = described_class.new(language: "es")
      expect(client.catalog_base).to eq("https://www.rockauto.com/es/catalog")
      expect(client.localized("/tools/")).to eq("https://www.rockauto.com/es/tools/")
    end

    it "requests the localized part search page" do
      client = described_class.new(language: "de")
      stub_request(:get, "https://www.rockauto.com/de/partsearch/")
        .to_return(status: 200,
                   body: fixture("partsearch/manufacturers.html"),
                   headers: { "Content-Type" => "text/html" })

      result = client.get_manufacturers
      expect(result.count).to eq(3)
    end

    it "uses the configured language for the catalog" do
      client = described_class.new(language: "fr")
      stub_request(:get, "https://www.rockauto.com/fr/catalog/")
        .to_return(status: 200,
                   body: fixture("catalog/makes-fr.html"),
                   headers: { "Content-Type" => "text/html" })

      result = client.get_makes
      expect(result.makes).to include("PEUGEOT")
    end

    it "keeps the language cookie when following RockAuto's locale redirect" do
      url = "https://www.rockauto.com/es/partsearch/"
      stub_request(:get, url).to_return(
        { status: 302, headers: { "Location" => "/es/partsearch/", "Set-Cookie" => "language=es; path=/; secure" } },
        { status: 200, body: fixture("partsearch/manufacturers.html"), headers: { "Content-Type" => "text/html" } }
      )

      result = described_class.new(language: "es").get_manufacturers

      expect(result.count).to eq(3)
      expect(a_request(:get, url).with { |request| request.headers["Cookie"].to_s.include?("language=es") })
        .to have_been_made.once
      expect(a_request(:get, url)).to have_been_made.times(2)
    end

    it "keeps the language cookie when following a localized catalog redirect" do
      url = "https://www.rockauto.com/es/catalog/honda,2010,accord"
      stub_request(:get, url).to_return(
        { status: 302, headers: { "Location" => "/es/catalog/honda,2010,accord", "Set-Cookie" => "language=es; path=/; secure" } },
        { status: 200, body: fixture("catalog/engines.html"), headers: { "Content-Type" => "text/html" } }
      )

      result = described_class.new(language: "es").get_engines_for_vehicle("honda", 2010, "accord")

      expect(result.engines.map(&:carcode)).to eq(["1444945"])
      expect(a_request(:get, url).with { |request| request.headers["Cookie"].to_s.include?("language=es") })
        .to have_been_made.once
    end
  end
end
