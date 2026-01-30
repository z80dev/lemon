defmodule CodingAgent.LayeredConfig do
  @moduledoc """
  Layered configuration system for the coding agent.

  Loads configuration from `.lemon/config.exs` files at multiple levels:
  - **Global**: `~/.lemon/agent/config.exs`
  - **Project**: `<project>/.lemon/config.exs`
  - **Session**: In-memory overrides for the current session

  Configuration is merged in order (global -> project -> session), with later
  values taking precedence. This allows users to set global defaults and
  override them per-project or per-session.

  ## Configuration File Format

  Config files are Elixir scripts that return a keyword list or map:

      # ~/.lemon/agent/config.exs
      [
        model: "claude-sonnet-4-20250514",
        thinking_level: :medium,
        tools: [
          bash: [timeout: 120_000],
          read: [max_lines: 5000]
        ],
        extensions: [
          "~/.lemon/agent/extensions/my-ext"
        ]
      ]

  ## Usage

      # Load config for a project directory
      config = LayeredConfig.load("/path/to/project")

      # Get values with defaults
      model = LayeredConfig.get(config, :model, "claude-sonnet-4-20250514")

      # Get values that must exist (raises on missing)
      model = LayeredConfig.get!(config, :model)

      # Set session-level overrides
      config = LayeredConfig.put(config, :thinking_level, :high)

      # Nested access
      timeout = LayeredConfig.get(config, [:tools, :bash, :timeout], 60_000)
  """

  require Logger

  alias CodingAgent.Config

  @type config_value :: term()
  @type config_key :: atom() | [atom()]
  @type config_layer :: :global | :project | :session

  @type t :: %__MODULE__{
          global: map(),
          project: map(),
          session: map(),
          cwd: String.t() | nil
        }

  defstruct [
    global: %{},
    project: %{},
    session: %{},
    cwd: nil
  ]

  # Default configuration values
  @defaults %{
    # Model settings
    model: nil,
    thinking_level: :off,

    # Compaction settings
    compaction: %{
      enabled: true,
      reserve_tokens: 16384,
      keep_recent_tokens: 20000
    },

    # Retry settings
    retry: %{
      enabled: true,
      max_retries: 3,
      base_delay_ms: 1000
    },

    # Tool settings
    tools: %{
      bash: %{timeout: 120_000, sandbox: false},
      read: %{max_lines: 2000},
      write: %{confirm: false},
      edit: %{confirm: false},
      glob: %{max_results: 1000},
      grep: %{max_results: 500, context_lines: 2}
    },

    # Extension paths
    extensions: [],

    # Shell settings
    shell: %{
      path: nil,
      command_prefix: nil
    },

    # Display settings
    theme: "default",
    debug: false
  }

  # ============================================================================
  # Loading
  # ============================================================================

  @doc """
  Load configuration for a project directory.

  Loads and merges configuration from:
  1. Global config (`~/.lemon/agent/config.exs`)
  2. Project config (`<cwd>/.lemon/config.exs`)

  Returns a config struct that can be queried with `get/2`, `get/3`, and `get!/2`.

  ## Parameters

    * `cwd` - The current working directory (project root)

  ## Examples

      config = LayeredConfig.load("/home/user/project")
      model = LayeredConfig.get(config, :model)
  """
  @spec load(String.t()) :: t()
  def load(cwd) do
    global = load_file(global_config_path())
    project = load_file(project_config_path(cwd))

    %__MODULE__{
      global: global,
      project: project,
      session: %{},
      cwd: cwd
    }
  end

  @doc """
  Load configuration from a specific file.

  Returns an empty map if the file doesn't exist or can't be evaluated.

  ## Parameters

    * `path` - Path to the config.exs file

  ## Examples

      config = LayeredConfig.load_file("~/.lemon/agent/config.exs")
  """
  @spec load_file(String.t()) :: map()
  def load_file(path) do
    expanded_path = Path.expand(path)

    if File.exists?(expanded_path) do
      try do
        {result, _bindings} = Code.eval_file(expanded_path)
        normalize_config(result)
      rescue
        e ->
          Logger.warning("Failed to load config from #{path}: #{Exception.message(e)}")
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Reload configuration from disk.

  Re-reads global and project config files, preserving session overrides.

  ## Parameters

    * `config` - The existing config struct

  ## Examples

      config = LayeredConfig.reload(config)
  """
  @spec reload(t()) :: t()
  def reload(%__MODULE__{cwd: cwd, session: session}) do
    global = load_file(global_config_path())
    project = load_file(project_config_path(cwd))

    %__MODULE__{
      global: global,
      project: project,
      session: session,
      cwd: cwd
    }
  end

  # ============================================================================
  # Accessors
  # ============================================================================

  @doc """
  Get a configuration value with an optional default.

  Looks up the value in the merged configuration (session -> project -> global -> defaults).
  Supports nested keys using a list of atoms.

  ## Parameters

    * `config` - The config struct
    * `key` - Atom or list of atoms for nested access
    * `default` - Default value if key is not found (default: nil)

  ## Examples

      # Simple access
      model = LayeredConfig.get(config, :model)

      # With default
      model = LayeredConfig.get(config, :model, "claude-sonnet-4-20250514")

      # Nested access
      timeout = LayeredConfig.get(config, [:tools, :bash, :timeout], 60_000)
  """
  @spec get(t(), config_key(), config_value()) :: config_value()
  def get(%__MODULE__{} = config, key, default \\ nil) do
    merged = merge_layers(config)

    case get_in_config(merged, key) do
      nil -> get_default(key, default)
      value -> value
    end
  end

  @doc """
  Get a configuration value, raising if not found.

  Like `get/3` but raises `KeyError` if the key is not present in
  any layer and no default exists.

  ## Parameters

    * `config` - The config struct
    * `key` - Atom or list of atoms for nested access

  ## Examples

      model = LayeredConfig.get!(config, :model)

  ## Raises

    * `KeyError` - If the key is not found
  """
  @spec get!(t(), config_key()) :: config_value()
  def get!(%__MODULE__{} = config, key) do
    merged = merge_layers(config)

    case get_in_config(merged, key) do
      nil ->
        case get_default(key, :__not_found__) do
          :__not_found__ ->
            raise KeyError, key: key, term: "LayeredConfig"

          default_value ->
            default_value
        end

      value ->
        value
    end
  end

  @doc """
  Set a session-level configuration value.

  Session values take precedence over project and global values.
  This is useful for runtime overrides.

  ## Parameters

    * `config` - The config struct
    * `key` - Atom or list of atoms for nested access
    * `value` - The value to set

  ## Examples

      config = LayeredConfig.put(config, :thinking_level, :high)
      config = LayeredConfig.put(config, [:tools, :bash, :timeout], 300_000)
  """
  @spec put(t(), config_key(), config_value()) :: t()
  def put(%__MODULE__{session: session} = config, key, value) do
    updated_session = put_in_config(session, key, value)
    %{config | session: updated_session}
  end

  @doc """
  Set a value at a specific layer.

  Allows setting values at global, project, or session level.

  ## Parameters

    * `config` - The config struct
    * `layer` - One of `:global`, `:project`, or `:session`
    * `key` - Atom or list of atoms for nested access
    * `value` - The value to set

  ## Examples

      config = LayeredConfig.put_layer(config, :project, :model, "gpt-4")
  """
  @spec put_layer(t(), config_layer(), config_key(), config_value()) :: t()
  def put_layer(%__MODULE__{} = config, layer, key, value) do
    case layer do
      :global ->
        updated = put_in_config(config.global, key, value)
        %{config | global: updated}

      :project ->
        updated = put_in_config(config.project, key, value)
        %{config | project: updated}

      :session ->
        put(config, key, value)
    end
  end

  @doc """
  Get the raw value from a specific layer.

  Returns the value at the specified layer without merging.
  Useful for debugging or inspecting layer-specific values.

  ## Parameters

    * `config` - The config struct
    * `layer` - One of `:global`, `:project`, or `:session`
    * `key` - Atom or list of atoms for nested access

  ## Examples

      global_model = LayeredConfig.get_layer(config, :global, :model)
  """
  @spec get_layer(t(), config_layer(), config_key()) :: config_value()
  def get_layer(%__MODULE__{} = config, layer, key) do
    layer_data =
      case layer do
        :global -> config.global
        :project -> config.project
        :session -> config.session
      end

    get_in_config(layer_data, key)
  end

  @doc """
  Check if a key exists in the configuration.

  Returns true if the key exists in any layer (session, project, global) or defaults.

  ## Parameters

    * `config` - The config struct
    * `key` - Atom or list of atoms for nested access

  ## Examples

      if LayeredConfig.has_key?(config, :model) do
        # ...
      end
  """
  @spec has_key?(t(), config_key()) :: boolean()
  def has_key?(%__MODULE__{} = config, key) do
    merged = merge_layers(config)
    get_in_config(merged, key) != nil or get_default(key, :__not_found__) != :__not_found__
  end

  @doc """
  Get all configuration values as a merged map.

  Returns the fully merged configuration from all layers with defaults applied.

  ## Parameters

    * `config` - The config struct

  ## Examples

      all = LayeredConfig.to_map(config)
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    deep_merge(@defaults, merge_layers(config))
  end

  @doc """
  Get the configuration from a specific layer as a map.

  ## Parameters

    * `config` - The config struct
    * `layer` - One of `:global`, `:project`, or `:session`

  ## Examples

      project_config = LayeredConfig.layer_to_map(config, :project)
  """
  @spec layer_to_map(t(), config_layer()) :: map()
  def layer_to_map(%__MODULE__{} = config, layer) do
    case layer do
      :global -> config.global
      :project -> config.project
      :session -> config.session
    end
  end

  # ============================================================================
  # Persistence
  # ============================================================================

  @doc """
  Save the global configuration to disk.

  Writes the global layer to `~/.lemon/agent/config.exs`.

  ## Parameters

    * `config` - The config struct

  ## Examples

      :ok = LayeredConfig.save_global(config)
  """
  @spec save_global(t()) :: :ok | {:error, term()}
  def save_global(%__MODULE__{global: global}) do
    path = global_config_path()
    save_to_file(path, global)
  end

  @doc """
  Save the project configuration to disk.

  Writes the project layer to `<cwd>/.lemon/config.exs`.

  ## Parameters

    * `config` - The config struct

  ## Examples

      :ok = LayeredConfig.save_project(config)
  """
  @spec save_project(t()) :: :ok | {:error, term()}
  def save_project(%__MODULE__{project: project, cwd: cwd}) when is_binary(cwd) do
    path = project_config_path(cwd)
    save_to_file(path, project)
  end

  def save_project(%__MODULE__{cwd: nil}), do: {:error, :no_cwd}

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @spec global_config_path() :: String.t()
  defp global_config_path do
    Path.join(Config.agent_dir(), "config.exs")
  end

  @spec project_config_path(String.t()) :: String.t()
  defp project_config_path(cwd) do
    Path.join(Config.project_config_dir(cwd), "config.exs")
  end

  @spec normalize_config(term()) :: map()
  defp normalize_config(result) when is_list(result) do
    if Keyword.keyword?(result) do
      result
      |> Enum.map(fn {k, v} -> {k, normalize_value(v)} end)
      |> Map.new()
    else
      %{}
    end
  end

  defp normalize_config(result) when is_map(result) do
    result
    |> Enum.map(fn {k, v} -> {normalize_key(k), normalize_value(v)} end)
    |> Map.new()
  end

  defp normalize_config(_), do: %{}

  @spec normalize_key(term()) :: atom()
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
  defp normalize_key(key), do: key

  @spec normalize_value(term()) :: term()
  defp normalize_value(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {k, v} -> {k, normalize_value(v)} end)
      |> Map.new()
    else
      Enum.map(value, &normalize_value/1)
    end
  end

  defp normalize_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {normalize_key(k), normalize_value(v)} end)
    |> Map.new()
  end

  defp normalize_value(value), do: value

  @spec merge_layers(t()) :: map()
  defp merge_layers(%__MODULE__{global: global, project: project, session: session}) do
    global
    |> deep_merge(project)
    |> deep_merge(session)
  end

  @spec deep_merge(map(), map()) :: map()
  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      if is_map(base_val) and is_map(override_val) do
        deep_merge(base_val, override_val)
      else
        override_val
      end
    end)
  end

  defp deep_merge(_base, override), do: override

  @spec get_in_config(map(), config_key()) :: config_value()
  defp get_in_config(map, key) when is_atom(key) do
    Map.get(map, key)
  end

  defp get_in_config(map, [key]) when is_atom(key) do
    Map.get(map, key)
  end

  defp get_in_config(map, [key | rest]) when is_atom(key) do
    case Map.get(map, key) do
      nested when is_map(nested) -> get_in_config(nested, rest)
      _ -> nil
    end
  end

  defp get_in_config(_map, []), do: nil

  @spec put_in_config(map(), config_key(), config_value()) :: map()
  defp put_in_config(map, key, value) when is_atom(key) do
    Map.put(map, key, value)
  end

  defp put_in_config(map, [key], value) when is_atom(key) do
    Map.put(map, key, value)
  end

  defp put_in_config(map, [key | rest], value) when is_atom(key) do
    nested = Map.get(map, key, %{})
    updated_nested = put_in_config(nested, rest, value)
    Map.put(map, key, updated_nested)
  end

  defp put_in_config(map, [], _value), do: map

  @spec get_default(config_key(), config_value()) :: config_value()
  defp get_default(key, fallback) do
    case get_in_config(@defaults, key) do
      nil -> fallback
      value -> value
    end
  end

  @spec save_to_file(String.t(), map()) :: :ok | {:error, term()}
  defp save_to_file(path, config) do
    expanded = Path.expand(path)
    dir = Path.dirname(expanded)

    with :ok <- File.mkdir_p(dir) do
      content = format_config(config)
      File.write(expanded, content)
    end
  end

  @spec format_config(map()) :: String.t()
  defp format_config(config) do
    # Convert map to keyword list for nicer formatting
    keyword_list = map_to_keyword(config)

    formatted =
      keyword_list
      |> Enum.map(&format_config_entry/1)
      |> Enum.join(",\n")

    "[\n#{formatted}\n]\n"
  end

  @spec map_to_keyword(map()) :: keyword()
  defp map_to_keyword(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      key = if is_atom(k), do: k, else: String.to_atom(k)
      {key, map_to_keyword_value(v)}
    end)
    |> Enum.sort_by(fn {k, _} -> Atom.to_string(k) end)
  end

  @spec map_to_keyword_value(term()) :: term()
  defp map_to_keyword_value(value) when is_map(value), do: map_to_keyword(value)
  defp map_to_keyword_value(value), do: value

  @spec format_config_entry({atom(), term()}) :: String.t()
  defp format_config_entry({key, value}) do
    formatted_value = format_value(value, 2)
    "  #{key}: #{formatted_value}"
  end

  @spec format_value(term(), non_neg_integer()) :: String.t()
  defp format_value(value, _indent) when is_atom(value), do: ":#{value}"
  defp format_value(value, _indent) when is_binary(value), do: inspect(value)
  defp format_value(value, _indent) when is_number(value), do: to_string(value)
  defp format_value(value, _indent) when is_boolean(value), do: to_string(value)

  defp format_value(value, indent) when is_list(value) do
    if Keyword.keyword?(value) and value != [] do
      entries =
        value
        |> Enum.map(fn {k, v} ->
          String.duplicate(" ", indent + 2) <> "#{k}: #{format_value(v, indent + 2)}"
        end)
        |> Enum.join(",\n")

      "[\n#{entries}\n#{String.duplicate(" ", indent)}]"
    else
      "[#{Enum.map_join(value, ", ", &format_value(&1, indent))}]"
    end
  end

  defp format_value(value, indent) when is_map(value) do
    if map_size(value) == 0 do
      "%{}"
    else
      entries =
        value
        |> Enum.map(fn {k, v} ->
          key_str = if is_atom(k), do: "#{k}:", else: "#{inspect(k)} =>"
          String.duplicate(" ", indent + 2) <> "#{key_str} #{format_value(v, indent + 2)}"
        end)
        |> Enum.join(",\n")

      "%{\n#{entries}\n#{String.duplicate(" ", indent)}}"
    end
  end

  defp format_value(value, _indent), do: inspect(value)
end
