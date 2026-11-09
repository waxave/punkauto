# frozen_string_literal: true

require "json"
require "fileutils"
require "sqlite3"
require "digest"
require "time"

module Punkauto
  module DisplayText
    SMALL_WORDS = {
      "en" => %w[a an and as at but by for in of on or the to],
      "es" => %w[a al con de del el en la las los o para por y],
      "fr" => %w[à au aux avec de des du en et la le les ou pour par],
      "de" => %w[am an auf aus bei das dem den der des die ein eine für im in mit oder und von zu]
    }.freeze
    module_function

    # Normalize display labels while retaining mixed-case brand spellings.
    def titleize(value, language: "en")
      text = value.to_s.gsub(/\s+/, " ").strip
      return text unless text == text.downcase || text == text.upcase

      small_words = SMALL_WORDS.fetch(language.to_s.downcase.split(/[-_]/).first, SMALL_WORDS["en"])
      words = text.downcase.split(/(\s+|[-\/])/)
      words.each_with_index.map do |word, index|
        if word.match?(/\A(?:\s+|[-\/])\z/) || word.empty?
          word
        elsif index.positive? && small_words.include?(word)
          word
        else
          word.sub(/\A\p{L}/u) { |letter| letter.upcase }
        end
      end.join
    end
  end

  # Safe JSON-based serialization for the public model objects cached by Client.
  module CacheCodec
    module_function

    def dump(value)
      JSON.generate(encode(value))
    end

    def load(payload)
      decode(JSON.parse(payload))
    end

    def encode(value)
      case value
      when Model
        { "__type" => "model", "class" => value.class.name, "attributes" => raw_attributes(value).transform_values { |v| encode(v) } }
      when Time
        { "__type" => "time", "value" => value.iso8601 }
      when Symbol
        { "__type" => "symbol", "value" => value.to_s }
      when Array then value.map { |v| encode(v) }
      when Hash
        { "__type" => "hash", "entries" => value.map { |k, v| [encode(k), encode(v)] } }
      when String, Numeric, TrueClass, FalseClass, NilClass then value
      else
        raise ArgumentError, "unsupported cached value: #{value.class}"
      end
    end

    def raw_attributes(model)
      model.to_h.merge(model.instance_variable_get(:@raw_display_values) || {})
    end

    def decode(value)
      case value
      when Array then value.map { |v| decode(v) }
      when Hash
        case value["__type"]
        when "model"
          klass = value.fetch("class").split("::").reduce(Object) { |scope, name| scope.const_get(name, false) }
          raise ArgumentError, "not a Punkauto model" unless klass <= Model
          attrs = value.fetch("attributes").transform_values { |v| decode(v) }
          klass.new(**attrs.transform_keys(&:to_sym))
        when "time" then Time.iso8601(value.fetch("value"))
        when "symbol" then value.fetch("value").to_sym
        when "hash" then value.fetch("entries").to_h { |k, v| [decode(k), decode(v)] }
        else value.transform_values { |v| decode(v) }
        end
      else value
      end
    end
  end

  # Applies display-only changes to copies of API models, leaving identifiers
  # and the cached source objects untouched.
  module ResultPresenter
    DISPLAY_FIELDS = {
      "VehicleMakes" => { makes: :strings },
      "VehicleYears" => { make: :string },
      "VehicleModels" => { make: :string, models: :strings },
      "VehicleEngines" => { make: :string, model: :string },
      "Engine" => { description: :string },
      "VehiclePartCategories" => { make: :string, model: :string },
      "VehiclePartsResult" => { make: :string, model: :string, category: :string },
      "PartCategory" => { name: :string },
      "PartInfo" => { name: :string },
      "ToolCategory" => { name: :string },
      "ToolInfo" => { name: :string },
      "ToolCategories" => {},
      "ToolsResult" => { category: :string },
      "PartGroupOptions" => { part_groups: :options },
      "PartTypeOptions" => { part_types: :options },
      "WhatIsPartCalledResult" => { main_category: :string, subcategory: :string, full_path: :string },
      "WhatIsPartCalledResults" => {}
    }.freeze

    module_function

    def call(value, language: "en")
      case value
      when Array then value.map { |item| call(item, language: language) }
      when Vehicle
        vehicle = Vehicle.new(make: DisplayText.titleize(value.make, language: language), year: value.year,
                              model: DisplayText.titleize(value.model, language: language), engine: call(value.engine, language: language))
        vehicle.client = value.client
        vehicle
      when Model then present_model(value, language)
      else value
      end
    end

    def present_model(model, language)
      fields = DISPLAY_FIELDS.fetch(model.class.name.split("::").last, {})
      original = CacheCodec.raw_attributes(model)
      attrs = model.to_h.transform_values { |value| call(value, language: language) }
      raw_values = model.instance_variable_get(:@raw_display_values) || {}
      fields.each do |field, mode|
        next unless attrs.key?(field)

        source = raw_values.fetch(field, original[field])
        attrs[field] = case mode
                       when :strings
                         Array(source).map { |text| display_text(text, language) }
                       when :options
                         Array(source).map { |option| present_option(option, language) }
                       else
                         display_text(source, language)
                       end
      end
      copy = model.class.new(**attrs)
      copy.instance_variable_set(:@raw_display_values, raw_values.merge(fields.keys.to_h { |field| [field, raw_values.fetch(field, original[field])] })) unless fields.empty?
      copy
    end

    def present_option(option, language)
      return call(option, language: language) unless option.is_a?(PartSearchOption)

      raw = CacheCodec.raw_attributes(option)
      data = option.to_h
      data[:text] = display_text(raw[:text], language)
      copy = option.class.new(**data)
      raw_values = option.instance_variable_get(:@raw_display_values) || {}
      copy.instance_variable_set(:@raw_display_values, raw_values.merge(text: raw_values.fetch(:text, raw[:text])))
      copy
    end

    def display_text(value, language)
      value.nil? ? nil : DisplayText.titleize(value, language: language)
    end
  end

  # Small interface shared by the persistent and per-client cache backends.
  class MemoryResultCache
    def initialize(max_entries: 1100)
      @entries = {}
      @max_entries = max_entries
    end

    def read(key)
      entry = @entries[key]
      return nil unless entry
      if entry[:expires_at] <= Time.now.to_f
        @entries.delete(key)
        return nil
      end
      entry[:accessed_at] = Time.now.to_f
      entry[:hits] += 1
      entry[:value]
    end

    def write(key, value, ttl_hours:)
      @entries.delete(@entries.min_by { |_k, v| v[:accessed_at] }&.first) if !@entries.key?(key) && @entries.size >= @max_entries
      now = Time.now.to_f
      @entries[key] = { value: value, created_at: now, accessed_at: now,
                        expires_at: now + ttl_hours * 3600, hits: 0 }
    end

    def stats
      { entries: @entries.size, hits: @entries.values.sum { |v| v[:hits] }, path: nil }
    end

    def clear
      count = @entries.size
      @entries.clear
      count
    end

    def clear_expired
      expired = @entries.select { |_k, v| v[:expires_at] <= Time.now.to_f }.keys
      expired.each { |key| @entries.delete(key) }
      expired.length
    end
  end

  # Persistent cache shared across client instances and CLI invocations.
  class SQLiteResultCache
    DEFAULT_PATH = File.join(ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache")), "punkauto", "cache.sqlite3").freeze

    attr_reader :path

    def initialize(path: ENV.fetch("PUNKAUTO_CACHE_PATH", DEFAULT_PATH), max_entries: 1100)
      @path = File.expand_path(path)
      @max_entries = max_entries
      FileUtils.mkdir_p(File.dirname(@path))
      with_db do |db|
        db.execute_batch(<<~SQL)
          PRAGMA foreign_keys = ON;
          CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS languages (
            id INTEGER PRIMARY KEY, code TEXT NOT NULL UNIQUE
          );
          CREATE TABLE IF NOT EXISTS entities (
            id INTEGER PRIMARY KEY,
            language_id INTEGER NOT NULL REFERENCES languages(id) ON DELETE CASCADE,
            entity_type TEXT NOT NULL,
            natural_key TEXT NOT NULL,
            data_json TEXT NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(language_id, entity_type, natural_key)
          );
          CREATE TABLE IF NOT EXISTS entity_links (
            parent_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            relationship TEXT NOT NULL,
            child_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(parent_id, relationship, child_id)
          );
          CREATE INDEX IF NOT EXISTS entity_links_child ON entity_links(child_id);
          CREATE TABLE IF NOT EXISTS makes (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            display_name TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS vehicle_years (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            make_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            year INTEGER NOT NULL, UNIQUE(make_entity_id, year)
          );
          CREATE TABLE IF NOT EXISTS vehicle_models (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            make_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            year_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            year INTEGER NOT NULL, name TEXT NOT NULL, display_name TEXT NOT NULL,
            UNIQUE(make_entity_id, year_entity_id, display_name)
          );
          CREATE TABLE IF NOT EXISTS engines (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            vehicle_model_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            carcode TEXT NOT NULL, description TEXT NOT NULL, href TEXT,
            UNIQUE(vehicle_model_id, carcode)
          );
          CREATE INDEX IF NOT EXISTS vehicle_years_make ON vehicle_years(make_entity_id, year);
          CREATE INDEX IF NOT EXISTS vehicle_models_make_year ON vehicle_models(make_entity_id, year);
          CREATE INDEX IF NOT EXISTS engines_vehicle_model ON engines(vehicle_model_id);
          CREATE TABLE IF NOT EXISTS part_categories (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            name TEXT NOT NULL, display_name TEXT NOT NULL, group_name TEXT NOT NULL, href TEXT
          );
          CREATE TABLE IF NOT EXISTS parts (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            part_number TEXT NOT NULL, name TEXT NOT NULL, display_name TEXT NOT NULL,
            brand TEXT, price TEXT, url TEXT, image_url TEXT, info_url TEXT, video_url TEXT,
            UNIQUE(entity_id, part_number)
          );
          CREATE TABLE IF NOT EXISTS vehicle_category_parts (
            engine_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            category_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            part_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(engine_entity_id, category_entity_id, part_entity_id)
          );
          CREATE INDEX IF NOT EXISTS vehicle_category_parts_part ON vehicle_category_parts(part_entity_id);
          CREATE INDEX IF NOT EXISTS parts_number ON parts(part_number);
          CREATE TABLE IF NOT EXISTS tool_categories (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            parent_entity_id INTEGER REFERENCES entities(id) ON DELETE CASCADE,
            group_name TEXT NOT NULL, name TEXT NOT NULL, display_name TEXT NOT NULL, href TEXT, level INTEGER NOT NULL
          );
          CREATE TABLE IF NOT EXISTS tools (
            entity_id INTEGER PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,
            part_number TEXT NOT NULL, name TEXT NOT NULL, display_name TEXT NOT NULL,
            brand TEXT, price TEXT, url TEXT, image_url TEXT, info_url TEXT,
            UNIQUE(entity_id, part_number)
          );
          CREATE TABLE IF NOT EXISTS tool_category_items (
            category_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            tool_entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(category_entity_id, tool_entity_id)
          );
          CREATE INDEX IF NOT EXISTS tool_categories_parent ON tool_categories(parent_entity_id);
          CREATE INDEX IF NOT EXISTS tool_category_items_tool ON tool_category_items(tool_entity_id);
          CREATE INDEX IF NOT EXISTS tools_number ON tools(part_number);
          CREATE TABLE IF NOT EXISTS query_sets (
            id INTEGER PRIMARY KEY,
            cache_key TEXT NOT NULL,
            language_id INTEGER NOT NULL REFERENCES languages(id) ON DELETE CASCADE,
            operation TEXT NOT NULL,
            arguments_json TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            accessed_at REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 0,
            UNIQUE(language_id, cache_key)
          );
          CREATE INDEX IF NOT EXISTS query_sets_language_expiry ON query_sets(language_id, expires_at);
          CREATE TABLE IF NOT EXISTS query_set_entities (
            query_set_id INTEGER NOT NULL REFERENCES query_sets(id) ON DELETE CASCADE,
            entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(query_set_id, entity_id)
          );
          CREATE TABLE IF NOT EXISTS cache_entries (
            cache_key TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            created_at REAL NOT NULL,
            accessed_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 0
          );
          CREATE INDEX IF NOT EXISTS cache_entries_expiry ON cache_entries(expires_at);
        SQL
        db.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, ?)", [Time.now.to_f])
        migrate_query_sets(db)
        migrate_vehicle_models(db)
        migrate_raw_display_columns(db)
      end
    end

    def read(key, language: "en")
      now = Time.now.to_f
      result = nil
      with_db do |db|
        row = db.get_first_row("SELECT id, expires_at FROM query_sets WHERE cache_key = ? AND language_id = (SELECT id FROM languages WHERE code = ?)", [key, language.to_s.downcase])
        if row && row[1].to_f > now
          root_id = db.get_first_value("SELECT entity_id FROM query_set_entities WHERE query_set_id = ? ORDER BY ordinal LIMIT 1", [row[0]])
          db.execute("UPDATE query_sets SET accessed_at = ?, hits = hits + 1 WHERE cache_key = ? AND language_id = (SELECT id FROM languages WHERE code = ?)", [now, key, language.to_s.downcase])
          result = hydrate_result(db, root_id) if root_id
        elsif row
          db.execute("DELETE FROM query_sets WHERE cache_key = ? AND language_id = (SELECT id FROM languages WHERE code = ?)", [key, language.to_s.downcase])
          prune_orphan_entities(db)
        end
      end
      result
    end

    def write(key, value, ttl_hours:, language: "en", operation: "unknown", arguments: [])
      now = Time.now.to_f
      with_db do |db|
        db.transaction do
          lang_code = language.to_s.downcase
          db.execute("INSERT OR IGNORE INTO languages(code) VALUES(?)", [lang_code])
          lang_id = db.get_first_value("SELECT id FROM languages WHERE code = ?", [lang_code]).to_i
          db.execute("INSERT INTO query_sets (cache_key, language_id, operation, arguments_json, fetched_at, expires_at, accessed_at, hits) VALUES (?, ?, ?, ?, ?, ?, ?, 0) ON CONFLICT(language_id, cache_key) DO UPDATE SET operation=excluded.operation, arguments_json=excluded.arguments_json, fetched_at=excluded.fetched_at, expires_at=excluded.expires_at, accessed_at=excluded.accessed_at, hits=0",
                     [key, lang_id, operation.to_s, JSON.generate(CacheCodec.encode(arguments)), now, now + ttl_hours * 3600, now])
          query_id = db.get_first_value("SELECT id FROM query_sets WHERE cache_key = ? AND language_id = ?", [key, lang_id]).to_i
          db.execute("DELETE FROM query_set_entities WHERE query_set_id = ?", [query_id])
          entity_ids = persist_result(db, value, language.to_s.downcase)
          entity_ids.each_with_index do |entity_id, ordinal|
            db.execute("INSERT OR IGNORE INTO query_set_entities(query_set_id, entity_id, ordinal) VALUES(?, ?, ?)", [query_id, entity_id, ordinal])
          end
          excess = db.get_first_value("SELECT COUNT(*) FROM query_sets").to_i - @max_entries
          db.execute("DELETE FROM query_sets WHERE id IN (SELECT id FROM query_sets ORDER BY accessed_at ASC LIMIT ?)", [excess]) if excess.positive?
          prune_orphan_entities(db)
        end
      end
    end

    def stats
      with_db do |db|
        row = db.get_first_row("SELECT COUNT(*), COALESCE(SUM(hits), 0) FROM query_sets")
        { entries: row[0].to_i, hits: row[1].to_i, path: path }
      end
    end

    def clear
      with_db do |db|
        count = db.get_first_value("SELECT COUNT(*) FROM query_sets").to_i
        db.execute("DELETE FROM query_sets")
        prune_orphan_entities(db)
        count
      end
    end

    def clear_expired
      with_db do |db|
        db.execute("DELETE FROM query_sets WHERE expires_at <= ?", [Time.now.to_f])
        count = db.changes
        prune_orphan_entities(db)
        count
      end
    end

    private

    def persist_result(db, value, language)
      lang_id = db.get_first_value("SELECT id FROM languages WHERE code = ?", [language]).to_i
      root_id = persist_entity(db, lang_id, "result", "#{value.class.name}:#{Digest::SHA256.hexdigest(CacheCodec.dump(value))}", root_model(value))
      case value
      when VehicleMakes
        CacheCodec.raw_attributes(value)[:makes].each_with_index do |name, i|
          id = persist_entity(db, lang_id, "make", name.to_s.downcase, { name: name })
          db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [id, name, DisplayText.titleize(name, language: language)])
          link_entity(db, root_id, "makes", id, i)
        end
      when VehicleYears
        raw_make = CacheCodec.raw_attributes(value)[:make]
        make_id = persist_entity(db, lang_id, "make", raw_make.to_s.downcase, { name: raw_make })
        db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [make_id, raw_make, DisplayText.titleize(raw_make, language: language)])
        link_entity(db, root_id, "make", make_id, 0)
        value.years.each_with_index do |year, i|
          id = persist_entity(db, lang_id, "year", "#{raw_make.downcase}:#{year}", { make: raw_make, year: year })
          db.execute("INSERT INTO vehicle_years(entity_id, make_entity_id, year) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year=excluded.year", [id, make_id, year])
          link_entity(db, make_id, "years", id, i)
          link_entity(db, root_id, "years", id, i)
        end
      when VehicleModels
        raw_attrs = CacheCodec.raw_attributes(value)
        raw_make = raw_attrs[:make]
        raw_models = raw_attrs[:models]
        make_id = persist_entity(db, lang_id, "make", raw_make.to_s.downcase, { name: raw_make })
        db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [make_id, raw_make, DisplayText.titleize(raw_make, language: language)])
        link_entity(db, root_id, "make", make_id, 0)
        raw_models.each_with_index do |name, i|
          natural = "#{raw_make.downcase}:#{value.year}:#{name.downcase}"
          id = persist_entity(db, lang_id, "vehicle_model", natural, { make: raw_make, year: value.year, name: name })
          year_id = persist_year(db, lang_id, make_id, raw_make, value.year)
          db.execute("INSERT INTO vehicle_models(entity_id, make_entity_id, year_entity_id, year, name, display_name) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year_entity_id=excluded.year_entity_id, year=excluded.year, name=excluded.name, display_name=excluded.display_name", [id, make_id, year_id, value.year, name, DisplayText.titleize(name, language: language)])
          link_entity(db, make_id, "years", year_id, 0)
          link_entity(db, year_id, "models", id, i)
          link_entity(db, root_id, "models", id, i)
        end
      when VehicleEngines
        raw_attrs = CacheCodec.raw_attributes(value)
        raw_make = raw_attrs[:make]
        raw_model = raw_attrs[:model]
        model_id = vehicle_model_id(db, lang_id, raw_make, value.year, raw_model)
        raw_attrs[:engines].each_with_index do |engine, i|
          engine_attrs = CacheCodec.raw_attributes(engine)
          id = persist_entity(db, lang_id, "engine", "#{raw_make.downcase}:#{value.year}:#{raw_model.downcase}:#{engine.carcode}", engine)
          db.execute("INSERT INTO engines(entity_id, vehicle_model_id, carcode, description, href) VALUES(?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET vehicle_model_id=excluded.vehicle_model_id, carcode=excluded.carcode, description=excluded.description, href=excluded.href",
                     [id, model_id, engine.carcode, engine_attrs[:description], engine.href])
          link_entity(db, root_id, "vehicle_model", model_id, 0)
          link_entity(db, model_id, "engines", id, i)
          link_entity(db, root_id, "engines", id, i)
        end
      when VehiclePartCategories
        raw_attrs = CacheCodec.raw_attributes(value)
        model_id = vehicle_model_id(db, lang_id, raw_attrs[:make], value.year, raw_attrs[:model])
        raw_attrs[:categories].each_with_index do |category, i|
          id = persist_category(db, lang_id, category)
          link_entity(db, root_id, "categories", id, i)
          db.execute("INSERT OR IGNORE INTO entity_links(parent_id, relationship, child_id, ordinal) VALUES(?, 'vehicle_categories', ?, ?)", [model_id, id, i])
        end
      when VehiclePartsResult
        raw_attrs = CacheCodec.raw_attributes(value)
        raw_make = raw_attrs[:make]
        raw_model = raw_attrs[:model]
        model_id = vehicle_model_id(db, lang_id, raw_make, value.year, raw_model)
        engine_id = persist_entity(db, lang_id, "engine", "#{raw_make.downcase}:#{value.year}:#{raw_model.downcase}:#{value.carcode}", { carcode: value.carcode })
        db.execute("INSERT INTO engines(entity_id, vehicle_model_id, carcode, description, href) VALUES(?, ?, ?, '', NULL) ON CONFLICT(entity_id) DO UPDATE SET vehicle_model_id=excluded.vehicle_model_id, carcode=excluded.carcode", [engine_id, model_id, value.carcode])
        raw_category = raw_attrs[:category]
        category = PartCategory.new(name: raw_category, group_name: raw_category)
        category_id = persist_category(db, lang_id, category)
        link_entity(db, root_id, "vehicle_model", model_id, 0)
        link_entity(db, model_id, "engines", engine_id, 0)
        db.execute("DELETE FROM vehicle_category_parts WHERE engine_entity_id = ? AND category_entity_id = ?", [engine_id, category_id])
        raw_attrs[:parts].each_with_index do |part, i|
          part_id = persist_part(db, lang_id, part)
          link_entity(db, root_id, "parts", part_id, i)
          db.execute("INSERT OR IGNORE INTO vehicle_category_parts(engine_entity_id, category_entity_id, part_entity_id, ordinal) VALUES(?, ?, ?, ?)", [engine_id, category_id, part_id, i])
        end
        link_entity(db, root_id, "vehicle", model_id, 0)
      when ToolCategories
        CacheCodec.raw_attributes(value)[:categories].each_with_index do |category, i|
          id = persist_tool_category(db, lang_id, category)
          link_entity(db, root_id, "tool_categories", id, i)
          link_tool_category_ancestors(db, root_id, id)
        end
      when ToolsResult
        raw_attrs = CacheCodec.raw_attributes(value)
        category_id = persist_tool_category(db, lang_id, ToolCategory.new(name: raw_attrs[:category], group_name: value.category_path, href: value.category_path, level: 1))
        link_entity(db, root_id, "tool_categories", category_id, 0)
        link_tool_category_ancestors(db, root_id, category_id)
        db.execute("DELETE FROM tool_category_items WHERE category_entity_id = ?", [category_id])
        raw_attrs[:tools].each_with_index do |tool, i|
          id = persist_tool(db, lang_id, tool)
          link_entity(db, root_id, "tools", id, i)
          db.execute("INSERT OR IGNORE INTO tool_category_items(category_entity_id, tool_entity_id, ordinal) VALUES(?, ?, ?)", [category_id, id, i])
        end
      when PartSearchResult
        CacheCodec.raw_attributes(value)[:parts].each_with_index { |part, i| link_entity(db, root_id, "parts", persist_part(db, lang_id, part), i) }
      when ManufacturerOptions
        value.manufacturers.each_with_index { |item, i| link_entity(db, root_id, "manufacturers", persist_child_model(db, lang_id, item), i) }
      when PartGroupOptions
        value.part_groups.each_with_index { |item, i| link_entity(db, root_id, "part_groups", persist_child_model(db, lang_id, item), i) }
      when PartTypeOptions
        value.part_types.each_with_index { |item, i| link_entity(db, root_id, "part_types", persist_child_model(db, lang_id, item), i) }
      when WhatIsPartCalledResults
        value.results.each_with_index { |item, i| link_entity(db, root_id, "results", persist_child_model(db, lang_id, item), i) }
      end
      [root_id]
    end

    def root_model(value)
      return value unless value.is_a?(Model)

      data = CacheCodec.raw_attributes(value)
      data.each { |key, item| data[key] = [] if item.is_a?(Array) }
      value.class.new(**data)
    end

    def persist_child_model(db, language_id, model)
      natural = if model.respond_to?(:part_number)
                  model.part_number.to_s
                elsif model.respond_to?(:value)
                  model.value.to_s
                elsif model.respond_to?(:full_path)
                  model.full_path.to_s
                else
                  Digest::SHA256.hexdigest(CacheCodec.dump(model))
                end
      persist_entity(db, language_id, model.class.name.split("::").last, natural, model)
    end

    def hydrate_result(db, entity_id)
      row = db.get_first_row("SELECT data_json FROM entities WHERE id = ?", [entity_id])
      return nil unless row

      model = CacheCodec.load(row[0])
      return model unless model.is_a?(Model)

      fields = {
        "VehicleMakes" => [[:makes, "makes"]],
        "VehicleYears" => [[:years, "years"]],
        "VehicleModels" => [[:models, "models"]],
        "VehicleEngines" => [[:engines, "engines"]],
        "VehiclePartCategories" => [[:categories, "categories"]],
        "VehiclePartsResult" => [[:parts, "parts"]],
        "ToolCategories" => [[:categories, "tool_categories"]],
        "ToolsResult" => [[:tools, "tools"]],
        "PartSearchResult" => [[:parts, "parts"]],
        "ManufacturerOptions" => [[:manufacturers, "manufacturers"]],
        "PartGroupOptions" => [[:part_groups, "part_groups"]],
        "PartTypeOptions" => [[:part_types, "part_types"]],
        "WhatIsPartCalledResults" => [[:results, "results"]]
      }
      fields.fetch(model.class.name.split("::").last, []).each do |attribute, relationship|
        child_rows = db.execute("SELECT e.data_json FROM entity_links l JOIN entities e ON e.id = l.child_id WHERE l.parent_id = ? AND l.relationship = ? ORDER BY l.ordinal", [entity_id, relationship])
        children = child_rows.map do |child_row|
          child = CacheCodec.load(child_row[0])
          child.is_a?(Hash) ? (child[:name] || child[:year] || child["name"] || child["year"]) : child
        end
        data = model.to_h
        data[attribute] = children
        model = model.class.new(**data)
      end
      model
    end

    def persist_entity(db, language_id, type, natural_key, data)
      db.execute("INSERT INTO entities(language_id, entity_type, natural_key, data_json, updated_at) VALUES(?, ?, ?, ?, ?) ON CONFLICT(language_id, entity_type, natural_key) DO UPDATE SET data_json=excluded.data_json, updated_at=excluded.updated_at",
                 [language_id, type, natural_key.to_s, CacheCodec.dump(data), Time.now.to_f])
      db.get_first_value("SELECT id FROM entities WHERE language_id = ? AND entity_type = ? AND natural_key = ?", [language_id, type, natural_key.to_s]).to_i
    end

    def link_entity(db, parent_id, relationship, child_id, ordinal)
      db.execute("INSERT OR REPLACE INTO entity_links(parent_id, relationship, child_id, ordinal) VALUES(?, ?, ?, ?)", [parent_id, relationship, child_id, ordinal])
    end

    def prune_orphan_entities(db)
      db.execute_batch(<<~SQL)
        WITH RECURSIVE reachable(id) AS (
          SELECT entity_id FROM query_set_entities
          UNION
          SELECT links.child_id FROM entity_links AS links
          INNER JOIN reachable ON links.parent_id = reachable.id
        )
        DELETE FROM entities WHERE id NOT IN (SELECT id FROM reachable);
      SQL
    end

    # Earlier development versions stored an opaque JSON result on query_sets
    # and used a globally unique cache key. Preserve metadata and memberships
    # while migrating to the language-scoped relational query schema.
    def migrate_query_sets(db)
      table_sql = db.get_first_value("SELECT sql FROM sqlite_master WHERE type='table' AND name='query_sets'").to_s
      if table_sql.include?("UNIQUE(language_id, cache_key)") && !table_sql.include?("result_json")
        db.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, ?)", [Time.now.to_f])
        return
      end

      memberships = db.table_info("query_set_entities").empty? ? [] : db.execute("SELECT query_set_id, entity_id, ordinal FROM query_set_entities")
      query_rows = db.execute("SELECT id, cache_key, language_id, operation, arguments_json, fetched_at, expires_at, accessed_at, hits FROM query_sets")
      db.execute_batch("PRAGMA foreign_keys = OFF;")
      db.transaction do
        db.execute_batch("DROP INDEX IF EXISTS query_sets_language_expiry;")
        db.execute_batch("DROP TABLE IF EXISTS query_set_entities;")
        db.execute_batch("ALTER TABLE query_sets RENAME TO query_sets_legacy_v1;")
        db.execute_batch(<<~SQL)
          CREATE TABLE query_sets (
            id INTEGER PRIMARY KEY,
            cache_key TEXT NOT NULL,
            language_id INTEGER NOT NULL REFERENCES languages(id) ON DELETE CASCADE,
            operation TEXT NOT NULL,
            arguments_json TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            accessed_at REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 0,
            UNIQUE(language_id, cache_key)
          );
          CREATE INDEX query_sets_language_expiry ON query_sets(language_id, expires_at);
          CREATE TABLE query_set_entities (
            query_set_id INTEGER NOT NULL REFERENCES query_sets(id) ON DELETE CASCADE,
            entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(query_set_id, entity_id)
          );
        SQL
        query_rows.each do |row|
          db.execute("INSERT OR IGNORE INTO query_sets(id, cache_key, language_id, operation, arguments_json, fetched_at, expires_at, accessed_at, hits) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)", row)
        end
        memberships.each do |row|
          db.execute("INSERT OR IGNORE INTO query_set_entities(query_set_id, entity_id, ordinal) VALUES(?, ?, ?)", row)
        end
        db.execute_batch("DROP TABLE query_sets_legacy_v1;")
      end
      db.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(2, ?)", [Time.now.to_f])
    ensure
      db.execute_batch("PRAGMA foreign_keys = ON;")
    end

    def migrate_vehicle_models(db)
      columns = db.table_info("vehicle_models").map { |column| column["name"] || column[1] }
      unless columns.include?("year_entity_id")
        db.execute_batch("ALTER TABLE vehicle_models ADD COLUMN year_entity_id INTEGER REFERENCES entities(id);")
        db.execute("CREATE INDEX IF NOT EXISTS vehicle_models_year_entity ON vehicle_models(year_entity_id)")
        rows = db.execute("SELECT vm.entity_id, vm.make_entity_id, vm.year, make.data_json, make.language_id FROM vehicle_models vm JOIN entities make ON make.id = vm.make_entity_id")
        db.transaction do
          rows.each do |model_id, make_id, year, make_json, language_id|
            make_data = CacheCodec.load(make_json)
            make_name = make_data.is_a?(Hash) ? (make_data[:name] || make_data["name"]) : nil
            next unless make_name

            year_id = persist_year(db, language_id, make_id, make_name, year)
            db.execute("UPDATE vehicle_models SET year_entity_id = ? WHERE entity_id = ?", [year_id, model_id])
            link_entity(db, model_id, "year", year_id, 0)
            link_entity(db, model_id, "make", make_id, 0)
          end
        end
      end
      db.execute("CREATE INDEX IF NOT EXISTS vehicle_models_year_entity ON vehicle_models(year_entity_id)")
      db.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(3, ?)", [Time.now.to_f])
    end

    def migrate_raw_display_columns(db)
      tables = %w[makes vehicle_models part_categories parts tool_categories tools]
      db.transaction do
        tables.each do |table|
          columns = db.table_info(table).map { |column| column["name"] || column[1] }
          db.execute_batch("ALTER TABLE #{table} ADD COLUMN name TEXT;") unless columns.include?("name")
          rows = db.execute("SELECT data.id, data.data_json FROM entities data JOIN #{table} typed ON typed.entity_id = data.id WHERE typed.name IS NULL")
          rows.each do |entity_id, payload|
            begin
              value = CacheCodec.load(payload)
              name = if value.is_a?(Model) && value.respond_to?(:name)
                       value.name
                     elsif value.is_a?(Hash)
                       value[:name] || value["name"]
                     end
              db.execute("UPDATE #{table} SET name = ? WHERE entity_id = ?", [name, entity_id]) unless name.nil?
            rescue StandardError
              next
            end
          end
        end
        db.execute("INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(4, ?)", [Time.now.to_f])
      end
    end

    def vehicle_model_id(db, language_id, make, year, model)
      make_id = persist_entity(db, language_id, "make", make.to_s.downcase, { name: make })
      db.execute("INSERT INTO makes(entity_id, name, display_name) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name", [make_id, make, DisplayText.titleize(make, language: language_for(db, language_id))])
      natural = "#{make.to_s.downcase}:#{year}:#{model.to_s.downcase}"
      id = persist_entity(db, language_id, "vehicle_model", natural, { make: make, year: year, name: model })
      year_id = persist_year(db, language_id, make_id, make, year)
      db.execute("INSERT INTO vehicle_models(entity_id, make_entity_id, year_entity_id, year, name, display_name) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year_entity_id=excluded.year_entity_id, year=excluded.year, name=excluded.name, display_name=excluded.display_name", [id, make_id, year_id, year, model, DisplayText.titleize(model, language: language_for(db, language_id))])
      link_entity(db, id, "make", make_id, 0)
      link_entity(db, id, "year", year_id, 0)
      link_entity(db, make_id, "years", year_id, 0)
      id
    end

    def persist_year(db, language_id, make_id, make, year)
      id = persist_entity(db, language_id, "year", "#{make.to_s.downcase}:#{year}", { make: make, year: year })
      db.execute("INSERT INTO vehicle_years(entity_id, make_entity_id, year) VALUES(?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET make_entity_id=excluded.make_entity_id, year=excluded.year", [id, make_id, year])
      link_entity(db, id, "make", make_id, 0)
      id
    end

    def persist_category(db, language_id, category)
      id = persist_entity(db, language_id, "part_category", category.group_name.to_s.downcase, category)
      raw_name = CacheCodec.raw_attributes(category)[:name]
      db.execute("INSERT INTO part_categories(entity_id, name, display_name, group_name, href) VALUES(?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET name=excluded.name, display_name=excluded.display_name, group_name=excluded.group_name, href=excluded.href", [id, raw_name, DisplayText.titleize(raw_name, language: language_for(db, language_id)), category.group_name, category.href])
      id
    end

    def persist_part(db, language_id, part)
      number = part.part_number.to_s
      id = persist_entity(db, language_id, "part", number.empty? ? Digest::SHA256.hexdigest(CacheCodec.dump(part)) : number.downcase, part)
      raw_name = CacheCodec.raw_attributes(part)[:name]
      db.execute("INSERT INTO parts(entity_id, part_number, name, display_name, brand, price, url, image_url, info_url, video_url) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET part_number=excluded.part_number, name=excluded.name, display_name=excluded.display_name, brand=excluded.brand, price=excluded.price, url=excluded.url, image_url=excluded.image_url, info_url=excluded.info_url, video_url=excluded.video_url",
                 [id, number, raw_name, DisplayText.titleize(raw_name, language: language_for(db, language_id)), part.brand, part.price, part.url, part.image_url, part.info_url, part.video_url])
      id
    end

    def persist_tool_category(db, language_id, category)
      path = category.href.to_s.split(/[?#]/, 2).first.to_s
      path = path.sub(%r{\Ahttps?://[^/]+}, "")
      path = path.sub(%r{\A/[^/]+/tools/}, "")
      natural_key = path.empty? ? category.group_name.to_s.downcase : path.downcase
      parent_id = nil
      if path.include?(",")
        parent_path = path.split(",")[0...-1].join(",")
        parent_key = parent_path.downcase
        parent_id = db.get_first_value("SELECT id FROM entities WHERE language_id = ? AND entity_type = 'tool_category' AND natural_key = ?", [language_id, parent_key])
        unless parent_id
          lang_code = db.get_first_value("SELECT code FROM languages WHERE id = ?", [language_id])
          parent_name = parent_path.split(",").last.to_s.tr("+", " ")
          parent = ToolCategory.new(name: DisplayText.titleize(parent_name, language: lang_code), group_name: parent_name,
                                    href: "/#{lang_code}/tools/#{parent_path}", level: [category.level.to_i - 1, 1].max)
          parent_id = persist_tool_category(db, language_id, parent)
        end
      end
      id = persist_entity(db, language_id, "tool_category", natural_key, category)
      raw_name = CacheCodec.raw_attributes(category)[:name]
      db.execute("INSERT INTO tool_categories(entity_id, parent_entity_id, group_name, name, display_name, href, level) VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET parent_entity_id=excluded.parent_entity_id, group_name=excluded.group_name, name=excluded.name, display_name=excluded.display_name, href=excluded.href, level=excluded.level", [id, parent_id, category.group_name, raw_name, DisplayText.titleize(raw_name, language: language_for(db, language_id)), category.href, category.level])
      link_entity(db, parent_id, "children", id, category.level.to_i) if parent_id
      id
    end

    def link_tool_category_ancestors(db, result_id, category_id)
      ordinal = 0
      parent_id = db.get_first_value("SELECT parent_entity_id FROM tool_categories WHERE entity_id = ?", [category_id])
      while parent_id
        link_entity(db, result_id, "tool_category_ancestors", parent_id, ordinal)
        ordinal += 1
        parent_id = db.get_first_value("SELECT parent_entity_id FROM tool_categories WHERE entity_id = ?", [parent_id])
      end
    end

    def persist_tool(db, language_id, tool)
      number = tool.part_number.to_s
      id = persist_entity(db, language_id, "tool", number.empty? ? Digest::SHA256.hexdigest(CacheCodec.dump(tool)) : number.downcase, tool)
      raw_name = CacheCodec.raw_attributes(tool)[:name]
      db.execute("INSERT INTO tools(entity_id, part_number, name, display_name, brand, price, url, image_url, info_url) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(entity_id) DO UPDATE SET part_number=excluded.part_number, name=excluded.name, display_name=excluded.display_name, brand=excluded.brand, price=excluded.price, url=excluded.url, image_url=excluded.image_url, info_url=excluded.info_url",
                 [id, number, raw_name, DisplayText.titleize(raw_name, language: language_for(db, language_id)), tool.brand, tool.price, tool.url, tool.image_url, tool.info_url])
      id
    end

    def language_for(db, language_id)
      db.get_first_value("SELECT code FROM languages WHERE id = ?", [language_id]) || "en"
    end

    def with_db
      db = SQLite3::Database.new(path)
      db.busy_timeout = 5000
      db.execute("PRAGMA foreign_keys = ON")
      yield db
    ensure
      db&.close
    end
  end

  # Decorates selected public read methods without changing their return types.
  module PersistentClientCache
    TTL_METHODS = {
      get_manufacturers: :dropdown_cache_hours,
      get_part_groups: :dropdown_cache_hours,
      get_part_types: :dropdown_cache_hours
    }.freeze
    CACHED_METHODS = %i[
      get_makes get_years_for_make get_models_for_make_year get_engines_for_vehicle get_vehicle
      get_part_categories search_parts get_parts_by_category get_individual_parts_from_subcategory
      get_tool_categories get_tools_by_category get_manufacturers get_part_groups get_part_types
      search_parts_by_number what_is_part_called
    ].freeze

    CACHED_METHODS.each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        store = @result_cache
        cacheable = method_name != :get_vehicle
        unless cacheable && @cache_config.enabled && store && @cache_backend == :sqlite
          result = super(*args, **kwargs, &block)
          return display == :transformed ? ResultPresenter.call(result, language: language) : result
        end

        key_data = JSON.generate([method_name, language, CacheCodec.encode(args), CacheCodec.encode(kwargs)])
        key = "v1:#{Digest::SHA256.hexdigest(key_data)}"
        cached = store.read(key, language: language)
        return ResultPresenter.call(cached, language: language) if !cached.nil? && display == :transformed
        return cached unless cached.nil?

        result = super(*args, **kwargs, &block)
        ttl_setting = PersistentClientCache::TTL_METHODS[method_name]
        ttl = if ttl_setting
                @dropdown_cache_hours
              elsif %i[get_parts_by_category get_individual_parts_from_subcategory].include?(method_name)
                @cache_config.part_ttl_hours
              elsif %i[search_parts_by_number get_tools_by_category].include?(method_name)
                @cache_config.result_ttl_hours
              else
                @dropdown_cache_hours
              end
        store.write(key, result, ttl_hours: ttl, language: language,
                    operation: method_name, arguments: [args, kwargs]) unless result.nil?
        display == :transformed ? ResultPresenter.call(result, language: language) : result
      end
    end
  end
end
