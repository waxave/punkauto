# frozen_string_literal: true

module Punkauto
  # Result of a part number search.
  class PartSearchResult < Model
    attribute :parts
    attribute :count
    attribute :search_term
    attribute :manufacturer, default: "All"
    attribute :part_group, default: "All"

    def to_s
      "PartSearchResult(#{count} parts for '#{search_term}')"
    end
  end
end
