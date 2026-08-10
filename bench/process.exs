Code.require_file("support.exs", __DIR__)

# Per-conversation process spawn, register and lookup.
#
# Lemon gives every run its own supervised, registry-named process
# (`LemonRouter.RunProcess` under `LemonRouter.RunSupervisor`, addressed by
# `{:via, Registry, {LemonRouter.RunRegistry, run_id}}`). Whether that is
# affordable at a few thousand concurrent conversations is a fair question, and
# it is answerable with a number.
#
# WHAT THIS DOES NOT MEASURE: a real `RunProcess` resolves a conversation,
# subscribes to the Bus, submits an `ExecutionCommand` into an engine runtime
# and starts a watchdog. Booting one of those is dominated by the engine, which
# is usually a network call to a model provider. What is measured here is the
# substrate the run lifecycle is built on — spawn, register, look up, shut down
# — with a GenServer whose init does nothing. Read the numbers as "the process
# machinery costs about this much", not "a run starts in this long".

LemonBench.banner("Registry-named process lifecycle")

defmodule BenchRunProcess do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  defp via(id), do: {:via, Registry, {BenchRegistry, id}}

  @impl true
  def init(opts) do
    # A state map roughly the size of a real run's metadata snapshot.
    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       session_key: "agent:bench:telegram:default:dm:1",
       status: :running,
       started_at: System.monotonic_time(:millisecond),
       meta: %{engine: "claude_code", model: "claude-fable-5"}
     }}
  end

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

{:ok, _} = Registry.start_link(keys: :unique, name: BenchRegistry)

{:ok, sup} =
  DynamicSupervisor.start_link(
    strategy: :one_for_one,
    name: BenchRunSupervisor,
    max_children: 200_000
  )

start_one = fn id ->
  {:ok, pid} = DynamicSupervisor.start_child(BenchRunSupervisor, {BenchRunProcess, id: id})
  pid
end

# ---------------------------------------------------------------------------
# Single-process lifecycle latency
# ---------------------------------------------------------------------------

IO.puts("\n--- single process operations ------------------------------------------\n")

# Spawn cost is deliberately absent here: Benchee would run it millions of
# times and either exhaust the supervisor's child limit or measure a machine
# under memory pressure. It is measured in bulk below instead, where the
# population is bounded and the number means something.

_ = start_one.("warm")

Benchee.run(
  %{
    "registry lookup (hit)" => fn ->
      Registry.lookup(BenchRegistry, "warm")
    end,
    "registry lookup (miss)" => fn ->
      Registry.lookup(BenchRegistry, "nope")
    end,
    "call via registry name" => fn ->
      GenServer.call({:via, Registry, {BenchRegistry, "warm"}}, :ping)
    end
  },
  time: 3,
  warmup: 1,
  print: [fast_warning: false]
)

# Clear out everything the latency run created before measuring bulk behaviour.
for {_, pid, _, _} <- DynamicSupervisor.which_children(sup) do
  DynamicSupervisor.terminate_child(sup, pid)
end

# ---------------------------------------------------------------------------
# Bulk spawn: how long to stand up N concurrent conversations
# ---------------------------------------------------------------------------

IO.puts("\n--- bulk spawn ---------------------------------------------------------\n")

for n <- [1_000, 10_000, 50_000] do
  {us, _} =
    :timer.tc(fn ->
      for i <- 1..n, do: start_one.("bulk_#{n}_#{i}")
    end)

  alive = DynamicSupervisor.count_children(sup).active

  # Memory is reported in its own section below. `:erlang.memory(:processes)`
  # here would be the VM-wide total, not this population's share, and printing
  # it next to a process count invites exactly the wrong subtraction.
  IO.puts(
    String.pad_trailing("#{n} processes", 20) <>
      String.pad_leading(LemonBench.num(us / 1000, 1) <> " ms", 12) <>
      String.pad_leading(LemonBench.num(us / n, 2) <> " us each", 16) <>
      String.pad_leading(LemonBench.fmt_ops(n * 1_000_000 / us) <> "/s", 16) <>
      String.pad_leading("#{alive} alive", 14)
  )

  for {_, pid, _, _} <- DynamicSupervisor.which_children(sup) do
    DynamicSupervisor.terminate_child(sup, pid)
  end

  :erlang.garbage_collect()
end

# ---------------------------------------------------------------------------
# Concurrent spawn: many callers starting runs at once
# ---------------------------------------------------------------------------
#
# `DynamicSupervisor.start_child/2` is a call into a single supervisor process,
# so this is the same serialisation question the Store has. Worth knowing where
# the ceiling is before assuming a supervisor can absorb a traffic spike.

IO.puts("\n--- concurrent spawn (single DynamicSupervisor) ------------------------\n")

for workers <- [1, 8, 32] do
  per_worker = div(20_000, workers)

  {ops, us} =
    LemonBench.throughput(workers, per_worker, fn w, i ->
      start_one.("conc_#{workers}_#{w}_#{i}")
    end)

  LemonBench.report("#{workers} concurrent starters", ops, us, workers * per_worker)

  for {_, pid, _, _} <- DynamicSupervisor.which_children(sup) do
    DynamicSupervisor.terminate_child(sup, pid)
  end
end

# ---------------------------------------------------------------------------
# Memory per idle conversation
# ---------------------------------------------------------------------------

IO.puts("\n--- memory per idle process --------------------------------------------\n")

:erlang.garbage_collect()
before_mem = :erlang.memory(:total)
n = 50_000

for i <- 1..n, do: start_one.("mem_#{i}")

:erlang.garbage_collect()
after_mem = :erlang.memory(:total)
per_proc = (after_mem - before_mem) / n

IO.puts(
  "#{n} idle registered GenServers: " <>
    "#{Float.round((after_mem - before_mem) / 1_048_576, 1)} MB total, " <>
    "#{Float.round(per_proc, 0)} bytes each"
)

IO.puts("""

That figure includes the Registry entry and the supervisor's child record, not
just the process. It is measured on processes that have never received a
message; a run that has streamed a conversation carries its own heap on top.
""")
