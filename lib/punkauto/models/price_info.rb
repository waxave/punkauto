# frozen_string_literal: true

module Punkauto
  # A single price/stock observation at a specific time.
  class PriceStockSnapshot < Model
    attribute :price, default: nil
    attribute :availability, default: nil
    attribute :stock_level, default: nil
    attribute :shipping_info, default: nil
    attribute :sale_info, default: nil
    attribute :time_collected, default: -> { Time.now }
    attribute :source_url, default: nil

    def recent?(max_age_minutes = 60)
      (Time.now - time_collected) < (max_age_minutes * 60)
    end

    def to_s
      price_str = price || "Price not available"
      availability_str = availability ? " (#{availability})" : ""
      "#{price_str}#{availability_str} at #{time_collected.strftime('%Y-%m-%d %H:%M')}"
    end
  end

  # Historical price and stock tracking for a specific part.
  class PriceInfo < Model
    attribute :part_number
    attribute :current_snapshot, default: nil
    attribute :price_history, default: -> { [] }
    attribute :max_history_entries, default: 50

    def add_snapshot(snapshot)
      self.current_snapshot = snapshot
      price_history << snapshot
      self.price_history = price_history.last(max_history_entries) if price_history.length > max_history_entries
    end

    def current_price
      current_snapshot&.price if current_snapshot&.recent?
    end

    def current_availability
      current_snapshot&.availability if current_snapshot&.recent?
    end

    def has_recent_data?(max_age_minutes = 60)
      !current_snapshot.nil? && current_snapshot.recent?(max_age_minutes)
    end

    def price_trend
      return nil if price_history.length < 2

      recent_prices = []
      price_history.last(5).reverse_each do |snapshot|
        next unless snapshot.price

        begin
          recent_prices << snapshot.price.delete("$,").to_f
        rescue StandardError
          next
        end
      end

      return nil if recent_prices.length < 2

      first_price = recent_prices.last  # Oldest in sample
      last_price  = recent_prices.first # Most recent

      if last_price > first_price * 1.05
        "increasing"
      elsif last_price < first_price * 0.95
        "decreasing"
      else
        "stable"
      end
    end

    def lowest_price
      lowest_price = nil
      lowest_value = Float::INFINITY

      price_history.each do |snapshot|
        next unless snapshot.price

        begin
          price_num = snapshot.price.delete("$,").to_f
          if price_num < lowest_value
            lowest_value = price_num
            lowest_price = snapshot.price
          end
        rescue StandardError
          next
        end
      end

      lowest_price
    end

    def highest_price
      highest_price = nil
      highest_value = 0

      price_history.each do |snapshot|
        next unless snapshot.price

        begin
          price_num = snapshot.price.delete("$,").to_f
          if price_num > highest_value
            highest_value = price_num
            highest_price = snapshot.price
          end
        rescue StandardError
          next
        end
      end

      highest_price
    end
  end

  # Combines static part information with dynamic pricing data.
  class PartWithPricing < Model
    attribute :name
    attribute :part_number
    attribute :brand, default: nil
    attribute :url, default: nil
    attribute :image_url, default: nil
    attribute :info_url, default: nil
    attribute :video_url, default: nil
    attribute :pricing, default: nil

    def update_pricing(price: nil, availability: nil, stock_level: nil,
                       shipping_info: nil, sale_info: nil, source_url: nil)
      snapshot = PriceStockSnapshot.new(
        price: price,
        availability: availability,
        stock_level: stock_level,
        shipping_info: shipping_info,
        sale_info: sale_info,
        source_url: source_url
      )

      self.pricing = PriceInfo.new(part_number: part_number) if pricing.nil?
      pricing.add_snapshot(snapshot)
    end

    def current_price
      pricing&.current_price
    end

    def current_availability
      pricing&.current_availability
    end

    def needs_price_update?(max_age_minutes = 60)
      !(pricing && pricing.has_recent_data?(max_age_minutes))
    end

    def to_s
      price_str = ""
      if pricing&.current_snapshot&.price
        price_str = " - #{pricing.current_snapshot.price}"
      end

      brand_str = brand ? " (#{brand})" : ""
      "#{name}#{price_str}#{brand_str}"
    end
  end

  # Combines static tool information with dynamic pricing data.
  class ToolWithPricing < Model
    attribute :name
    attribute :part_number, default: "Unknown"
    attribute :brand, default: nil
    attribute :description, default: nil
    attribute :url, default: nil
    attribute :image_url, default: nil
    attribute :info_url, default: nil
    attribute :video_url, default: nil
    attribute :specifications, default: nil
    attribute :pricing, default: nil

    def update_pricing(price: nil, availability: nil, stock_level: nil,
                       shipping_info: nil, sale_info: nil, source_url: nil)
      snapshot = PriceStockSnapshot.new(
        price: price,
        availability: availability,
        stock_level: stock_level,
        shipping_info: shipping_info,
        sale_info: sale_info,
        source_url: source_url
      )

      self.pricing = PriceInfo.new(part_number: part_number) if pricing.nil?
      pricing.add_snapshot(snapshot)
    end

    def current_price
      pricing&.current_price
    end

    def current_availability
      pricing&.current_availability
    end

    def needs_price_update?(max_age_minutes = 60)
      !(pricing && pricing.has_recent_data?(max_age_minutes))
    end

    def to_s
      price_str = ""
      if pricing&.current_snapshot&.price
        price_str = " - #{pricing.current_snapshot.price}"
      end

      brand_str = brand ? " (#{brand})" : ""
      "#{name}#{price_str}#{brand_str}"
    end
  end
end
