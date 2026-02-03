From Lemon’s README, you already have a bunch of the “OpenClaw-shaped” pieces: per-conversation queues (ThreadWorker), a scheduler with concurrency slots, abort/steering, and a *Task tool* that can delegate to multiple “subagent engines” (internal `CodingAgent.Session`, Codex CLI, Claude CLI) with streaming + resume tokens. ([GitHub][1])

So the real question isn’t “how do we add subagents?”—it’s “how do we turn subagents + background work into a first‑class *orchestration runtime* with consistent semantics (queues, lanes, budgets, cancellation, join), and make it more capable than OpenClaw’s model?”

Below is a concrete gap analysis (OpenClaw vs Lemon) and a design that turns Lemon into a *coordinator of subagents + async workers*, not just a single-agent runner.

---

## What OpenClaw has that’s directly relevant

### 1) A lane-aware command queue (global + per-session) with “message queue modes”

OpenClaw serializes runs per session key and caps overall concurrency via lane-aware FIFO queues, with defaults like `main` lane concurrency 4 and `subagent` lane concurrency 8. It also has queue modes like `collect`, `followup`, `steer`, `steer-backlog`, plus debounce/cap/drop policies. ([OpenClaw][2])

### 2) Per-agent tool policy + sandbox policy

OpenClaw lets each agent have different sandbox settings and tool allow/deny policies (with precedence rules and profiles). ([OpenClaw][3])

### 3) “Background exec” sessions with a `process` tool

OpenClaw’s `exec` can auto-background after `yieldMs`, returns a `sessionId`, and the `process` tool can `poll/log/write/kill`. Sessions are in-memory and lost on restart. ([OpenClaw][4])

### 4) Silent housekeeping (`NO_REPLY`) + pre-compaction memory flush

OpenClaw supports silent turns (suppressed delivery) and runs a “memory flush” before compaction thresholds. ([OpenClaw][5])

---

## What Lemon already has (important advantages)

### You already have subagents + engines + resume tokens

Your Task tool can delegate subtasks to `codex|claude|internal` engines, stream progress back, provide resume tokens, role prompts, and abort signals. ([GitHub][1])

### You already have per-conversation serialization + global scheduling primitives

LemonGateway has a Scheduler (“slot-based allocation”) and ThreadWorkers for per-conversation sequential execution. ([GitHub][1])

### You already have BEAM-native cancellation + responsiveness

Abort signals live in ETS for fast concurrent checks, tool execution runs in separate Tasks, streams auto-cancel when owner dies, etc. ([GitHub][1])

---

## The real gaps (what you’d build to become “better than OpenClaw”)

### Gap A — A unified orchestration model across:

* “main agent run”
* subagent runs (Task tool)
* background OS processes (build/test/indexers)
* pure async work (web fetch, repo scan, embeddings, etc.)

Right now Lemon has the parts, but coordination semantics likely differ per subsystem (ThreadWorker vs Task tool vs tool Tasks). The “better than OpenClaw” move is to define **one run/task model** and route everything through it.

### Gap B — Lane + budget aware scheduling for *subagents and async tasks*

OpenClaw’s lane queue is the key idea: separate lanes like `main`, `subagent`, `cron`, etc. ([OpenClaw][2])
Lemon has scheduler + thread workers, but to exceed OpenClaw you want:

* lane caps
* per-tenant fairness (per project / per chat / per user)
* cost/token budgets
* priority + deadline scheduling (optional)

### Gap C — First-class “async subagent” semantics

Today Task tool *can* spawn subagents, but if you want Lemon to coordinate many subagents and other workers:

* Task tool should support **async spawn + later join**
* parent agent should be able to run multiple subagents concurrently (within caps)
* provide “join patterns”: `wait_all`, `wait_any`, `map_reduce`, “speculative parallel then pick best”

OpenClaw explicitly avoids nested fan-out in subagents. Lemon can win here by *supporting it safely* via budgets + lanes.

### Gap D — Durable background processes (beat OpenClaw here)

OpenClaw background sessions are lost on restart. ([OpenClaw][4])
Lemon can beat this by persisting:

* process metadata (command, cwd, env, start time, owner)
* rolling logs (bounded)
* exit status
  …and optionally reconnecting to OS PIDs (best-effort) or at least preserving logs/status.

---

## Target design: “Runs, lanes, and a task graph”

### Core concepts to add (or make explicit)

1. **RunId**: every unit of work gets a stable id
2. **Lane**: controls concurrency caps (e.g. `:main`, `:subagent`, `:background_exec`, `:io_heavy`)
3. **Budget**: time, tokens, dollars, tool permissions
4. **RunGraph**: parent/child relationships + join

