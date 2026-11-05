# frozen_string_literal: true

module Punkauto
  # Filter parameters for order history search.
  class OrderHistoryFilter < Model
    VALID_RANGES = ["1 Month", "3 Months", "6 Months", "9 Months", "1 Year", "2 Years", "All"].freeze

    attribute :date_range, default: "3 Months"
    attribute :vehicle, default: "All"
    attribute :part_category, default: "All"
    attribute :part_number, default: nil

    def validate!
      return if VALID_RANGES.include?(date_range)

      raise ArgumentError, "Date range must be one of: #{VALID_RANGES.join(', ')}"
    end
  end

  # Individual order in order history.
  class OrderHistoryItem < Model
    attribute :order_number
    attribute :date
    attribute :status
    attribute :total
    attribute :vehicle, default: nil
    attribute :order_url, default: nil
  end

  # Result from order history search.
  class OrderHistoryResult < Model
    attribute :orders, default: -> { [] }
    attribute :count, default: 0
    attribute :filter_applied
    attribute :search_time, default: -> { Time.now.iso8601 }

    def orders_by_status(status)
      orders.select { |order| order.status.downcase.include?(status.downcase) }
    end

    def total_amount
      total = 0.0
      orders.each do |order|
        begin
          total += order.total.delete("$,").to_f
        rescue StandardError
          next
        end
      end
      total
    end
  end

  # Request to add external order to account history.
  class ExternalOrderRequest < Model
    attribute :email_or_phone
    attribute :order_number

    def validate!
      unless order_number && order_number.match?(/\A\d+\z/)
        raise ArgumentError, "Order number must be numeric"
      end
      raise ArgumentError, "Order number cannot exceed 12 digits" if order_number.length > 12

      raise ArgumentError, "Email or phone cannot be empty" if email_or_phone.nil? || email_or_phone.strip.empty?
      raise ArgumentError, "Email or phone cannot exceed 50 characters" if email_or_phone.length > 50

      @email_or_phone = email_or_phone.strip
    end
  end

  # Saved address information.
  class SavedAddress < Model
    attribute :name
    attribute :full_name
    attribute :address_line1
    attribute :address_line2, default: nil
    attribute :city
    attribute :state
    attribute :postal_code
    attribute :country, default: "US"
    attribute :phone, default: nil
    attribute :is_default, default: false
    attribute :address_id, default: nil
  end

  # Result from retrieving saved addresses.
  class SavedAddressesResult < Model
    attribute :addresses, default: -> { [] }
    attribute :count, default: 0
    attribute :has_default, default: false

    def default_address
      addresses.find(&:is_default)
    end
  end

  # Saved vehicle information.
  class SavedVehicle < Model
    attribute :year
    attribute :make
    attribute :model
    attribute :engine, default: nil
    attribute :carcode, default: nil
    attribute :display_name
    attribute :catalog_url, default: nil
    attribute :vehicle_id, default: nil
  end

  # Result from retrieving saved vehicles.
  class SavedVehiclesResult < Model
    attribute :vehicles, default: -> { [] }
    attribute :count, default: 0

    def vehicle_by_year_make_model(year, make, model)
      vehicles.find do |vehicle|
        vehicle.year == year &&
          vehicle.make.upcase == make.upcase &&
          vehicle.model.upcase == model.upcase
      end
    end
  end

  # Comprehensive account activity information.
  class AccountActivityResult < Model
    attribute :order_history, default: nil
    attribute :saved_addresses, default: nil
    attribute :saved_vehicles, default: nil
    attribute :has_discount_codes, default: false
    attribute :has_store_credit, default: false
    attribute :has_alerts, default: false
    attribute :last_updated, default: -> { Time.now.iso8601 }
  end
end
