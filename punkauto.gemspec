# frozen_string_literal: true

require_relative "lib/punkauto/version"

Gem::Specification.new do |spec|
  spec.name          = "punkauto"
  spec.version       = Punkauto::VERSION
  spec.authors       = ["Jesus Urias"]
  spec.email         = ["xesvs@pm.me"]

  spec.summary       = "Ruby API client for RockAuto.com automotive parts search"
  spec.description   = "A comprehensive Ruby client for RockAuto.com. Search for " \
                       "vehicle parts by make/year/model, browse the tools catalog, " \
                       "look up part numbers, track order status, and manage your " \
                       "saved vehicles and addresses."
  spec.homepage      = "https://github.com/waxave/punkauto"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["source_code_uri"] = "https://github.com/waxave/punkauto"
  spec.metadata["changelog_uri"]   = "https://github.com/waxave/punkauto/blob/main/CHANGELOG.md"
  spec.files = Dir.glob("lib/**/*.rb") + %w[LICENSE README.md CHANGELOG.md exe/punkauto]
  spec.bindir        = "exe"
  spec.executables   = ["punkauto"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", ">= 2.0"
  spec.add_dependency "faraday-cookie_jar", ">= 0.0.7"
  spec.add_dependency "faraday-follow_redirects", ">= 0.3"
  spec.add_dependency "faraday-gzip", ">= 1.0"
  spec.add_dependency "http-cookie", ">= 1.0"
  spec.add_dependency "nokogiri", ">= 1.13"
  spec.add_dependency "sqlite3", ">= 1.6"

  spec.add_development_dependency "rake", ">= 13.0"
  spec.add_development_dependency "rspec", ">= 3.0"
  spec.add_development_dependency "webmock", ">= 3.0"
end
