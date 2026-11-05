# frozen_string_literal: true

module Punkauto
  # Minimal declarative base class for the data models.
  #
  # Provides lightweight, validation-style model behaviour:
  #   * `attribute :name`                 -> required (missing key raises)
  #   * `attribute :name, default: value` -> optional with default
  #   * `attribute :name, default: -> {}` -> factory for mutable defaults
  #   * unknown keyword arguments are silently ignored
  #
  # Subclasses may define a `validate!` method to normalize/validate input.
  class Model
    UNSET = Object.new.freeze

    class << self
      def attributes
        @attributes ||= {}
      end

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@attributes, attributes.dup)
      end

      def attribute(name, default: UNSET)
        attributes[name] = default
        attr_accessor name
      end
    end

    def initialize(**kwargs)
      self.class.attributes.each do |name, default|
        if kwargs.key?(name)
          instance_variable_set(:"@#{name}", kwargs[name])
        elsif !default.equal?(UNSET)
          instance_variable_set(:"@#{name}", default.respond_to?(:call) ? default.call : default)
        else
          raise ArgumentError, "missing keyword: #{name}"
        end
      end

      validate! if respond_to?(:validate!)
    end

    def to_h
      self.class.attributes.keys.to_h { |name| [name, public_send(name)] }
    end

    def ==(other)
      other.is_a?(self.class) && to_h == other.to_h
    end
    alias eql? ==

    def hash
      [self.class, to_h].hash
    end

    def inspect
      "#<#{self.class.name} #{to_h.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')}>"
    end
  end
end
