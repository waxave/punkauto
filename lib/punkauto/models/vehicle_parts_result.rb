# frozen_string_literal: true

module Punkauto
  # Parts results for a specific vehicle and category.
  class VehiclePartsResult < Model
    attribute :make      # Vehicle make
    attribute :year      # Vehicle year
    attribute :model     # Vehicle model
    attribute :carcode   # Vehicle carcode
    attribute :category  # Part category name
    attribute :parts     # Found parts
    attribute :count     # Total number of parts found
  end
end
