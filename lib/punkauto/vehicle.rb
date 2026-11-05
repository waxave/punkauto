# frozen_string_literal: true

module Punkauto
  # Represents a fully specified vehicle with engine configuration.
  #
  # Provides scoped access to parts data for the specific vehicle.
  class Vehicle
    attr_reader :make, :year, :model, :engine, :client

    def initialize(make:, year:, model:, engine:)
      @make = make.upcase
      @year = year
      @model = model.upcase
      @engine = engine
      @client = nil
    end

    # Internal method to set the client reference.
    def client=(client)
      @client = client
    end

    # Get the vehicle's carcode.
    def carcode
      engine.carcode
    end

    # Get part categories for this vehicle.
    def get_part_categories
      raise Error, "Vehicle not properly initialized - missing client reference" unless client

      client.get_part_categories(make, year, model, carcode)
    end

    # Get parts for a specific category on this vehicle.
    def get_parts_by_category(category_group_name)
      raise Error, "Vehicle not properly initialized - missing client reference" unless client

      client.get_parts_by_category(make, year, model, carcode, category_group_name)
    end

    # Get individual parts from a subcategory URL for this vehicle.
    def get_individual_parts_from_subcategory(subcategory_url)
      raise Error, "Vehicle not properly initialized - missing client reference" unless client

      client.get_individual_parts_from_subcategory(make, year, model, carcode, subcategory_url)
    end

    def to_s
      "#{make} #{year} #{model} - #{engine.description}"
    end

    def inspect
      "Vehicle(make='#{make}', year=#{year}, model='#{model}', carcode='#{carcode}')"
    end
  end
end
