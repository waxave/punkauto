# frozen_string_literal: true

require "json"
require "optparse"

module Punkauto
  # Command-line interface for the Punkauto client.
  module CLI
    module_function

    GLOBAL_OPTIONS = { json: false, language: "en", display: :original, cache_backend: :sqlite, cache_path: nil, enable_caching: true }.freeze

    def main(argv = ARGV, out: $stdout, err: $stderr, input: $stdin, client_factory: ->(options) { Client.new(**options) })
      args = argv.dup
      options = GLOBAL_OPTIONS.dup
      OptionParser.new do |parser|
        parser.on("--json", "Output machine-readable JSON") { options[:json] = true }
        parser.on("--language CODE", "RockAuto language (default: en)") { |value| options[:language] = value }
        parser.on("--display MODE", %w[original transformed], "Display text mode (default: original)") { |value| options[:display] = value.to_sym }
        parser.on("--cache-backend BACKEND", %w[sqlite memory], "Cache backend (default: sqlite)") { |value| options[:cache_backend] = value.to_sym }
        parser.on("--cache-path PATH", "SQLite cache database path") { |value| options[:cache_path] = value }
        parser.on("--no-cache", "Disable caching for this invocation") { options[:enable_caching] = false }
        parser.on("-h", "--help", "Show help") { out.puts(help); return 0 }
      end.order!(args)

      return legacy_search(args, options, out, err, client_factory) if legacy_invocation?(args)
      return command_help(out) if args.empty? || %w[help --help].include?(args.first)

      command = args.shift
      command_options = {}
      if command == "search"
        parser = OptionParser.new do |opts|
          opts.on("--manufacturer NAME") { |v| command_options[:manufacturer] = v }
          opts.on("--part-group NAME") { |v| command_options[:part_group] = v }
          opts.on("--part-type NAME") { |v| command_options[:part_type] = v }
          opts.on("--part-name NAME") { |v| command_options[:part_name] = v }
        end
        parser.parse!(args)
      elsif command == "categories" || command == "parts"
        parser = OptionParser.new do |opts|
          opts.on("--carcode CODE") { |v| command_options[:carcode] = v }
          opts.on("--engine-index N", Integer) { |v| command_options[:engine_index] = v }
        end
        parser.parse!(args)
      elsif command == "account"
        parser = OptionParser.new do |opts|
          opts.on("--email EMAIL") { |v| command_options[:email] = v }
          opts.on("--date-range RANGE") { |v| command_options[:date_range] = v }
          opts.on("--vehicle NAME") { |v| command_options[:vehicle] = v }
          opts.on("--part-category NAME") { |v| command_options[:part_category] = v }
          opts.on("--part-number NUMBER") { |v| command_options[:part_number] = v }
        end
        parser.parse!(args)
      end

      client_options = options.slice(:language, :display, :cache_backend, :cache_path, :enable_caching)
      client = client_factory.call(client_options)
      result = nil
      client.with do |session|
        if command == "account"
          login!(session, command_options, input, err)
          result = account_command(session, args, command_options)
        else
          result = execute_command(session, command, args, command_options)
        end
      end
      print_result(result, options[:json], out)
      0
    rescue OptionParser::ParseError, ArgumentError, Punkauto::Error => e
      err.puts("punkauto: #{e.message}")
      err.puts("Run 'punkauto help' for usage.")
      1
    rescue Interrupt
      err.puts("punkauto: cancelled")
      130
    end

    def execute_command(client, command, args, opts)
      case command
      when "makes" then no_args!(args); client.get_makes
      when "years" then require_args!(args, 1); client.get_years_for_make(args[0])
      when "models" then require_args!(args, 2); client.get_models_for_make_year(args[0], Integer(args[1]))
      when "engines" then require_args!(args, 3); client.get_engines_for_vehicle(args[0], Integer(args[1]), args[2])
      when "vehicle"
        require_args!(args, 3); client.get_vehicle(args[0], Integer(args[1]), args[2], engine_index: opts.fetch(:engine_index, 0))
      when "categories"
        if opts[:carcode]
          no_args!(args); client.search_parts(opts[:carcode])
        else
          require_args!(args, 3); client.get_vehicle(args[0], Integer(args[1]), args[2], engine_index: opts.fetch(:engine_index, 0)).get_part_categories
        end
      when "parts"
        require_args!(args, opts[:carcode] ? 1 : 4)
        if opts[:carcode]
          raise ArgumentError, "use 'categories --carcode' to look up categories directly"
        end
        vehicle = client.get_vehicle(args[0], Integer(args[1]), args[2], engine_index: opts.fetch(:engine_index, 0))
        vehicle.get_parts_by_category(args[3])
      when "subcategory"
        require_args!(args, 4)
        client.get_vehicle(args[0], Integer(args[1]), args[2]).get_individual_parts_from_subcategory(args[3])
      when "manufacturers" then no_args!(args); client.get_manufacturers
      when "part-groups" then no_args!(args); client.get_part_groups
      when "part-types" then no_args!(args); client.get_part_types
      when "search"
        require_args!(args, 1); client.search_parts_by_number(args[0], **opts)
      when "part-name" then require_args!(args, 1); client.what_is_part_called(args.join(" "))
      when "tools"
        operation = args.shift or raise ArgumentError, "expected 'categories' or 'list'"
        case operation
        when "categories" then client.get_tool_categories(args.join(" ").gsub(" ", "+"))
        when "list" then require_args!(args, 1); client.get_tools_by_category(args.join(" "))
        else raise ArgumentError, "unknown tools operation: #{operation}"
        end
      when "orders"
        operation = args.shift or raise ArgumentError, "expected 'status' or 'request-list'"
        case operation
        when "status" then require_args!(args, 2); client.lookup_order_status(args[0], args[1])
        when "request-list" then require_args!(args, 2); client.request_order_list(args[0], args[1])
        else raise ArgumentError, "unknown orders operation: #{operation}"
        end
      when "cache"
        operation = args.shift or raise ArgumentError, "expected cache operation"
        no_args!(args)
        case operation
        when "stats" then client.cache_stats
        when "clear" then client.clear_all_caches
        when "clear-expired" then client.clear_expired_caches
        when "clear-search" then client.clear_parts_search_cache; { cleared: true }
        else raise ArgumentError, "unknown cache operation: #{operation}"
        end
      else
        raise ArgumentError, "unknown command: #{command}"
      end
    end

    def account_command(client, args, opts)
      operation = args.shift or raise ArgumentError, "expected account operation"
      case operation
      when "addresses" then no_args!(args); client.get_saved_addresses
      when "vehicles" then no_args!(args); client.get_saved_vehicles
      when "activity" then no_args!(args); client.get_account_activity
      when "orders"
        no_args!(args)
        filter = OrderHistoryFilter.new(date_range: opts.fetch(:date_range, "3 Months"), vehicle: opts.fetch(:vehicle, "All"), part_category: opts.fetch(:part_category, "All"), part_number: opts[:part_number])
        client.get_order_history(filter)
      when "add-order" then require_args!(args, 2); client.add_external_order(args[0], args[1])
      else raise ArgumentError, "unknown account operation: #{operation}"
      end
    end

    def login!(client, opts, input, err)
      email = opts[:email] || ENV["PUNKAUTO_EMAIL"] || prompt(input, err, "RockAuto email: ")
      password = ENV["PUNKAUTO_PASSWORD"] || hidden_prompt(input, err, "RockAuto password: ")
      raise Punkauto::Error, "login failed; check credentials" unless client.login(email, password)
    ensure
      password = nil
    end

    def prompt(input, err, text)
      err.print(text)
      input.gets&.chomp or raise ArgumentError, "email is required"
    end

    def hidden_prompt(input, err, text)
      err.print(text)
      if input.respond_to?(:noecho)
        input.noecho(&:gets).to_s.tap { err.puts }
      else
        input.gets.to_s
      end.chomp
    end

    def legacy_invocation?(args)
      args.length >= 3 && !%w[makes years models engines vehicle categories parts subcategory manufacturers part-groups part-types search part-name tools orders account cache].include?(args.first)
    end

    def legacy_search(args, options, out, err, client_factory)
      make, year, model, category = args
      raise ArgumentError, "year must be an integer" unless year.match?(/\A\d+\z/)
      client = client_factory.call(options.slice(:language, :display, :cache_backend, :cache_path, :enable_caching))
      result = client.with do |session|
        vehicle = session.get_vehicle(make, year.to_i, model)
        categories = vehicle.get_part_categories
        if category
          match = categories.categories.find { |item| item.name.downcase.include?(category.downcase) }
          raise ArgumentError, "category '#{category}' not found" unless match
          vehicle.get_parts_by_category(match.group_name)
        else
          categories
        end
      end
      print_result(result, options[:json], out)
      0
    rescue Punkauto::Error, ArgumentError => e
      err.puts("punkauto: #{e.message}")
      1
    end

    def require_args!(args, count)
      raise ArgumentError, "expected at least #{count} argument(s)" if args.length < count
    end

    def no_args!(args)
      raise ArgumentError, "unexpected arguments: #{args.join(' ')}" unless args.empty?
    end

    def serialize(value)
      case value
      when Array then value.map { |item| serialize(item) }
      when Hash then value.transform_values { |item| serialize(item) }
      when Punkauto::Model then value.to_h.transform_values { |item| serialize(item) }
      when Punkauto::Vehicle then { make: value.make, year: value.year, model: value.model, engine: serialize(value.engine), carcode: value.carcode }
      when Symbol then value.to_s
      else value
      end
    end

    def print_result(value, json, out)
      out.puts(JSON.pretty_generate(serialize(value)))
    end

    def command_help(out)
      out.puts(help)
      0
    end

    def help
      <<~TEXT
        Usage: punkauto [--json] [--language CODE] [--display original|transformed]
                        [--cache-backend sqlite|memory]
                        [--cache-path PATH] [--no-cache] COMMAND [ARGS] [OPTIONS]

        Vehicle catalog:
          makes | years MAKE | models MAKE YEAR | engines MAKE YEAR MODEL
          vehicle MAKE YEAR MODEL [--engine-index N]
          categories MAKE YEAR MODEL [--engine-index N] | categories --carcode CODE
          parts MAKE YEAR MODEL CATEGORY [--engine-index N]
          subcategory MAKE YEAR MODEL URL

        Part search:
          manufacturers | part-groups | part-types
          search NUMBER [--manufacturer NAME] [--part-group NAME] [--part-type NAME] [--part-name NAME]
          part-name QUERY

        Other:
          tools categories [PATH] | tools list PATH
          orders status CONTACT NUMBER | orders request-list email|sms CONTACT
          account addresses|vehicles|activity|orders|add-order CONTACT NUMBER [--email EMAIL]
          cache stats|clear|clear-expired|clear-search

        Account commands prompt for login credentials. Set PUNKAUTO_EMAIL and
        PUNKAUTO_PASSWORD to provide them non-interactively.
        SQLite caching is persistent by default; use --cache-backend memory or
        --no-cache to change it for this invocation.
        --display transformed titleizes supported display fields; --display
        original returns RockAuto text as received.
        Legacy syntax remains supported: punkauto MAKE YEAR MODEL [CATEGORY]
      TEXT
    end
  end
end
