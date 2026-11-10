# Punkauto

A Ruby API client for [RockAuto.com](https://www.rockauto.com) — the world's
largest online automotive parts catalog. Punkauto talks to RockAuto's catalog
API and catalog pages directly, so you get real-time stock, pricing, and
availability as structured Ruby objects instead of scraping search results.

- **Vehicle lookup chain** — makes → years → models → engines → parts
- **Part search** — manufacturers, part groups, part types, part numbers
- **Tools catalog** — categories and tool listings
- **Order status** — public order lookup and order-list requests
- **Account features** — saved vehicles, addresses, order history

## Installation

Add this line to your application's `Gemfile`:

```ruby
gem "punkauto"
```

To use it straight from the repository:

```ruby
gem "punkauto", github: "waxave/punkauto"
```

Then run:

```sh
bundle install
```

Or install it directly:

```sh
gem install punkauto
```

## Quick start

```ruby
require "punkauto"

Punkauto::Client.new.with do |client|
  vehicle = client.get_vehicle("TOYOTA", 2020, "CAMRY")
  puts "Vehicle: #{vehicle.year} #{vehicle.make} #{vehicle.model}"

  brake_parts = vehicle.get_parts_by_category("Brake & Wheel Hub")
  puts "Found #{brake_parts.count} brake components"

  brake_parts.parts.first(3).each do |part|
    puts "- #{part.brand} #{part.part_number}: #{part.price}"
  end
end
```

`Client#with` guarantees the HTTP session is closed when the block ends. You
can also manage the session manually with `client.close`.

## Configuration

```ruby
client = Punkauto::Client.new(
  language: "en",             # language code: en, es, de, fr, ...
  use_mobile_profile: true,   # mobile user-agent reduces CAPTCHA triggers
  enable_caching: true,
  part_cache_hours: 12,
  search_cache_hours: 12,
  dropdown_cache_hours: 24,
  max_cached_parts: 1000,
  max_cached_searches: 100,
  cache_backend: :sqlite,     # :sqlite (persistent, default) or :memory
  cache_path: "./punkauto.sqlite3", # optional; defaults under XDG cache dir
  display: :original          # :original (default) or :transformed
)
```

| Option | Default | Description |
|---|---|---|
| `language` | `"en"` | Language code used in the URL path (`/en/`, `/es/`, `/de/`, `/fr/`, ...) |
| `use_mobile_profile` | `true` | Use a mobile browser user-agent and headers |
| `enable_caching` | `true` | Enable result caching |
| `part_cache_hours` | `12` | Expiry (hours) for cached vehicle-part results |
| `search_cache_hours` | `12` | Expiry (hours) for cached part-search and tool results |
| `dropdown_cache_hours` | `24` | Expiry (hours) for catalog and dropdown results |
| `max_cached_parts` | `1000` | Cache capacity setting for part data |
| `max_cached_searches` | `100` | Cache capacity setting for search results |
| `cache_backend` | `:sqlite` | `:sqlite` shares cache across clients/processes; `:memory` is client-local |
| `cache_path` | `$XDG_CACHE_HOME/punkauto/cache.sqlite3` or `~/.cache/punkauto/cache.sqlite3` | SQLite location; override with `PUNKAUTO_CACHE_PATH` |
| `display` | `:original` | Return original text or titleize supported display fields with `:transformed` |

For Rails, keep the writable database with the application, not inside the gem:

```ruby
Punkauto::Client.new(
  cache_path: Rails.root.join("storage/punkauto/cache.sqlite3").to_s
)
```

Add the chosen `storage/` path to `.gitignore`. In production, put it on a
persistent volume if it must survive deployments. SQLite is a local-file cache;
separate application servers need a shared filesystem to share one database.

## Public API

### Vehicle lookup

```ruby
makes   = client.get_makes                    # => VehicleMakes
years   = client.get_years_for_make("HONDA")  # => VehicleYears
models  = client.get_models_for_make_year("HONDA", 2021) # => VehicleModels
engines = client.get_engines_for_vehicle("HONDA", 2021, "CIVIC") # => VehicleEngines
```

Each result exposes `count` plus its collection (`makes`, `years`, `models`,
`engines`).

`get_vehicle` resolves the engine and returns a scoped `Vehicle` object:

```ruby
vehicle = client.get_vehicle("HONDA", 2021, "CIVIC")        # first engine
vehicle = client.get_vehicle("HONDA", 2021, "CIVIC", engine_index: 2)
```

`Vehicle` exposes `carcode` and scoped part lookup:

```ruby
vehicle.carcode                          # RockAuto's vehicle identifier
categories = vehicle.get_part_categories # => VehiclePartCategories
parts      = vehicle.get_parts_by_category("Brake & Wheel Hub") # => VehiclePartsResult
parts      = vehicle.get_individual_parts_from_subcategory(subcategory_url)
```

### Part search

```ruby
manufacturers = client.get_manufacturers   # => ManufacturerOptions
part_groups   = client.get_part_groups     # => PartGroupOptions
part_types    = client.get_part_types      # => PartTypeOptions
```

Look up by display name (case-insensitive):

```ruby
manufacturers.manufacturer_by_name("acdelco").value
part_groups.part_group_by_name("Brake & Wheel Hub").value
```

Search by part number with optional filters:

```ruby
result = client.search_parts_by_number(
  "90919-*",                    # supports wildcards
  manufacturer: "DENSO",
  part_group: "Ignition",
  part_type: "Ignition Coil"
)
```

Find what a part is called:

```ruby
results = client.what_is_part_called("brake pads") # => WhatIsPartCalledResults
```

> **Note:** `what_is_part_called` is best-effort — RockAuto renders those
> results via client-side autocomplete, so they aren't present in the
> server-rendered response. Use `search_parts_by_number` for reliable part
> discovery.

`client.search_parts(carcode)` returns the part categories available for a
carcode without needing the full vehicle context.

### Tools

```ruby
categories = client.get_tool_categories              # => ToolCategories
subcats    = client.get_tool_categories("Engine")
tools      = client.get_tools_by_category("Engine,Oil+Pump+Priming+Tool") # => ToolsResult
```

### Order status (public)

```ruby
result = client.lookup_order_status("customer@example.com", "123456789")

if result.success
  order = result.order
  puts "Order #{order.order_number}: #{order.status}"
  puts "Tracking: #{order.shipping.tracking_number}" if order.shipping&.tracking_number
else
  puts result.error.message
  result.error.suggestions.each { |s| puts "  • #{s}" }
end
```

Request an order list by email or SMS:

```ruby
client.request_order_list("email", "customer@example.com")
client.request_order_list("sms", "5551234567")
```

## Authenticated API

These methods require a successful `login`.

```ruby
success = client.login("email@example.com", "password")

if success
  client.get_saved_addresses    # => SavedAddressesResult
  client.get_saved_vehicles     # => SavedVehiclesResult
  client.get_account_activity   # => AccountActivityResult
  client.get_order_history      # => OrderHistoryResult
  client.get_order_history(Punkauto::OrderHistoryFilter.new(date_range: "1 Year"))

  client.add_external_order("other@example.com", "123456789")
  client.logout
end

client.authentication_status    # => Hash of session state
```

## Caching

```ruby
client.cache_stats            # => Hash of cache settings and statistics
client.clear_all_caches       # => Hash of what was cleared
client.clear_expired_caches   # => Hash of expired entry counts
client.clear_parts_search_cache # clears this client's dropdown objects

client.configure_cache(
  enable_caching: false,
  part_cache_hours: 24,
  max_cached_parts: 500
)
```

The default SQLite cache is a persistent, versioned relational database.
`languages` scopes localized records; makes, years, models, engines, part
categories, parts, tool categories, and tools are stored as linked entities.
Cached query sets reference those records and preserve result order. Cache hits
are rebuilt as the existing Ruby model types. The default file is
`$XDG_CACHE_HOME/punkauto/cache.sqlite3`, or `~/.cache/punkauto/cache.sqlite3`
when `XDG_CACHE_HOME` is unset. Set `cache_path:` or `PUNKAUTO_CACHE_PATH` to
choose a different file. The earlier opaque `cache_entries` table is retained;
its language and entity relationships are not guessed during migration.

Structured tables retain the original value in its regular column (`name`) and
store the normalized/titleized presentation value separately in `display_name`.
Titleization uses basic language-specific small-word rules for English,
Spanish, French, and German. Original API values are used for identifiers,
group names, URLs, part numbers, and default Ruby model responses. Cache keys
include operation arguments and language. Entries expire according to the
configured TTL settings and are subject to cache-capacity limits. Account data,
credentials, cookies, and order lookups are not persisted. The CLI shares the
same SQLite cache by default. Its cache commands operate on that database;
`cache clear` removes query sets and now-unlinked entities but retains the
language registry and legacy table.
`cache clear-search` only resets the current client's in-memory dropdown
objects; it does not remove persistent SQLite query entries. Use `cache clear`
to clear the shared persistent results.

Set `display: :transformed` to receive titleized display fields from the client.
The default `:original` preserves RockAuto's text. This setting does not affect
cache keys or lookup values: identifiers, category `group_name`s, part numbers,
and URLs remain unchanged. Both display modes reuse the same cached result.

## Error handling

All errors subclass `Punkauto::Error`:

```ruby
begin
  client.get_parts_by_category("HONDA", 2021, "CIVIC", "123", "Engine")
rescue Punkauto::AuthenticationRequiredError => e
  # operation requires login
rescue Punkauto::CaptchaError => e
  # RockAuto's anti-bot system intervened
rescue Punkauto::ApiError => e
  # a request or parse failed
rescue Punkauto::Error => e
  # any other client error
end
```

## Data models

- **Vehicle** — `Engine`, `VehicleMakes`, `VehicleYears`, `VehicleModels`,
  `VehicleEngines`, `VehiclePartCategories`, `VehiclePartsResult`, `Vehicle`
- **Parts** — `PartInfo`, `PartCategory`, `PartSearchOption`,
  `ManufacturerOptions`, `PartGroupOptions`, `PartTypeOptions`,
  `PartSearchResult`, `WhatIsPartCalledResult`, `WhatIsPartCalledResults`
- **Tools** — `ToolCategory`, `ToolCategories`, `ToolInfo`, `ToolsResult`
- **Orders** — `OrderItem`, `ShippingInfo`, `BillingInfo`, `OrderStatus`,
  `OrderStatusError`, `OrderStatusResult`
- **Account** — `SavedAddress`, `SavedAddressesResult`, `SavedVehicle`,
  `SavedVehiclesResult`, `OrderHistoryItem`, `OrderHistoryResult`,
  `OrderHistoryFilter`, `AccountActivityResult`

## CLI

Run from an installed gem as `punkauto ...`, or directly from a checkout with
`./exe/punkauto ...`. Global options go before the command. Results are printed
as JSON; `--json` is accepted as an explicit output-mode flag.

```sh
punkauto makes
punkauto years HONDA
punkauto models HONDA 2021
punkauto engines HONDA 2021 CIVIC
punkauto vehicle HONDA 2021 CIVIC --engine-index 1
punkauto categories HONDA 2021 CIVIC
punkauto parts HONDA 2021 CIVIC "Brake & Wheel Hub"
punkauto categories --carcode 12345
punkauto subcategory HONDA 2021 CIVIC '/en/catalog/...'

punkauto manufacturers
punkauto part-groups
punkauto part-types
punkauto search '90919-*' --manufacturer DENSO --part-group Ignition
punkauto part-name 'brake pads'
punkauto tools categories
punkauto tools categories 'Engine,Oil+Pump+Priming+Tool'
punkauto tools list 'Engine,Oil+Pump+Priming+Tool'
punkauto orders status customer@example.com 123456789
punkauto orders request-list email customer@example.com

punkauto --json makes
punkauto --language es makes
punkauto --display transformed makes
punkauto --cache-path ./tmp/punkauto.sqlite3 cache stats
punkauto --cache-backend memory makes
punkauto --no-cache makes

punkauto account addresses --email customer@example.com
punkauto account vehicles
punkauto account activity
punkauto account orders --date-range '1 Year'
punkauto account add-order other@example.com 123456789

punkauto cache stats
punkauto cache clear-expired
punkauto cache clear-search
punkauto cache clear

# Backward-compatible shorthand:
punkauto Honda 2021 Civic brake
```

Use `punkauto help` for the complete command summary. `--language CODE`,
`--display original|transformed`, `--cache-backend sqlite|memory`,
`--cache-path PATH`, `--no-cache`, and `--json` are global options and should
appear before the command. Account operations log in for that invocation and
prompt for the password without echoing it. Set `PUNKAUTO_EMAIL` and
`PUNKAUTO_PASSWORD` for non-interactive use; do not put passwords in command
arguments. Login state is not persisted. Unlike the old in-memory-only CLI,
the default SQLite cache does persist across invocations; memory-backend cache
entries do not.

## Development

This repository uses [mise](https://mise.jdx.dev/) to select Ruby and run
project tasks. The pinned Ruby version is in `mise.toml`.

```sh
mise install          # install the configured Ruby version
mise run setup        # bundle install
mise run test         # full RSpec suite
mise run test:cli     # CLI specs only
mise run check        # Ruby syntax checks and full test suite
mise run build        # build punkauto.gem
```

Run `mise tasks` to list the available tasks. The equivalent direct test
commands are `bundle exec rspec` and `bundle exec rspec spec/cli_spec.rb`.

### Releases

Before releasing, update `Punkauto::VERSION` in `lib/punkauto/version.rb` and
add a dated section for that version to `CHANGELOG.md`. Commit the release
metadata on a clean `main` branch, then choose the desired release scope:

```sh
mise run release:local # test, build, and create a local v<VERSION> tag
mise run release       # release:local, then push main and the tag to origin
mise run release:gem   # release, then publish punkauto-<VERSION>.gem
```

Release tasks do not change the version or changelog. They reject a dirty tree,
non-main branch, missing dated changelog entry, invalid version, or existing
tag. RubyGems publishing uses the credentials configured for the `gem` command;
do not store credentials in this repository.

## Disclaimer

This client is for educational and legitimate research purposes. Respect
RockAuto's terms of service, implement appropriate rate limiting, and do not
abuse the service or scrape large datasets.
