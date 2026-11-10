# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2026-11-09

### Fixed
- Persist RockAuto locale cookies before following redirects, avoiding redirect
  loops on localized catalog and part-search pages.
- Apply transformed display casing to vehicle labels and engine descriptions.

## [0.3.0] - 2026-11-09

### Added
- Persistent relational SQLite result caching, with configurable backend and path.
- A command-line interface for catalog, part search, tools, orders, account, and
  cache operations.
- Optional transformed display text while preserving original lookup values.

### Fixed
- Ignore catalog navigation and query links when parsing vehicle makes and tool
  categories.

## [0.2.0] - 2026-11-04

### Added
- Configurable `language:` option on `Punkauto::Client` (default `"en"`). The
  language is threaded through the URL path prefix (`/en/`, `/es/`, `/de/`,
  `/fr/`, ...) for the catalog, tools, part search, and account pages.

## [0.1.0] - 2026-11-04

### Added
- Initial release.
- `Punkauto::Client` with the full RockAuto.com API surface:
  - Vehicle lookup chain (`get_makes`, `get_years_for_make`,
    `get_models_for_make_year`, `get_engines_for_vehicle`, `get_vehicle`).
  - Part discovery (`get_part_categories`, `get_parts_by_category`,
    `get_individual_parts_from_subcategory`, `search_parts`).
  - Part search (`get_manufacturers`, `get_part_groups`, `get_part_types`,
    `search_parts_by_number`, `what_is_part_called`).
  - Tools (`get_tool_categories`, `get_tools_by_category`).
  - Order status (`lookup_order_status`, `request_order_list`).
  - Authenticated account features (`login`, `logout`,
    `get_saved_addresses`, `get_saved_vehicles`, `get_account_activity`,
    `get_order_history`, `add_external_order`).
- In-memory caching with configurable TTLs and limits.
- Command-line interface (`punkauto`).
- Data models for vehicles, parts, tools, orders, and account data.
