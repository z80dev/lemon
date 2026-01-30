defmodule CodingAgent.SettingsManager do
  @moduledoc """
  Manages global and project-specific settings with merging.

  Settings are stored as JSON files and can exist at two levels:
  - Global: `~/.lemon/agent/settings.json`
  - Project: `<project>/.lemon/settings.json`

  When loading settings, project settings override global settings for non-nil values.
  List fields (like `extension_paths`) are concatenated.

  ## Usage

      # Load merged settings for a project
      settings = CodingAgent.SettingsManager.load("/path/to/project")

      # Get specific settings groups
      compaction = CodingAgent.SettingsManager.get_compaction_settings(settings)
      retry = CodingAgent.SettingsManager.get_retry_settings(settings)

      # Save settings
      CodingAgent.SettingsManager.save_global(settings)
      CodingAgent.SettingsManager.save_project("/path/to/project", settings)

  ## Model Configuration

  `defaultModel` can be a map or a string:

      {
        "defaultModel": { "provider": "anthropic", "modelId": "claude-sonnet-4-20250514" },
        "baseUrl": "https://api.anthropic.com"
      }

      {
        "defaultModel": "claude-sonnet-4-20250514"
      }

  You can also set top-level `provider`/`model` and configure providers:

      {
        "provider": "anthropic",
        "model": "claude-sonnet-4-20250514",
        "providers": {
          "anthropic": {
            "apiKey": "sk-ant-...",
            "baseUrl": "https://api.anthropic.com"
          }
        }
      }
  """

  alias CodingAgent.Config

  @type thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh

  @type model_config :: %{
          provider: String.t() | nil,
          model_id: String.t(),
          base_url: String.t() | nil
        }

  @type t :: %__MODULE__{
          # Model settings
          default_model: model_config() | nil,
          default_thinking_level: thinking_level(),
          scoped_models: [model_config()],

          # Provider settings
          providers: %{optional(String.t()) => %{api_key: String.t() | nil, base_url: String.t() | nil}},

          # Compaction settings
          compaction_enabled: boolean(),
          reserve_tokens: non_neg_integer(),
          keep_recent_tokens: non_neg_integer(),

          # Retry settings
          retry_enabled: boolean(),
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),

          # Shell settings
          shell_path: String.t() | nil,
          command_prefix: String.t() | nil,

          # Tool settings
          auto_resize_images: boolean(),

          # Extension settings
          extension_paths: [String.t()],

          # Display settings
          theme: String.t()
        }

  defstruct [
    # Model settings
    default_model: nil,
    default_thinking_level: :medium,
    scoped_models: [],

    # Provider settings
    providers: %{},

    # Compaction settings
    compaction_enabled: true,
    reserve_tokens: 16384,
    keep_recent_tokens: 20000,

    # Retry settings
    retry_enabled: true,
    max_retries: 3,
    base_delay_ms: 1000,

    # Shell settings
    shell_path: nil,
    command_prefix: nil,

    # Tool settings
    auto_resize_images: true,

    # Extension settings
    extension_paths: [],

    # Display settings
    theme: "default"
  ]

  # Fields that should be concatenated when merging instead of replaced
  @list_fields [:extension_paths, :scoped_models]

  # ============================================================================
  # Loading
  # ============================================================================

  @doc """
  Load settings from global and project files, merging them.

  Project settings take precedence over global settings for non-nil values.
  List fields (extension_paths, scoped_models) are concatenated.

  ## Parameters

    * `cwd` - The current working directory (project root)

  ## Examples

      iex> settings = CodingAgent.SettingsManager.load("/home/user/project")
      %CodingAgent.SettingsManager{...}
  """
  @spec load(String.t()) :: t()
  def load(cwd) do
    global = load_file(Config.settings_file())
    project = load_file(project_settings_file(cwd))
    merge(global, project)
  end

  @doc """
  Load settings from a single file.

  Returns default settings if the file doesn't exist or can't be parsed.

  ## Parameters

    * `path` - The path to the settings JSON file

  ## Examples

      iex> settings = CodingAgent.SettingsManager.load_file("~/.lemon/agent/settings.json")
      %CodingAgent.SettingsManager{...}
  """
  @spec load_file(String.t()) :: t()
  def load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, map} -> from_map(map)
          {:error, _} -> %__MODULE__{}
        end

      {:error, _} ->
        %__MODULE__{}
    end
  end

  # ============================================================================
  # Saving
  # ============================================================================

  @doc """
  Save settings to global file.

  Creates the parent directory if it doesn't exist.

  ## Parameters

    * `settings` - The settings struct to save

  ## Examples

      iex> CodingAgent.SettingsManager.save_global(settings)
      :ok
  """
  @spec save_global(t()) :: :ok
  def save_global(%__MODULE__{} = settings) do
    path = Config.settings_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(to_map(settings), pretty: true))
    :ok
  end

  @doc """
  Save settings to project file.

  Creates the parent directory if it doesn't exist.

  ## Parameters

    * `cwd` - The project root directory
    * `settings` - The settings struct to save

  ## Examples

      iex> CodingAgent.SettingsManager.save_project("/home/user/project", settings)
      :ok
  """
  @spec save_project(String.t(), t()) :: :ok
  def save_project(cwd, %__MODULE__{} = settings) do
    path = project_settings_file(cwd)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(to_map(settings), pretty: true))
    :ok
  end

  # ============================================================================
  # Merging
  # ============================================================================

  @doc """
  Merge two settings structs, second takes precedence for non-nil values.

  For list fields (extension_paths, scoped_models), the lists are concatenated
  with the base list first, followed by the override list.

  ## Parameters

    * `base` - The base settings (typically global)
    * `override` - The override settings (typically project)

  ## Examples

      iex> base = %CodingAgent.SettingsManager{theme: "dark", max_retries: 3}
      iex> override = %CodingAgent.SettingsManager{max_retries: 5}
      iex> CodingAgent.SettingsManager.merge(base, override)
      %CodingAgent.SettingsManager{theme: "dark", max_retries: 5, ...}
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = override) do
    defaults = %__MODULE__{}

    fields = Map.keys(defaults) -- [:__struct__]

    merged_map =
      Enum.reduce(fields, %{}, fn field, acc ->
        base_value = Map.get(base, field)
        override_value = Map.get(override, field)
        default_value = Map.get(defaults, field)

        merged_value =
          cond do
            field in @list_fields ->
              (base_value || []) ++ (override_value || [])

            field == :providers ->
              merge_provider_configs(base_value || %{}, override_value || %{})

            true ->
              if override_value != default_value do
                override_value
              else
                base_value
              end
          end

        Map.put(acc, field, merged_value)
      end)

    struct(__MODULE__, merged_map)
  end

  # ============================================================================
  # Getters
  # ============================================================================

  @doc """
  Get compaction settings as a map.

  ## Parameters

    * `settings` - The settings struct

  ## Returns

  A map with `:enabled`, `:reserve_tokens`, and `:keep_recent_tokens` keys.

  ## Examples

      iex> CodingAgent.SettingsManager.get_compaction_settings(settings)
      %{enabled: true, reserve_tokens: 16384, keep_recent_tokens: 20000}
  """
  @spec get_compaction_settings(t()) :: %{
          enabled: boolean(),
          reserve_tokens: non_neg_integer(),
          keep_recent_tokens: non_neg_integer()
        }
  def get_compaction_settings(%__MODULE__{} = settings) do
    %{
      enabled: settings.compaction_enabled,
      reserve_tokens: settings.reserve_tokens,
      keep_recent_tokens: settings.keep_recent_tokens
    }
  end

  @doc """
  Get retry settings as a map.

  ## Parameters

    * `settings` - The settings struct

  ## Returns

  A map with `:enabled`, `:max_retries`, and `:base_delay_ms` keys.

  ## Examples

      iex> CodingAgent.SettingsManager.get_retry_settings(settings)
      %{enabled: true, max_retries: 3, base_delay_ms: 1000}
  """
  @spec get_retry_settings(t()) :: %{
          enabled: boolean(),
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer()
        }
  def get_retry_settings(%__MODULE__{} = settings) do
    %{
      enabled: settings.retry_enabled,
      max_retries: settings.max_retries,
      base_delay_ms: settings.base_delay_ms
    }
  end

  @doc """
  Get model settings as a map.

  ## Parameters

    * `settings` - The settings struct

  ## Returns

  A map with `:default_model`, `:default_thinking_level`, and `:scoped_models` keys.

  ## Examples

      iex> CodingAgent.SettingsManager.get_model_settings(settings)
      %{default_model: nil, default_thinking_level: :off, scoped_models: []}
  """
  @spec get_model_settings(t()) :: %{
          default_model: model_config() | nil,
          default_thinking_level: thinking_level(),
          scoped_models: [model_config()]
        }
  def get_model_settings(%__MODULE__{} = settings) do
    %{
      default_model: settings.default_model,
      default_thinking_level: settings.default_thinking_level,
      scoped_models: settings.scoped_models
    }
  end

  @doc """
  Get shell settings as a map.

  ## Parameters

    * `settings` - The settings struct

  ## Returns

  A map with `:shell_path` and `:command_prefix` keys.

  ## Examples

      iex> CodingAgent.SettingsManager.get_shell_settings(settings)
      %{shell_path: nil, command_prefix: nil}
  """
  @spec get_shell_settings(t()) :: %{
          shell_path: String.t() | nil,
          command_prefix: String.t() | nil
        }
  def get_shell_settings(%__MODULE__{} = settings) do
    %{
      shell_path: settings.shell_path,
      command_prefix: settings.command_prefix
    }
  end

  # ============================================================================
  # Conversion
  # ============================================================================

  @doc false
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    default_model =
      parse_model_config(map["defaultModel"] || map["default_model"]) ||
        parse_model_config(
          map["defaultModelName"] || map["default_model_name"] ||
            map["defaultModelId"] || map["default_model_id"]
        ) ||
        parse_model_config(%{
          "provider" => map["provider"] || map["chat_provider"],
          "modelId" => map["model"] || map["chat_model"]
        })

    default_model =
      maybe_override_base_url(
        default_model,
        map["baseUrl"] || map["base_url"]
      )

    providers = parse_providers(map["providers"] || map["provider_configs"] || map["providerConfigs"])

    default_model = maybe_override_base_url_from_provider(default_model, providers)

    %__MODULE__{
      # Model settings
      default_model: default_model,
      providers: providers,
      default_thinking_level:
        parse_thinking_level(map["defaultThinkingLevel"] || map["default_thinking_level"]),
      scoped_models: parse_scoped_models(map["scopedModels"] || map["scoped_models"]),

      # Compaction settings
      compaction_enabled:
        parse_boolean(
          map["compactionEnabled"] || map["compaction_enabled"],
          true
        ),
      reserve_tokens: map["reserveTokens"] || map["reserve_tokens"] || 16384,
      keep_recent_tokens: map["keepRecentTokens"] || map["keep_recent_tokens"] || 20000,

      # Retry settings
      retry_enabled: parse_boolean(map["retryEnabled"] || map["retry_enabled"], true),
      max_retries: map["maxRetries"] || map["max_retries"] || 3,
      base_delay_ms: map["baseDelayMs"] || map["base_delay_ms"] || 1000,

      # Shell settings
      shell_path: map["shellPath"] || map["shell_path"],
      command_prefix: map["commandPrefix"] || map["command_prefix"],

      # Tool settings
      auto_resize_images:
        parse_boolean(
          map["autoResizeImages"] || map["auto_resize_images"],
          true
        ),

      # Extension settings
      extension_paths: map["extensionPaths"] || map["extension_paths"] || [],

      # Display settings
      theme: map["theme"] || "default"
    }
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = settings) do
    %{
      # Model settings
      "defaultModel" => encode_model_config(settings.default_model),
      "provider" => settings.default_model && settings.default_model.provider,
      "model" => settings.default_model && settings.default_model.model_id,
      "defaultThinkingLevel" => encode_thinking_level(settings.default_thinking_level),
      "scopedModels" => Enum.map(settings.scoped_models, &encode_model_config/1),

      # Provider settings
      "providers" => encode_providers(settings.providers),

      # Compaction settings
      "compactionEnabled" => settings.compaction_enabled,
      "reserveTokens" => settings.reserve_tokens,
      "keepRecentTokens" => settings.keep_recent_tokens,

      # Retry settings
      "retryEnabled" => settings.retry_enabled,
      "maxRetries" => settings.max_retries,
      "baseDelayMs" => settings.base_delay_ms,

      # Shell settings
      "shellPath" => settings.shell_path,
      "commandPrefix" => settings.command_prefix,

      # Tool settings
      "autoResizeImages" => settings.auto_resize_images,

      # Extension settings
      "extensionPaths" => settings.extension_paths,

      # Display settings
      "theme" => settings.theme
    }
    |> reject_nil_values()
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp project_settings_file(cwd) do
    Path.join([Config.project_config_dir(cwd), "settings.json"])
  end

  defp maybe_override_base_url(nil, _base_url), do: nil

  defp maybe_override_base_url(config, base_url) when is_map(config) do
    current = Map.get(config, :base_url)

    if (is_nil(current) or current == "") and is_binary(base_url) and base_url != "" do
      Map.put(config, :base_url, base_url)
    else
      config
    end
  end

  defp maybe_override_base_url_from_provider(nil, _providers), do: nil

  defp maybe_override_base_url_from_provider(%{provider: provider} = config, providers)
       when is_binary(provider) do
    current = Map.get(config, :base_url)
    provider_cfg = Map.get(providers, provider)
    base_url = provider_cfg && Map.get(provider_cfg, :base_url)

    if (is_nil(current) or current == "") and is_binary(base_url) and base_url != "" do
      Map.put(config, :base_url, base_url)
    else
      config
    end
  end

  defp maybe_override_base_url_from_provider(config, _providers), do: config

  defp parse_providers(nil), do: %{}

  defp parse_providers(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      key = provider_key(k)
      cfg = parse_provider_config(v)

      if key && cfg do
        Map.put(acc, key, cfg)
      else
        acc
      end
    end)
  end

  defp parse_provider_config(nil), do: nil

  defp parse_provider_config(map) when is_map(map) do
    %{
      api_key: map["apiKey"] || map["api_key"],
      base_url: map["baseUrl"] || map["base_url"]
    }
    |> reject_nil_values()
  end

  defp parse_provider_config(_), do: nil

  defp encode_providers(providers) when is_map(providers) do
    providers
    |> Enum.map(fn {k, v} -> {k, encode_provider_config(v)} end)
    |> Map.new()
  end

  defp encode_provider_config(nil), do: %{}

  defp encode_provider_config(cfg) when is_map(cfg) do
    %{
      "apiKey" => Map.get(cfg, :api_key),
      "baseUrl" => Map.get(cfg, :base_url)
    }
    |> reject_nil_values()
  end

  defp provider_key(k) when is_atom(k), do: Atom.to_string(k)
  defp provider_key(k) when is_binary(k), do: k
  defp provider_key(_), do: nil

  defp merge_provider_configs(base, override) do
    Map.merge(base, override, fn _key, base_cfg, override_cfg ->
      Map.merge(base_cfg || %{}, override_cfg || %{})
    end)
  end

  defp parse_model_config(nil), do: nil

  defp parse_model_config(%{"provider" => provider} = map) do
    model_id = map["modelId"] || map["model_id"] || map["modelName"] || map["model_name"]
    base_url = map["baseUrl"] || map["base_url"]

    if is_binary(model_id) and model_id != "" do
      %{provider: provider, model_id: model_id, base_url: base_url}
    else
      nil
    end
  end

  defp parse_model_config(map) when is_map(map) do
    model_id = map["modelId"] || map["model_id"] || map["modelName"] || map["model_name"]
    base_url = map["baseUrl"] || map["base_url"]

    if is_binary(model_id) and model_id != "" do
      %{provider: nil, model_id: model_id, base_url: base_url}
    else
      nil
    end
  end

  defp parse_model_config(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        %{provider: provider, model_id: model_id, base_url: nil}

      [model_id] when model_id != "" ->
        %{provider: nil, model_id: model_id, base_url: nil}

      _ ->
        nil
    end
  end

  defp parse_model_config(_), do: nil

  defp encode_model_config(nil), do: nil

  defp encode_model_config(%{model_id: model_id} = config) do
    %{
      "provider" => Map.get(config, :provider),
      "modelId" => model_id,
      "baseUrl" => Map.get(config, :base_url)
    }
    |> reject_nil_values()
  end

  defp parse_scoped_models(nil), do: []
  defp parse_scoped_models(models) when is_list(models) do
    models
    |> Enum.map(&parse_model_config/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_scoped_models(_), do: []

  defp parse_thinking_level(nil), do: :off
  defp parse_thinking_level("off"), do: :off
  defp parse_thinking_level("minimal"), do: :minimal
  defp parse_thinking_level("low"), do: :low
  defp parse_thinking_level("medium"), do: :medium
  defp parse_thinking_level("high"), do: :high
  defp parse_thinking_level("xhigh"), do: :xhigh
  defp parse_thinking_level(level) when is_atom(level), do: level
  defp parse_thinking_level(_), do: :off

  defp encode_thinking_level(:off), do: "off"
  defp encode_thinking_level(:minimal), do: "minimal"
  defp encode_thinking_level(:low), do: "low"
  defp encode_thinking_level(:medium), do: "medium"
  defp encode_thinking_level(:high), do: "high"
  defp encode_thinking_level(:xhigh), do: "xhigh"
  defp encode_thinking_level(_), do: "off"

  defp parse_boolean(nil, default), do: default
  defp parse_boolean(true, _default), do: true
  defp parse_boolean(false, _default), do: false
  defp parse_boolean("true", _default), do: true
  defp parse_boolean("false", _default), do: false
  defp parse_boolean(_, default), do: default

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
