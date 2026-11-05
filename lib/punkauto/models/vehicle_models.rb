# frozen_string_literal: true

module Punkauto
  # Models available for a specific make and year.
  class VehicleModels < Model
    attribute :make    # Vehicle make
    attribute :year    # Vehicle year
    attribute :models  # Available models
    attribute :count   # Total number of models
  end
end
