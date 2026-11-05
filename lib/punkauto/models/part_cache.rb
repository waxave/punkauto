# frozen_string_literal: true

module Punkauto
  # Wrapper for cached PartInfo with metadata.
  class CachedPartInfo < Model
    attribute :part_info
    attribute :cached_at
    attribute :access_count, default: 1
    attribute :last_accessed

    def self.create(part_info)
      now = Time.now
      new(part_info: part_info, cached_at: now, last_accessed: now)
    end

    def access
      self.access_count += 1
      self.last_accessed = Time.now
      part_info
    end

    def expired?(ttl_hours = 12)
      (Time.now - cached_at) > (ttl_hours * 3600)
    end
  end

  # Wrapper for cached VehiclePartsResult with metadata.
  class CachedVehiclePartsResult < Model
    attribute :result
    attribute :cache_key
    attribute :cached_at
    attribute :access_count, default: 1
    attribute :last_accessed

    def self.create(result, cache_key)
      now = Time.now
      new(result: result, cache_key: cache_key, cached_at: now, last_accessed: now)
    end

    def access
      self.access_count += 1
      self.last_accessed = Time.now
      result
    end

    def expired?(ttl_hours = 12)
      (Time.now - cached_at) > (ttl_hours * 3600)
    end
  end

  # In-memory cache for parts and part search results.
  class PartCache < Model
    attribute :parts, default: -> { {} }
    attribute :vehicle_results, default: -> { {} }
    attribute :max_parts, default: 1000
    attribute :max_results, default: 100

    def get_part(part_number)
      cached = parts[part_number]
      if cached && !cached.expired?
        cached.access
      elsif cached
        parts.delete(part_number)
        nil
      end
    end

    def cache_part(part_info)
      evict_oldest_part if parts.length >= max_parts
      parts[part_info.part_number] = CachedPartInfo.create(part_info)
    end

    def get_vehicle_result(cache_key)
      cached = vehicle_results[cache_key]
      if cached && !cached.expired?
        cached.access
      elsif cached
        vehicle_results.delete(cache_key)
        nil
      end
    end

    def cache_vehicle_result(result, cache_key)
      evict_oldest_result if vehicle_results.length >= max_results
      vehicle_results[cache_key] = CachedVehiclePartsResult.create(result, cache_key)
    end

    def clear_expired
      expired_parts = parts.select { |_k, v| v.expired? }.keys
      expired_results = vehicle_results.select { |_k, v| v.expired? }.keys

      expired_parts.each { |key| parts.delete(key) }
      expired_results.each { |key| vehicle_results.delete(key) }

      [expired_parts.length, expired_results.length]
    end

    def clear_all
      parts.clear
      vehicle_results.clear
    end

    def cache_stats
      total_part_accesses = parts.values.sum(&:access_count)
      total_result_accesses = vehicle_results.values.sum(&:access_count)

      {
        cached_parts: parts.length,
        cached_results: vehicle_results.length,
        total_part_accesses: total_part_accesses,
        total_result_accesses: total_result_accesses,
        avg_part_accesses: parts.empty? ? 0 : (total_part_accesses.to_f / parts.length).round(2),
        avg_result_accesses: vehicle_results.empty? ? 0 : (total_result_accesses.to_f / vehicle_results.length).round(2),
        parts_capacity_used: (parts.length.to_f / max_parts * 100).round(1),
        results_capacity_used: (vehicle_results.length.to_f / max_results * 100).round(1)
      }
    end

    def self.generate_vehicle_cache_key(make, model, year, engine = nil, category = nil)
      key_parts = [make.downcase, model.downcase, year]
      key_parts << engine.downcase if engine
      key_parts << category.downcase if category
      key_parts.join("|")
    end

    private

    def evict_oldest_part
      return if parts.empty?

      oldest_key = parts.min_by { |_k, v| v.last_accessed }.first
      parts.delete(oldest_key)
    end

    def evict_oldest_result
      return if vehicle_results.empty?

      oldest_key = vehicle_results.min_by { |_k, v| v.last_accessed }.first
      vehicle_results.delete(oldest_key)
    end
  end

  # Configuration for part caching behavior.
  class CacheConfiguration < Model
    attribute :enabled, default: true
    attribute :part_ttl_hours, default: 12
    attribute :result_ttl_hours, default: 12
    attribute :max_parts, default: 1000
    attribute :max_results, default: 100
    attribute :auto_cleanup_interval, default: 3600

    def create_cache
      PartCache.new(max_parts: max_parts, max_results: max_results)
    end
  end
end
