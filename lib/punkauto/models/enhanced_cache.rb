# frozen_string_literal: true

module Punkauto
  # Cache for static part information that changes infrequently.
  class StaticPartCache < Model
    attribute :parts, default: -> { {} }
    attribute :tools, default: -> { {} }
    attribute :cached_at, default: -> { Time.now }
    attribute :last_cleanup, default: -> { Time.now }
    attribute :ttl_hours, default: 168 # 1 week

    def cache_part(part_info)
      parts[part_info.part_number] = part_info
    end

    def cache_tool(tool_info)
      tools[tool_info.part_number] = tool_info
    end

    def get_part(part_number)
      parts[part_number]
    end

    def get_tool(part_number)
      tools[part_number]
    end

    def expired?
      (Time.now - cached_at) > (ttl_hours * 3600)
    end

    def cleanup_if_needed
      if (Time.now - last_cleanup) > (24 * 3600) # Daily cleanup
        self.last_cleanup = Time.now
      end
    end
  end

  # Cache for dynamic pricing information that changes frequently.
  class PricingCache < Model
    attribute :pricing_data, default: -> { {} }
    attribute :last_cleanup, default: -> { Time.now }
    attribute :max_entries, default: 5000
    attribute :ttl_minutes, default: 30

    def cache_pricing(part_number, price_info)
      pricing_data[part_number] = price_info
      evict_old_entries if pricing_data.length > max_entries
    end

    def get_pricing(part_number)
      price_info = pricing_data[part_number]
      if price_info && price_info.has_recent_data?(ttl_minutes)
        price_info
      elsif price_info
        pricing_data.delete(part_number)
        nil
      end
    end

    def update_pricing(part_number, price: nil, availability: nil, stock_level: nil,
                       shipping_info: nil, sale_info: nil, source_url: nil)
      price_info = pricing_data[part_number]
      if price_info.nil?
        price_info = PriceInfo.new(part_number: part_number)
        pricing_data[part_number] = price_info
      end

      snapshot = PriceStockSnapshot.new(
        price: price,
        availability: availability,
        stock_level: stock_level,
        shipping_info: shipping_info,
        sale_info: sale_info,
        source_url: source_url
      )

      price_info.add_snapshot(snapshot)
    end

    def cleanup_expired
      expired_keys = pricing_data.select { |_k, v| !v.has_recent_data?(ttl_minutes) }.keys
      expired_keys.each { |key| pricing_data.delete(key) }
      self.last_cleanup = Time.now
      expired_keys.length
    end

    def stats
      recent_count = pricing_data.values.count { |v| v.has_recent_data?(ttl_minutes) }
      total_snapshots = pricing_data.values.sum { |v| v.price_history.length }

      {
        total_parts_with_pricing: pricing_data.length,
        parts_with_recent_pricing: recent_count,
        total_price_snapshots: total_snapshots,
        cache_utilization: (pricing_data.length.to_f / max_entries * 100).round(1),
        avg_snapshots_per_part: pricing_data.empty? ? 0 : (total_snapshots.to_f / pricing_data.length).round(1)
      }
    end

    private

    def evict_old_entries
      sorted = pricing_data.sort_by do |_k, v|
        v.current_snapshot ? v.current_snapshot.time_collected : Time.at(0)
      end

      entries_to_remove = [1, sorted.length / 5].max
      sorted.first(entries_to_remove).each { |part_number, _| pricing_data.delete(part_number) }
    end
  end

  # Unified cache that combines static and dynamic data efficiently.
  class EnhancedPartCache < Model
    attribute :static_cache, default: -> { StaticPartCache.new }
    attribute :pricing_cache, default: -> { PricingCache.new }
    attribute :search_results_cache, default: -> { {} }
    attribute :search_cache_ttl_hours, default: 2

    def get_part_with_history(part_number)
      static_info = static_cache.get_part(part_number)
      return nil unless static_info

      PartWithHistory.new(
        part_info: static_info,
        pricing_history: pricing_cache.get_pricing(part_number)
      )
    end

    def get_tool_with_history(part_number)
      static_info = static_cache.get_tool(part_number)
      return nil unless static_info

      ToolWithHistory.new(
        tool_info: static_info,
        pricing_history: pricing_cache.get_pricing(part_number)
      )
    end

    def cache_part_complete(part_info, price: nil, availability: nil, stock_level: nil,
                            shipping_info: nil, sale_info: nil, source_url: nil)
      static_cache.cache_part(part_info)

      if [price, availability, stock_level, shipping_info, sale_info].any?
        pricing_cache.update_pricing(
          part_info.part_number,
          price: price, availability: availability, stock_level: stock_level,
          shipping_info: shipping_info, sale_info: sale_info, source_url: source_url
        )
      end
    end

    def cache_tool_complete(tool_info, price: nil, availability: nil, stock_level: nil,
                            shipping_info: nil, sale_info: nil, source_url: nil)
      static_cache.cache_tool(tool_info)

      if [price, availability, stock_level, shipping_info, sale_info].any?
        pricing_cache.update_pricing(
          tool_info.part_number,
          price: price, availability: availability, stock_level: stock_level,
          shipping_info: shipping_info, sale_info: sale_info, source_url: source_url
        )
      end
    end

    def update_pricing_only(part_number, price: nil, availability: nil, stock_level: nil,
                            shipping_info: nil, sale_info: nil, source_url: nil)
      pricing_cache.update_pricing(
        part_number,
        price: price, availability: availability, stock_level: stock_level,
        shipping_info: shipping_info, sale_info: sale_info, source_url: source_url
      )
    end

    def cache_search_result(cache_key, result)
      search_results_cache[cache_key] = result
    end

    def get_search_result(cache_key)
      search_results_cache[cache_key]
    end

    def cleanup_all
      static_cache.cleanup_if_needed
      expired_pricing = pricing_cache.cleanup_expired

      {
        static_parts_cached: static_cache.parts.length,
        static_tools_cached: static_cache.tools.length,
        pricing_entries_expired: expired_pricing,
        search_results_cached: search_results_cache.length,
        pricing_stats: pricing_cache.stats
      }
    end

    def comprehensive_stats
      pricing_stats = pricing_cache.stats

      {
        static_cache: {
          parts_count: static_cache.parts.length,
          tools_count: static_cache.tools.length,
          is_expired: static_cache.expired?,
          age_hours: (Time.now - static_cache.cached_at) / 3600.0
        },
        pricing_cache: pricing_stats,
        search_cache: {
          results_count: search_results_cache.length
        },
        total_memory_efficiency: {
          static_data_separation: "✅ Static info cached long-term",
          pricing_data_separation: "✅ Pricing cached short-term with history",
          search_results_separation: "✅ Search results cached separately"
        }
      }
    end
  end
end
