# frozen_string_literal: true

module Punkauto
  # Represents a vehicle engine configuration.
  class Engine < Model
    attribute :description # Engine description (e.g., '2.4L L4 DOHC')
    attribute :carcode     # RockAuto's unique vehicle identifier
    attribute :href, default: nil # Link to engine catalog page
  end
end
