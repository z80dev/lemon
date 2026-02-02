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
  Structured status report for extension loading at session startup.

  Published as a single `{:extension_status_report, report}` event for UI/CLI consumption.

  - `:extensions` - List of successfully loaded extension metadata
  - `:load_errors` - List of extensions that failed to load
  - `:tool_conflicts` - Tool conflict report from ToolRegistry
  - `:total_loaded` - Count of successfully loaded extensions
  - `:total_errors` - Count of extensions that failed to load
  - `:loaded_at` - Timestamp when extensions were loaded
  """
  @type extension_status_report :: %{
          extensions: [extension_metadata()],
          load_errors: [load_error()],
          tool_conflicts: CodingAgent.ToolRegistry.conflict_report() | nil,
          total_loaded: non_neg_integer(),
          total_errors: non_neg_integer(),
          loaded_at: integer()
        }

  # ETS table for storing extension source paths
  @source_path_table :coding_agent_extension_source_paths

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
  and a list of load errors for files that failed to compile or load.

  ## Parameters

    * `paths` - List of directory paths to search for extensions

  ## Returns

    * `{:ok, extensions, load_errors}` - Tuple with loaded extensions and errors

  ## Examples

      {:ok, extensions, errors} = CodingAgent.Extensions.load_extensions_with_errors([
        "~/.lemon/agent/extensions",
        "/path/to/project/.lemon/extensions"
      ])

      if errors != [] do
        IO.puts("Some extensions failed to load:")
        for error <- errors do
          IO.puts("  - \#{error.source_path}: \#{error.error_message}")
        end
      end
  """
  @spec load_extensions_with_errors([String.t()]) ::
          {:ok, loaded_extensions(), [load_error()]}
  def load_extensions_with_errors(paths) when is_list(paths) do
    # Ensure the source path table exists
    ensure_source_path_table()

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

    {:ok, Enum.uniq(extensions), Enum.reverse(errors)}
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
          # Log but don't crash on hook errors
          IO.warn("Hook error for #{event}: #{inspect(e)}")
      catch
        :throw, reason ->
          IO.warn("Hook throw for #{event}: #{inspect(reason)}")

        :exit, reason ->
          IO.warn("Hook exit for #{event}: #{inspect(reason)}")
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
  and tool conflict information.

  ## Parameters

    * `extensions` - List of successfully loaded extension modules
    * `load_errors` - List of load error maps (from `load_extensions_with_errors/1`)
    * `opts` - Options for the report:
      * `:cwd` - Current working directory (required for tool conflict report)
      * `:tool_conflict_report` - Pre-computed conflict report (optional)

  ## Returns

  An `extension_status_report()` map with all relevant information.

  ## Examples

      {:ok, extensions, errors} = Extensions.load_extensions_with_errors(paths)
      report = Extensions.build_status_report(extensions, errors, cwd: "/path/to/project")

      # Report structure:
      # %{
      #   extensions: [%{name: "my-ext", version: "1.0.0", ...}],
      #   load_errors: [%{source_path: "/bad/ext.ex", error_message: "syntax error"}],
      #   tool_conflicts: %{conflicts: [...], total_tools: 16, ...},
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

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Ensure the ETS table for source paths exists
  @spec ensure_source_path_table() :: :ok
  defp ensure_source_path_table do
    case :ets.whereis(@source_path_table) do
      :undefined ->
        :ets.new(@source_path_table, [:set, :public, :named_table])
        :ok

      _tid ->
        :ok
    end
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
    # Look for .ex and .exs files
    patterns = [
      Path.join(dir, "*.ex"),
      Path.join(dir, "*.exs"),
      Path.join([dir, "*", "lib", "**", "*.ex"])
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
  end

  # Load and compile an extension file, tracking source paths
  @spec load_extension_file(String.t()) :: [module()]
  defp load_extension_file(path) do
    try do
      modules =
        Code.compile_file(path)
        |> Enum.map(fn {module, _binary} -> module end)

      extension_modules = Enum.filter(modules, &implements_extension?/1)

      # Store the source path for each module
      Enum.each(extension_modules, fn module ->
        store_source_path(module, path)
      end)

      extension_modules
    rescue
      _ -> []
    end
  end

  # Load and compile an extension file with error tracking
  # Returns {:ok, modules} or {:error, error, message}
  @spec load_extension_file_safe(String.t()) ::
          {:ok, [module()]} | {:error, term(), String.t()}
  defp load_extension_file_safe(path) do
    modules =
      Code.compile_file(path)
      |> Enum.map(fn {module, _binary} -> module end)

    extension_modules = Enum.filter(modules, &implements_extension?/1)

    # Store the source path for each module
    Enum.each(extension_modules, fn module ->
      store_source_path(module, path)
    end)

    {:ok, extension_modules}
  rescue
    e in CompileError ->
      {:error, e, "Compile error: #{e.description}"}

    e in SyntaxError ->
      {:error, e, "Syntax error at line #{e.line}: #{e.description}"}

    e in TokenMissingError ->
      {:error, e, "Token error at line #{e.line}: #{e.description}"}

    e ->
      {:error, e, Exception.message(e)}
  end

  # Check if a module implements the Extension behaviour
  @spec implements_extension?(module()) :: boolean()
  defp implements_extension?(module) do
    behaviours = module.__info__(:attributes)[:behaviour] || []
    CodingAgent.Extensions.Extension in behaviours
  rescue
    _ -> false
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
end
