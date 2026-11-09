# frozen_string_literal: true

require_relative "punkauto/version"
require_relative "punkauto/errors"
require_relative "punkauto/model"
require_relative "punkauto/models"
require_relative "punkauto/cache_store"
require_relative "punkauto/parsers"
require_relative "punkauto/base_client"
require_relative "punkauto/client"
require_relative "punkauto/vehicle"
require_relative "punkauto/cli"

# Punkauto — a Ruby API client for RockAuto.com automotive parts search.
module Punkauto
  Client.prepend(PersistentClientCache)

  # Compatibility alias for the main client class.
  RockAutoClient = Client unless const_defined?(:RockAutoClient)
end
