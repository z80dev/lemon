defmodule LemonAgent.ModelRuntime.SessionPins do
  @moduledoc """
  Best-effort per-session pinning of a committed fallback candidate.

  When a session's turn commits on a non-primary provider and/or credential,
  the fallback executor pins `{provider, credential_ref}` for that session so
  later turns lead with the candidate that actually worked - provider prompt
  caches are keyed per provider+credential, so bouncing back to a failing
  primary (or a different credential) every turn destroys cache hit rates.

  Pins are advisory ordering hints, never gates: a missing table or a `nil` /
  `:global` scope simply means no pin. State lives in a public named ETS table
  owned by this process (same pattern as `LemonAgent.AbortSignal.TableOwner`).

  Pins deliberately outlive the session process (they are keyed by the
  persisted session id so resumed sessions keep their stickiness), so nothing
  clears them at session termination. To keep the table bounded in
  long-running daemons that churn through many sessions, the owning process
  sweeps out pins older than 7 days (the timestamp refreshes on every
  `pin/3`) once an hour.
  """

  use GenServer

  @table :lemon_agent_session_pins
  @sweep_interval_ms 60 * 60 * 1000
  @pin_ttl_ms 7 * 24 * 60 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Pin `{provider, credential_ref}` for a session scope, replacing any
  existing pin. No-op for `nil`/`:global` scopes.
  """
  @spec pin(term(), String.t(), String.t() | nil) :: :ok
  def pin(session_scope, provider, credential_ref)

  def pin(session_scope, _provider, _credential_ref) when session_scope in [nil, :global], do: :ok

  def pin(session_scope, provider, credential_ref) when is_binary(provider) do
    :ets.insert(
      @table,
      {session_scope, %{provider: provider, credential_ref: credential_ref},
       System.system_time(:millisecond)}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  def pin(_session_scope, _provider, _credential_ref), do: :ok

  @spec get(term()) :: %{provider: String.t(), credential_ref: String.t() | nil} | nil
  def get(session_scope) when session_scope in [nil, :global], do: nil

  def get(session_scope) do
    case :ets.lookup(@table, session_scope) do
      [{^session_scope, pin, _inserted_at_ms}] -> pin
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec clear(term()) :: :ok
  def clear(session_scope) when session_scope in [nil, :global], do: :ok

  def clear(session_scope) do
    :ets.delete(@table, session_scope)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Drop all pins. Intended for tests.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Delete pins older than the TTL. Runs periodically in the owning process;
  exposed for tests.
  """
  @spec sweep(non_neg_integer()) :: non_neg_integer()
  def sweep(ttl_ms \\ @pin_ttl_ms) do
    cutoff = System.system_time(:millisecond) - ttl_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  rescue
    ArgumentError -> 0
  end

  @impl true
  def init(:ok) do
    ensure_table()
    schedule_sweep()
    {:ok, %{}}
  end

  # If another process created the table with this process as heir, ETS sends
  # this message when the original owner exits.
  @impl true
  def handle_info({:"ETS-TRANSFER", @table, _from, _gift_data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _ = sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
