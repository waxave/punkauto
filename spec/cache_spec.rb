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

RSpec.describe Punkauto::SQLiteResultCache do
  it "persists typed model results across client cache instances" do
    path = ENV.fetch("PUNKAUTO_CACHE_PATH")
    first = described_class.new(path: path)
    result = Punkauto::VehicleMakes.new(makes: %w[HONDA TOYOTA], count: 2)
    first.write("makes", result, ttl_hours: 1)

    second = described_class.new(path: path)
    cached = second.read("makes")
    expect(cached).to be_a(Punkauto::VehicleMakes)
    expect(cached.makes).to eq(%w[HONDA TOYOTA])
    expect(second.stats[:entries]).to eq(1)
    expect(second.stats[:hits]).to eq(1)
  end

  it "removes expired entries" do
    path = ENV.fetch("PUNKAUTO_CACHE_PATH")
    cache = described_class.new(path: path)
    cache.write("expired", { value: "old" }, ttl_hours: -1)

    expect(cache.read("expired")).to be_nil
    expect(cache.clear_expired).to eq(0)
    expect(cache.stats[:entries]).to eq(0)
  end

  it "stores localized results separately and links engine data relationally" do
    path = ENV.fetch("PUNKAUTO_CACHE_PATH")
    cache = described_class.new(path: path)
    en_result = Punkauto::VehicleEngines.new(
      make: "TOYOTA", year: 2020, model: "CAMRY",
      engines: [Punkauto::Engine.new(description: "2.5L L4", carcode: "12345")], count: 1
    )
    es_result = Punkauto::VehicleMakes.new(makes: ["TOYOTA"], count: 1)
    cache.write("same-key", en_result, ttl_hours: 1, language: "en", operation: :get_engines_for_vehicle,
                arguments: ["TOYOTA", 2020, "CAMRY"])
    cache.write("same-key", es_result, ttl_hours: 1, language: "es", operation: :get_makes)

    expect(cache.read("same-key", language: "en")).to be_a(Punkauto::VehicleEngines)
    expect(cache.read("same-key", language: "es")).to be_a(Punkauto::VehicleMakes)
    db = SQLite3::Database.new(path)
    row = db.get_first_row(<<~SQL)
      SELECT languages.code, makes.name, makes.display_name, vehicle_years.year,
             vehicle_models.display_name, engines.carcode
      FROM engines
      JOIN entities AS engine_entity ON engine_entity.id = engines.entity_id
      JOIN languages ON languages.id = engine_entity.language_id
      JOIN vehicle_models ON vehicle_models.entity_id = engines.vehicle_model_id
      JOIN makes ON makes.entity_id = vehicle_models.make_entity_id
      JOIN vehicle_years ON vehicle_years.entity_id = vehicle_models.year_entity_id
    SQL
    expect(row).to eq(["en", "TOYOTA", "Toyota", 2020, "Camry", "12345"])
    expect(db.get_first_value("SELECT COUNT(*) FROM languages")).to eq(2)
  ensure
    db&.close
  end

  it "titleizes normalized labels but preserves existing mixed case" do
    expect(Punkauto::DisplayText.titleize("BRAKE & WHEEL HUB")).to eq("Brake & Wheel Hub")
    expect(Punkauto::DisplayText.titleize("ACDelco Gold")).to eq("ACDelco Gold")
    expect(Punkauto::DisplayText.titleize("SISTEMA DE FRENOS", language: "es")).to eq("Sistema de Frenos")
  end

  it "keeps the raw model value when serializing a transformed presentation copy" do
    raw = Punkauto::PartCategory.new(name: "BRAKE & WHEEL HUB", group_name: "BRAKE+&+WHEEL+HUB")
    transformed = Punkauto::ResultPresenter.call(raw)

    expect(transformed.name).to eq("Brake & Wheel Hub")
    expect(transformed.group_name).to eq("BRAKE+&+WHEEL+HUB")
    expect(Punkauto::CacheCodec.load(Punkauto::CacheCodec.dump(transformed)).name).to eq("BRAKE & WHEEL HUB")
    expect(raw.name).to eq("BRAKE & WHEEL HUB")
  end

  it "transforms part search labels without changing their values" do
    options = Punkauto::PartGroupOptions.new(
      part_groups: [Punkauto::PartSearchOption.new(value: "BRAKE", text: "BRAKE & WHEEL HUB")], count: 1
    )
    transformed = Punkauto::ResultPresenter.call(options)

    expect(transformed.part_groups.first.text).to eq("Brake & Wheel Hub")
    expect(transformed.part_groups.first.value).to eq("BRAKE")
    expect(Punkauto::CacheCodec.load(Punkauto::CacheCodec.dump(transformed)).part_groups.first.text).to eq("BRAKE & WHEEL HUB")
  end

  it "transforms every supported display model while preserving lookup fields" do
    option = Punkauto::PartSearchOption.new(value: "BRAKE", text: "BRAKE & WHEEL HUB")
    category = Punkauto::PartCategory.new(name: "BRAKE & WHEEL HUB", group_name: "BRAKE+&+WHEEL+HUB")
    part = Punkauto::PartInfo.new(name: "BRAKE PADS", part_number: "BP-123")
    tool_category = Punkauto::ToolCategory.new(name: "ENGINE TOOLS", group_name: "Engine+Tools", href: "/en/tools/Engine+Tools", level: 1)
    tool = Punkauto::ToolInfo.new(name: "OIL FILTER TOOL", part_number: "OT-1")
    what_is = Punkauto::WhatIsPartCalledResult.new(
      main_category: "BRAKES", subcategory: "BRAKE PADS", full_path: "BRAKES/BRAKE PADS"
    )

    results = [
      Punkauto::VehicleMakes.new(makes: ["HONDA"], count: 1),
      Punkauto::VehicleYears.new(make: "HONDA", years: [2010], count: 1),
      Punkauto::VehicleModels.new(make: "HONDA", year: 2010, models: ["ACCORD"], count: 1),
      Punkauto::VehicleEngines.new(
        make: "HONDA", year: 2010, model: "ACCORD",
        engines: [Punkauto::Engine.new(description: "2.4l L4", carcode: "1444945")], count: 1
      ),
      Punkauto::VehiclePartCategories.new(
        make: "HONDA", year: 2010, model: "ACCORD", carcode: "1444945", categories: [category], count: 1
      ),
      Punkauto::VehiclePartsResult.new(
        make: "HONDA", year: 2010, model: "ACCORD", carcode: "1444945",
        category: "BRAKE PADS", parts: [part], count: 1
      ),
      category,
      part,
      tool_category,
      tool,
      Punkauto::ToolCategories.new(categories: [tool_category], count: 1, level: 1),
      Punkauto::ToolsResult.new(tools: [tool], count: 1, category: "ENGINE TOOLS", category_path: "Engine+Tools"),
      Punkauto::ManufacturerOptions.new(manufacturers: [option], count: 1),
      Punkauto::PartGroupOptions.new(part_groups: [option], count: 1),
      Punkauto::PartTypeOptions.new(part_types: [option], count: 1),
      what_is,
      Punkauto::WhatIsPartCalledResults.new(results: [what_is], count: 1, search_term: "BRAKES")
    ].map { |result| Punkauto::ResultPresenter.call(result, language: "es") }

    expect(results[0].makes).to eq(["Honda"])
    expect(results[1].make).to eq("Honda")
    expect(results[2].models).to eq(["Accord"])
    expect(results[3].engines.first.description).to eq("2.4L L4")
    expect(results[4].categories.first.name).to eq("Brake & Wheel Hub")
    expect(results[4].categories.first.group_name).to eq("BRAKE+&+WHEEL+HUB")
    expect(results[5].category).to eq("Brake Pads")
    expect(results[5].parts.first.part_number).to eq("BP-123")
    expect(results[6].name).to eq("Brake & Wheel Hub")
    expect(results[7].name).to eq("Brake Pads")
    expect(results[8].name).to eq("Engine Tools")
    expect(results[9].name).to eq("Oil Filter Tool")
    expect(results[10].categories.first.name).to eq("Engine Tools")
    expect(results[11].category).to eq("Engine Tools")
    expect(results[11].tools.first.name).to eq("Oil Filter Tool")
    expect(results[12].manufacturers.first.text).to eq("Brake & Wheel Hub")
    expect(results[13].part_groups.first.value).to eq("BRAKE")
    expect(results[13].part_groups.first.text).to eq("Brake & Wheel Hub")
    expect(results[14].part_types.first.text).to eq("Brake & Wheel Hub")
    expect(results[15].full_path).to eq("Brakes/Brake Pads")
    expect(results[16].results.first.main_category).to eq("Brakes")
  end

  it "transforms vehicle display values without normalizing them back to uppercase" do
    raw = Punkauto::Vehicle.new(
      make: "HONDA", year: 2010, model: "ACCORD",
      engine: Punkauto::Engine.new(description: "2.4l L4", carcode: "1444945")
    )

    transformed = Punkauto::ResultPresenter.call(raw, language: "es")

    expect(transformed.make).to eq("Honda")
    expect(transformed.model).to eq("Accord")
    expect(transformed.engine.description).to eq("2.4L L4")
    expect(transformed.carcode).to eq("1444945")
  end

  it "stores tool categories with parent links and rebuilds their model results" do
    cache = described_class.new(path: ENV.fetch("PUNKAUTO_CACHE_PATH"))
    result = Punkauto::ToolCategories.new(
      categories: [
        Punkauto::ToolCategory.new(name: "ENGINE", group_name: "Engine", href: "/en/tools/Engine", level: 1),
        Punkauto::ToolCategory.new(name: "OIL FILTER", group_name: "Oil Filter", href: "/en/tools/Engine,Oil+Filter", level: 2)
      ], count: 2, level: 2, parent_path: "Engine"
    )
    cache.write("tool-categories", result, ttl_hours: 1, operation: :get_tool_categories)

    cached = cache.read("tool-categories")
    expect(cached.categories.map(&:name)).to eq(["ENGINE", "OIL FILTER"])
    db = SQLite3::Database.new(cache.path)
    expect(db.get_first_value("SELECT COUNT(*) FROM tool_categories WHERE parent_entity_id IS NOT NULL")).to eq(1)
  ensure
    db&.close
  end

  it "migrates the earlier opaque query cache without deleting legacy entries" do
    path = ENV.fetch("PUNKAUTO_CACHE_PATH")
    legacy = SQLite3::Database.new(path)
    legacy.execute_batch(<<~SQL)
      CREATE TABLE languages(id INTEGER PRIMARY KEY, code TEXT NOT NULL UNIQUE);
      INSERT INTO languages(id, code) VALUES(1, 'en');
      CREATE TABLE entities(
        id INTEGER PRIMARY KEY, language_id INTEGER NOT NULL, entity_type TEXT NOT NULL,
        natural_key TEXT NOT NULL, data_json TEXT NOT NULL, updated_at REAL NOT NULL
      );
      CREATE TABLE query_sets (
        id INTEGER PRIMARY KEY, cache_key TEXT NOT NULL UNIQUE,
        language_id INTEGER NOT NULL, operation TEXT NOT NULL,
        arguments_json TEXT NOT NULL, result_json TEXT NOT NULL,
        fetched_at REAL NOT NULL, expires_at REAL NOT NULL,
        accessed_at REAL NOT NULL, hits INTEGER NOT NULL DEFAULT 0
      );
      INSERT INTO query_sets VALUES(1, 'legacy-key', 1, 'get_makes', '[]', '{}', 1, 2, 1, 0);
      CREATE TABLE cache_entries(
        cache_key TEXT PRIMARY KEY, payload TEXT NOT NULL, created_at REAL NOT NULL,
        accessed_at REAL NOT NULL, expires_at REAL NOT NULL, hits INTEGER NOT NULL DEFAULT 0
      );
      INSERT INTO cache_entries VALUES('keep-me', 'legacy payload', 1, 1, 2, 0);
      CREATE TABLE makes(entity_id INTEGER PRIMARY KEY, display_name TEXT NOT NULL);
    SQL
    legacy.execute("INSERT INTO entities VALUES(1, 1, 'make', 'toyota', ?, 1)", [Punkauto::CacheCodec.dump(name: "TOYOTA")])
    legacy.execute("INSERT INTO makes VALUES(1, 'Toyota')")
    legacy.close

    described_class.new(path: path)
    migrated = SQLite3::Database.new(path)
    columns = migrated.table_info("query_sets").map { |column| column["name"] || column[1] }
    expect(columns).not_to include("result_json")
    expect(migrated.get_first_value("SELECT operation FROM query_sets WHERE cache_key = 'legacy-key'")).to eq("get_makes")
    expect(migrated.get_first_value("SELECT payload FROM cache_entries WHERE cache_key = 'keep-me'")).to eq("legacy payload")
    expect(migrated.get_first_value("SELECT name FROM makes WHERE entity_id = 1")).to eq("TOYOTA")
    expect(migrated.get_first_value("SELECT MAX(version) FROM schema_migrations")).to eq(4)
  ensure
    legacy&.close
    migrated&.close
  end
end
