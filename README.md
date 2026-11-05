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
  use_mobile_profile: true,   # mobile user-agent reduces CAPTCHA triggers
  enable_caching: true,
  part_cache_hours: 12,
  search_cache_hours: 12,
  dropdown_cache_hours: 24,
  max_cached_parts: 1000,
  max_cached_searches: 100
)
```

| Option | Default | Description |
|---|---|---|
| `use_mobile_profile` | `true` | Use a mobile browser user-agent and headers |
| `enable_caching` | `true` | Enable in-memory caching of parts and searches |
| `part_cache_hours` | `12` | TTL (hours) for cached individual parts |
| `search_cache_hours` | `12` | TTL (hours) for cached search results |
| `dropdown_cache_hours` | `24` | TTL (hours) for cached dropdown options |
| `max_cached_parts` | `1000` | Maximum parts held in cache |
| `max_cached_searches` | `100` | Maximum search results held in cache |

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
client.clear_parts_search_cache

client.configure_cache(
  enable_caching: false,
  part_cache_hours: 24,
  max_cached_parts: 500
)
```

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

```sh
punkauto Honda 2021 Civic          # list part categories
punkauto Honda 2021 Civic brake    # search the "brake" category
```

## Development

```sh
bundle install
bundle exec rspec
```

## Disclaimer

This client is for educational and legitimate research purposes. Respect
RockAuto's terms of service, implement appropriate rate limiting, and do not
abuse the service or scrape large datasets.
