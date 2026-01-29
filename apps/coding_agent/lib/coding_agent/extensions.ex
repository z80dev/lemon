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
  """

  alias CodingAgent.Config

  @type extension_module :: module()
  @type loaded_extensions :: [extension_module()]

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
    extensions =
      paths
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&discover_extensions/1)
      |> Enum.uniq()

    {:ok, extensions}
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
    extensions
    |> Enum.filter(&has_callback?(&1, :tools, 1))
    |> Enum.flat_map(fn ext ->
      try do
        ext.tools(cwd)
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
      end
    end

    :ok
  end

  # ============================================================================
  # Extension Info
  # ============================================================================

  @doc """
  Get information about loaded extensions.

  Returns a list of maps containing name and version for each extension.

  ## Parameters

    * `extensions` - List of loaded extension modules

  ## Returns

  A list of maps with `:name`, `:version`, and `:module` keys.

  ## Examples

      info = CodingAgent.Extensions.get_info(extensions)
      # => [%{name: "my-ext", version: "1.0.0", module: MyExt}]
  """
  @spec get_info(loaded_extensions()) :: [%{name: String.t(), version: String.t(), module: module()}]
  def get_info(extensions) when is_list(extensions) do
    Enum.map(extensions, fn ext ->
      %{
        name: safe_call(ext, :name, [], "unknown"),
        version: safe_call(ext, :version, [], "0.0.0"),
        module: ext
      }
    end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Discover extension modules in a directory
  @spec discover_extensions(String.t()) :: [module()]
  defp discover_extensions(dir) do
    # Look for .ex and .exs files
    patterns = [
      Path.join(dir, "*.ex"),
      Path.join(dir, "*.exs"),
      Path.join([dir, "*", "lib", "**", "*.ex"])
    ]

    files =
      patterns
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&File.regular?/1)

    # Compile and load each file, extracting extension modules
    files
    |> Enum.flat_map(&load_extension_file/1)
    |> Enum.filter(&implements_extension?/1)
  end

  # Load and compile an extension file
  @spec load_extension_file(String.t()) :: [module()]
  defp load_extension_file(path) do
    try do
      Code.compile_file(path)
      |> Enum.map(fn {module, _binary} -> module end)
    rescue
      _ -> []
    end
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
