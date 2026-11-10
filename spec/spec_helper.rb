# frozen_string_literal: true

require "punkauto"
require "webmock/rspec"
require "json"
require "nokogiri"
require "tmpdir"
require "fileutils"
require "securerandom"

WebMock.disable_net_connect!(allow_localhost: true)

def fixture(path)
  File.read(File.join(__dir__, "fixtures", path))
end

RSpec.configure do |config|
  config.around do |example|
    previous_cache_path = ENV["PUNKAUTO_CACHE_PATH"]
    cache_dir = Dir.mktmpdir("punkauto-spec-")
    ENV["PUNKAUTO_CACHE_PATH"] = File.join(cache_dir, "cache.sqlite3")
    example.run
  ensure
    previous_cache_path ? ENV["PUNKAUTO_CACHE_PATH"] = previous_cache_path : ENV.delete("PUNKAUTO_CACHE_PATH")
    FileUtils.remove_entry(cache_dir) if cache_dir && File.exist?(cache_dir)
  end

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
