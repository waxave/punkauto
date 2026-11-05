# frozen_string_literal: true

module Punkauto
  # Represents an individual tool with static information (no pricing data).
  class ToolInfo < Model
    attribute :name
    attribute :part_number, default: "Unknown"
    attribute :price, default: nil
    attribute :brand, default: nil
    attribute :description, default: nil
    attribute :url, default: nil
    attribute :image_url, default: nil
    attribute :info_url, default: nil
    attribute :video_url, default: nil
    attribute :specifications, default: nil

    # Static technical details
    attribute :category, default: nil
    attribute :features, default: nil
    attribute :warranty_info, default: nil

    def to_s
      brand_str = brand ? " (#{brand})" : ""
      "#{name}#{brand_str}"
    end
  end

  # Complete tool information including static data and pricing history.
  class ToolWithHistory < Model
    attribute :tool_info                          # Static tool information
    attribute :pricing_history, default: nil      # Complete pricing and stock history

    def current_price
      pricing_history&.current_price
    end

    def current_availability
      pricing_history&.current_availability
    end

    def price_history
      return [] unless pricing_history

      pricing_history.price_history.map do |snapshot|
        {
          price: snapshot.price,
          availability: snapshot.availability,
          stock_level: snapshot.stock_level,
          time_collected: snapshot.time_collected,
          shipping_info: snapshot.shipping_info,
          sale_info: snapshot.sale_info
        }
      end
    end

    def price_trend_analysis
      return { trend: nil, lowest_price: nil, highest_price: nil } unless pricing_history

      {
        trend: pricing_history.price_trend,
        lowest_price: pricing_history.lowest_price,
        highest_price: pricing_history.highest_price,
        price_history_count: pricing_history.price_history.length,
        has_recent_data: pricing_history.has_recent_data?
      }
    end

    def needs_price_refresh?(max_age_minutes: 30)
      !(pricing_history && pricing_history.has_recent_data?(max_age_minutes))
    end

    def update_pricing(price: nil, availability: nil, stock_level: nil,
                       shipping_info: nil, sale_info: nil, source_url: nil)
      if pricing_history.nil?
        self.pricing_history = PriceInfo.new(part_number: tool_info.part_number)
      end

      snapshot = PriceStockSnapshot.new(
        price: price,
        availability: availability,
        stock_level: stock_level,
        shipping_info: shipping_info,
        sale_info: sale_info,
        source_url: source_url
      )

      pricing_history.add_snapshot(snapshot)
    end

    def to_s
      price = current_price
      price_str = price ? " - #{price}" : ""
      brand_str = tool_info.brand ? " (#{tool_info.brand})" : ""
      "#{tool_info.name}#{price_str}#{brand_str}"
    end
  end
end
