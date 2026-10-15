defmodule LemonOmp.Manager do
  @moduledoc """
  Admission control and the snapshot table for omp sessions.

  The manager serializes starts so the live-process cap holds under concurrent
  requests, monitors every `LemonOmp.Session`, and owns a public ETS table of
  the latest published wire snapshot per invocation id. Reads (`list`, `get`)
  come from that table and never block on a busy session process. Ended
  sessions stay listed (bounded) so their result and outcome remain visible;
  they are in-memory only — after a Lemon restart, `LemonOmp.discover/2` finds
  them on disk and `LemonOmp.start/2` with `resume` reopens them.

  A session that dies without publishing its own exit (a crash of the Elixir
  process itself) is marked failed here, so no snapshot claims to be running
  after its owner is gone.
  """

  use GenServer

  alias LemonCore.{Bus, Event}

  @table :lemon_omp_sessions
  @topic "omp"
  @max_ended 50

  @spec bus_topic() :: String.t()
  def bus_topic, do: @topic

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Start a session process if under the live cap."
  @spec start_session(keyword(), pos_integer()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts, max_live) do
    GenServer.call(__MODULE__, {:start_session, opts, max_live}, 15_000)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Record and broadcast a session snapshot. Called by the session process."
  @spec publish(pid(), map(), String.t()) :: :ok
  def publish(pid, %{"id" => id} = wire, reason) do
    if table?(), do: :ets.insert(@table, {id, pid, wire})

    if Bus.running?() do
      Bus.broadcast(@topic, Event.new(:omp_session, %{"reason" => reason, "session" => wire}))
    end

    if reason == "exited", do: GenServer.cast(__MODULE__, {:ended, id})
    :ok
  rescue
    _ -> :ok
  end

  @doc "All snapshots, newest first."
  @spec all() :: [{String.t(), pid(), map()}]
  def all do
    if table?() do
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_id, _pid, wire} -> -(wire["startedAt"] || 0) end)
    else
      []
    end
  end

  @spec lookup(String.t()) :: {:ok, pid(), map()} | :error
  def lookup(id) when is_binary(id) do
    if table?() do
      case :ets.lookup(@table, id) do
        [{^id, pid, wire}] -> {:ok, pid, wire}
        [] -> :error
      end
    else
      :error
    end
  end

  def lookup(_id), do: :error

  @spec live_count() :: non_neg_integer()
  def live_count do
    Enum.count(all(), fn {_id, pid, wire} -> live?(pid, wire) end)
  end

  @doc "Whether a snapshot's process is still running."
  @spec live?(pid(), map()) :: boolean()
  def live?(pid, wire), do: wire["status"] not in ["closed", "failed"] and Process.alive?(pid)

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:start_session, opts, max_live}, _from, state) do
    if live_count() >= max_live do
      {:reply, {:error, :too_many_sessions}, state}
    else
      case DynamicSupervisor.start_child(LemonOmp.SessionSupervisor, {LemonOmp.Session, opts}) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          owned = {opts[:id], opts[:worktree]}
          {:reply, {:ok, pid}, %{state | monitors: Map.put(state.monitors, ref, owned)}}

        {:error, {:shutdown, {:spawn_failed, _reason}}} ->
          {:reply, {:error, :startup_failed}, state}

        {:error, _reason} ->
          {:reply, {:error, :startup_failed}, state}
      end
    end
  end

  @impl true
  def handle_cast({:ended, _id}, state) do
    evict_ended()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {owned, monitors} = Map.pop(state.monitors, ref)

    with {id, worktree} when is_binary(id) <- owned,
         [{^id, pid, wire}] <- :ets.lookup(@table, id) do
      wire =
        if wire["status"] not in ["closed", "failed"] do
          now = System.system_time(:millisecond)

          wire =
            Map.merge(wire, %{
              "status" => "failed",
              "activity" => nil,
              "activeTools" => [],
              "pendingApprovals" => [],
              "endedAt" => now,
              "updatedAt" => now,
              "error" => "the Lemon process supervising omp stopped unexpectedly",
              "exit" => %{"code" => nil, "reason" => down_reason(reason)}
            })

          publish(pid, wire, "exited")
          wire
        else
          wire
        end

      if worktree && not Map.has_key?(wire["worktree"] || %{}, "kept") do
        # A hard-killed Session cannot run terminate/2. Give omp's stdin EOF
        # shutdown time to finish before inspecting the owned worktree.
        Task.start(fn ->
          Process.sleep(1_500)
          cleaned = LemonOmp.Worktree.cleanup(worktree)
          publish(pid, Map.put(wire, "worktree", cleaned), "exited")
        end)
      end
    end

    {:noreply, %{state | monitors: monitors}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp down_reason(:normal), do: "stopped"
  defp down_reason(:shutdown), do: "shutdown"
  defp down_reason({:shutdown, _}), do: "shutdown"
  defp down_reason(_reason), do: "crashed"

  defp evict_ended do
    ended =
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn {_id, _pid, wire} -> wire["status"] in ["closed", "failed"] end)
      |> Enum.sort_by(fn {_id, _pid, wire} -> -(wire["endedAt"] || 0) end)

    ended
    |> Enum.drop(@max_ended)
    |> Enum.each(fn {id, _pid, _wire} -> :ets.delete(@table, id) end)
  end
end
