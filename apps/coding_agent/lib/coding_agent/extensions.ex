defmodule CodingAgent.Extensions do
  @moduledoc """
  Extension management for CodingAgent.

  Extensions can provide:
  - Additional tools
  - Custom prompts/skills
  - Resource loading (CLAUDE.md, AGENTS.md, etc.)
  - Hooks for agent events

  ## Loading Extensions

  Extensions can be loaded from multiple locations:
  - Global extensions directory (`~/.lemon/agent/extensions/`)
  - Project-local extensions (`.lemon/extensions/`)
  - Explicit paths

  ## Extension Discovery

  Extensions are discovered by looking for modules that implement
  the `CodingAgent.Extensions.Extension` behaviour. Each extension
  directory can contain:
  - Elixir source files (`.ex`, `.exs`)
  - A `mix.exs` for complex extensions

  ## Example

      # Load extensions from default paths
      {:ok, extensions} = CodingAgent.Extensions.load_extensions([
        CodingAgent.Config.extensions_dir(),
        CodingAgent.Config.project_extensions_dir(cwd)
      ])

      # Get all tools from loaded extensions
      tools = CodingAgent.Extensions.get_tools(extensions, cwd)

      # Get hooks
      hooks = CodingAgent.Extensions.get_hooks(extensions)

      # Get extension metadata for UIs/diagnostics
      metadata = CodingAgent.Extensions.list_extensions()
  """

  alias CodingAgent.Config
  alias Lemon.Reload
  require Logger

  @type extension_module :: module()
  @type loaded_extensions :: [extension_module()]

  @type extension_metadata :: %{
          name: String.t(),
          version: String.t(),
          module: module(),
          source_path: String.t() | nil,
          capabilities: [atom()],
          config_schema: map()
        }

  @typedoc """
  Load error details for an extension that failed to load.

  - `:source_path` - Path to the file that failed to load
  - `:error` - The error reason (exception, compile error, etc.)
  - `:error_message` - Human-readable error message
  """
  @type load_error :: %{
          source_path: String.t(),
          error: term(),
          error_message: String.t()
        }

  @typedoc """
  Validation error details for an extension that loaded but failed validation.

  - `:module` - The extension module that failed validation
  - `:source_path` - Path to the extension source file
  - `:errors` - List of specific validation failure messages
  """
  @type validation_error :: %{
          module: module(),
          source_path: String.t() | nil,
          errors: [String.t()]
        }

  @typedoc """
  Provider conflict when multiple extensions try to register the same provider name.

  - `:type` - The provider type (e.g., `:model`)
  - `:name` - The conflicting provider name
  - `:winner` - The extension module that won (first to register)
  - `:shadowed` - List of extension modules that were shadowed
  """
  @type provider_conflict :: %{
          type: atom(),
          name: atom() | String.t(),
          winner: module(),
          shadowed: [module()]
        }

  @typedoc """
  Provider registration report for extension-provided providers.

  - `:registered` - List of successfully registered providers with their source extension
  - `:conflicts` - List of provider conflicts between extensions
  - `:total_registered` - Count of successfully registered providers
  - `:total_conflicts` - Count of provider name conflicts
  """
  @type provider_registration_report :: %{
          registered: [
            %{type: atom(), name: atom() | String.t(), module: module(), extension: module()}
          ],
          conflicts: [provider_conflict()],
          total_registered: non_neg_integer(),
          total_conflicts: non_neg_integer()
        }

  @typedoc """
  Structured status report for extension loading at session startup.

  Published as a single `{:extension_status_report, report}` event for UI/CLI consumption.

  - `:extensions` - List of successfully loaded extension metadata
  - `:load_errors` - List of extensions that failed to load
  - `:validation_errors` - List of extensions that loaded but failed validation
  - `:tool_conflicts` - Tool conflict report from ToolRegistry
  - `:provider_registration` - Provider registration report (conflicts, registered providers)
  - `:total_loaded` - Count of successfully loaded extensions
  - `:total_errors` - Count of extensions that failed to load
  - `:total_validation_errors` - Count of extensions that failed validation
  - `:loaded_at` - Timestamp when extensions were loaded
  """
  @type extension_status_report :: %{
          extensions: [extension_metadata()],
          load_errors: [load_error()],
          validation_errors: [validation_error()],
          tool_conflicts: CodingAgent.ToolRegistry.conflict_report() | nil,
          provider_registration: provider_registration_report() | nil,
          total_loaded: non_neg_integer(),
          total_errors: non_neg_integer(),
          total_validation_errors: non_neg_integer(),
          loaded_at: integer()
        }

  # ETS table for storing extension source paths
  @source_path_table :coding_agent_extension_source_paths
  # ETS table for storing last extension load errors
  @load_error_table :coding_agent_extension_load_errors
  @last_load_errors_pd_key {__MODULE__, :last_load_errors}

  # ============================================================================
  # Extension Loading
  # ============================================================================

  @doc """
  Load extensions from the given paths.

  Discovers and loads extension modules from the specified directories.
  Returns a list of loaded extension modules.

  ## Parameters

    * `paths` - List of directory paths to search for extensions

  ## Returns

    * `{:ok, extensions}` - List of loaded extension modules
    * `{:error, reason}` - If loading fails

  ## Examples

      {:ok, extensions} = CodingAgent.Extensions.load_extensions([
        "~/.lemon/agent/extensions",
        "/path/to/project/.lemon/extensions"
      ])
  """
  @spec load_extensions([String.t()]) :: {:ok, loaded_extensions()} | {:error, term()}
  def load_extensions(paths) when is_list(paths) do
    # Ensure the source path table exists
    ensure_source_path_table()

    extensions =
      paths
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&discover_extensions/1)
      |> Enum.uniq()

    {:ok, extensions}
  end

  @doc """
  Load extensions from the given paths, capturing any load errors.

  Similar to `load_extensions/1` but returns both successfully loaded extensions
  and a list of load errors for files that failed to compile or load, as well
  as a list of validation errors for extensions that loaded but failed validation.

  ## Parameters

    * `paths` - List of directory paths to search for extensions

  ## Returns

    * `{:ok, extensions, load_errors, validation_errors}` - Tuple with loaded extensions,
      load errors, and validation errors

  ## Examples

      {:ok, extensions, load_errors, validation_errors} = CodingAgent.Extensions.load_extensions_with_errors([
        "~/.lemon/agent/extensions",
        "/path/to/project/.lemon/extensions"
      ])

      if load_errors != [] do
        IO.puts("Some extensions failed to load:")
        for error <- load_errors do
          IO.puts("  - \#{error.source_path}: \#{error.error_message}")
        end
      end

      if validation_errors != [] do
        IO.puts("Some extensions failed validation:")
        for error <- validation_errors do
          IO.puts("  - \#{inspect(error.module)}: \#{Enum.join(error.errors, ", ")}")
        end
      end
  """
  @spec load_extensions_with_errors([String.t()]) ::
          {:ok, loaded_extensions(), [load_error()], [validation_error()]}
  def load_extensions_with_errors(paths) when is_list(paths) do
    # Ensure the source path table exists
    ensure_source_path_table()
    ensure_load_error_table()

    {extensions, errors} =
      paths
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&discover_extension_files/1)
      |> Enum.reduce({[], []}, fn file, {exts, errs} ->
        case load_extension_file_safe(file) do
          {:ok, modules} ->
            valid_modules = Enum.filter(modules, &implements_extension?/1)
            {valid_modules ++ exts, errs}

          {:error, error, message} ->
            error_info = %{
              source_path: file,
              error: error,
              error_message: message
            }

            {exts, [error_info | errs]}
        end
      end)

    # Validate loaded extensions
    {valid_extensions, validation_errors} =
      extensions
      |> Enum.uniq()
      |> Enum.reduce({[], []}, fn module, {valid, val_errs} ->
        path = get_source_path(module)

        case validate_extension(module, path) do
          :ok ->
            {[module | valid], val_errs}

          {:error, errs} ->
            val_error = %{
              module: module,
              source_path: path,
              errors: errs
            }

            {valid, [val_error | val_errs]}
        end
      end)

    load_errors = Enum.reverse(errors)
    store_load_errors(load_errors)
    store_validation_errors(Enum.reverse(validation_errors))

    {:ok, Enum.reverse(valid_extensions), load_errors, Enum.reverse(validation_errors)}
  end

  @doc """
  Load extensions from default paths for a working directory.

  Loads extensions from:
  - Global extensions directory (`~/.lemon/agent/extensions/`)
  - Project-local extensions (`.lemon/extensions/`)

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

    * `{:ok, extensions}` - List of loaded extension modules
  """
  @spec load_default_extensions(String.t()) :: {:ok, loaded_extensions()}
  def load_default_extensions(cwd) do
    paths = [
      Config.extensions_dir(),
      Config.project_extensions_dir(cwd)
    ]

    load_extensions(paths)
  end

  # ============================================================================
  # Tool Collection
  # ============================================================================

  @doc """
  Get tools from loaded extensions.

  Collects all tools provided by the given extension modules.

  ## Parameters

    * `extensions` - List of loaded extension modules
    * `cwd` - Current working directory (passed to each extension's `tools/1`)

  ## Returns

  A list of `AgentCore.Types.AgentTool` structs.

  ## Examples

      tools = CodingAgent.Extensions.get_tools(extensions, "/path/to/project")
  """
  @spec get_tools(loaded_extensions(), String.t()) :: [AgentCore.Types.AgentTool.t()]
  def get_tools(extensions, cwd) when is_list(extensions) do
    get_tools_with_source(extensions, cwd)
    |> Enum.map(fn {tool, _module} -> tool end)
  end

  @doc """
  Get tools from loaded extensions with source module tracking.

  Similar to `get_tools/2` but returns tuples of `{tool, extension_module}`
  to enable conflict detection and debugging.

  ## Parameters

    * `extensions` - List of loaded extension modules
    * `cwd` - Current working directory (passed to each extension's `tools/1`)

  ## Returns

  A list of `{AgentCore.Types.AgentTool.t(), module()}` tuples.

  ## Examples

      tools_with_source = CodingAgent.Extensions.get_tools_with_source(extensions, cwd)
      # => [{%AgentTool{name: "my_tool", ...}, MyExtension}, ...]
  """
  @spec get_tools_with_source(loaded_extensions(), String.t()) ::
          [{AgentCore.Types.AgentTool.t(), module()}]
  def get_tools_with_source(extensions, cwd) when is_list(extensions) do
    extensions
    |> Enum.filter(&has_callback?(&1, :tools, 1))
    |> Enum.flat_map(fn ext ->
      ensure_tool_types_loaded()

      try do
        ext.tools(cwd)
        |> Enum.map(fn tool -> {tool, ext} end)
      rescue
        _ -> []
      end
    end)
  end

  # ============================================================================
  # Provider Collection
  # ============================================================================

  @doc """
  Get providers from loaded extensions.

  Collects all provider specifications from the given extension modules.
  Each provider spec includes `:type`, `:name`, `:module`, and `:config`.

  ## Parameters

    * `extensions` - List of loaded extension modules

  ## Returns

  A list of `{provider_spec, extension_module}` tuples for tracking source.

  ## Examples

      providers = CodingAgent.Extensions.get_providers(extensions)
      # => [{%{type: :model, name: :my_model, ...}, MyExtension}, ...]
  """
  @spec get_providers(loaded_extensions()) :: [{map(), module()}]
  def get_providers(extensions) when is_list(extensions) do
    extensions
    |> Enum.filter(&has_callback?(&1, :providers, 0))
    |> Enum.flat_map(fn ext ->
      try do
        ext.providers()
        |> Enum.map(fn provider_spec ->
          # Normalize the provider spec with defaults
          normalized = %{
            type: Map.get(provider_spec, :type),
            name: Map.get(provider_spec, :name),
            module: Map.get(provider_spec, :module),
            config: Map.get(provider_spec, :config, %{})
          }

          {normalized, ext}
        end)
      rescue
        _ -> []
      end
    end)
  end

  @doc """
  Register extension-provided providers into the Ai.ProviderRegistry.

  Collects all providers from extensions and registers them, detecting and
  reporting conflicts when multiple extensions try to register the same
  provider name. Only `:model` type providers are currently registered;
  other types are logged and skipped.

  ## Conflict Resolution

  When multiple extensions provide a provider with the same type and name:
  - The first extension (alphabetically by module name) wins
  - Subsequent extensions are logged as conflicts but not registered
  - Built-in providers always take precedence (already registered)

  ## Parameters

    * `extensions` - List of loaded extension modules

  ## Returns

  A `provider_registration_report()` map with:
  - `:registered` - List of successfully registered providers
  - `:conflicts` - List of provider conflicts
  - `:total_registered` - Count of registered providers
  - `:total_conflicts` - Count of conflicts

  ## Examples

      report = CodingAgent.Extensions.register_extension_providers(extensions)
      # => %{
      #   registered: [%{type: :model, name: :my_model, module: MyProvider, extension: MyExt}],
      #   conflicts: [],
      #   total_registered: 1,
      #   total_conflicts: 0
      # }
  """
  @spec register_extension_providers(loaded_extensions()) :: provider_registration_report()
  def register_extension_providers(extensions) when is_list(extensions) do
    # Get all provider specs with their source extension
    all_providers = get_providers(extensions)

    # Group by {type, name} to detect conflicts
    grouped =
      all_providers
      |> Enum.group_by(fn {spec, _ext} -> {spec.type, spec.name} end)

    # Process each group, registering the first and tracking conflicts
    {registered, conflicts} =
      Enum.reduce(grouped, {[], []}, fn {{type, name}, providers}, {reg_acc, conf_acc} ->
        # Sort by extension module name for deterministic ordering
        sorted = Enum.sort_by(providers, fn {_spec, ext} -> inspect(ext) end)
        [{winner_spec, winner_ext} | losers] = sorted

        # Check if already registered (built-in provider takes precedence)
        already_registered =
          case type do
            :model -> Ai.ProviderRegistry.registered?(name)
            _ -> false
          end

        cond do
          # Skip non-model providers for now (log info)
          type != :model ->
            require Logger

            Logger.debug(
              "Extension #{inspect(winner_ext)} provides unsupported provider type #{inspect(type)} for #{inspect(name)}, skipping"
            )

            {reg_acc, conf_acc}

          # Built-in provider already registered
          already_registered ->
            require Logger

            Logger.debug(
              "Provider #{inspect(name)} already registered (built-in), skipping extension provider from #{inspect(winner_ext)}"
            )

            # Treat all extension providers as conflicts against the built-in
            if losers != [] do
              conflict = %{
                type: type,
                name: name,
                winner: :builtin,
                shadowed: Enum.map([{winner_spec, winner_ext} | losers], fn {_, ext} -> ext end)
              }

              {reg_acc, [conflict | conf_acc]}
            else
              {reg_acc, conf_acc}
            end

          # Register the winner
          true ->
            :ok = Ai.ProviderRegistry.register(name, winner_spec.module)

            registered_entry = %{
              type: type,
              name: name,
              module: winner_spec.module,
              extension: winner_ext
            }

            # Track conflicts if there are losers
            conf_acc =
              if losers != [] do
                conflict = %{
                  type: type,
                  name: name,
                  winner: winner_ext,
                  shadowed: Enum.map(losers, fn {_, ext} -> ext end)
                }

                [conflict | conf_acc]
              else
                conf_acc
              end

            {[registered_entry | reg_acc], conf_acc}
        end
      end)

    %{
      registered: Enum.reverse(registered),
      conflicts: Enum.reverse(conflicts),
      total_registered: length(registered),
      total_conflicts: length(conflicts)
    }
  end

  @doc """
  Unregister all extension-provided providers from the Ai.ProviderRegistry.

  This function removes providers that were previously registered by extensions,
  based on the provider registration report. It's typically called before
  reloading extensions to clean up the registry.

  ## Parameters

    * `report` - A `provider_registration_report()` from a previous registration

  ## Returns

  `:ok`

  ## Examples

      report = CodingAgent.Extensions.register_extension_providers(extensions)
      # ... later, before reload ...
      :ok = CodingAgent.Extensions.unregister_extension_providers(report)
  """
  @spec unregister_extension_providers(provider_registration_report() | nil) :: :ok
  def unregister_extension_providers(nil), do: :ok

  def unregister_extension_providers(%{registered: registered}) when is_list(registered) do
    Enum.each(registered, fn %{type: :model, name: name} ->
      Ai.ProviderRegistry.unregister(name)
    end)

    :ok
  end

  def unregister_extension_providers(_), do: :ok

  # ============================================================================
  # Hook Collection
  # ============================================================================

  @doc """
  Get hooks from loaded extensions.

  Collects all hooks provided by the given extension modules.
  Hooks with the same name from multiple extensions are combined
  into a list.

  ## Parameters

    * `extensions` - List of loaded extension modules

  ## Returns

  A keyword list where each key maps to a list of hook functions.

  ## Examples

      hooks = CodingAgent.Extensions.get_hooks(extensions)
      # => [on_message_start: [fn1, fn2], on_tool_execution_end: [fn3]]

      # Execute all hooks for an event
      for hook <- Keyword.get(hooks, :on_message_start, []) do
        hook.(message)
      end
  """
  @spec get_hooks(loaded_extensions()) :: keyword([function()])
  def get_hooks(extensions) when is_list(extensions) do
    extensions
    |> Enum.filter(&has_callback?(&1, :hooks, 0))
    |> Enum.flat_map(fn ext ->
      try do
        ext.hooks()
      rescue
        _ -> []
      end
    end)
    |> Enum.group_by(fn {k, _v} -> k end, fn {_k, v} -> v end)
    |> Keyword.new()
  end

  @doc """
  Execute hooks for a given event.

  Calls all registered hooks for the event with the provided arguments.
  Errors in individual hooks are caught and logged but don't stop
  execution of other hooks.

  ## Parameters

    * `hooks` - Keyword list of hooks (from `get_hooks/1`)
    * `event` - The event name (atom)
    * `args` - List of arguments to pass to each hook

  ## Returns

  `:ok`

  ## Examples

      hooks = CodingAgent.Extensions.get_hooks(extensions)
      CodingAgent.Extensions.execute_hooks(hooks, :on_message_start, [message])
  """
  @spec execute_hooks(keyword([function()]), atom(), list()) :: :ok
  def execute_hooks(hooks, event, args \\ []) do
    hook_fns = Keyword.get(hooks, event, [])

    for hook_fn <- hook_fns do
      try do
        apply(hook_fn, args)
      rescue
        e ->
          # Log but don't crash on hook errors.
          Logger.warning("Hook error for #{event}: #{Exception.message(e)}")
      catch
        :throw, reason ->
          Logger.warning("Hook throw for #{event}: #{inspect(reason)}")

        :exit, reason ->
          Logger.warning("Hook exit for #{event}: #{inspect(reason)}")
      end
    end

    :ok
  end

  # ============================================================================
  # Extension Info
  # ============================================================================

  @doc """
  Get information about loaded extensions.

  Returns a list of maps containing name, version, module, source path,
  capabilities, and config schema for each extension. This is useful for
  UIs and diagnostics to show what plugins are active and render settings.

  ## Parameters

    * `extensions` - List of loaded extension modules

  ## Returns

  A list of maps with `:name`, `:version`, `:module`, `:source_path`,
  `:capabilities`, and `:config_schema` keys.

  ## Examples

      info = CodingAgent.Extensions.get_info(extensions)
      # => [%{name: "my-ext", version: "1.0.0", module: MyExt, source_path: "/path/to/ext.ex",
      #       capabilities: [:tools, :hooks], config_schema: %{"type" => "object", ...}}]
  """
  @spec get_info(loaded_extensions()) :: [extension_metadata()]
  def get_info(extensions) when is_list(extensions) do
    Enum.map(extensions, fn ext ->
      %{
        name: safe_call(ext, :name, [], "unknown"),
        version: safe_call(ext, :version, [], "0.0.0"),
        module: ext,
        source_path: get_source_path(ext),
        capabilities: safe_call(ext, :capabilities, [], []),
        config_schema: safe_call(ext, :config_schema, [], %{})
      }
    end)
  end

  @doc """
  Get the source file path for a loaded extension module.

  Returns the path from which the extension was loaded, or nil if unknown.

  ## Parameters

    * `module` - The extension module

  ## Returns

  The file path as a string, or nil if not tracked.

  ## Examples

      path = CodingAgent.Extensions.get_source_path(MyExtension)
      # => "/home/user/.lemon/agent/extensions/my_extension.ex"
  """
  @spec get_source_path(module()) :: String.t() | nil
  def get_source_path(module) when is_atom(module) do
    case :ets.whereis(@source_path_table) do
      :undefined ->
        nil

      _tid ->
        case :ets.lookup(@source_path_table, module) do
          [{^module, path}] -> path
          [] -> nil
        end
    end
  end

  @doc """
  Return the most recent extension load errors, if any.

  This function retrieves cached load errors from the last call to
  `load_extensions_with_errors/1`. It is useful for observability in
  fallback mode when no session context exists (e.g., in the `extensions_status`
  tool when the session is not found).

  The errors are stored in an ETS table and persist across function calls
  until the next `load_extensions_with_errors/1` invocation replaces them.

  ## Returns

  A tuple of `{errors, loaded_at}` where:
    - `errors` - List of `load_error()` maps (may be empty)
    - `loaded_at` - Millisecond timestamp when extensions were last loaded,
      or `nil` if `load_extensions_with_errors/1` was never called

  ## Examples

      # When no extensions have been loaded yet
      {[], nil} = CodingAgent.Extensions.last_load_errors()

      # After loading extensions with some failures
      {:ok, _exts, _errors, _validation_errors} = CodingAgent.Extensions.load_extensions_with_errors(paths)
      {errors, loaded_at} = CodingAgent.Extensions.last_load_errors()
      # errors is a list of %{source_path: ..., error: ..., error_message: ...}
      # loaded_at is an integer timestamp in milliseconds
  """
  @spec last_load_errors() :: {[load_error()], integer() | nil}
  def last_load_errors do
    case Process.get(@last_load_errors_pd_key) do
      {errors, loaded_at} when is_list(errors) ->
        {errors, loaded_at}

      _ ->
        case :ets.whereis(@load_error_table) do
          :undefined ->
            {[], nil}

          _tid ->
            errors =
              case :ets.lookup(@load_error_table, :last_errors) do
                [{:last_errors, value}] -> value
                [] -> []
              end

            loaded_at =
              case :ets.lookup(@load_error_table, :last_loaded_at) do
                [{:last_loaded_at, value}] -> value
                [] -> nil
              end

            {errors, loaded_at}
        end
    end
  end

  @doc """
  List all loaded extensions with their metadata.

  Returns metadata for all extensions that have been loaded via
  `load_extensions/1`. This is a convenience function for UIs and
  diagnostics that don't have access to the session's extension list.

  ## Returns

  A list of extension metadata maps.

  ## Examples

      extensions = CodingAgent.Extensions.list_extensions()
      # => [%{name: "my-ext", version: "1.0.0", module: MyExt, source_path: "..."}]
  """
  @spec list_extensions() :: [extension_metadata()]
  def list_extensions do
    case :ets.whereis(@source_path_table) do
      :undefined ->
        []

      _tid ->
        :ets.tab2list(@source_path_table)
        |> Enum.map(fn {module, _path} -> module end)
        |> get_info()
    end
  end

  @doc """
  Build a structured status report for extension loading.

  Creates a comprehensive report suitable for UI/CLI consumption at session
  startup. The report includes all loaded extensions, any load errors,
  tool conflict information, and provider registration details.

  ## Parameters

    * `extensions` - List of successfully loaded extension modules
    * `load_errors` - List of load error maps (from `load_extensions_with_errors/1`)
    * `opts` - Options for the report:
      * `:cwd` - Current working directory (required for tool conflict report)
      * `:tool_conflict_report` - Pre-computed conflict report (optional)
      * `:provider_registration` - Pre-computed provider registration report (optional)

  ## Returns

  An `extension_status_report()` map with all relevant information.

  ## Examples

      {:ok, extensions, errors, _validation_errors} = Extensions.load_extensions_with_errors(paths)
      report = Extensions.build_status_report(extensions, errors, cwd: "/path/to/project")

      # Report structure:
      # %{
      #   extensions: [%{name: "my-ext", version: "1.0.0", ...}],
      #   load_errors: [%{source_path: "/bad/ext.ex", error_message: "syntax error"}],
      #   tool_conflicts: %{conflicts: [...], total_tools: 16, ...},
      #   provider_registration: %{registered: [...], conflicts: [], ...},
      #   total_loaded: 2,
      #   total_errors: 1,
      #   loaded_at: 1706745600000
      # }
  """
  @spec build_status_report(loaded_extensions(), [load_error()], keyword()) ::
          extension_status_report()
  def build_status_report(extensions, load_errors, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    precomputed_conflicts = Keyword.get(opts, :tool_conflict_report)
    precomputed_providers = Keyword.get(opts, :provider_registration)

    # Get extension metadata
    extension_info = get_info(extensions)

    # Get tool conflicts if cwd is provided
    tool_conflicts =
      cond do
        precomputed_conflicts != nil ->
          precomputed_conflicts

        cwd != nil ->
          CodingAgent.ToolRegistry.tool_conflict_report(cwd)

        true ->
          nil
      end

    %{
      extensions: extension_info,
      load_errors: load_errors,
      tool_conflicts: tool_conflicts,
      provider_registration: precomputed_providers,
      total_loaded: length(extensions),
      total_errors: length(load_errors),
      loaded_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Find duplicate tool names across loaded extensions.

  Returns a map of tool names to the list of extension modules that
  provide that tool. Only tools with multiple providers are included.
  This is useful for detecting conflicts at the extension level before
  merging with built-in tools.

  ## Parameters

    * `extensions` - List of loaded extension modules
    * `cwd` - Current working directory (passed to each extension's `tools/1`)

  ## Returns

  A map where keys are tool names (strings) and values are lists of
  extension modules that provide that tool.

  ## Examples

      duplicates = CodingAgent.Extensions.find_duplicate_tools(extensions, cwd)
      # => %{"my_tool" => [ExtensionA, ExtensionB]}
  """
  @spec find_duplicate_tools(loaded_extensions(), String.t()) :: %{String.t() => [module()]}
  def find_duplicate_tools(extensions, cwd) when is_list(extensions) do
    extensions
    |> get_tools_with_source(cwd)
    |> Enum.group_by(fn {tool, _module} -> tool.name end, fn {_tool, module} -> module end)
    |> Enum.filter(fn {_name, modules} -> length(modules) > 1 end)
    |> Map.new()
  end

  @doc """
  Clear all cached extension modules and data.

  This function:
  1. Soft-purges all extension modules from the code server
  2. Clears the source path ETS table
  3. Clears the load error ETS table

  This prepares the system for a fresh extension reload without restarting
  the BEAM. After calling this function, you should call `load_extensions_with_errors/1`
  to reload extensions.

  ## Returns

  `:ok`

  ## Examples

      # Reload extensions in a session
      :ok = CodingAgent.Extensions.clear_extension_cache()
      {:ok, extensions, errors, _validation_errors} = CodingAgent.Extensions.load_extensions_with_errors(paths)
  """
  @spec clear_extension_cache() :: :ok
  def clear_extension_cache do
    # Get all currently tracked extension modules
    modules =
      case :ets.whereis(@source_path_table) do
        :undefined ->
          []

        _tid ->
          :ets.tab2list(@source_path_table)
          |> Enum.map(fn {module, _path} -> module end)
      end

    # Soft purge each module from the code server (safe for running processes)
    for module <- modules do
      _ = Reload.soft_purge_module(module)
    end

    # Clear the source path table
    case :ets.whereis(@source_path_table) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(@source_path_table)
    end

    # Clear the load error table
    case :ets.whereis(@load_error_table) do
      :undefined -> :ok
      _tid -> :ets.delete_all_objects(@load_error_table)
    end

    Process.delete(@last_load_errors_pd_key)

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Ensure the ETS table for source paths exists
  @spec ensure_source_path_table() :: :ok
  defp ensure_source_path_table do
    case :ets.whereis(@source_path_table) do
      :undefined ->
        try do
          :ets.new(@source_path_table, [:set, :public, :named_table])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp ensure_load_error_table do
    case :ets.whereis(@load_error_table) do
      :undefined ->
        try do
          :ets.new(@load_error_table, [:set, :public, :named_table])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp store_load_errors(errors) do
    ensure_load_error_table()
    loaded_at = System.system_time(:millisecond)
    :ets.insert(@load_error_table, {:last_errors, errors})
    :ets.insert(@load_error_table, {:last_loaded_at, loaded_at})
    Process.put(@last_load_errors_pd_key, {errors, loaded_at})
    :ok
  end

  defp store_validation_errors(errors) do
    ensure_load_error_table()
    :ets.insert(@load_error_table, {:last_validation_errors, errors})
    :ok
  end

  # Store the source path for an extension module
  @spec store_source_path(module(), String.t()) :: true
  defp store_source_path(module, path) do
    ensure_source_path_table()
    :ets.insert(@source_path_table, {module, path})
  end

  # Discover extension modules in a directory
  @spec discover_extensions(String.t()) :: [module()]
  defp discover_extensions(dir) do
    # Compile and load each file, extracting extension modules
    dir
    |> discover_extension_files()
    |> Enum.flat_map(&load_extension_file/1)
    |> Enum.filter(&implements_extension?/1)
  end

  # Discover extension files in a directory (without loading)
  @spec discover_extension_files(String.t()) :: [String.t()]
  defp discover_extension_files(dir) do
    expanded = Path.expand(dir)

    # Look for .ex and .exs files at the top level without relying on glob
    top_level_files =
      case File.ls(expanded) do
        {:ok, entries} ->
          entries
          |> Enum.map(&Path.join(expanded, &1))
          |> Enum.filter(&File.regular?/1)
          |> Enum.filter(fn path -> Path.extname(path) in [".ex", ".exs"] end)

        _ ->
          []
      end

    # Look for nested .ex files (lib/**) using glob
    nested_files = Path.wildcard(Path.join([expanded, "*", "lib", "**", "*.ex"]))

    (top_level_files ++ nested_files)
    |> Enum.filter(&File.regular?/1)
  end

  # Load and compile an extension file, tracking source paths
  @spec load_extension_file(String.t()) :: [module()]
  defp load_extension_file(path) do
    case load_extension_file_safe(path) do
      {:ok, modules} -> modules
      {:error, _error, _message} -> []
    end
  end

  # Load and compile an extension file with error tracking
  # Returns {:ok, modules} or {:error, error, message}
  @spec load_extension_file_safe(String.t()) ::
          {:ok, [module()]} | {:error, term(), String.t()}
  defp load_extension_file_safe(path) do
    case Reload.reload_extension(path) do
      {:ok,
       %{status: :error, metadata: %{error_message: message}, errors: [%{reason: reason} | _]}} ->
        {:error, reason, message}

      {:ok, %{metadata: %{compiled_modules: modules}}} ->
        extension_modules = Enum.filter(modules, &implements_extension?/1)

        # Store the source path for each module
        Enum.each(extension_modules, fn module ->
          store_source_path(module, path)
        end)

        {:ok, extension_modules}

      {:error, reason} ->
        {:error, reason, inspect(reason)}
    end
  end

  # Check if a module implements the Extension behaviour
  @spec implements_extension?(module()) :: boolean()
  defp implements_extension?(module) do
    unless Code.ensure_loaded?(module) do
      false
    else
      behaviours = module.__info__(:attributes)[:behaviour] || []

      if CodingAgent.Extensions.Extension in behaviours do
        true
      else
        has_required =
          function_exported?(module, :name, 0) and
            function_exported?(module, :version, 0)

        has_optional =
          function_exported?(module, :tools, 1) or
            function_exported?(module, :hooks, 0) or
            function_exported?(module, :providers, 0) or
            function_exported?(module, :capabilities, 0) or
            function_exported?(module, :config_schema, 0)

        has_required and has_optional
      end
    end
  rescue
    _ -> false
  end

  # ============================================================================
  # Extension Validation
  # ============================================================================

  @doc """
  Validate an extension module for required callbacks and return types.

  Checks:
  - Required callbacks `name/0` and `version/0` are implemented
  - `name/0` returns a string
  - `version/0` returns a string
  - `tools/1` returns a list (if implemented)
  - `hooks/0` returns a keyword list (if implemented)
  - `capabilities/0` returns a list (if implemented)
  - `config_schema/0` returns a map (if implemented)
  - `providers/0` returns a list (if implemented)

  ## Parameters

    * `module` - The extension module to validate
    * `path` - Optional source path for error reporting

  ## Returns

    * `:ok` - Validation passed
    * `{:error, errors}` - List of validation error messages
  """
  @spec validate_extension(module(), String.t() | nil) :: :ok | {:error, [String.t()]}
  def validate_extension(module, path \\ nil) do
    errors = []

    # Check required callbacks exist and return correct types
    errors = validate_name_callback(module, errors)
    errors = validate_version_callback(module, errors)

    # Check optional callbacks return correct types if implemented
    errors = validate_tools_callback(module, path, errors)
    errors = validate_hooks_callback(module, errors)
    errors = validate_capabilities_callback(module, errors)
    errors = validate_config_schema_callback(module, errors)
    errors = validate_providers_callback(module, errors)

    case errors do
      [] -> :ok
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  defp validate_name_callback(module, errors) do
    if function_exported?(module, :name, 0) do
      try do
        result = module.name()

        if is_binary(result) do
          errors
        else
          ["name/0 must return a string, got: #{inspect(result)}" | errors]
        end
      rescue
        e -> ["name/0 raised an error: #{Exception.message(e)}" | errors]
      end
    else
      ["missing required callback: name/0" | errors]
    end
  end

  defp validate_version_callback(module, errors) do
    if function_exported?(module, :version, 0) do
      try do
        result = module.version()

        if is_binary(result) do
          errors
        else
          ["version/0 must return a string, got: #{inspect(result)}" | errors]
        end
      rescue
        e -> ["version/0 raised an error: #{Exception.message(e)}" | errors]
      end
    else
      ["missing required callback: version/0" | errors]
    end
  end

  defp validate_tools_callback(module, path, errors) do
    if function_exported?(module, :tools, 1) do
      try do
        # Use the extension's own directory or a fallback for validation
        cwd = if path, do: Path.dirname(path), else: "/"
        result = module.tools(cwd)

        if is_list(result) do
          errors
        else
          ["tools/1 must return a list, got: #{inspect(result)}" | errors]
        end
      rescue
        e -> ["tools/1 raised an error: #{Exception.message(e)}" | errors]
      end
    else
      errors
    end
  end

  defp validate_hooks_callback(module, errors) do
    if function_exported?(module, :hooks, 0) do
      try do
        result = module.hooks()

        if Keyword.keyword?(result) do
          errors
        else
          ["hooks/0 must return a keyword list, got: #{inspect(result)}" | errors]
        end
      rescue
        e -> ["hooks/0 raised an error: #{Exception.message(e)}" | errors]
      end
    else
      errors
    end
  end

  defp validate_capabilities_callback(module, errors) do
    if function_exported?(module, :capabilities, 0) do
      try do
        result = module.capabilities()

        if is_list(result) do
          errors
        else
          ["capabilities/0 must return a list, got: #{inspect(result)}" | errors]
        end
      rescue
        e -> ["capabilities/0 raised an error: #{Exception.message(e)}" | errors]
      end
    else
      errors
    end
  end

  defp validate_config_schema_callback(module, errors) do
    if function_exported?(module, :config_schema, 0) do
      try do
        result = module.config_schema()

        if is_map(result) do
          errors
        else
          ["config_schema/0 must return a map, got: #{inspect(result)}" | errors]
        end
      rescue
        e -> ["config_schema/0 raised an error: #{Exception.message(e)}" | errors]
      end
    else
      errors
    end
  end

  defp validate_providers_callback(module, errors) do
    if function_exported?(module, :providers, 0) do
      try do
        result = module.providers()

        if is_list(result) do
          errors
        else
          ["providers/0 must return a list, got: #{inspect(result)}" | errors]
        end
      rescue
        e -> ["providers/0 raised an error: #{Exception.message(e)}" | errors]
      end
    else
      errors
    end
  end

  # Check if a module has a specific callback
  @spec has_callback?(module(), atom(), non_neg_integer()) :: boolean()
  defp has_callback?(module, function, arity) do
    function_exported?(module, function, arity)
  end

  # Safely call a function with a default value on error
  @spec safe_call(module(), atom(), list(), term()) :: term()
  defp safe_call(module, function, args, default) do
    if function_exported?(module, function, length(args)) do
      try do
        apply(module, function, args)
      rescue
        _ -> default
      end
    else
      default
    end
  end

  defp ensure_tool_types_loaded do
    Code.ensure_loaded?(AgentCore.Types.AgentTool)
    Code.ensure_loaded?(AgentCore.Types.AgentToolResult)
  end
end
