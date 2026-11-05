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
                   body: '<select id="manufacturer_partsearch_007"><option value="x">X</option></select>',
                   headers: { "Content-Type" => "text/html" })

      result = client.get_manufacturers
      expect(result.count).to eq(1)
    end

    it "uses the configured language for the catalog" do
      client = described_class.new(language: "fr")
      stub_request(:get, "https://www.rockauto.com/fr/catalog/")
        .to_return(status: 200,
                   body: '<a href="/fr/catalog/PEUGEOT">Peugeot</a>',
                   headers: { "Content-Type" => "text/html" })

      result = client.get_makes
      expect(result.makes).to include("PEUGEOT")
    end
  end
end
