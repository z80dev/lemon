defmodule LemonRouter.SessionReadModel do
  @moduledoc """
  Coordinator-owned read model for active session state.

  `SessionRegistry` remains the storage mechanism, but callers outside the
  coordinator must treat it as an internal read model exposed through this API.
  """

  @registry_select_spec [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]

  @spec busy?(binary()) :: boolean()
  def busy?(session_key) when is_binary(session_key) and session_key != "" do
    active_run(session_key) != :none
  end

  def busy?(_), do: false

  @spec active_run(binary()) :: {:ok, binary()} | :none
  def active_run(session_key) when is_binary(session_key) and session_key != "" do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{_pid, meta} | _] ->
        case Map.get(meta, :run_id) do
          run_id when is_binary(run_id) and run_id != "" -> {:ok, run_id}
          _ -> :none
        end

      _ ->
        :none
    end
  rescue
    _ -> :none
  end

  def active_run(_), do: :none

  @spec list_active() :: list()
  def list_active do
    Registry.select(LemonRouter.SessionRegistry, @registry_select_spec)
  rescue
    _ -> []
  end
end
