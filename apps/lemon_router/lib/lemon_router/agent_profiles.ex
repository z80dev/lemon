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
  def init(_opts) do
    profiles = load_profiles()
    {:ok, %{profiles: profiles}}
  end

  @impl true
  def handle_call({:get, agent_id}, _from, state) do
    profile = Map.get(state.profiles, agent_id, default_profile())
    {:reply, profile, state}
  end

  def handle_call(:list, _from, state) do
    profiles = Map.values(state.profiles)
    {:reply, profiles, state}
  end

  @impl true
  def handle_cast(:reload, state) do
    profiles = load_profiles()
    {:noreply, %{state | profiles: profiles}}
  end

  defp load_profiles do
    # TODO: Load from config file or store
    %{
      "default" => default_profile()
    }
  end

  defp default_profile do
    %{
      id: "default",
      name: "Default Agent",
      engine: "lemon",
      tool_policy: %{},
      system_prompt: nil,
      rate_limit: nil
    }
  end
end
