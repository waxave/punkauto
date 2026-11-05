# frozen_string_literal: true

RSpec.describe Punkauto::PartCache do
  let(:part) { Punkauto::PartInfo.new(name: "Brake Pad", part_number: "P-123") }

  it "caches and retrieves parts" do
    cache = described_class.new
    cache.cache_part(part)
    expect(cache.get_part("P-123").name).to eq("Brake Pad")
  end

  it "returns nil for uncached parts" do
    expect(described_class.new.get_part("missing")).to be_nil
  end

  it "evicts expired parts" do
    cache = described_class.new
    cache.cache_part(part)
    cached = cache.parts["P-123"]
    cached.instance_variable_set(:@cached_at, Time.now - 20 * 3600)
    expect(cache.get_part("P-123")).to be_nil
  end

  it "generates stable cache keys" do
    key = described_class.generate_vehicle_cache_key("HONDA", "Civic", "2020", "100", "Brake")
    expect(key).to eq("honda|civic|2020|100|brake")
  end
end

RSpec.describe Punkauto::CacheConfiguration do
  it "creates a cache with matching limits" do
    config = described_class.new(max_parts: 5, max_results: 3)
    cache = config.create_cache
    expect(cache.max_parts).to eq(5)
    expect(cache.max_results).to eq(3)
  end
end
