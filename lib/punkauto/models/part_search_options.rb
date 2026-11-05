# frozen_string_literal: true

module Punkauto
  # A single dropdown option for parts search.
  class PartSearchOption < Model
    attribute :value  # Option value sent to server
    attribute :text   # Display text for option
  end

  # Collection of manufacturer options for parts search.
  class ManufacturerOptions < Model
    attribute :manufacturers
    attribute :count
    attribute :last_updated, default: nil

    def manufacturer_by_name(name)
      name_lower = name.downcase
      manufacturers.find { |mfr| mfr.text.downcase == name_lower }
    end

    def manufacturer_names
      manufacturers.map(&:text)
    end
  end

  # Collection of part group options for parts search.
  class PartGroupOptions < Model
    attribute :part_groups
    attribute :count
    attribute :last_updated, default: nil

    def part_group_by_name(name)
      name_lower = name.downcase
      part_groups.find { |group| group.text.downcase == name_lower }
    end

    def part_group_names
      part_groups.map(&:text)
    end
  end

  # Collection of part type options for parts search.
  class PartTypeOptions < Model
    attribute :part_types
    attribute :count
    attribute :last_updated, default: nil

    def part_type_by_name(name)
      name_lower = name.downcase
      part_types.find { |type| type.text.downcase == name_lower }
    end
  end

  # Result from 'what is part called' keyword search.
  class WhatIsPartCalledResult < Model
    attribute :main_category
    attribute :subcategory
    attribute :full_path

    def to_s
      "#{main_category}/#{subcategory}"
    end
  end

  # Collection of results from 'what is part called' search.
  class WhatIsPartCalledResults < Model
    attribute :results
    attribute :count
    attribute :search_term

    def category_tuples
      results.map { |result| [result.main_category, result.subcategory] }
    end
  end
end
