defmodule CodingAgent.ExecutionNode.ToolSession do
  @moduledoc """
  Destination-side owner for one controller session's routed tool calls.

  Routed calls (`coding_agent.tool`) are short-lived tasks, but the tools they
  run keep per-session state: shell working directory and environment,
  background processes, `eval` kernels and the read tracker used by `edit`.
  Those resources bind to this process as their session owner, so they
  survive between calls and die together when the session goes idle.

  A session stays alive while any call holds it and for `idle_ms` (default 30
  minutes) after the last call returns. Expiry stops the process, which ends
  every resource bound to it.
  """

  use GenServer

  @registry CodingAgent.ExecutionNode.ToolSession.Registry
  @supervisor CodingAgent.ExecutionNode.ToolSession.Supervisor
  @default_idle_ms 30 * 60 * 1000

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :session_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, session_id}})
  end

  @doc """
  Returns the owner for `session_id`, starting it if needed, and holds it for
  the calling process until `release/1` or the caller exits.
  """
  @spec acquire(String.t(), keyword()) :: {:ok, pid()} | {:error, :tool_session_unavailable}
  def acquire(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, pid} <- ensure(session_id, opts),
         :ok <- GenServer.call(pid, {:acquire, self()}) do
      {:ok, pid}
    else
      _ -> {:error, :tool_session_unavailable}
    end
  catch
    :exit, _ -> {:error, :tool_session_unavailable}
  end

  @doc "Releases the calling process's hold on `pid`."
  @spec release(pid()) :: :ok
  def release(pid) when is_pid(pid) do
    GenServer.cast(pid, {:release, self()})
  end

  defp ensure(session_id, opts) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, Keyword.put(opts, :session_id, session_id)}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _} = error -> error
        end
    end
  end

  @impl true
  def init(opts) do
    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      holders: %{},
      timer: nil
    }

    {:ok, arm(state)}
  end

  @impl true
  def handle_call({:acquire, pid}, _from, state) do
    state = cancel(state)
    holders = Map.put_new_lazy(state.holders, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | holders: holders}}
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, drop(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, drop(state, pid)}

  def handle_info({:idle, timer}, %{timer: timer, holders: holders} = state)
      when map_size(holders) == 0,
      do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp drop(state, pid) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        state

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        state = %{state | holders: holders}
        if map_size(holders) == 0, do: arm(state), else: state
    end
  end

  defp arm(state) do
    state = cancel(state)
    timer = make_ref()
    Process.send_after(self(), {:idle, timer}, state.idle_ms)
    %{state | timer: timer}
  end

  defp cancel(state), do: %{state | timer: nil}
end
