# frozen_string_literal: true

module Punkauto
  # Represents a tool category in RockAuto's tools section.
  class ToolCategory < Model
    attribute :name        # Category name (e.g., 'Engine', 'Oil Pump Priming Tool')
    attribute :group_name  # URL-safe group name for API calls
    attribute :href        # Relative URL path to the category
    attribute :level       # Hierarchy level (1=main, 2=subcategory, 3=specific tool)

    def to_s
      "#{name} (Level #{level})"
    end
  end
end
