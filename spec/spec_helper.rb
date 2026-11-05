# frozen_string_literal: true

require "punkauto"
require "webmock/rspec"
require "json"
require "nokogiri"

WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
