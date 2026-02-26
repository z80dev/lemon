defmodule LemonRouter.AgentProfiles do
  @moduledoc """
  Agent profile configuration management.

  Loads and manages agent configurations including:
  - Default engine
  - Tool policies
  - System prompts
  - Rate limits
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get an agent profile by ID.
  """
  @spec get(agent_id :: binary()) :: map() | nil
  def get(agent_id) do
    GenServer.call(__MODULE__, {:get, agent_id})
  end

  @doc """
  Check whether an agent profile key exists.
  """
  @spec exists?(agent_id :: binary()) :: boolean()
  def exists?(agent_id) do
    GenServer.call(__MODULE__, {:exists, agent_id})
  end

  @doc """
  List all agent profiles.
  """
  @spec list() :: [map()]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Reload agent profiles from configuration.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  @impl true
  def init(opts) do
    profiles = load_profiles(:cached, opts)
    {:ok, %{profiles: profiles, opts: opts}}
  end

  @impl true
  def handle_call({:get, agent_id}, _from, state) do
    profile = Map.get(state.profiles, agent_id, default_profile())
    {:reply, profile, state}
  end

  def handle_call({:exists, agent_id}, _from, state) do
    {:reply, Map.has_key?(state.profiles, agent_id), state}
  end

  def handle_call(:list, _from, state) do
    profiles = Map.values(state.profiles)
    {:reply, profiles, state}
  end

  @impl true
  def handle_cast(:reload, state) do
    profiles = load_profiles(:reload, state.opts)
    {:noreply, %{state | profiles: profiles}}
  end

  defp load_profiles(mode, opts) do
    cwd = resolve_config_cwd(opts)

    # Use canonical TOML config (global + project) for agent profiles.
    # Project-local config is resolved from `cwd` and overrides global config.
    cfg =
      case mode do
        :reload -> LemonCore.Config.reload(cwd)
        _ -> LemonCore.Config.cached(cwd)
      end

    profiles = cfg.agents || %{}

    # Normalize to map keyed by agent_id with atom keys for internal use.
    profiles =
      profiles
      |> Enum.map(fn {id, p} ->
        {to_string(id), normalize_profile(id, p)}
      end)
      |> Map.new()

    if map_size(profiles) == 0 do
      %{"default" => default_profile()}
    else
      Map.put_new(profiles, "default", default_profile())
    end
  end

  defp resolve_config_cwd(opts) when is_list(opts) do
    case opts[:cwd] ||
           Application.get_env(:lemon_router, :agent_profiles_cwd) ||
           System.get_env("LEMON_AGENT_PROFILES_CWD") do
      cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
      _ -> File.cwd!()
    end
  end

  defp default_profile do
    %{
      id: "default",
      name: "Default Agent",
      description: nil,
      avatar: nil,
      default_engine: "lemon",
      tool_policy: nil,
      system_prompt: nil,
      model: nil,
      rate_limit: nil
    }
  end

  defp normalize_profile(id, profile) when is_map(profile) do
    %{
      id: profile[:id] || profile["id"] || to_string(id),
      name: profile[:name] || profile["name"] || to_string(id),
      description: profile[:description] || profile["description"],
      avatar: profile[:avatar] || profile["avatar"],
      default_engine:
        profile[:default_engine] || profile["default_engine"] ||
          profile[:engine] || profile["engine"] || "lemon",
      tool_policy: profile[:tool_policy] || profile["tool_policy"],
      system_prompt: profile[:system_prompt] || profile["system_prompt"],
      model: profile[:model] || profile["model"],
      rate_limit: profile[:rate_limit] || profile["rate_limit"]
    }
  end

  defp normalize_profile(_id, _), do: default_profile()
end
