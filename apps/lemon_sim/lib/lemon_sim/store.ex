defmodule LemonSim.Store do
  @moduledoc """
  Persistence helpers for simulation state.
  """

  alias LemonSim.State

  @state_table :lemon_sim_world_states

  @doc """
  Persists state by `sim_id`.
  """
  @spec put_state(State.t()) :: :ok | {:error, term()}
  def put_state(%State{sim_id: sim_id} = state) when is_binary(sim_id) do
    LemonCore.Store.put(@state_table, sim_id, state)
  end

  @doc """
  Loads state for `sim_id`.
  """
  @spec get_state(String.t()) :: State.t() | nil
  def get_state(sim_id) when is_binary(sim_id) do
    @state_table
    |> LemonCore.Store.get(sim_id)
    |> normalize_state()
  end

  @doc """
  Deletes persisted state for `sim_id`.
  """
  @spec delete_state(String.t()) :: :ok | {:error, term()}
  def delete_state(sim_id) when is_binary(sim_id) do
    LemonCore.Store.delete(@state_table, sim_id)
  end

  @doc """
  Lists all persisted simulation states.
  """
  @spec list_states() :: [State.t()]
  def list_states do
    @state_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_key, value} -> normalize_state(value) end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_state(%State{} = state), do: state
  defp normalize_state(%{} = map), do: State.new(map)
  defp normalize_state(_), do: nil
end
