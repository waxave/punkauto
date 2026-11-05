# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
