# frozen_string_literal: true

module Punkauto
  # Part categories available for a specific vehicle.
  class VehiclePartCategories < Model
    attribute :make        # Vehicle make
    attribute :year        # Vehicle year
    attribute :model       # Vehicle model
    attribute :carcode     # Vehicle carcode
    attribute :categories  # Available part categories
    attribute :count       # Total number of categories
  end
end