### How it maps to what you have

* LemonGateway `Job` becomes a `Run` root (already close). ([GitHub][1])
* ThreadWorker remains the *per-chat ordering layer*
* Scheduler becomes lane/budget aware (global fairness)
* Task tool subagents become *child runs* scheduled in the `:subagent` lane
* Bash/background processes become runs in `:background_exec` lane

---

## Concrete implementation sketches (Elixir)

### 1) Lane-aware queue primitive (BEAM version of OpenClaw’s command queue)

This is a small reusable building block you can embed inside `LemonGateway.Scheduler` or use as a standalone GenServer.

```elixir
defmodule LemonGateway.LaneQueue do
  @moduledoc """
  Lane-aware FIFO queue with concurrency caps per lane.

  Use cases:
  - global caps per lane (:main, :subagent, :background_exec, ...)
  - fairness / backpressure: queue depth, wait time metrics
  """

  use GenServer
  require Logger

  @type lane :: atom() | {:session, term()}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue a 0-arity function. Returns {:ok, result} or {:error, reason}.
  """
  def run(server \\ __MODULE__, lane, fun, meta \\ %{}) when is_function(fun, 0) do
    GenServer.call(server, {:enqueue, lane, fun, meta}, :infinity)
  end

  # -------- internals --------

  def init(opts) do
    caps = Keyword.fetch!(opts, :caps)
    task_sup = Keyword.fetch!(opts, :task_supervisor)

    state = %{
      caps: caps, # %{main: 4, subagent: 8, ...}
      task_sup: task_sup,
      lanes: %{}, # lane => %{running: non_neg_integer(), q: :queue.queue(job_id)}
      jobs: %{}   # job_id => %{from, lane, fun, meta, task_ref}
    }

    {:ok, state}
  end

  def handle_call({:enqueue, lane, fun, meta}, from, st) do
    job_id = make_ref()
    st = put_in(st.jobs[job_id], %{from: from, lane: lane, fun: fun, meta: meta, task_ref: nil})

    st =
      st
      |> lane_enqueue(lane, job_id)
      |> drain_lane(lane)

    {:noreply, st}
  end

  def handle_info({ref, {:ok, result}}, st) do
    {:noreply, complete_job(ref, {:ok, result}, st)}
  end

  def handle_info({ref, {:error, reason}}, st) do
    {:noreply, complete_job(ref, {:error, reason}, st)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, st) do
    # Task crashed
    {:noreply, complete_job(ref, {:error, reason}, st)}
  end

  # ----- helpers -----

  defp lane_state(st, lane) do
    Map.get(st.lanes, lane, %{running: 0, q: :queue.new()})
  end

  defp cap_for_lane(st, lane) do
    # default cap=1 for lanes you didn't configure
    Map.get(st.caps, lane, 1)
  end

  defp lane_enqueue(st, lane, job_id) do
    ls = lane_state(st, lane)
    ls = %{ls | q: :queue.in(job_id, ls.q)}
    put_in(st.lanes[lane], ls)
  end

  defp drain_lane(st, lane) do
    ls = lane_state(st, lane)
    cap = cap_for_lane(st, lane)

    cond do
      ls.running >= cap ->
        st

      :queue.is_empty(ls.q) ->
        st

      true ->
        {{:value, job_id}, q2} = :queue.out(ls.q)
        job = st.jobs[job_id]

        task =
          Task.Supervisor.async_nolink(st.task_sup, fn ->
            # normalize to {:ok, _} / {:error, _}
            try do
              {:ok, job.fun.()}
            rescue
              e -> {:error, {e, __STACKTRACE__}}
            catch
              kind, err -> {:error, {kind, err}}
            end
          end)

        job = %{job | task_ref: task.ref}
        st = put_in(st.jobs[job_id], job)

        ls = %{ls | running: ls.running + 1, q: q2}
        st = put_in(st.lanes[lane], ls)

        # continue draining in case cap > 1
        drain_lane(st, lane)
    end
  end

  defp complete_job(task_ref, reply, st) do
    {job_id, job} =
      Enum.find(st.jobs, fn {_id, j} -> j.task_ref == task_ref end) ||
        {nil, nil}

    if job == nil do
      st
    else
      GenServer.reply(job.from, reply)

      # decrement running + drain
      lane = job.lane
      ls = lane_state(st, lane)
      ls = %{ls | running: max(ls.running - 1, 0)}

      st =
        st
        |> update_in([:lanes, lane], fn _ -> ls end)
        |> update_in([:jobs], &Map.delete(&1, job_id))
        |> drain_lane(lane)

      st
    end
  end
end
```

**How you’d use it in LemonGateway:**

