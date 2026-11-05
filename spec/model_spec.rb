# frozen_string_literal: true

RSpec.describe Punkauto::Model do
  let(:klass) do
    Class.new(Punkauto::Model) do
      attribute :required_field
      attribute :optional_field, default: nil
      attribute :with_default, default: "hello"
      attribute :factory_field, default: -> { [] }
    end
  end

  it "assigns provided attributes" do
    obj = klass.new(required_field: "x", optional_field: "y")
    expect(obj.required_field).to eq("x")
    expect(obj.optional_field).to eq("y")
  end

  it "raises when a required attribute is missing" do
    expect { klass.new }.to raise_error(ArgumentError, /required_field/)
  end

  it "applies value defaults" do
    expect(klass.new(required_field: "x").with_default).to eq("hello")
  end

  it "applies factory defaults independently per instance" do
    a = klass.new(required_field: "x")
    b = klass.new(required_field: "x")
    a.factory_field << 1
    expect(b.factory_field).to be_empty
  end

  it "ignores unknown keyword arguments (Pydantic v2 default)" do
    expect { klass.new(required_field: "x", bogus: true) }.not_to raise_error
    expect(klass.new(required_field: "x").to_h).not_to have_key(:bogus)
  end

  it "implements equality and to_h" do
    a = klass.new(required_field: "x")
    b = klass.new(required_field: "x")
    expect(a).to eq(b)
    expect(a.to_h[:required_field]).to eq("x")
  end

  it "runs a subclass validate! hook" do
    validated = Class.new(Punkauto::Model) do
      attribute :value
      def validate!
        raise ArgumentError, "must be even" if value.odd?

        @value = value * 2
      end
    end

    expect(validated.new(value: 2).value).to eq(4)
    expect { validated.new(value: 3) }.to raise_error(ArgumentError, /even/)
  end
end
