# frozen_string_literal: true

require "stringio"

RSpec.describe Punkauto::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  class FakeCliClient
    attr_reader :calls

    def initialize(_options = {})
      @calls = []
    end

    def with
      yield self
    end

    def get_makes
      Punkauto::VehicleMakes.new(makes: %w[HONDA TOYOTA], count: 2)
    end

    def get_years_for_make(make)
      @calls << [:years, make]
      Punkauto::VehicleYears.new(make: make, years: [2020], count: 1)
    end

    def login(email, password)
      @calls << [:login, email, password]
      true
    end

    def get_saved_addresses
      @calls << [:addresses]
      Punkauto::SavedAddressesResult.new(addresses: [], count: 0)
    end
  end

  it "prints command results as JSON" do
    status = described_class.main(%w[--json makes], out: out, err: err, client_factory: ->(opts) { FakeCliClient.new(opts) })

    expect(status).to eq(0)
    expect(JSON.parse(out.string)).to eq("makes" => %w[HONDA TOYOTA], "count" => 2)
  end

  it "dispatches catalog commands and validates numeric years" do
    factory = ->(opts) { FakeCliClient.new(opts) }
    expect(described_class.main(%w[years Honda 2020], out: out, err: err, client_factory: factory)).to eq(0)
    expect(JSON.parse(out.string)["make"]).to eq("Honda")

    expect(described_class.main(%w[models Honda nope], out: out, err: err, client_factory: factory)).to eq(1)
    expect(err.string).to include("invalid value for Integer")
  end

  it "logs in during an account command using provided credentials" do
    client = FakeCliClient.new
    factory = ->(_opts) { client }
    input = StringIO.new("person@example.com\nsecret\n")

    status = described_class.main(%w[account addresses], out: out, err: err, input: input, client_factory: factory)

    expect(status).to eq(0)
    expect(client.calls).to include([:login, "person@example.com", "secret"], [:addresses])
    expect(out.string).not_to include("secret")
  end

  it "shows help without making a request" do
    expect(described_class.main(["help"], out: out, err: err)).to eq(0)
    expect(out.string).to include("Usage: punkauto")
  end

  it "passes the display mode to the client factory" do
    received_options = nil
    factory = lambda do |options|
      received_options = options
      FakeCliClient.new(options)
    end

    expect(described_class.main(%w[--display transformed makes], out: out, err: err, client_factory: factory)).to eq(0)
    expect(received_options[:display]).to eq(:transformed)
  end
end
