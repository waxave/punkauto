# frozen_string_literal: true

module Punkauto
  # Represents a part category/group.
  class PartCategory < Model
    attribute :name        # Category name (e.g., 'Brake & Wheel Hub')
    attribute :group_name  # URL-encoded group name for API calls
    attribute :href, default: nil
  end
end