* `:main` lane for top-level user jobs
* `:subagent` lane for Task tool children
* `:background_exec` lane for long OS processes

This matches OpenClaw’s “main vs subagent lanes” idea, but you can go further with more lanes + budgets. ([OpenClaw][2])

---

### 2) Make Task tool truly orchestration-friendly: async spawn + join

You already have Task tool delegation + resume tokens. ([GitHub][1])
To turn it into an orchestration primitive, add:

* `async: true` → return `task_id` immediately (plus resume token if available)
* `join: "poll"` tool or `task_poll` tool → fetch status + tail logs
* `join: "await"` option for “block until done” (current behavior)

Sketch for a Task tool execute function (matches the `execute: fn _id, params, signal, on_update -> ... end` pattern shown in README). ([GitHub][1])

```elixir
defmodule CodingAgent.Tools.Task do
  alias LemonGateway.LaneQueue
  alias CodingAgent.Tools.TaskStore

  def execute(_tool_id, params, abort_signal, on_update) do
    engine = Map.get(params, "engine", "internal")
    async? = Map.get(params, "async", false)
    prompt = Map.fetch!(params, "prompt")
    role = Map.get(params, "role", "implement")

    task_id = TaskStore.new_task(%{engine: engine, role: role, prompt: prompt})

    runner_fun = fn ->
      # IMPORTANT: record streaming updates into TaskStore so async callers can poll
      on_update_safe = fn evt ->
        TaskStore.append_event(task_id, evt)
        on_update.(evt)
      end

      result =
        run_subagent(engine, prompt, role, abort_signal, on_update_safe)

      TaskStore.finish(task_id, result)
      result
    end

    # schedule in :subagent lane
    if async? do
      Task.start(fn ->
        _ = LaneQueue.run(:lemon_lane_queue, :subagent, runner_fun, %{task_id: task_id})
      end)

      {:ok, %{"task_id" => task_id}}
    else
      case LaneQueue.run(:lemon_lane_queue, :subagent, runner_fun, %{task_id: task_id}) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp run_subagent("codex", prompt, role, abort_signal, on_update), do: ...
  defp run_subagent("claude", prompt, role, abort_signal, on_update), do: ...
  defp run_subagent("internal", prompt, role, abort_signal, on_update), do: ...
end
```

This turns your Task tool into a **spawn primitive**. From there you can build higher-level orchestration tools (parallel map-reduce, reviewers, speculative execution).

---

### 3) Add a durable “process manager” (beat OpenClaw’s background exec)

OpenClaw’s background exec sessions are in-memory and lost on restart. ([OpenClaw][4])
Lemon can do better by persisting process session state (even if you can’t always reattach to the OS process).

A BEAM-idiomatic structure:

* `CodingAgent.ProcessSupervisor` (DynamicSupervisor)
* `CodingAgent.ProcessSession` (GenServer managing a Port + ring buffer)
* `CodingAgent.ProcessStore` (ETS + optional disk journal)
* tools:

  * `bash` (or `exec`) supports `yield_ms`, `background`, `timeout_sec`
  * `process` supports `list/poll/log/write/kill/clear`

The *tool surface* should match OpenClaw because it’s proven ergonomic. ([OpenClaw][4])

Tool request examples (shape):

```json
{ "tool": "exec", "command": "npm test", "yieldMs": 1000 }
{ "tool": "process", "action": "poll", "sessionId": "..." }
{ "tool": "process", "action": "kill", "sessionId": "..." }
```

In Lemon, the difference would be:

* persist logs/status so UI can recover after restarts
* send a “completion event” into the same event stream LemonGateway already uses ([GitHub][1])

---

### 4) RunGraph: coordinate subagents + workers as a DAG

Once you have `RunId`s and async Task spawns, you can add orchestration patterns that OpenClaw doesn’t really aim for:

* **fan-out / fan-in**: run N subagents, merge results
* **review loops**: implement → test → review → patch
* **speculative**: run two approaches, pick best, cancel the other
* **dependency DAG**: task B waits for artifacts from task A

Minimal “run graph” store (ETS is fine at first; you already use ETS heavily). ([GitHub][1])

```elixir
defmodule LemonGateway.RunGraph do
  @table :lemon_run_graph

  def init! do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  end

  def new_run(attrs) do
    run_id = System.unique_integer([:positive])
    :ets.insert(@table, {run_id, Map.merge(%{state: :queued, parent: nil, children: []}, attrs)})
    run_id
  end

  def add_child(parent_id, child_id) do
    update(parent_id, fn r -> Map.update!(r, :children, &[child_id | &1]) end)
    update(child_id, fn r -> Map.put(r, :parent, parent_id) end)
  end

  def update(run_id, fun) do
    [{^run_id, r}] = :ets.lookup(@table, run_id)
    r2 = fun.(r)
    :ets.insert(@table, {run_id, r2})
    r2
  end

  def get(run_id) do
    case :ets.lookup(@table, run_id) do
      [{^run_id, r}] -> {:ok, r}
      [] -> {:error, :not_found}
    end
  end
end
```

