# frozen_string_literal: true

module Punkauto
  # Collection of tool categories.
  class ToolCategories < Model
    attribute :categories
    attribute :count
    attribute :level
    attribute :parent_path, default: ""

    def to_s
      "ToolCategories(#{count} categories at level #{level})"
    end
  end
end
