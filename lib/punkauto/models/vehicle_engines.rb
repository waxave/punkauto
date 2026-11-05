# frozen_string_literal: true

module Punkauto
  # Engines available for a specific make, year, and model.
  class VehicleEngines < Model
    attribute :make     # Vehicle make
    attribute :year     # Vehicle year
    attribute :model    # Vehicle model
    attribute :engines  # Available engine configurations
    attribute :count    # Total number of engines
  end
end
