# frozen_string_literal: true

module Punkauto
  # Individual item in an order.
  class OrderItem < Model
    attribute :part_number
    attribute :description
    attribute :brand
    attribute :quantity
    attribute :unit_price
    attribute :total_price
    attribute :status, default: "Unknown"
    attribute :tracking_number, default: nil
  end

  # Shipping information for an order.
  class ShippingInfo < Model
    attribute :method
    attribute :cost
    attribute :carrier, default: nil
    attribute :tracking_number, default: nil
    attribute :estimated_delivery, default: nil
    attribute :actual_delivery, default: nil
  end

  # Billing information for an order.
  class BillingInfo < Model
    attribute :subtotal
    attribute :shipping_cost
    attribute :tax, default: "$0.00"
    attribute :total
    attribute :payment_method, default: nil
    attribute :payment_status, default: "Unknown"
  end

  # Complete order status information.
  class OrderStatus < Model
    attribute :order_number
    attribute :order_date, default: nil
    attribute :status
    attribute :customer_email, default: nil
    attribute :customer_phone, default: nil

    attribute :items, default: -> { [] }
    attribute :item_count, default: 0

    attribute :billing, default: nil
    attribute :shipping, default: nil

    attribute :notes, default: nil
    attribute :return_eligibility, default: false
    attribute :last_updated, default: nil

    def validate!
      unless order_number && order_number.match?(/\A\d+\z/)
        raise ArgumentError, "Order number must be numeric"
      end
      raise ArgumentError, "Order number cannot exceed 12 digits" if order_number.length > 12
    end

    def total_items
      items.sum(&:quantity)
    end

    def shipped_items
      items.select(&:tracking_number)
    end

    def pending_items
      shipped_statuses = %w[shipped delivered in\ transit]
      items.reject { |item| shipped_statuses.include?(item.status.downcase) }
    end

    def fully_shipped?
      shipped_items.length == items.length
    end

    def tracking_info?
      items.any?(&:tracking_number)
    end
  end

  # Request parameters for order lookup.
  class OrderLookupRequest < Model
    attribute :email_or_phone
    attribute :order_number

    def validate!
      validate_order_number!
      validate_email_or_phone!
    end

    private

    def validate_order_number!
      unless order_number && order_number.match?(/\A\d+\z/)
        raise ArgumentError, "Order number must be numeric"
      end
      raise ArgumentError, "Order number cannot exceed 12 digits" if order_number.length > 12
    end

    def validate_email_or_phone!
      raise ArgumentError, "Email or phone cannot be empty" if email_or_phone.nil? || email_or_phone.strip.empty?
      raise ArgumentError, "Email or phone cannot exceed 50 characters" if email_or_phone.length > 50

      @email_or_phone = email_or_phone.strip
    end
  end

  # Request to get list of orders for a customer.
  class OrderListRequest < Model
    attribute :method
    attribute :contact

    def validate!
      unless %w[email sms].include?(method.downcase)
        raise ArgumentError, "Method must be 'email' or 'sms'"
      end
      @method = method.downcase

      raise ArgumentError, "Contact information cannot be empty" if contact.nil? || contact.strip.empty?
      raise ArgumentError, "Contact information cannot exceed 50 characters" if contact.length > 50

      @contact = contact.strip
    end
  end

  # Error response from order status lookup.
  class OrderStatusError < Model
    attribute :error_type
    attribute :message
    attribute :order_number, default: nil
    attribute :suggestions, default: -> { [] }

    def self.order_not_found(order_number)
      new(
        error_type: "ORDER_NOT_FOUND",
        message: "Order #{order_number} was not found",
        order_number: order_number,
        suggestions: [
          "Verify the order number is correct",
          "Check that the email/phone matches the order",
          "Ensure the order was placed with RockAuto"
        ]
      )
    end

    def self.invalid_credentials(order_number)
      new(
        error_type: "INVALID_CREDENTIALS",
        message: "Email or phone does not match order records",
        order_number: order_number,
        suggestions: [
          "Verify email address spelling",
          "Try phone number if email doesn't work",
          "Check for alternate email addresses used"
        ]
      )
    end

    def self.system_error(message)
      new(
        error_type: "SYSTEM_ERROR",
        message: message,
        suggestions: [
          "Try again in a few minutes",
          "Clear browser cache and cookies",
          "Contact RockAuto customer service"
        ]
      )
    end
  end

  # Result from order status lookup.
  class OrderStatusResult < Model
    attribute :success
    attribute :order, default: nil
    attribute :error, default: nil
    attribute :lookup_time, default: -> { Time.now.iso8601 }

    def self.success_result(order)
      new(success: true, order: order)
    end

    def self.error_result(error)
      new(success: false, error: error)
    end

    def to_s
      if success && order
        "Order #{order.order_number}: #{order.status}"
      elsif error
        "Error: #{error.message}"
      else
        "Unknown result"
      end
    end
  end
end
