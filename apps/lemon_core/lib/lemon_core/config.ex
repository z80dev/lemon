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

  alias LemonCore.Config.{Features, Memory, Modular, Validator}

  defstruct providers: %{},
            model_roles: %{},
            budgets: %{},
            model_routing: %{},
            agent: %{},
            tui: %{},
            logging: %{},
            gateway: %{},
            agents: %{},
            memory: %{auto_recall: true, write_approval: false},
            skills: %{write_approval: false},
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
          model_roles: %{optional(String.t()) => String.t()},
          budgets: map(),
          model_routing: map(),
          agent: map(),
          tui: map(),
          logging: map(),
          gateway: map(),
          agents: map(),
          memory: %{auto_recall: boolean(), write_approval: boolean()},
          skills: %{write_approval: boolean()},
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
    modular = Modular.load(project_dir: project_dir)

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

        {:error, {:invalid_toml, reason}} ->
          raise LemonCore.Config.ValidationError,
            message:
              "#{expanded}: cannot load TOML: #{reason}. Run `lemon config validate --verbose` after fixing the file.",
            errors: []

        {:error, reason} ->
          detail = if is_atom(reason), do: :file.format_error(reason), else: reason

          raise LemonCore.Config.ValidationError,
            message:
              "#{expanded}: cannot load configuration: #{detail}. Run `lemon config validate --verbose` after fixing the file.",
            errors: []
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
      model_roles: config.model_roles,
      budgets: config.budgets,
      model_routing: config.model_routing,
      agent: config.agent,
      tui: config.tui,
      logging: config.logging,
      gateway: config.gateway,
      agents: config.agents,
      memory: config.memory,
      skills: config.skills,
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
      model_roles: modular.model_roles,
      budgets: modular.budgets,
      model_routing: modular.model_routing,
      agent: convert_agent(modular.agent, modular.tools),
      tui: convert_tui(modular.tui),
      logging: convert_logging(modular.logging),
      gateway: convert_gateway(modular.gateway),
      agents: convert_agents(profiles, defaults),
      memory: convert_memory(modular.memory, modular.features),
      skills: modular.skills,
      secrets: modular.secrets
    }
  end

  # `auto_recall` here is the effective switch hot paths read per turn: it is
  # off when `[memory] auto_recall = false` *or* when durable memory itself is
  # killed (`[features] session_search = "off"`), since the kill switch promises
  # that memory search is inactive.
  defp convert_memory(memory, features) do
    %{
      write_approval: memory.write_approval,
      auto_recall:
        Memory.auto_recall?(memory) and
          Features.enabled?(features, :session_search)
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
      approval_mode: tools.approval_mode,
      edit: tools.edit,
      bash: tools.bash,
      lsp: tools.lsp,
      intent_tracing: tools.intent_tracing,
      web: tools.web,
      wasm: tools.wasm,
      disclosure: tools.disclosure,
      checkpoint: tools.checkpoint,
      semantic_find: tools.semantic_find,
      browser: tools.browser,
      computer_use: tools.computer_use
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

    tool_policy =
      case Map.fetch(cfg, "tool_policy_json") do
        {:ok, json} when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, nil} -> LemonCore.ToolPolicy.deny_all()
            {:ok, policy} -> parse_tool_policy(policy)
            {:error, _reason} -> LemonCore.ToolPolicy.deny_all()
          end

        {:ok, _invalid} ->
          LemonCore.ToolPolicy.deny_all()

        :error ->
          parse_tool_policy(cfg["tool_policy"])
      end

    base
    |> Map.put(:name, cfg["name"] || base.name || id)
    |> Map.put(:description, cfg["description"])
    |> Map.put(:avatar, cfg["avatar"])
    |> Map.put(:model, cfg["model"] || base.model)
    |> Map.put(:system_prompt, cfg["system_prompt"])
    |> Map.put(:tool_policy, tool_policy)
    |> Map.put(:rate_limit, cfg["rate_limit"])
    |> Map.put(:node, cfg["node"])
    |> Map.put(:status, cfg["status"] || base.status)
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

  @doc false
  def parse_tool_policy(nil), do: nil

  def parse_tool_policy(policy) do
    case LemonCore.ToolPolicy.parse(policy) do
      {:ok, validated} -> validated
      {:error, _reason} -> LemonCore.ToolPolicy.deny_all()
    end
  end

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

    budgets =
      config.budgets
      |> deep_merge_values(overrides["budgets"])
      |> Modular.resolve_budgets()

    case Validator.validate_budgets(budgets) do
      :ok ->
        :ok

      {:error, errors} ->
        raise LemonCore.Config.ValidationError, message: "Invalid budgets", errors: errors
    end

    %__MODULE__{
      providers: deep_merge_values(config.providers, overrides["providers"]),
      model_roles: merge_model_roles(config.model_roles, overrides["model_roles"]),
      budgets: budgets,
      model_routing: deep_merge_values(config.model_routing, overrides["model_routing"]),
      agent: deep_merge_values(config.agent, overrides["agent"]),
      tui: deep_merge_values(config.tui, overrides["tui"]),
      logging: deep_merge_values(config.logging, overrides["logging"]),
      gateway: deep_merge_values(config.gateway, overrides["gateway"]),
      agents: deep_merge_values(config.agents, overrides["agents"]),
      memory: deep_merge_values(config.memory, overrides["memory"]),
      skills: deep_merge_values(config.skills, overrides["skills"]),
      secrets: config.secrets
    }
  end

  # Role names are metadata strings, not atom-keyed config fields.
  defp merge_model_roles(base, nil), do: base

  defp merge_model_roles(base, override) when is_map(base) and is_map(override),
    do: Map.merge(base, override)

  defp merge_model_roles(_base, override), do: override

  # Deep merge a value into existing config, handling nil override gracefully
  defp deep_merge_values(base, nil), do: base

  defp deep_merge_values(base, override) when is_map(base) and is_map(override) do
    LemonCore.MapHelpers.deep_merge(base, atomize_keys(override))
  end

  defp deep_merge_values(_base, override), do: override

  # Only reuse existing atoms; arbitrary override keys remain strings.
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {existing_atom_or_string(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(value), do: value

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

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
  defp parse_thinking_level("auto"), do: :auto
  defp parse_thinking_level(level) when is_atom(level), do: level
  defp parse_thinking_level(level), do: level

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
