# frozen_string_literal: true

module Punkauto
  # Result of a tools search containing individual tools.
  class ToolsResult < Model
    attribute :tools
    attribute :count
    attribute :category
    attribute :category_path

    def to_s
      "ToolsResult(#{count} tools in #{category})"
    end
  end
end