From there:

* scheduler dispatches `RunId`s
* subagents create child RunIds in `:subagent` lane
* join logic can be implemented as a simple “wait until all children terminal” state machine

---

## “Better than OpenClaw” features worth prioritizing

### 1) Durable background work

OpenClaw explicitly says background sessions are lost on restart. ([OpenClaw][4])
If Lemon persists run state + logs, your TUI can reconnect and show:

* running jobs
* last output tail
* completion results
* retry controls

### 2) Multi-subagent concurrency with guardrails

OpenClaw uses a `subagent` lane and tries to avoid collisions. ([OpenClaw][2])
Lemon can go beyond by allowing multiple subagents concurrently *with budgets*:

* lane cap (`:subagent => 8`)
* per-parent cap (e.g. max 3 children running)
* cost cap / token cap per parent run

### 3) Silent housekeeping + pre-compaction “flush”

You already have compaction and session tree features. ([GitHub][1])
Adding **silent turns** and a **pre-compaction flush** improves long-running coordination:

* subagents can write durable “state of work” artifacts before compaction pressure
* background indexing can update memory without spamming the user

OpenClaw’s `NO_REPLY` convention + flush threshold is a good model. ([OpenClaw][5])

### 4) Per-agent / per-subagent tool policy

OpenClaw’s tool policy precedence is a mature approach. ([OpenClaw][3])
Even if you don’t do Docker sandboxing immediately, you can still implement:

* tool allow/deny profiles
* per-engine restrictions (Codex subagent can’t run bash, etc.)
* “approval gates” for write/exec tools

This matters when you start coordinating many workers.

---

## Suggested integration points inside Lemon (based on your README)

These are the parts I’d wire together first:

1. **LemonGateway.Scheduler**: add *lane caps* and export a `run_in_lane/3` API for Task tool to use. (Scheduler is explicitly in the tree.) ([GitHub][1])
2. **CodingAgent.Tools.Task**: add `async` + polling + join patterns on top of your existing engine delegation. ([GitHub][1])
3. **A ProcessManager tool**: extend your “bash” tool idea into background sessions with poll/kill/write. (You already run bash in separate tasks to keep UI responsive.) ([GitHub][1])
4. **RunGraph + persistence hooks**: use your JSONL session persistence for agent transcripts, and ETS/disk for run/task metadata. ([GitHub][1])

---

## Invariants & tests that matter for orchestration

If Lemon becomes “multi-worker orchestrator”, bugs show up as races and zombie work. These invariants keep you sane:

* **At-most-one writer per transcript**: a given `CodingAgent.Session` JSONL file must be mutated by exactly one process at a time.
* **Cancellation is sticky**: abort signal must short-circuit tool execution, subagent runs, and background processes (consistent behavior).
* **Queue fairness**: long background runs must not starve interactive runs (lane separation).
* **Idempotent retries**: retry only individual steps (like OpenClaw’s policy), not whole multi-step flows. ([OpenClaw][6])

---

## Bottom line

Lemon already *has* subagents and job orchestration. ([GitHub][1])
To make Lemon a **better OpenClaw for coordinating subagents + async workers**, focus on:

1. **Unify everything under Runs + Lanes + Budgets**
2. **Make Task tool async-first (spawn/join) and lane-scheduled**
3. **Add a durable background process manager (poll/kill/log)**
4. **Add policy + silent housekeeping hooks for long-lived coordination**

If you want, I can propose a concrete “v0 API” for:

* `task.spawn`, `task.poll`, `task.join`
* `exec` / `process` tools
* scheduler lane config
  …that fits your existing `AgentCore.new_tool` interface and LemonGateway event model.

[1]: https://github.com/z80dev/lemon "GitHub - z80dev/lemon: yet another agent runtime"
[2]: https://docs.openclaw.ai/concepts/queue "Command Queue - OpenClaw"
[3]: https://docs.openclaw.ai/multi-agent-sandbox-tools "Multi-Agent Sandbox & Tools - OpenClaw"
[4]: https://docs.openclaw.ai/gateway/background-process "Background Exec and Process Tool - OpenClaw"
[5]: https://docs.openclaw.ai/reference/session-management-compaction "Session Management Deep Dive - OpenClaw"
[6]: https://docs.openclaw.ai/concepts/retry "Retry Policy - OpenClaw"
