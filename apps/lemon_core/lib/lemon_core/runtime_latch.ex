defmodule LemonCore.RuntimeLatch do
  @moduledoc """
  Runtime-wide fail-stop latch.

  Once tripped (for example by an extension module collision in
  `CodingAgent.Extensions`), the runtime stops trusting code it loaded:
  `LemonAgent.Loop` refuses every tool call, coding sessions abort and refuse
  to start, and subscribers (such as background reviews) cancel their work.

  The trip state is a boot-sticky `:persistent_term` key, written at most once
  per VM and never cleared: it survives a restart of this process and clears
  only when the runtime restarts. `tripped?/0` reads only that key. This
  supervised process only delivers `{:runtime_latch_tripped, reason}` to
  subscribers. A subscriber should monitor the pid `subscribe/0` returns and
  re-subscribe when it restarts; `subscribe/0` notifies immediately when the
  latch is already tripped, so nothing tripped during the gap is missed.
  """

  use GenServer

  require Logger

  @key {__MODULE__, :tripped}

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Whether the latch is tripped."
  @spec tripped?() :: boolean()
  def tripped?, do: :persistent_term.get(@key, nil) != nil

  @doc "The reason the latch was tripped, or `nil`."
  @spec reason() :: term()
  def reason, do: :persistent_term.get(@key, nil)

  @doc """
  Trip the latch. The first reason is kept; later trips only re-notify
  subscribers. Works even while this process is restarting.
  """
  @spec trip(term()) :: :ok
  def trip(reason) do
    # An aborted lock still trips: losing first-reason ordering beats failing open.
    with :aborted <- :global.trans({@key, self()}, fn -> record_trip(reason) end, [node()], 5),
         do: record_trip(reason)

    GenServer.cast(__MODULE__, :notify)
  end

  # Rare one-shot fail-stop write: at most once per VM, serialized above.
  defp record_trip(reason) do
    if :persistent_term.get(@key, nil) == nil do
      :persistent_term.put(@key, reason)
      Logger.error("Runtime latch tripped: #{inspect(reason)}; restart the runtime")
    end

    :ok
  end

  @doc """
  Subscribe the calling process to trips and return the latch pid to monitor.
  A process that subscribes after the latch tripped is notified immediately.
  """
  @spec subscribe() :: {:ok, pid()}
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @impl true
  def init(_opts), do: {:ok, %{subscribers: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid),
        do: state,
        else: put_in(state.subscribers[pid], Process.monitor(pid))

    if tripped?(), do: send(pid, {:runtime_latch_tripped, reason()})
    {:reply, {:ok, self()}, state}
  end

  @impl true
  def handle_cast(:notify, state) do
    Enum.each(Map.keys(state.subscribers), &send(&1, {:runtime_latch_tripped, reason()}))
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
end
