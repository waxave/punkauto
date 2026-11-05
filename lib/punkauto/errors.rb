# frozen_string_literal: true

module Punkauto
  # Base error for all Punkauto errors.
  class Error < StandardError; end

  # Raised when an HTTP or API-level request fails.
  class ApiError < Error; end

  # Raised when a feature requires an authenticated session but none exists.
  class AuthenticationRequiredError < Error; end

  # Raised when RockAuto's anti-bot system demands a CAPTCHA.
  class CaptchaError < Error; end

  # Raised when the order status lookup cannot locate an order.
  class OrderNotFoundError < Error; end
end
