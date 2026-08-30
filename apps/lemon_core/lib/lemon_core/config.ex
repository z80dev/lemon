defmodule LemonCore.Config do
  @moduledoc """
  Canonical Lemon configuration loader.

  Loads TOML configuration from:
  - Global: `~/.lemon/config.toml`
  - Project: `<project>/.lemon/config.toml`

  Both locations are configurable; see `LemonCore.Paths`.

  Project values override global values. Environment variables override both.

  Configuration is delegated to `LemonCore.Config.Modular` which enforces
  the canonical config schema and rejects deprecated sections (`[agent]`,
  `[agents]`, `[agent.tools]`).
  """

  require Logger

  defstruct providers: %{},
            agent: %{},
            tui: %{},
            logging: %{},
            gateway: %{},
            agents: %{},
            secrets: %LemonCore.Config.Secrets{}

  @type provider_config :: %{
          optional(:api_key) => String.t() | nil,
          optional(:base_url) => String.t() | nil,
          optional(:api_key_secret) => String.t() | nil,
          optional(:auth_source) => String.t() | nil,
          optional(:oauth_secret) => String.t() | nil,
          optional(:project) => String.t() | nil,
          optional(:project_id) => String.t() | nil,
          optional(:project_secret) => String.t() | nil
        }
  @type t :: %__MODULE__{
          providers: %{optional(String.t()) => provider_config()},
          agent: map(),
          tui: map(),
          logging: map(),
          gateway: map(),
          agents: map(),
          secrets: LemonCore.Config.Secrets.t()
        }

  @doc """
  Path to global config file.
  """
  @spec global_path() :: String.t()
  def global_path, do: LemonCore.Paths.global_config()

  @doc """
  Path to project config file for a given cwd.
  """
  @spec project_path(String.t()) :: String.t()
  def project_path(cwd), do: LemonCore.Paths.project_config(cwd)

  @doc """
  Load merged config (global + project) with environment overrides.
  """
  @spec load(String.t() | nil, keyword()) :: t()
  def load(cwd \\ nil, opts \\ []) do
    cached(cwd, opts)
  end

  @doc """
  Load config using the supervised cache when available.

  This is the default hot-path read. It avoids re-reading/parsing TOML on every call.
  """
  @spec cached(String.t() | nil, keyword()) :: t()
  def cached(cwd \\ nil, opts \\ []) do
    base =
      if Keyword.get(opts, :cache, true) and Code.ensure_loaded?(LemonCore.ConfigCache) and
           function_exported?(LemonCore.ConfigCache, :available?, 0) and
           LemonCore.ConfigCache.available?() do
        LemonCore.ConfigCache.get(cwd, opts)
      else
        load_base_from_disk(cwd)
      end

    apply_overrides(base, Keyword.get(opts, :overrides))
  end

  @doc """
  Force a reload from disk (and update the cache when available).

  Use this for explicit reload flows (e.g. admin reload, control plane refresh).
  """
  @spec reload(String.t() | nil, keyword()) :: t()
  def reload(cwd \\ nil, opts \\ []) do
    base =
      if Code.ensure_loaded?(LemonCore.ConfigCache) and
           function_exported?(LemonCore.ConfigCache, :available?, 0) and
           LemonCore.ConfigCache.available?() do
        LemonCore.ConfigCache.reload(cwd, opts)
      else
        load_base_from_disk(cwd)
      end

    apply_overrides(base, Keyword.get(opts, :overrides))
  end

  @doc false
  @spec load_base_from_disk(String.t() | nil) :: t()
  def load_base_from_disk(cwd \\ nil) do
    project_dir = if is_binary(cwd) and cwd != "", do: cwd, else: File.cwd!()

    # Use Modular for the main config (this enforces deprecated section checks
    # and applies environment variable overrides during resolution).
    modular = LemonCore.Config.Modular.load(project_dir: project_dir)

    # Also load raw settings for profiles/agents (not in Modular struct)
    raw = load_raw_settings(project_dir)
    profiles = raw["profiles"] || %{}
    defaults = raw["defaults"] || %{}

    from_modular(modular, profiles, defaults)
  end

  @doc """
  Load a single TOML file without environment overrides.
  """
  @spec load_file(String.t()) :: map()
  def load_file(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      case Toml.decode_file(expanded) do
        {:ok, map} ->
          stringify_keys(map)

        {:error, reason} ->
          Logger.warning("Failed to parse config TOML at #{expanded}: #{inspect(reason)}")
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Get a nested config value.
  """
  @spec get(t(), [atom()] | atom(), term()) :: term()
  def get(%__MODULE__{} = config, key, default \\ nil) do
    get_in_config(to_map(config), key, default)
  end

  @doc """
  Return config as a plain map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      providers: config.providers,
      agent: config.agent,
      tui: config.tui,
      logging: config.logging,
      gateway: config.gateway,
      agents: config.agents,
      secrets: secrets_to_map(config.secrets)
    }
  end

  # ============================================================================
  # Modular -> Legacy conversion
  # ============================================================================

  # Converts a Modular config struct into a legacy Config struct.
  # `profiles` and `defaults` are raw TOML maps for building the agents field.
  defp from_modular(modular, profiles, defaults) do
    %__MODULE__{
      providers: convert_providers(modular.providers),
      agent: convert_agent(modular.agent, modular.tools),
      tui: convert_tui(modular.tui),
      logging: convert_logging(modular.logging),
      gateway: convert_gateway(modular.gateway),
      agents: convert_agents(profiles, defaults),
      secrets: modular.secrets
    }
  end

  defp convert_providers(%LemonCore.Config.Providers{providers: providers}) do
    providers
  end

  defp convert_agent(agent, tools) do
    agent_map = Map.from_struct(agent)

    # Convert thinking_level string to atom
    agent_map =
      Map.update(agent_map, :default_thinking_level, :medium, &parse_thinking_level/1)

    # Nest tools into agent (legacy shape: agent.tools.*)
    tools_map = convert_tools(tools)
    Map.put(agent_map, :tools, tools_map)
  end

  defp convert_tools(tools) do
    %{
      auto_resize_images: tools.auto_resize_images,
      web: tools.web,
      wasm: tools.wasm,
      execute_code: tools.execute_code,
      disclosure: tools.disclosure
    }
  end

  defp convert_tui(tui) do
    Map.from_struct(tui)
  end

  defp convert_logging(logging) do
    logging
    |> Map.from_struct()
    |> reject_nil_values()
  end

  # The modular Gateway keeps the per-platform sections in `channels` and their
  # flags in `enabled_channels` so the library never names a chat platform. The
  # legacy map keeps the flat shape every reader expects: `gateway[:foo]` and
  # `gateway[:enable_foo]`.
  defp convert_gateway(gateway) do
    map = Map.from_struct(gateway)
    {channels, map} = Map.pop(map, :channels, %{})
    {enabled, map} = Map.pop(map, :enabled_channels, %{})

    map
    |> Map.merge(channels)
    |> Map.merge(Map.new(enabled, fn {id, value} -> {:"enable_#{id}", value} end))
  end

  defp convert_agents(profiles, defaults) when is_map(profiles) do
    defaults = parse_defaults(defaults)

    profiles
    |> stringify_keys()
    |> Enum.reduce(%{}, fn {id, cfg}, acc ->
      parsed = parse_agent_profile(to_string(id), cfg, defaults)
      Map.put(acc, to_string(id), parsed)
    end)
    |> ensure_default_agent(defaults)
  end

  defp convert_agents(_, defaults) do
    ensure_default_agent(%{}, parse_defaults(defaults))
  end

  # ============================================================================
  # Profile / Agent parsing (kept for agents field)
  # ============================================================================

  defp parse_defaults(map) when is_map(map) do
    map = stringify_keys(map)

    %{
      "provider" => normalize_optional_string(map["provider"]),
      "model" => normalize_optional_string(map["model"]),
      "thinking_level" => normalize_optional_string(map["thinking_level"])
    }
    |> reject_nil_values()
  end

  defp parse_defaults(_), do: %{}

  defp ensure_default_agent(agents, defaults) when is_map(agents) do
    if Map.has_key?(agents, "default") do
      agents
    else
      Map.put(agents, "default", default_agent_profile("default", %{}, defaults))
    end
  end

  defp parse_agent_profile(id, cfg, defaults) do
    cfg = stringify_keys(cfg || %{})

    base = default_agent_profile(id, cfg, defaults)

    tool_policy = parse_tool_policy(cfg["tool_policy"])

    base
    |> Map.put(:name, cfg["name"] || base.name || id)
    |> Map.put(:description, cfg["description"])
    |> Map.put(:avatar, cfg["avatar"])
    |> Map.put(:model, cfg["model"] || base.model)
    |> Map.put(:system_prompt, cfg["system_prompt"])
    |> Map.put(:tool_policy, tool_policy)
    |> Map.put(:rate_limit, cfg["rate_limit"])
    |> Map.put(:status, cfg["status"] || base.status || "active")
  end

  defp default_agent_profile(id, _cfg, defaults) do
    name =
      if id == "default" do
        "Default Agent"
      else
        id
      end

    default_model = if id == "default", do: defaults["model"], else: nil

    %{
      id: id,
      name: name,
      description: nil,
      avatar: nil,
      model: default_model,
      system_prompt: nil,
      tool_policy: nil,
      rate_limit: nil,
      status: "active"
    }
  end

  defp parse_tool_policy(nil), do: nil

  defp parse_tool_policy(map) when is_map(map) do
    map = stringify_keys(map)

    allow =
      case map["allow"] do
        "all" -> :all
        :all -> :all
        list when is_list(list) -> Enum.map(list, &to_string/1)
        other when is_binary(other) -> [other]
        _ -> :all
      end

    deny =
      case map["deny"] do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        other when is_binary(other) -> [other]
        _ -> []
      end

    require_approval =
      case map["require_approval"] do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        other when is_binary(other) -> [other]
        _ -> []
      end

    approvals =
      case map["approvals"] do
        approvals when is_map(approvals) ->
          approvals
          |> stringify_keys()
          |> Enum.reduce(%{}, fn {tool_name, mode}, acc ->
            mode =
              case mode do
                :always -> :always
                "always" -> :always
                true -> :always
                :never -> :never
                "never" -> :never
                false -> :never
                _ -> nil
              end

            if mode do
              Map.put(acc, tool_name, mode)
            else
              acc
            end
          end)

        _ ->
          %{}
      end

    profile =
      case map["profile"] do
        "full_access" -> :full_access
        "minimal_core" -> :minimal_core
        "read_only" -> :read_only
        "safe_mode" -> :safe_mode
        "subagent_restricted" -> :subagent_restricted
        "no_external" -> :no_external
        "custom" -> :custom
        _ -> nil
      end

    %{
      allow: allow,
      deny: deny,
      require_approval: require_approval,
      approvals: approvals,
      no_reply: parse_boolean(map["no_reply"], false),
      profile: profile
    }
  end

  defp parse_tool_policy(_), do: nil

  # ============================================================================
  # Raw settings loader (for profiles that Modular doesn't expose)
  # ============================================================================

  defp load_raw_settings(project_dir) do
    global = load_file(global_path())

    project =
      if is_binary(project_dir) and project_dir != "" do
        load_file(project_path(project_dir))
      else
        %{}
      end

    LemonCore.MapHelpers.deep_merge(global, project)
  end

  # ============================================================================
  # Overrides
  # ============================================================================

  defp apply_overrides(config, nil), do: config

  defp apply_overrides(%__MODULE__{} = config, overrides) when is_map(overrides) do
    overrides = stringify_keys(overrides)

    %__MODULE__{
      providers: deep_merge_values(config.providers, overrides["providers"]),
      agent: deep_merge_values(config.agent, overrides["agent"]),
      tui: deep_merge_values(config.tui, overrides["tui"]),
      logging: deep_merge_values(config.logging, overrides["logging"]),
      gateway: deep_merge_values(config.gateway, overrides["gateway"]),
      agents: deep_merge_values(config.agents, overrides["agents"]),
      secrets: config.secrets
    }
  end

  # Deep merge a value into existing config, handling nil override gracefully
  defp deep_merge_values(base, nil), do: base

  defp deep_merge_values(base, override) when is_map(base) and is_map(override) do
    LemonCore.MapHelpers.deep_merge(base, atomize_keys(override))
  end

  defp deep_merge_values(_base, override), do: override

  # Convert string keys to atoms for merging into atom-keyed config maps
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(value), do: value

  # ============================================================================
  # Helpers
  # ============================================================================

  defp secrets_to_map(%LemonCore.Config.Secrets{} = secrets) do
    secrets
    |> Map.from_struct()
    |> Map.update!(:sources, fn sources ->
      Enum.map(sources, fn
        %LemonCore.Config.Secrets.Source{} = source -> Map.from_struct(source)
        source -> source
      end)
    end)
  end

  defp secrets_to_map(secrets), do: secrets

  defp parse_thinking_level(nil), do: :medium
  defp parse_thinking_level("off"), do: :off
  defp parse_thinking_level("minimal"), do: :minimal
  defp parse_thinking_level("low"), do: :low
  defp parse_thinking_level("medium"), do: :medium
  defp parse_thinking_level("high"), do: :high
  defp parse_thinking_level("xhigh"), do: :xhigh
  defp parse_thinking_level(level) when is_atom(level), do: level
  defp parse_thinking_level(_), do: :medium

  defp parse_boolean(nil, default), do: default
  defp parse_boolean(true, _default), do: true
  defp parse_boolean(false, _default), do: false
  defp parse_boolean("true", _default), do: true
  defp parse_boolean("false", _default), do: false
  defp parse_boolean("1", _default), do: true
  defp parse_boolean("0", _default), do: false
  defp parse_boolean(_, default), do: default

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp stringify_keys(value), do: LemonCore.MapHelpers.stringify_keys(value)

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp get_in_config(map, key, default) when is_atom(key) do
    Map.get(map, key, default)
  end

  defp get_in_config(map, [key], default), do: get_in_config(map, key, default)

  defp get_in_config(map, [key | rest], default) when is_map(map) do
    case Map.get(map, key) do
      nil -> default
      nested -> get_in_config(nested, rest, default)
    end
  end
end
