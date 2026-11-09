# frozen_string_literal: true

RSpec.describe Punkauto::Client do
  let(:catalogapi) { "https://www.rockauto.com/catalog/catalogapi.php" }

  describe "#get_makes" do
    before do
      stub_request(:get, "https://www.rockauto.com/en/catalog/")
        .to_return(status: 200, body: <<~HTML, headers: { "Content-Type" => "text/html" })
          <html><body>
            <a href="/en/catalog/TOYOTA">Toyota</a>
            <a href="/en/catalog/HONDA">Honda</a>
            <a href="/en/catalog/HONDA,2020">Honda 2020</a>
            <a href="/en/catalog/?LANGUAGE=DE">Deutsch</a>
            <a href="/en/catalog/?NEWCURRENCY=USD">US Dollars</a>
            <a href="/en/catalog/?MOBILEMENU=SHOW&amp;CURMENU=SHOW">Menu</a>
            <a href="/en/catalog/?LANGUAGE=FR&amp;MOBILEMENU=SHOW">French menu</a>
          </body></html>
        HTML
    end

    it "returns sorted makes" do
      result = subject.get_makes
      expect(result).to be_a(Punkauto::VehicleMakes)
      expect(result.makes).to eq(%w[HONDA TOYOTA])
      expect(result.count).to eq(2)
    end

    it "reuses the default SQLite cache across client instances" do
      first = Punkauto::Client.new.get_makes
      second = Punkauto::Client.new.get_makes

      expect(second).to eq(first)
      expect(a_request(:get, "https://www.rockauto.com/en/catalog/")).to have_been_made.once
    end

    it "supports transformed and original views over the same cached response" do
      transformed = Punkauto::Client.new(display: :transformed).get_makes
      original = Punkauto::Client.new(display: :original).get_makes

      expect(transformed.makes).to eq(%w[Honda Toyota])
      expect(original.makes).to eq(%w[HONDA TOYOTA])
      expect(a_request(:get, "https://www.rockauto.com/en/catalog/")).to have_been_made.once
    end
  end

  describe "#get_years_for_make" do
    before do
      stub_request(:post, catalogapi).to_return(status: 200, body: "{}")
      stub_request(:get, "https://www.rockauto.com/en/catalog/honda")
        .to_return(status: 200, body: <<~HTML, headers: { "Content-Type" => "text/html" })
          <html><body>
            <a href="/en/catalog/honda,2020">2020</a>
            <a href="/en/catalog/honda,2019">2019</a>
            <a href="/en/catalog/honda,1950">1950</a>
            <a href="/en/catalog/honda,1800">1800</a>
          </body></html>
        HTML
    end

    it "returns years in descending order within range" do
      result = subject.get_years_for_make("Honda")
      expect(result.years).to eq([2020, 2019, 1950])
      expect(result.make).to eq("HONDA")
    end
  end

  describe "#get_manufacturers" do
    before do
      stub_request(:get, "https://www.rockauto.com/en/partsearch/")
        .to_return(status: 200, body: <<~HTML, headers: { "Content-Type" => "text/html" })
          <html><body>
            <select id="manufacturer_partsearch_007">
              <option value="">All</option>
              <option value="ACDELCO">ACDELCO</option>
              <option value="3M">3M</option>
            </select>
          </body></html>
        HTML
    end

    it "parses manufacturer options and supports lookup" do
      result = subject.get_manufacturers
      expect(result.manufacturers.map(&:text)).to eq(%w[All ACDELCO 3M])
      expect(result.manufacturer_by_name("acdelco").value).to eq("ACDELCO")
      expect(result.manufacturer_by_name("missing")).to be_nil
    end

    it "caches results" do
      first = subject.get_manufacturers
      second = subject.get_manufacturers
      expect(second).to eq(first)
    end
  end

  describe "#search_parts_by_number" do
    before do
      stub_request(:get, "https://www.rockauto.com/en/partsearch/")
        .to_return(status: 200, body: '<input name="_nck" value="token123">',
                   headers: { "Content-Type" => "text/html" })

      stub_request(:post, "https://www.rockauto.com/en/partsearch/")
        .to_return(status: 200, body: "<html></html>", headers: { "Content-Type" => "text/html" })
    end

    it "returns a PartSearchResult" do
      result = subject.search_parts_by_number("90919-02230")
      expect(result).to be_a(Punkauto::PartSearchResult)
      expect(result.search_term).to eq("90919-02230")
    end
  end

  describe "#lookup_order_status" do
    before do
      stub_request(:get, "https://www.rockauto.com/orderstatus/")
        .to_return(status: 200, body: '<input name="_nck" value="token123">',
                   headers: { "Content-Type" => "text/html" })

      stub_request(:post, "https://www.rockauto.com/orderstatus/orderstatus.php")
        .to_return(status: 200, body: "Order not found", headers: { "Content-Type" => "text/html" })
    end

    it "returns an ORDER_NOT_FOUND error result" do
      result = subject.lookup_order_status("customer@example.com", "123")
      expect(result.success).to be(false)
      expect(result.error.error_type).to eq("ORDER_NOT_FOUND")
      expect(result.error.message).to eq("Order 123 was not found")
    end

    it "returns a system error when no security token is present" do
      stub_request(:get, "https://www.rockauto.com/orderstatus/")
        .to_return(status: 200, body: "<html></html>", headers: { "Content-Type" => "text/html" })

      result = subject.lookup_order_status("customer@example.com", "123")
      expect(result.error.error_type).to eq("SYSTEM_ERROR")
    end
  end

  describe "#generate_jnck_token" do
    it "percent-encodes the token" do
      subject.instance_variable_set(:@nck_token, "a+b/c=")
      expect(subject.generate_jnck_token).to eq("&_jnck=a%2Bb%2Fc%3D")
    end

    it "returns an empty string without a token" do
      subject.instance_variable_set(:@nck_token, nil)
      expect(subject.generate_jnck_token).to eq("")
    end
  end

  describe "#with" do
    it "yields the client and returns the block value" do
      result = Punkauto::Client.new.with { |client| client.object_id }
      expect(result).to be_a(Integer)
    end
  end
end
