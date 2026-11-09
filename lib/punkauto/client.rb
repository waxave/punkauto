# frozen_string_literal: true

require "json"
require "set"
require "uri"
require "time"
require "nokogiri"

module Punkauto
  # Main RockAuto API client.
  #
  # Talks to RockAuto's catalog API and HTML pages to search for automotive
  # parts, tools, and order status.
  class Client < BaseClient
    BROWSER_HEADERS = {
      "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
      "Accept-Language" => "en-US,en;q=0.9",
      "Accept-Encoding" => "gzip, deflate, br",
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Sec-Ch-Ua" => '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
      "Sec-Ch-Ua-Mobile" => "?0",
      "Sec-Ch-Ua-Platform" => '"Windows"',
      "Sec-Fetch-Dest" => "document",
      "Sec-Fetch-Mode" => "navigate",
      "Sec-Fetch-Site" => "same-origin",
      "Sec-Fetch-User" => "?1",
      "Upgrade-Insecure-Requests" => "1",
      "Referer" => "https://www.rockauto.com/",
      "Cache-Control" => "no-cache",
      "Pragma" => "no-cache"
    }.freeze

    attr_reader :cache_config, :dropdown_cache_hours, :display

    def initialize(
      use_mobile_profile: true,
      language: "en",
      enable_caching: true,
      part_cache_hours: 12,
      search_cache_hours: 12,
      dropdown_cache_hours: 24,
      max_cached_parts: 1000,
      max_cached_searches: 100,
      cache_backend: :sqlite,
      cache_path: nil,
      display: :original
    )
      @display = display.respond_to?(:to_sym) ? display.to_sym : display
      unless %i[original transformed].include?(@display)
        raise ArgumentError, "display must be :original or :transformed"
      end
      super(use_mobile_profile: use_mobile_profile, language: language)

      @nck_token = nil
      @session_initialized = false

      @cache_config = CacheConfiguration.new(
        enabled: enable_caching,
        part_ttl_hours: part_cache_hours,
        result_ttl_hours: search_cache_hours,
        max_parts: max_cached_parts,
        max_results: max_cached_searches
      )

      @part_cache = enable_caching ? @cache_config.create_cache : nil
      @cache_backend = cache_backend.to_sym
      @cache_path = cache_path
      unless %i[sqlite memory].include?(@cache_backend)
        raise ArgumentError, "cache_backend must be :sqlite or :memory"
      end
      @result_cache = if enable_caching
                        if @cache_backend == :sqlite
                          SQLiteResultCache.new(path: cache_path || ENV["PUNKAUTO_CACHE_PATH"] || SQLiteResultCache::DEFAULT_PATH,
                                                max_entries: max_cached_parts + max_cached_searches)
                        else
                          MemoryResultCache.new(max_entries: max_cached_parts + max_cached_searches)
                        end
                      end

      @dropdown_cache_hours = dropdown_cache_hours
      @manufacturer_cache = nil
      @part_group_cache = nil
      @part_type_cache = nil
    end

    # Convenience helper that closes the HTTP session after the block.
    def with
      yield self
    ensure
      close
    end

    # === SESSION / CAPTCHA BYPASS ===

    def initialize_session
      return if @session_initialized

      begin
        response = @session.get("https://www.rockauto.com/")
        html = response.body.to_s

        match = html.match(/window\._nck\s*=\s*"([^"]+)"/)
        if match
          @nck_token = match[1]
        else
          parent_match = html.match(/parent\.window\._nck\s*=\s*"([^"]+)"/)
          @nck_token = parent_match[1] if parent_match
        end

        @session_initialized = true
      rescue StandardError
        @session_initialized = true
      end
    end

    def generate_jnck_token
      return "" unless @nck_token

      encoded = URI.encode_www_form_component(@nck_token)
      "&_jnck=#{encoded}"
    end

    def call_catalog_api(function, payload)
      initialize_session

      api_data = {
        "func" => function,
        "payload" => JSON.generate(payload),
        "api_json_request" => "1"
      }

      jnck = generate_jnck_token
      api_data["_jnck"] = jnck[7..] unless jnck.empty?

      headers = {
        "Accept" => "text/plain, */*; q=0.01",
        "Content-Type" => "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With" => "XMLHttpRequest",
        "Referer" => "https://www.rockauto.com/",
        "sec-ch-ua" => '"Chromium";v="139", "Not;A=Brand";v="99"',
        "sec-ch-ua-mobile" => "?1",
        "sec-ch-ua-platform" => '"iOS"',
        "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
      }

      response = @session.post("https://www.rockauto.com/catalog/catalogapi.php", api_data, headers)
      JSON.parse(response.body)
    rescue StandardError => e
      raise Error, "Catalog API call failed: #{e.message}"
    end

    # === BASIC CATALOG METHODS ===

    def get_makes
      response = @session.get("#{catalog_base}/")
      doc = Nokogiri::HTML(response.body)

      makes = Set.new
      doc.css("a[href]").each do |link|
        href = link["href"].to_s
        next unless href.include?("/catalog/") && href.count("/") >= 3

        # Catalog filter links (language, currency, mobile menu, etc.) often
        # use a query string after the catalog root. They are not vehicle makes.
        path = href.split(/[?#]/, 2).first
        parts = path.to_s.strip("/").split("/")
        next unless parts.length == 3 && parts[1] == "catalog"
        next unless parts.length >= 3

        make = parts[2].split(",", 2).first
        makes.add(make.upcase) if make && make.match?(/\A[A-Za-z][A-Za-z0-9 -]*\z/)
      end

      sorted = makes.to_a.sort
      VehicleMakes.new(makes: sorted, count: sorted.length)
    rescue StandardError => e
      raise Error, "Failed to fetch makes: #{e.message}"
    end

    def get_years_for_make(make)
      simulate_navigation_context(make: make)

      response = @session.get("#{catalog_base}/#{make.downcase}")
      doc = Nokogiri::HTML(response.body)

      years = Set.new
      doc.css("a[href]").each do |link|
        href = link["href"].to_s
        next unless href.include?("/#{make.downcase},")

        parts = href.split(",")
        next if parts.length < 2

        begin
          year = Integer(parts[1])
        rescue ArgumentError
          next
        end

        years.add(year) if year.between?(1950, 2030)
      end

      sorted = years.to_a.sort.reverse
      VehicleYears.new(make: make.upcase, years: sorted, count: sorted.length)
    rescue StandardError => e
      raise Error, "Failed to fetch years for #{make}: #{e.message}"
    end

    def get_models_for_make_year(make, year)
      response = @session.get("#{catalog_base}/#{make.downcase},#{year}")
      doc = Nokogiri::HTML(response.body)

      models = Set.new
      doc.css("a[href]").each do |link|
        href = link["href"].to_s
        next unless href.include?("/#{make.downcase},#{year},")

        parts = href.split(",")
        next if parts.length < 3

        model = parts[2]
        models.add(model.upcase) if model && model.length > 1
      end

      sorted = models.to_a.sort
      VehicleModels.new(make: make.upcase, year: year, models: sorted, count: sorted.length)
    rescue StandardError => e
      raise Error, "Failed to fetch models for #{make} #{year}: #{e.message}"
    end

    def get_engines_for_vehicle(make, year, model)
      url = "#{catalog_base}/#{make.downcase},#{year},#{model.downcase}"
      response = @session.get(url)
      doc = Nokogiri::HTML(response.body)

      engines = []
      doc.css("a[href]").each do |link|
        href = link["href"].to_s
        next unless href.include?("/#{make.downcase},#{year},#{model.downcase},")

        parts = href.split(",")
        next if parts.length < 5

        engine_desc = parts[3]
        carcode = parts[4]

        if engine_desc && carcode && carcode.match?(/\A\d+\z/)
          engine = Engine.new(description: engine_desc.gsub("+", " "), carcode: carcode, href: href)
          engines << engine unless engines.any? { |e| e.carcode == engine.carcode }
        end
      end

      VehicleEngines.new(make: make.upcase, year: year, model: model.upcase, engines: engines, count: engines.length)
    rescue StandardError => e
      raise Error, "Failed to fetch engines for #{make} #{year} #{model}: #{e.message}"
    end

    def get_part_categories(make, year, model, carcode)
      categories = part_categories_for_carcode(carcode)

      VehiclePartCategories.new(
        make: make.upcase, year: year, model: model.upcase,
        carcode: carcode, categories: categories, count: categories.length
      )
    rescue StandardError => e
      raise Error, "Failed to fetch part categories: #{e.message}"
    end

    # Search parts for a carcode directly, without a full vehicle context.
    # Returns the available part categories for the given carcode.
    def search_parts(carcode)
      categories = part_categories_for_carcode(carcode)

      VehiclePartCategories.new(
        make: "", year: 0, model: "",
        carcode: carcode, categories: categories, count: categories.length
      )
    end

    def get_parts_by_category(make, year, model, carcode, category_group_name)
      if @part_cache && @cache_config.enabled
        cache_key = PartCache.generate_vehicle_cache_key(make, model, year.to_s, carcode, category_group_name)
        cached = @part_cache.get_vehicle_result(cache_key)
        return cached if cached
      end

      payload = {
        "jsn" => {
          "carcode" => carcode,
          "groupname" => category_group_name,
          "tab" => "catalog",
          "idepth" => 5,
          "nodetype" => "groupname",
          "jsdata" => {
            "markets" => [{ "c" => "US" }, { "c" => "CA" }],
            "mktlist" => "US,CA",
            "Show" => 1
          }
        }
      }

      result = make_api_request("navnode_fetch", payload)
      parts = []

      if result["html_fill_sections"] && result["html_fill_sections"]["navchildren[]"]
        html_content = result["html_fill_sections"]["navchildren[]"]
        doc = Nokogiri::HTML(html_content)

        subcategory_links = []
        doc.css("a.navlabellink").each do |link|
          href = link["href"].to_s
          link_text = text_of(link)

          price_indicators = ["$", "Price:", "USD"]
          if !href.empty? && href.include?("catalog") && !link_text.empty? &&
             price_indicators.none? { |indicator| link_text.include?(indicator) }
            subcategory_links << [link_text, href]
          end
        end

        unless subcategory_links.empty?
          subcategory_links.each do |subcategory_name, subcategory_url|
            begin
              subcategory_parts = get_individual_parts_from_subcategory(make, year, model, carcode, subcategory_url)
              subcategory_parts.parts.each do |part|
                parts << part
                @part_cache.cache_part(part) if @part_cache && @cache_config.enabled
              end
            rescue StandardError
              # Skip subcategories that fail to parse; keep the rest.
              next
            end
          end
        end

        if parts.empty?
          items = doc.xpath("//div | //tr | //a").select do |node|
            node["class"] && node["class"].match?(/part|product|item/i)
          end

          items.each do |item|
            part_info = PartExtractor.extract_from_element(item)
            if part_info
              parts << part_info
              @part_cache.cache_part(part_info) if @part_cache && @cache_config.enabled
            end
          end

          if parts.empty?
            doc.css("a[href]").each do |link|
              part_info = PartExtractor.extract_from_element(link)
              if part_info && !parts.map(&:name).include?(part_info.name)
                parts << part_info
                @part_cache.cache_part(part_info) if @part_cache && @cache_config.enabled
              end
            end
          end
        end
      end

      vehicle_result = VehiclePartsResult.new(
        make: make.upcase, year: year, model: model.upcase,
        carcode: carcode, category: category_group_name,
        parts: parts, count: parts.length
      )

      if @part_cache && @cache_config.enabled
        cache_key = PartCache.generate_vehicle_cache_key(make, model, year.to_s, carcode, category_group_name)
        @part_cache.cache_vehicle_result(vehicle_result, cache_key)
      end

      vehicle_result
    rescue StandardError => e
      raise Error, "Failed to fetch parts for category: #{e.message}"
    end

    def get_individual_parts_from_subcategory(make, year, model, carcode, subcategory_url)
      url_parts = subcategory_url.strip("/").split(",")
      category_name = "Unknown"
      part_type = nil

      if url_parts.length >= 8
        category_name = url_parts[6].gsub("+", " ")
        part_type = url_parts[7]
      elsif url_parts.length >= 7
        category_name = url_parts[6].gsub("+", " ")
      end

      unless part_type
        return VehiclePartsResult.new(
          make: make.upcase, year: year, model: model.upcase,
          carcode: carcode, category: category_name, parts: [], count: 0
        )
      end

      payload = {
        "jsn" => {
          "carcode" => carcode,
          "parttype" => part_type,
          "tab" => "catalog",
          "idepth" => 8,
          "nodetype" => "parttype",
          "jsdata" => {
            "markets" => [{ "c" => "US" }, { "c" => "CA" }],
            "mktlist" => "US,CA",
            "Show" => 1
          }
        }
      }

      result = make_api_request("navnode_fetch", payload)
      parts = []

      if result["html_fill_sections"] && result["html_fill_sections"]["navchildren[]"]
        html_content = result["html_fill_sections"]["navchildren[]"]
        doc = Nokogiri::HTML(html_content)

        part_name = PartExtractor.titlecase(category_name)
        doc.css(".listing-inner").each do |listing|
          part_info = PartExtractor.extract_from_listing(listing, name: part_name)
          parts << part_info if part_info
        end
      end

      VehiclePartsResult.new(
        make: make.upcase, year: year, model: model.upcase,
        carcode: carcode, category: category_name, parts: parts, count: parts.length
      )
    rescue StandardError
      VehiclePartsResult.new(
        make: make.upcase, year: year, model: model.upcase,
        carcode: carcode, category: "Unknown", parts: [], count: 0
      )
    end

    def extract_part_from_table_row(row, cells)
      part_info = PartExtractor.extract_from_table_row(row, cells)

      if part_info && part_info.info_url
        video_url = extract_video_url(part_info.info_url)
        if video_url
          part_info = PartInfo.new(
            name: part_info.name,
            part_number: part_info.part_number,
            price: part_info.price,
            brand: part_info.brand,
            url: part_info.url,
            image_url: part_info.image_url,
            info_url: part_info.info_url,
            video_url: video_url
          )
        end
      end

      part_info
    end

    def extract_video_url(info_url)
      response = @session.get(info_url)
      doc = Nokogiri::HTML(response.body)
      PartExtractor.extract_video_url(doc.text, doc)
    rescue StandardError
      nil
    end

    # === VEHICLE-SCOPED OPERATIONS ===

    def get_vehicle(make, year, model, engine_index: 0)
      engines_result = get_engines_for_vehicle(make, year, model)
      raise Error, "No engines found for #{make} #{year} #{model}" if engines_result.engines.empty?
      if engine_index >= engines_result.engines.length
        raise Error, "Engine index #{engine_index} out of range. Available engines: #{engines_result.engines.length}"
      end

      selected_engine = engines_result.engines[engine_index]

      vehicle = Vehicle.new(make: make, year: year, model: model, engine: selected_engine)
      vehicle.client = self
      vehicle
    rescue StandardError => e
      raise Error, "Failed to create vehicle: #{e.message}"
    end

    # === TOOLS OPERATIONS ===

    def get_tool_categories(category_path = "")
      url = if category_path.empty?
              localized("/tools/")
            else
              localized("/tools/#{category_path}")
            end

      response = @session.get(url)
      doc = Nokogiri::HTML(response.body)
      categories = []

      level = category_path.empty? ? 1 : category_path.split(",").length

      doc.css("a.navlabellink").each do |link|
        href = link["href"].to_s
        text = text_of(link)

        # Language, currency, and mobile-menu links may share the tools URL
        # but are query parameters, not catalog category paths.
        path = href.split(/[?#]/, 2).first.to_s
        tools_prefix = "/#{language}/tools/"
        next unless path.start_with?(tools_prefix) && !text.empty? && text.length > 2

        path_part = path.delete_prefix(tools_prefix).strip("/")

        if category_path.empty?
          next unless !path_part.empty? && !path_part.include?(",") && !path_part.include?("/")

          categories << ToolCategory.new(name: text, group_name: text, href: href, level: 1)
        else
          next if path_part.empty?

          path_segments = path_part.split(",")
          expected_segments = category_path.split(",").length + 1

          if path_segments.length == expected_segments
            categories << ToolCategory.new(name: text, group_name: text, href: href, level: path_segments.length)
          end
        end
      end

      categories.uniq! { |c| c.name }

      ToolCategories.new(categories: categories, count: categories.length, level: level, parent_path: category_path)
    rescue StandardError => e
      raise Error, "Failed to fetch tool categories: #{e.message}"
    end

    def get_tools_by_category(category_path)
      url = localized("/tools/#{category_path}")
      response = @session.get(url)
      doc = Nokogiri::HTML(response.body)

      # Extract parttype nodes from the tools tree (hidden jsn inputs).
      parttype_ids = []
      doc.css('input[id^="jsn"]').each do |input|
        json = begin
          JSON.parse(input["value"].to_s)
        rescue JSON::ParserError
          nil
        end
        parttype_ids << json["parttype"] if json && json["nodetype"] == "parttype" && json["parttype"]
      end
      parttype_ids.uniq!

      tools = []
      parttype_ids.each do |parttype|
        payload = {
          "jsn" => {
            "tab" => "extras",
            "idepth" => 3,
            "nodetype" => "parttype",
            "parttype" => parttype,
            "jsdata" => { "markets" => [{ "c" => "US" }], "mktlist" => "US", "Show" => 1 }
          }
        }

        result = make_api_request("navnode_fetch", payload)
        html = html_fill_content(result)
        next unless html

        listing_doc = Nokogiri::HTML(html)
        listing_doc.css(".listing-inner").each do |listing|
          part = PartExtractor.extract_from_listing(listing)
          next unless part

          tools << ToolInfo.new(
            name: part.name,
            part_number: part.part_number,
            price: part.price,
            brand: part.brand,
            url: part.url,
            image_url: part.image_url,
            info_url: part.info_url
          )
        end
      end

      category_name = category_path.split(",").last.gsub("+", " ")

      ToolsResult.new(tools: tools, count: tools.length, category: category_name, category_path: category_path)
    rescue StandardError => e
      raise Error, "Failed to fetch tools for category: #{e.message}"
    end

    # === PARTS SEARCH METHODS ===

    def get_manufacturers(use_cache: true)
      return @manufacturer_cache if use_cache && @manufacturer_cache

      response = @session.get(localized("/partsearch/"))
      doc = Nokogiri::HTML(response.body)

      manufacturer_select = doc.at_css("select[id='manufacturer_partsearch_007']")
      raise Error, "Could not find manufacturer dropdown on parts search page" unless manufacturer_select

      manufacturers = []
      manufacturer_select.css("option").each do |option|
        value = option["value"].to_s
        text = text_of(option)
        manufacturers << PartSearchOption.new(value: value, text: text) unless text.empty?
      end

      @manufacturer_cache = ManufacturerOptions.new(
        manufacturers: manufacturers,
        count: manufacturers.length,
        last_updated: Time.now.iso8601
      )
    rescue StandardError => e
      raise Error, "Failed to fetch manufacturers: #{e.message}"
    end

    def get_part_groups(use_cache: true)
      return @part_group_cache if use_cache && @part_group_cache

      response = @session.get(localized("/partsearch/"))
      doc = Nokogiri::HTML(response.body)

      part_group_select = doc.at_css("select[id='partgroup_partsearch_007']")
      raise Error, "Could not find part group dropdown on parts search page" unless part_group_select

      part_groups = []
      part_group_select.css("option").each do |option|
        value = option["value"].to_s
        text = text_of(option)
        part_groups << PartSearchOption.new(value: value, text: text) unless text.empty?
      end

      @part_group_cache = PartGroupOptions.new(
        part_groups: part_groups,
        count: part_groups.length,
        last_updated: Time.now.iso8601
      )
    rescue StandardError => e
      raise Error, "Failed to fetch part groups: #{e.message}"
    end

    def get_part_types(use_cache: true)
      return @part_type_cache if use_cache && @part_type_cache

      response = @session.get(localized("/partsearch/"))
      doc = Nokogiri::HTML(response.body)

      part_type_select = doc.at_css("select[id='parttype_partsearch_007']")
      raise Error, "Could not find part type dropdown on parts search page" unless part_type_select

      part_types = []
      part_type_select.css("option").each do |option|
        value = option["value"].to_s
        text = text_of(option)
        part_types << PartSearchOption.new(value: value, text: text) unless text.empty?
      end

      @part_type_cache = PartTypeOptions.new(
        part_types: part_types,
        count: part_types.length,
        last_updated: Time.now.iso8601
      )
    rescue StandardError => e
      raise Error, "Failed to fetch part types: #{e.message}"
    end

    def clear_parts_search_cache
      @manufacturer_cache = nil
      @part_group_cache = nil
      @part_type_cache = nil
    end

    def search_parts_by_number(part_number, manufacturer: nil, part_group: nil, part_type: nil, part_name: nil)
      response = @session.get(localized("/partsearch/"))
      doc = Nokogiri::HTML(response.body)

      nck_input = doc.at_css("input[name='_nck']")
      raise Error, "Could not find security token on parts search page" unless nck_input

      security_token = nck_input["value"].to_s

      manufacturer_value = ""
      part_group_value = ""
      part_type_value = ""

      if manufacturer && manufacturer.downcase != "all"
        option = get_manufacturers.manufacturer_by_name(manufacturer)
        manufacturer_value = option.value if option
      end

      if part_group && part_group.downcase != "all"
        option = get_part_groups.part_group_by_name(part_group)
        part_group_value = option.value if option
      end

      if part_type && part_type.downcase != "all"
        option = get_part_types.part_type_by_name(part_type)
        part_type_value = option.value if option
      end

      form_data = {
        "_nck" => security_token,
        "dopartsearch" => "1",
        "partsearch[partnum][partsearch_007]" => part_number,
        "partsearch[manufacturer][partsearch_007]" => manufacturer_value,
        "partsearch[partgroup][partsearch_007]" => part_group_value,
        "partsearch[parttype][partsearch_007]" => part_type_value,
        "partsearch[partname][partsearch_007]" => part_name || "",
        "partsearch[do][partsearch_007]" => "Search"
      }

      headers = {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Referer" => localized("/partsearch/")
      }

      search_response = @session.post(localized("/partsearch/"), form_data, headers)
      result_doc = Nokogiri::HTML(search_response.body)
      parts = parse_parts_search_results(result_doc)

      PartSearchResult.new(
        parts: parts,
        count: parts.length,
        search_term: part_number,
        manufacturer: manufacturer || "All",
        part_group: part_group || "All"
      )
    rescue StandardError => e
      raise Error, "Failed to search parts: #{e.message}"
    end

    # Search for part categories using the "what is part called" feature.
    #
    # NOTE: The live RockAuto "what is part called" results are rendered by the
    # client-side autocomplete (JavaScript) and are not present in the
    # server-rendered form response, so this method is best-effort and may
    # return no meaningful results. Prefer `search_parts_by_number` for
    # reliable part discovery.
    def what_is_part_called(search_query)
      response = @session.get(localized("/partsearch/"))
      doc = Nokogiri::HTML(response.body)

      nck_input = doc.at_css("input[name='_nck']")
      raise Error, "Could not find security token on parts search page" unless nck_input

      security_token = nck_input["value"].to_s

      form_data = {
        "_nck" => security_token,
        "topsearchinput[submit]" => "1",
        "topsearchinput[input]" => search_query,
        "btntabsearch" => "Search"
      }

      headers = {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Referer" => localized("/partsearch/")
      }

      search_response = @session.post(localized("/partsearch/"), form_data, headers)
      result_doc = Nokogiri::HTML(search_response.body)
      results = parse_what_is_part_called_results(result_doc)

      WhatIsPartCalledResults.new(results: results, count: results.length, search_term: search_query)
    rescue StandardError => e
      raise Error, "Failed to search part categories: #{e.message}"
    end

    def parse_parts_search_results(doc)
      doc.css(".listing-inner").filter_map do |listing|
        PartExtractor.extract_from_listing(listing)
      end
    end

    def parse_what_is_part_called_results(doc)
      results = []

      doc.css("table").each do |table|
        table.css("tr").each do |row|
          cells = row.css("td, th")
          if cells.length >= 2
            main_category = text_of(cells[0])
            subcategory = text_of(cells[1])

            if !main_category.empty? && !subcategory.empty? && !main_category.include?("/")
              results << WhatIsPartCalledResult.new(
                main_category: main_category,
                subcategory: subcategory,
                full_path: "#{main_category}/#{subcategory}"
              )
            end
          end
        end
      end

      results
    end

    # === CACHE MANAGEMENT METHODS ===

    def cache_stats
      stats = {
        "caching_enabled" => @cache_config.enabled,
        "cache_settings" => {
          "part_cache_hours" => @cache_config.part_ttl_hours,
          "search_cache_hours" => @cache_config.result_ttl_hours,
          "dropdown_cache_hours" => @dropdown_cache_hours,
          "max_cached_parts" => @cache_config.max_parts,
          "max_cached_searches" => @cache_config.max_results
        },
        "dropdown_caches" => {
          "manufacturers_cached" => !@manufacturer_cache.nil?,
          "part_groups_cached" => !@part_group_cache.nil?,
          "part_types_cached" => !@part_type_cache.nil?
        },
        "part_cache" => nil
      }

      stats["part_cache"] = @part_cache.cache_stats if @part_cache
      stats["persistent_cache"] = @result_cache&.stats
      stats["cache_backend"] = @cache_backend.to_s
      stats
    end

    def clear_all_caches
      cleared = {
        "manufacturers" => !@manufacturer_cache.nil?,
        "part_groups" => !@part_group_cache.nil?,
        "part_types" => !@part_type_cache.nil?,
        "parts_cleared" => 0,
        "searches_cleared" => 0
      }

      @manufacturer_cache = nil
      @part_group_cache = nil
      @part_type_cache = nil

      if @part_cache
        stats = @part_cache.cache_stats
        cleared["parts_cleared"] = stats[:cached_parts]
        cleared["searches_cleared"] = stats[:cached_results]
        @part_cache.clear_all
      end

      cleared["result_cache_entries_cleared"] = @result_cache ? @result_cache.clear : 0

      cleared
    end

    def clear_expired_caches
      cleared = { "expired_parts" => 0, "expired_searches" => 0, "expired_dropdowns" => 0 }

      cutoff = Time.now - (@dropdown_cache_hours * 3600)

      if @manufacturer_cache && @manufacturer_cache.last_updated
        if Time.iso8601(@manufacturer_cache.last_updated) < cutoff
          @manufacturer_cache = nil
          cleared["expired_dropdowns"] += 1
        end
      end

      if @part_group_cache && @part_group_cache.last_updated
        if Time.iso8601(@part_group_cache.last_updated) < cutoff
          @part_group_cache = nil
          cleared["expired_dropdowns"] += 1
        end
      end

      if @part_type_cache && @part_type_cache.last_updated
        if Time.iso8601(@part_type_cache.last_updated) < cutoff
          @part_type_cache = nil
          cleared["expired_dropdowns"] += 1
        end
      end

      if @part_cache
        expired_parts, expired_searches = @part_cache.clear_expired
        cleared["expired_parts"] = expired_parts
        cleared["expired_searches"] = expired_searches
      end

      cleared["expired_result_entries"] = @result_cache ? @result_cache.clear_expired : 0

      cleared
    end

    def configure_cache(enable_caching: nil, part_cache_hours: nil, search_cache_hours: nil,
                        dropdown_cache_hours: nil, max_cached_parts: nil, max_cached_searches: nil)
      unless enable_caching.nil?
        @cache_config.enabled = enable_caching
        if !enable_caching
          @part_cache = nil
          @result_cache = nil
        elsif @part_cache.nil?
          @part_cache = @cache_config.create_cache
          @result_cache = if @cache_backend == :sqlite
                            SQLiteResultCache.new(path: @cache_path || ENV["PUNKAUTO_CACHE_PATH"] || SQLiteResultCache::DEFAULT_PATH)
                          else
                            MemoryResultCache.new(max_entries: @cache_config.max_parts + @cache_config.max_results)
                          end
        end
      end

      @cache_config.part_ttl_hours = part_cache_hours unless part_cache_hours.nil?
      @cache_config.result_ttl_hours = search_cache_hours unless search_cache_hours.nil?
      @dropdown_cache_hours = dropdown_cache_hours unless dropdown_cache_hours.nil?

      unless max_cached_parts.nil?
        @cache_config.max_parts = max_cached_parts
        @part_cache.max_parts = max_cached_parts if @part_cache
      end

      unless max_cached_searches.nil?
        @cache_config.max_results = max_cached_searches
        @part_cache.max_results = max_cached_searches if @part_cache
      end

      cache_stats
    end

    # === ORDER STATUS METHODS ===

    def lookup_order_status(email_or_phone, order_number)
      request = OrderLookupRequest.new(email_or_phone: email_or_phone, order_number: order_number)

      response = @session.get("https://www.rockauto.com/orderstatus/")
      doc = Nokogiri::HTML(response.body)

      nck_input = doc.at_css("input[name='_nck']")
      unless nck_input
        return OrderStatusResult.error_result(
          OrderStatusError.system_error("Could not find security token on order status page")
        )
      end

      security_token = nck_input["value"].to_s

      form_data = {
        "_nck" => security_token,
        "action" => "lookup",
        "emailorphone" => request.email_or_phone,
        "ordernum" => request.order_number,
        "lookup" => "Find Order"
      }

      headers = {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Referer" => "https://www.rockauto.com/orderstatus/"
      }

      lookup_response = @session.post("https://www.rockauto.com/orderstatus/orderstatus.php", form_data, headers)
      result_doc = Nokogiri::HTML(lookup_response.body)
      order_status = parse_order_status_response(result_doc, request.order_number)

      if order_status
        OrderStatusResult.success_result(order_status)
      else
        error_message = extract_order_error_message(result_doc)
        error =
          if error_message.downcase.include?("not found")
            OrderStatusError.order_not_found(request.order_number)
          elsif error_message.downcase.include?("email") || error_message.downcase.include?("phone")
            OrderStatusError.invalid_credentials(request.order_number)
          else
            OrderStatusError.system_error(error_message.empty? ? "Order lookup failed" : error_message)
          end

        OrderStatusResult.error_result(error)
      end
    rescue StandardError => e
      OrderStatusResult.error_result(OrderStatusError.system_error("Order lookup failed: #{e.message}"))
    end

    def request_order_list(method, contact)
      request = OrderListRequest.new(method: method, contact: contact)

      response = @session.get("https://www.rockauto.com/orderstatus/")
      doc = Nokogiri::HTML(response.body)

      nck_input = doc.at_css("input[name='_nck']")
      raise Error, "Could not find security token" unless nck_input

      security_token = nck_input["value"].to_s

      timestamp_input = doc.at_css("input[name='timestamp']")
      timestamp = timestamp_input ? timestamp_input["value"].to_s : ""

      form_data =
        if request.method == "email"
          {
            "_nck" => security_token,
            "action" => "sendorders",
            "sendordermethod" => "email",
            "emailaddrsend" => request.contact,
            "timestamp" => timestamp
          }
        else
          {
            "_nck" => security_token,
            "action" => "sendorders",
            "sendordermethod" => "mms",
            "mmsnumbersend" => request.contact,
            "timestamp" => timestamp
          }
        end

      headers = {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Referer" => "https://www.rockauto.com/orderstatus/"
      }

      request_response = @session.post("https://www.rockauto.com/orderstatus/orderstatus.php", form_data, headers)
      response_text = request_response.body.to_s.downcase
      %w[sent delivered order\ list].any? { |indicator| response_text.include?(indicator) }
    rescue StandardError => e
      raise Error, "Failed to request order list: #{e.message}"
    end

    def parse_order_status_response(doc, order_number)
      order_containers = doc.xpath("//div | //table | //section").select do |node|
        node["class"] && node["class"].match?(/order|status|details/i)
      end

      if order_containers.empty?
        order_text = doc.xpath("//text()").find { |node| node.text.match?(Regexp.new(Regexp.escape(order_number))) }
        return nil unless order_text
      end

      order_status = OrderStatus.new(order_number: order_number, status: "Unknown", items: [], item_count: 0)

      extract_basic_order_info(doc, order_status)
      extract_order_items(doc, order_status)
      extract_shipping_info(doc, order_status)
      extract_billing_info(doc, order_status)

      order_status.item_count = order_status.items.length

      return nil unless real_order_data?(order_status, order_number)

      order_status
    rescue StandardError
      nil
    end

    def extract_basic_order_info(doc, order_status)
      doc.xpath("//text()").each do |element|
        next unless element.text.match?(/status|shipped|processing|delivered/i)

        parent = element.parent
        next unless parent

        text = text_of(parent)
        if %w[shipped processing delivered cancelled].any? { |word| text.downcase.include?(word) }
          order_status.status = text
          break
        end
      end

      date_patterns = [
        /order date[:\s]*(.+)/i,
        /placed[:\s]*(.+)/i,
        /date[:\s]*(\d{1,2}\/\d{1,2}\/\d{4})/i
      ]

      date_patterns.each do |pattern|
        date_match = doc.xpath("//text()").find { |node| node.text.match?(pattern) }
        next unless date_match

        match = date_match.text.strip.match(pattern)
        if match
          order_status.order_date = match[1].strip
          break
        end
      end
    end

    def extract_order_items(doc, order_status)
      item_rows = []
      doc.css("table").each do |table|
        table.css("tr").each do |row|
          cells = row.css("td, th")
          item_rows << cells if cells.length >= 3
        end
      end

      item_rows.each do |cells|
        part_number = "Unknown"
        description = "Unknown"
        brand = "Unknown"
        quantity = 1
        unit_price = "$0.00"
        total_price = "$0.00"

        cells.each_with_index do |cell, i|
          text = text_of(cell)
          next unless !text.empty? && text.length > 2

          if i.zero? && text.match?(/\A[A-Z0-9\-]+\z/)
            part_number = text
          elsif text.downcase.include?("qty") || text.match?(/\A\d+\z/)
            quantity = text[/\d+/].to_i rescue quantity
          elsif text.include?("$")
            if text.include?(".")
              if unit_price == "$0.00"
                unit_price = text
              else
                total_price = text
              end
            end
          end
        end

        if part_number != "Unknown" || cells.any? { |cell| text_of(cell).include?("$") }
          order_status.items << OrderItem.new(
            part_number: part_number,
            description: description,
            brand: brand,
            quantity: quantity,
            unit_price: unit_price,
            total_price: total_price
          )
        end
      rescue StandardError
        next
      end
    end

    def extract_shipping_info(doc, order_status)
      tracking_patterns = [
        [/tracking[:\s]*([A-Z0-9]+)/i, nil],
        [/track[:\s]*([A-Z0-9]+)/i, nil],
        [/ups[:\s]*([A-Z0-9]+)/i, "UPS"],
        [/fedex[:\s]*([A-Z0-9]+)/i, "FedEx"],
        [/usps[:\s]*([A-Z0-9]+)/i, "USPS"]
      ]

      tracking_number = nil
      carrier = nil

      tracking_patterns.each do |pattern, default_carrier|
        node = doc.xpath("//text()").find { |n| n.text.match?(pattern) }
        next unless node

        match = node.text.strip.match(pattern)
        if match
          tracking_number = match[1].strip
          if default_carrier
            carrier = default_carrier
          elsif node.text.downcase.include?("ups")
            carrier = "UPS"
          elsif node.text.downcase.include?("fedex")
            carrier = "FedEx"
          elsif node.text.downcase.include?("usps")
            carrier = "USPS"
          end
          break
        end
      end

      shipping_cost = "$0.00"
      [/shipping[:\s]*(\$[\d.]+)/i, /freight[:\s]*(\$[\d.]+)/i].each do |pattern|
        node = doc.xpath("//text()").find { |n| n.text.match?(pattern) }
        next unless node

        match = node.text.strip.match(pattern)
        if match
          shipping_cost = match[1]
          break
        end
      end

      if tracking_number || shipping_cost != "$0.00"
        order_status.shipping = ShippingInfo.new(
          method: "Standard",
          cost: shipping_cost,
          carrier: carrier,
          tracking_number: tracking_number
        )
      end
    rescue StandardError
      nil
    end

    def extract_billing_info(doc, order_status)
      total = "$0.00"
      subtotal = "$0.00"

      [/total[:\s]*(\$[\d.]+)/i, /amount[:\s]*(\$[\d.]+)/i].each do |pattern|
        node = doc.xpath("//text()").find { |n| n.text.match?(pattern) }
        next unless node

        match = node.text.strip.match(pattern)
        if match
          total = match[1]
          break
        end
      end

      [/subtotal[:\s]*(\$[\d.]+)/i, /parts[:\s]*(\$[\d.]+)/i].each do |pattern|
        node = doc.xpath("//text()").find { |n| n.text.match?(pattern) }
        next unless node

        match = node.text.strip.match(pattern)
        if match
          subtotal = match[1]
          break
        end
      end

      if total != "$0.00" || subtotal != "$0.00"
        order_status.billing = BillingInfo.new(
          subtotal: subtotal,
          shipping_cost: "$0.00",
          total: total
        )
      end
    rescue StandardError
      nil
    end

    def extract_order_error_message(doc)
      doc.xpath("//div | //span | //p").each do |element|
        next unless element["class"] && element["class"].match?(/error|alert|warning/i)

        text = text_of(element)
        return text if !text.empty? && text.length > 10
      end

      error_node = doc.xpath("//text()").find { |node| node.text.match?(/error|not found|invalid|failed/i) }
      return error_node.text.strip if error_node

      "Order lookup failed"
    rescue StandardError
      "Unknown error occurred"
    end

    def real_order_data?(order_status, order_number)
      return false unless order_status

      status = order_status.status.to_s
      order_date = order_status.order_date.to_s

      return false if status.length > 1000
      return false if !order_date.empty? && order_date.length > 1000

      actual = order_status.order_number.to_s
      return false if !actual.empty? && actual != order_number.to_s

      item_count = order_status.item_count || 0
      has_billing = !order_status.billing.nil?

      if item_count > 0 && !order_status.items.empty?
        first_item = order_status.items.first
        return false if first_item.description.to_s.length > 500 || first_item.brand.to_s.length > 500
      end

      item_count > 0 || has_billing ||
        (status.length < 100 && status.downcase != "unknown" && !status.empty?)
    end

    # === AUTHENTICATED ACCOUNT METHODS ===

    def add_external_order(email_or_phone, order_number)
      raise AuthenticationRequiredError, "Authentication required for adding external orders" unless @is_authenticated

      request = ExternalOrderRequest.new(email_or_phone: email_or_phone, order_number: order_number)

      response = @session.get(localized("/accountactivity/"))
      doc = Nokogiri::HTML(response.body)

      nck_input = doc.at_css("input[name='_nck']")
      security_token = nck_input ? nck_input["value"].to_s : ""

      form_data = {
        "email_or_phone" => request.email_or_phone,
        "order_number" => request.order_number,
        "add_external_order" => "1"
      }
      form_data["_nck"] = security_token unless security_token.empty?

      headers = {
        "Content-Type" => "application/x-www-form-urlencoded",
        "Referer" => localized("/accountactivity/")
      }

      add_response = @session.post(localized("/accountactivity/"), form_data, headers)
      response_text = add_response.body.to_s.downcase

      success_indicators = %w[added success order\ added]
      failure_indicators = %w[error failed not\ found invalid]

      is_success = success_indicators.any? { |indicator| response_text.include?(indicator) }
      is_failure = failure_indicators.any? { |indicator| response_text.include?(indicator) }

      is_success && !is_failure
    rescue StandardError => e
      raise Error, "Failed to add external order: #{e.message}"
    end

    def get_saved_addresses
      raise AuthenticationRequiredError, "Authentication required for accessing saved addresses" unless @is_authenticated

      response = @session.get(localized("/profile/"), BROWSER_HEADERS)
      doc = Nokogiri::HTML(response.body)
      addresses = []

      addresses_section = doc.at_css("region[aria-label='Saved Addresses']")
      addresses_section ||= doc.xpath("//text()").find { |node| node.text.downcase.include?("saved addresses") }

      if addresses_section
        parent = addresses_section.respond_to?(:parent) ? addresses_section.parent : nil
        address_tables = parent ? parent.css("table") : doc.css("table")

        address_tables.each do |table|
          table.css("tr").each do |row|
            cells = row.css("td, th")
            next if cells.length < 2

            address_cell = cells[0]
            actions_cell = cells[-1]

            address_text = text_of(address_cell)
            next if address_text.empty? || address_text.downcase.include?("edit")

            lines = address_text.split("\n").map(&:strip).reject(&:empty?)
            if lines.length >= 3
              full_name = lines[0]
              address_line1 = lines[1]
              city_state_zip = lines[2]

              city = state = postal_code = ""
              unless city_state_zip.empty?
                parts = city_state_zip.split(",")
                if parts.length >= 2
                  city = parts[0].strip
                  state_zip = parts[1].strip.split
                  if state_zip.length >= 2
                    state = state_zip[0]
                    postal_code = state_zip[1..].join(" ")
                  end
                end
              end

              address_id = nil
              actions_cell&.css("button")&.each do |button|
                next unless button.text.downcase.include?("edit")

                onclick = button["onclick"].to_s
                unless onclick.empty?
                  id_match = onclick.match(/(\d+)/)
                  address_id = id_match[1] if id_match
                end
              end

              addresses << SavedAddress.new(
                name: full_name,
                full_name: full_name,
                address_line1: address_line1,
                city: city,
                state: state,
                postal_code: postal_code,
                country: "US",
                address_id: address_id
              )
            end
          end
        end
      end

      SavedAddressesResult.new(addresses: addresses, count: addresses.length, has_default: addresses.any?(&:is_default))
    rescue StandardError => e
      raise Error, "Failed to get saved addresses: #{e.message}"
    end

    def get_saved_vehicles
      raise AuthenticationRequiredError, "Authentication required for accessing saved vehicles" unless @is_authenticated

      response = @session.get(localized("/profile/"), BROWSER_HEADERS)
      doc = Nokogiri::HTML(response.body)
      vehicles = []

      vehicles_section = doc.at_css("region[aria-label='Saved Vehicles']")
      vehicles_section ||= doc.xpath("//text()").find { |node| node.text.downcase.include?("saved vehicles") }

      if vehicles_section
        parent = vehicles_section.respond_to?(:parent) ? vehicles_section.parent : nil
        vehicle_tables = parent ? parent.css("table") : doc.css("table")

        vehicle_tables.each do |table|
          table.css("tr").each do |row|
            cells = row.css("td, th")
            next if cells.length < 2

            vehicle_cell = cells[0]
            actions_cell = cells.length > 1 ? cells[-1] : nil

            vehicle_link = vehicle_cell.at_css("a")
            next unless vehicle_link

            vehicle_text = text_of(vehicle_link)
            catalog_url = vehicle_link["href"].to_s

            parts = vehicle_text.split
            if parts.length >= 3
              year = parts[0].match?(/\A\d+\z/) ? parts[0].to_i : 0
              make = parts[1]
              model = parts[2..].join(" ")

              carcode = nil
              if catalog_url.include?(",")
                url_parts = catalog_url.split(",")
                carcode = url_parts.last if url_parts.length >= 5
              end

              vehicle_id = nil
              actions_cell&.css("button")&.each do |button|
                next unless button.text.downcase.include?("delete")

                onclick = button["onclick"].to_s
                unless onclick.empty?
                  id_match = onclick.match(/(\d+)/)
                  vehicle_id = id_match[1] if id_match
                end
              end

              full_catalog_url = catalog_url.start_with?("http") ? catalog_url : "https://www.rockauto.com#{catalog_url}"

              vehicles << SavedVehicle.new(
                year: year,
                make: make,
                model: model,
                carcode: carcode,
                display_name: vehicle_text,
                catalog_url: full_catalog_url,
                vehicle_id: vehicle_id
              )
            end
          end
        end
      end

      SavedVehiclesResult.new(vehicles: vehicles, count: vehicles.length)
    rescue StandardError => e
      raise Error, "Failed to get saved vehicles: #{e.message}"
    end

    def get_account_activity
      raise AuthenticationRequiredError, "Authentication required for account activity" unless @is_authenticated

      saved_addresses = get_saved_addresses
      saved_vehicles = get_saved_vehicles

      response = @session.get(localized("/accountactivity/"), BROWSER_HEADERS)
      doc = Nokogiri::HTML(response.body)

      has_discount_codes = doc.xpath("//text()").any? { |node| node.text.downcase.include?("discount code") }
      has_store_credit = doc.xpath("//text()").any? { |node| node.text.downcase.include?("store credit") }
      has_alerts = doc.xpath("//text()").any? { |node| node.text.downcase.include?("availability alerts") }

      AccountActivityResult.new(
        saved_addresses: saved_addresses,
        saved_vehicles: saved_vehicles,
        has_discount_codes: has_discount_codes,
        has_store_credit: has_store_credit,
        has_alerts: has_alerts
      )
    rescue StandardError => e
      raise Error, "Failed to get account activity: #{e.message}"
    end

    def get_order_history(filter_params = nil)
      raise AuthenticationRequiredError, "Authentication required for accessing order history" unless @is_authenticated

      filter_params = OrderHistoryFilter.new if filter_params.nil?

      response = @session.get(localized("/orderhistory/"), BROWSER_HEADERS)
      doc = Nokogiri::HTML(response.body)
      orders = []

      doc.css("table").each do |table|
        rows = table.css("tr")
        rows[1..].each do |row| # skip header
          cells = row.css("td, th")
          next if cells.length < 3

          order_number_cell = text_of(cells[0])
          date_cell = cells.length > 1 ? text_of(cells[1]) : ""
          status_cell = cells.length > 2 ? text_of(cells[2]) : ""
          total_cell = cells.length > 3 ? text_of(cells[3]) : ""

          next if order_number_cell.empty? || date_cell.empty?

          order_url = nil
          status_link = row.at_css("a[href]")
          order_url = "https://www.rockauto.com#{status_link['href']}" if status_link && status_link["href"]

          orders << OrderHistoryItem.new(
            order_number: order_number_cell,
            date: date_cell,
            status: status_cell.empty? ? "Unknown" : status_cell,
            total: total_cell.empty? ? "$0.00" : total_cell,
            order_url: order_url
          )
        rescue StandardError
          next
        end
      end

      if orders.empty?
        doc.xpath("//div | //section").each do |section|
          next unless section["class"] && section["class"].downcase.include?("order")

          order_text = text_of(section)
          order_match = order_text.match(/order\s*#?\s*(\d+)/i)
          date_match = order_text.match(/(\d{1,2}\/\d{1,2}\/\d{4})/)

          if order_match
            orders << OrderHistoryItem.new(
              order_number: order_match[1],
              date: date_match ? date_match[1] : "Unknown",
              status: "Unknown",
              total: "$0.00"
            )
          end
        end
      end

      OrderHistoryResult.new(orders: orders, count: orders.length, filter_applied: filter_params)
    rescue StandardError => e
      raise Error, "Failed to get order history: #{e.message}"
    end

    private

    # Return the single HTML payload from a navnode_fetch response, regardless
    # of whether the key is `navchildren[]` (no groupindex) or
    # `navchildren[{groupindex}]`.
    def html_fill_content(result)
      sections = result["html_fill_sections"]
      return nil unless sections && !sections.empty?

      sections.values.first
    end

    def part_categories_for_carcode(carcode)
      payload = {
        "jsn" => {
          "carcode" => carcode,
          "tab" => "catalog",
          "idepth" => 3,
          "nodetype" => "carcode",
          "jsdata" => {
            "markets" => [{ "c" => "US" }, { "c" => "CA" }],
            "mktlist" => "US,CA",
            "Show" => 1
          }
        }
      }

      result = make_api_request("navnode_fetch", payload)
      categories = []

      if result["html_fill_sections"] && result["html_fill_sections"]["navchildren[]"]
        html_content = result["html_fill_sections"]["navchildren[]"]
        doc = Nokogiri::HTML(html_content)

        doc.css("a.navlabellink").each do |link|
          text = text_of(link)
          href = link["href"].to_s

          if !text.empty? && text.length > 2
            categories << PartCategory.new(name: text, group_name: text, href: href)
          end
        end
      end

      categories
    end

    def text_of(node)
      return "" if node.nil?

      node.text.gsub(/\s+/, " ").strip
    end
  end
end
