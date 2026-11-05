# frozen_string_literal: true

module Punkauto
  # List of available vehicle makes.
  class VehicleMakes < Model
    attribute :makes  # Alphabetically sorted list of vehicle makes
    attribute :count  # Total number of makes
  end
end
