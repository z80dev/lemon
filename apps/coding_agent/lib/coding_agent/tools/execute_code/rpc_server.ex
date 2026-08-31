defmodule CodingAgent.Tools.ExecuteCode.RpcServer do
  @moduledoc """
  Temporary per-cell file-RPC pump for persistent `execute_code` sessions.

  Where `Rpc.serve/2` pumps requests for a single per-call script task, this
  GenServer pumps the rpc directory of one *cell* of a persistent python
  kernel. It is started once per cell with the fresh `{dir, token}` bridge
  forwarded to the runner, and it lives until the owning caller ends the cell
  or dies. An abort signal gates further dispatch but does not stop the server:
  the owning execute process must be able to read final stats before explicit
  cleanup.

  The server runs in its own process, outside `PythonRepl.Session`: a slow
  tool or an approval wait inside a sweep occupies only this process, so the
  session's Port frame handling and cancellation path are never blocked.

  ## Lifecycle

      {:ok, server} =
        RpcServer.start_link(%{
          tools: cell_tools,
          tool_policy: tool_policy,
          approval_context: approval_context,
          max_calls: config.max_rpc_calls,
          max_result_bytes: config.max_rpc_result_bytes,
          signal: signal,
          rpc_dir: bridge.dir,
          token: bridge.token
        })

      # ... cell runs; the runner configured lemon_tools with the same
      # {dir, token} pair ...

      stats = RpcServer.drain_and_stats(server)
      :ok = RpcServer.stop(server)

    * `start_link/2` validates the ctx, is linked to its `start_link/2`
      parent, monitors the configured caller (the future session integration),
      and schedules the first poll.
    * Every `poll_interval_ms` the server checks the abort signal and then
      runs one bounded sweep of at most `:max_requests_per_sweep` requests
      (100 by default); once aborted it retains its final stats without
      dispatching new requests. Sweeps never overlap, so accounting stays
      single-threaded. A sweep that dies ABNORMALLY (any exit but `:normal`)
      — or is caught raising/throwing (a contained fault, see `sweep/3`) —
      is treated as potential accounting loss: its published-but-unreturned
      stats are gone, so `accounting_loss: true` is stamped and its claims
      are recovered immediately (markers plus the claim ledger below)
      before the next poll is scheduled.
    * `stop/2` is synchronous and idempotent. Every stop path — explicit
      stop, caller death, supervisor shutdown — funnels through
      `terminate/2`, which materializes the directory entries and then removes
      at most 10,000 protocol files (files and links only; the `0700`
      workspace directory itself belongs to the workspace teardown).
    * The process is `restart: :temporary`: a dead cell server is never
      resurrected against a directory its token has already rotated out of.

  ## The claim ledger

  The in-flight claim markers live in the rpc directory, which the script
  can write — so a hostile script can delete or replace a marker after the
  pump's publication gate. This server therefore keeps its OWN claim
  evidence: at `init/1` the ctx's `:on_claim` hook is installed to send
  every dispatch-bound claim (`{id, tool}`) to this process, which records
  it in `pending_claims` BEFORE the pump publishes the marker. The ledger
  is a superset of the published claims; it is cleared when the owning
  sweep's fate is decided — a consumed result (the sweep answered
  everything it claimed) or a death whose recovery just ran. A script that
  destroys markers only destroys half its claims' evidence; the ledger
  half still forces the answer, the call charge, the replay memory, and —
  when no response survives either — the `accounting_loss` lower-bound
  flag (see `Rpc.recover_orphaned_claims/3`).

  There is deliberately no final drain of requests, mirroring `Rpc.serve/2`:
  a request that is still pending when the server stops belongs to a cell
  that is already over, and running its tool would be work nobody is waiting
  for. Requests that were already *claimed* when a sweep was cancelled are
  different: the cancel path (and the abnormal-:DOWN path) answers them in
  writing (see `recover_orphaned_claims/3` below) without ever running
  their tools, and `notify-*.json` frames still on disk are drained on stop
  so a `notify()` issued immediately before the cell ended still reaches
  the conversation.

  ## Expected shared `Rpc` contract

  All protocol intelligence — authentication, policy, approval, budgets,
  atomic response writes, replay refusal — lives in the shared pump module
  (`CodingAgent.Tools.ExecuteCode.Rpc`), which is injected via the `:rpc`
  option so tests can substitute a fake. The server treats pump stats as
  opaque and only calls:
    * `process_pending(ctx, stats)` — one bounded sweep over `ctx.rpc_dir`.
      It selects at most `ctx.max_requests_per_sweep` regular request files or
      symlinks (100 by default) in ascending id order before decoding or
      authenticating their bodies; request directories are skipped for
      workspace teardown. Each selected request is removed non-recursively
      after handling, including stale, wrong, or missing tokens, so the next
      sweep continues through the remaining files. Authentication is
      constant-time and precedes any request counting,
      budget enforcement, or dispatch (stale, wrong, or missing tokens are
      denied and never appear in results or logs), enforces the call and
      result-byte budgets, runs allowed tools through the current
      `ToolPolicy`/`ToolExecutor` approval path, writes `res-<id>.json`
      atomically, and returns updated stats. The stats carry the pump's
      replay-tracking state, so a request id that was already answered —
      including one replayed after its response was consumed — is refused and
      never re-dispatched. Sweeps also consume `notify-*.json` side-channel
      frames, forwarding each through `ctx.on_update` when present (see
      `Rpc` for the caps); `text-*.json` result blocks are never touched by
      the sweep — the owning execute process reads them after the cell ends.
    * `process_request(id, ctx, stats)` — the single-request building block
      shared with `Rpc.serve/2`; not called by this server, which always
      sweeps via `process_pending/2`.
    * `recover_orphaned_claims(rpc_dir, stats, claimed)` — answers the
      in-flight claims a dead sweep leaves behind: on-disk markers plus the
      `claimed` ledger map (`%{id => tool}`) this server accumulated through
      `:on_claim`, returning stats with their call reservations and replay
      memory reconstructed (and `accounting_loss: true` when destroyed
      ledger evidence forces a lower bound). Called from every path that
      settles a sweep whose stats cannot be trusted — the cancel path
      (`abort/2`, `terminate/2`), the abnormal-:DOWN path, and the
      contained-fault result path — after the sweep task is brutally
      killed, dies on its own, or returns `{:sweep_failed, stats}`.
    * `drain_notifications(ctx, stats)` — the notification-only final drain;
      called from `drain_and_stats/2` (the teardown read ExecuteCode uses)
      and once more from `terminate/2` as a last-resort backstop before
      protocol-file cleanup.
    * `request_path/2` and `response_path/2` — protocol file naming, used by
      the integration and tests; the server itself never builds paths.

  `ctx` is the `Rpc` ctx extended with the per-cell `:token`. A wrong sweep
  implementation must not take the server down with it: a raising or throwing
  sweep is contained, logged (exception class only — exception payloads can
  embed the request body, which carries the token), and reported as a
  distinctly-tagged `{:sweep_failed, stats}` result carrying the pre-sweep
  snapshot. The handler then settles it exactly like an abnormal death —
  ledger recovery, `accounting_loss: true`, rescheduled polls — because a
  fault at an arbitrary sweep point may have dispatched and answered claims
  whose accounting died with the fault; only the process is kept alive.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CodingAgent.Tools.ExecuteCode.Rpc
  alias LemonAgent.AbortSignal

  @default_poll_interval_ms 25
  @stop_timeout_ms 5_000
  @stats_timeout_ms 5_000

  # Stop-time cleanup materializes every directory entry before the cap can
  # apply, so enumeration itself is not bounded. The cap limits deletions: a
  # cell that planted an unbounded number of files cannot make teardown delete
  # an unbounded number of files. Directories are left to the workspace
  # teardown, which owns the `0700` tree.
  @max_cleanup_files 10_000

  @typedoc """
  The shared pump ctx for one cell: the `Rpc` ctx plus the per-cell `:token`.

  See the "Expected shared `Rpc` contract" section of the moduledoc.
  """
  @type ctx :: %{
          required(:tools) => %{String.t() => LemonAgent.Types.AgentTool.t()},
          required(:tool_policy) => map() | nil,
          required(:approval_context) => map() | nil,
          required(:max_calls) => pos_integer(),
          required(:max_result_bytes) => pos_integer(),
          required(:signal) => reference() | nil,
          required(:rpc_dir) => String.t(),
          required(:token) => String.t(),
          optional(:poll_interval_ms) => pos_integer(),
          optional(:max_requests_per_sweep) => pos_integer(),
          optional(:max_parallel_rpc) => pos_integer(),
          optional(:on_update) => (LemonAgent.Types.AgentToolResult.t() -> :ok) | nil,
          # Injected by this server at init (see "The claim ledger" in the
          # moduledoc); never supplied by the caller.
          optional(:on_claim) => (integer(), String.t() -> any()) | nil
        }

  @type option ::
          {:rpc, module()}
          | {:poll_interval_ms, pos_integer()}
          | {:caller, pid()}
          | {:name, GenServer.name()}

  defstruct [
    :ctx,
    :rpc,
    :stats,
    :poll_interval_ms,
    :caller,
    :caller_monitor,
    :sweep_task,
    # The claim ledger: %{id => tool} for every claim the in-flight sweep
    # recorded via :on_claim and whose fate is not yet decided. See "The
    # claim ledger" in the moduledoc.
    pending_claims: %{}
  ]

  @doc """
  Starts a pump server for one cell.

  Options:

    * `:rpc` — pump module implementing the contract in the moduledoc;
      defaults to `CodingAgent.Tools.ExecuteCode.Rpc`. Test seam.
    * `:poll_interval_ms` — overrides `ctx.poll_interval_ms` (which defaults
      to #{@default_poll_interval_ms} ms). Test seam.
    * `:caller` — process whose death stops the server; defaults to the
      caller of `start_link/2`, which the server monitors. The server is
      linked to its `start_link/2` parent.

  Returns `{:error, {:invalid_ctx, key}}` without starting a process when a
  required ctx key is missing or malformed.
  """
  @spec start_link(ctx(), [option()]) :: GenServer.on_start() | {:error, {:invalid_ctx, atom()}}
  def start_link(ctx, opts \\ []) when is_map(ctx) do
    with :ok <- validate_ctx(ctx),
         {:ok, poll_interval_ms} <- resolve_poll_interval(ctx, opts) do
      rpc = Keyword.get(opts, :rpc, Rpc)
      caller = Keyword.get(opts, :caller, self())

      gen_opts =
        case Keyword.get(opts, :name) do
          nil -> []
          name -> [name: name]
        end

      GenServer.start_link(__MODULE__, {ctx, rpc, poll_interval_ms, caller}, gen_opts)
    end
  end

  @doc """
  Cancels any in-flight dispatch while retaining the server for a final stats
  read. The owning execute process must still call `stop/2`.
  """
  @spec abort(GenServer.server(), timeout()) :: :ok
  def abort(server, timeout \\ @stop_timeout_ms) do
    GenServer.call(server, :abort, timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Stops the server synchronously and removes the cell's protocol files.

  Idempotent: stopping a server that is already gone returns `:ok`.
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(server, timeout \\ @stop_timeout_ms) do
    GenServer.stop(server, :normal, timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the pump statistics accumulated so far.

  The map is the shared pump's opaque stats (`calls`, `denied`, `errors`,
  `bytes`, `tools_used`, plus the pump's private replay-tracking state); it
  can be handed to the cell's result details unchanged.

  A stats map may carry one server-added key: `:accounting_loss => true` is
  stamped when a sweep had to be brutally killed, died abnormally, or was
  caught faulting (see the contained-fault handling above) — work the dead
  sweep dispatched and answered without leaving recoverable claim evidence
  can no longer be reconstructed, so the accounting is a lower
  bound. Consumers must treat that conservatively (ExecuteCode forces
  `trust: :untrusted`).
  """
  @spec stats(GenServer.server(), timeout()) :: Rpc.stats()
  def stats(server, timeout \\ @stats_timeout_ms) do
    GenServer.call(server, :stats, timeout)
  end

  @doc """
  Runs the notification-only final drain, then returns the merged stats.

  The teardown read for the owning execute process: a `notify()` frame the
  cell flushed after its last sweep — including one written immediately
  before the cell ended — is forwarded here, and its count rides in the
  returned stats (`notify_forwarded`), so stop-time notifications are
  observable by the caller instead of dying with `terminate/2` (which still
  drains once more as a last-resort backstop). Requests are deliberately
  never drained; see the moduledoc. Meant for the teardown sequence, after
  the cell's dispatch was aborted — a sweep still in flight would return its
  own stats afterwards and supersede this read.

  Like `stats/2`, the returned map may carry `:accounting_loss => true`.
  """
  @spec drain_and_stats(GenServer.server(), timeout()) :: Rpc.stats()
  def drain_and_stats(server, timeout \\ @stats_timeout_ms) do
    GenServer.call(server, :drain_and_stats, timeout)
  end

  # ==========================================================================
  # GenServer callbacks
  # ==========================================================================

  @impl true
  def init({ctx, rpc, poll_interval_ms, caller}) do
    # Trapping exits guarantees terminate/2 — and with it protocol-file
    # cleanup — on supervisor shutdown or linked-parent death. A monitored
    # caller's death arrives as :DOWN and stops the server below.
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    schedule_poll(poll_interval_ms)

    # The claim ledger hook (the server owns it — never the caller): the
    # sweeping process feeds every dispatch-bound claim BEFORE the pump
    # publishes its marker, so this process's memory holds claim evidence
    # the script cannot delete. `send/2` from the sweep enqueues
    # immediately, so a sweep killed anywhere past that point has already
    # delivered its entry.
    ledger_pid = self()

    ctx =
      Map.put(ctx, :on_claim, fn id, tool when is_integer(id) and is_binary(tool) ->
        send(ledger_pid, {:claim_started, id, tool})
      end)

    {:ok,
     %__MODULE__{
       ctx: ctx,
       rpc: rpc,
       stats: rpc.initial_stats(),
       poll_interval_ms: poll_interval_ms,
       caller: caller,
       caller_monitor: caller_monitor,
       pending_claims: %{}
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  def handle_call(:drain_and_stats, _from, state) do
    # The teardown read: forward any notify() frames that landed after the
    # last sweep and fold their count into the stats the caller takes away
    # (terminate/2 keeps its own drain only as a backstop for callers that
    # never get here).
    state = drain_final_notifications(state)
    {:reply, state.stats, state}
  end

  def handle_call(:abort, _from, state) do
    :ok = abort_signal(state.ctx.signal)
    {:reply, :ok, cancel_sweep(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    if AbortSignal.aborted?(state.ctx.signal) do
      # ExecuteCode reads this snapshot after cancelling its facade task, then
      # explicitly stops us. Keeping the process alive preserves tool-use
      # accounting and the resulting trust classification through abort.
      {:noreply, state}
    else
      task =
        Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
          sweep(state.rpc, state.ctx, state.stats)
        end)

      {:noreply, %{state | sweep_task: task}}
    end
  end

  # The claim ledger feed: a sweep records each dispatch-bound claim here
  # before publishing its marker. Entries accumulate while the sweep runs
  # and are settled together with the sweep (result consumed → the sweep
  # answered everything it claimed; sweep dead → recovery just paid them).
  def handle_info({:claim_started, id, tool}, state)
      when is_integer(id) and is_binary(tool) do
    {:noreply, %{state | pending_claims: Map.put(state.pending_claims, id, tool)}}
  end

  def handle_info({ref, stats}, %{sweep_task: %Task{ref: ref}} = state) when is_map(stats) do
    Process.demonitor(ref, [:flush])
    # The sweep returned: it answered every claim it made (each claimed id
    # gets its response written before the sweep can return), so its ledger
    # entries are settled — all sends from the sweep precede this result in
    # the mailbox, so nothing of its is still in flight.
    state = %{state | stats: stats, sweep_task: nil, pending_claims: %{}}
    schedule_next_poll(state)
    {:noreply, state}
  end

  # A contained sweep fault (see sweep/3): the sweep could not return
  # trustworthy stats, which is exactly the abnormal-death accounting
  # hazard — it may have dispatched and answered claims whose accounting
  # died with the fault. It takes the same conservative path as an abnormal
  # :DOWN: settle its ledger entries through recovery NOW so no claimed id
  # waits for the next poll, flag the stats as a lower bound, and keep
  # serving — containment was never allowed to cost accounting correctness.
  def handle_info({ref, {:sweep_failed, stats_before}}, %{sweep_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    # The pre-sweep snapshot is all a failed sweep can vouch for; recovery
    # reconstructs the claims it can prove on top of it.
    state = %{state | stats: stats_before, sweep_task: nil}

    state = settle_failed_sweep(state)
    schedule_next_poll(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{sweep_task: %Task{ref: ref}} = state) do
    state = %{state | sweep_task: nil}

    state =
      if reason == :normal do
        # The task finished; its result message is already queued ahead of
        # this DOWN and will be consumed by a result handler above.
        state
      else
        # Abnormal sweep exit. The dead sweep may have published responses
        # and retired markers without ever returning its stats — no marker
        # evidence survives that window, so the accounting is a lower bound:
        # flag it (never overstate trust), settle its ledger entries, and
        # run recovery NOW so no claimed id waits for the next poll.
        settle_failed_sweep(state)
      end

    schedule_next_poll(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{caller_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  # A cancelled task can race its result or DOWN message with the abort call.
  # It no longer owns state after `cancel_sweep/1`, so those late notifications
  # are intentionally ignored.
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      # The owning caller (the future session integration) is gone: the cell
      # is over regardless of how it died, and cleanup must still run.
      pid == state.caller ->
        {:stop, :normal, state}

      # An unrelated linked process exiting normally says nothing about the
      # cell; tool code inside a sweep may hold transient links.
      reason == :normal ->
        {:noreply, state}

      # Supervisor shutdown and abnormal linked deaths keep their reason.
      true ->
        {:stop, reason, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = cancel_sweep(state)
    # A notify() issued immediately before the cell ended must still reach
    # the conversation; the stop path is the persistent mode's final drain.
    # (Notifications only — requests are deliberately never drained, see the
    # moduledoc.) The drain's returned stats — its forwarded counts — become
    # the final stats.
    state = drain_final_notifications(state)
    cleanup_files(state.ctx.rpc_dir)
    :ok
  end

  # ==========================================================================
  # Internals
  # ==========================================================================

  # A broken sweep must never take the server down: the cell would hang
  # waiting for responses nobody will write. The fault is contained here
  # and reported as `{:sweep_failed, stats}` — the PRE-sweep snapshot — so
  # the result handler can treat it exactly like an abnormal death
  # (ledger recovery plus `accounting_loss`) instead of mistaking the stale
  # snapshot for a completed sweep's truth, which would silently discard
  # every claim the failed sweep had already dispatched.
  defp sweep(rpc, ctx, stats) do
    rpc.process_pending(ctx, stats)
  rescue
    error ->
      # Class only: exception payloads can embed the request body, which
      # carries the per-cell token, and tokens never appear in logs.
      Logger.warning(
        "execute_code rpc sweep failed (#{inspect(error.__struct__)}); settling conservatively"
      )

      {:sweep_failed, stats}
  catch
    kind, _value ->
      Logger.warning("execute_code rpc sweep failed (#{kind}); settling conservatively")

      {:sweep_failed, stats}
  end

  # a small grace yield before the brutal kill covers the common "done but not
  # yet delivered" window. Only a genuinely killed sweep loses stats — that
  # path reconstructs what the markers and the claim ledger can prove and
  # flags the rest as lost.
  @sweep_cancel_grace_ms 25

  defp cancel_sweep(%{sweep_task: nil} = state), do: state

  defp cancel_sweep(%{sweep_task: task} = state) do
    case Task.yield(task, @sweep_cancel_grace_ms) do
      {:ok, stats} when is_map(stats) ->
        settle_completed_sweep(state, stats)

      _miss ->
        case Task.shutdown(task, :brutal_kill) do
          # Finished between the yield miss and the kill: same as above.
          {:ok, stats} when is_map(stats) ->
            settle_completed_sweep(state, stats)

          # Everything else — a genuinely killed sweep, or a contained fault
          # whose failure result raced the cancel — is a sweep that is
          # verifiably over and can no longer answer the requests it
          # claimed. After an abort no successor sweep will run either (the
          # server stops polling); pay its debts here so every claimed id
          # ends answered and its call reservations survive in the final
          # stats. Ids neither the markers nor the ledger can prove
          # (answered but never accounted) are unknowable now: flag the
          # loss so the trust classification falls back to untrusted
          # instead of trusted.
          _dead ->
            settle_failed_sweep(state)
        end
    end
  end

  # A sweep that verifiably answered everything it claimed (it returned its
  # stats): its markers are retired, every response is published, so its
  # stats are the truth — and its ledger entries are settled by its own
  # return. Task.yield/shutdown consumed ONLY the task result, so the
  # sweep's claim_started messages may still sit queued behind the
  # in-flight call — fold them through the settlement below, where the
  # returned stats' replay memory settles them as harmless duplicates
  # (every claim a completed sweep made was answered before it could
  # return). Recovery would find nothing else, but run it anyway — stale
  # markers from an even earlier sweep are still answered here because no
  # successor poll may exist.
  defp settle_completed_sweep(state, stats) do
    state = %{state | stats: stats, sweep_task: nil}

    state
    |> drain_queued_claims()
    |> settle_claims()
  end

  # A sweep whose fate was decided WITHOUT a trustworthy stats return
  # (abnormal :DOWN, brutal kill, or a contained fault): fold every ledger
  # entry in, flag the accounting as a lower bound, and pay the debts.
  defp settle_failed_sweep(state) do
    state
    |> drain_queued_claims()
    |> mark_accounting_loss()
    |> settle_claims()
  end

  # Settle the recorded claim ledger: run claim recovery with BOTH halves
  # of the evidence (markers plus the ledger), then clear the ledger —
  # every entry has now been paid into the stats (freshly owed, or already
  # settled by the sweep's own return and deduplicated by the replay
  # memory). The sweep task is over too: its result was consumed or its
  # shutdown already returned, so nothing may yield or kill it a second
  # time.
  defp settle_claims(state) do
    stats = recover_claims(state)
    %{state | stats: stats, sweep_task: nil, pending_claims: %{}}
  end

  # After a sweep is verifiably dead (brutal kill returned, or its :DOWN is
  # being processed), every claim_started message it sent is already in this
  # process's mailbox (local sends enqueue immediately, and a dead sender
  # sends nothing more) — but entries sent after the current message was
  # queued have not been processed by the handler yet. Fold them in here so
  # recovery sees the complete ledger.
  defp drain_queued_claims(%{pending_claims: claims} = state) do
    # Selective receive: non-matching messages stay in the mailbox untouched
    # — there is deliberately no catch-all, which would consume them.
    receive do
      {:claim_started, id, tool} when is_integer(id) and is_binary(tool) ->
        drain_queued_claims(%{state | pending_claims: Map.put(claims, id, tool)})
    after
      0 -> state
    end
  end

  # Same containment discipline as `sweep/3`: a broken pump must not take
  # the server (and the cell's result) down with it. Called only when the
  # owning sweep's fate is decided, so the ledger entries it passes are
  # exactly the claims that may still be owed.
  defp recover_claims(state) do
    state.rpc.recover_orphaned_claims(state.ctx.rpc_dir, state.stats, state.pending_claims)
  rescue
    error ->
      Logger.warning(
        "execute_code rpc claim recovery failed (#{inspect(error.__struct__)}); keeping previous stats"
      )

      state.stats
  catch
    kind, _value ->
      Logger.warning("execute_code rpc claim recovery failed (#{kind}); keeping previous stats")

      state.stats
  end

  # The stats stay opaque to this server, but it owns the value it hands
  # out, so it stamps its own conservative marker on it: executed work may
  # be missing from these stats. ExecuteCode reads the flag to force
  # `trust: :untrusted` — lost accounting must never classify network work
  # as trusted.
  defp mark_accounting_loss(%{stats: stats} = state) do
    %{state | stats: Map.put(stats, :accounting_loss, true)}
  end

  defp drain_final_notifications(state) do
    # The drained counts are the cell's last stats update: keep them, so
    # notify_forwarded (and anything else the drain accounts) is not
    # undercounted on stop.
    %{state | stats: state.rpc.drain_notifications(state.ctx, state.stats)}
  rescue
    error ->
      Logger.warning("execute_code rpc notification drain failed (#{inspect(error.__struct__)})")
      state
  catch
    kind, _value ->
      Logger.warning("execute_code rpc notification drain failed (#{kind})")
      state
  end

  defp abort_signal(nil), do: :ok
  defp abort_signal(signal), do: AbortSignal.abort(signal)

  defp schedule_next_poll(state) do
    unless AbortSignal.aborted?(state.ctx.signal) do
      schedule_poll(state.poll_interval_ms)
    end
  end

  defp schedule_poll(poll_interval_ms) do
    Process.send_after(self(), :poll, poll_interval_ms)
  end

  defp cleanup_files(rpc_dir) do
    case File.ls(rpc_dir) do
      {:ok, entries} ->
        entries
        # File.ls/1 has already materialized every entry; this cap bounds only
        # the subsequent deletion work.
        |> Enum.take(@max_cleanup_files)
        # File.rm removes files and symlinks and reports {:error, :eisdir}
        # for directories — recursion into planted trees would be unbounded
        # work, and the workspace teardown owns the tree.
        |> Enum.each(fn entry -> File.rm(Path.join(rpc_dir, entry)) end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp validate_ctx(ctx) do
    with :ok <- validate_required_ctx(ctx),
         :ok <- validate_optional_ctx(ctx) do
      :ok
    end
  end

  defp validate_required_ctx(ctx) do
    Enum.reduce_while(
      [:rpc_dir, :token, :tools, :max_calls, :max_result_bytes],
      :ok,
      fn key, :ok ->
        if valid_ctx_value?(key, Map.get(ctx, key)),
          do: {:cont, :ok},
          else: {:halt, {:error, {:invalid_ctx, key}}}
      end
    )
  end

  defp validate_optional_ctx(ctx) do
    Enum.reduce_while([:max_requests_per_sweep, :max_parallel_rpc], :ok, fn key, :ok ->
      case Map.fetch(ctx, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} when is_nil(value) ->
          # nil means "not configured": the shared pump applies its own
          # default, exactly like an absent key.
          {:cont, :ok}

        {:ok, value} ->
          if valid_ctx_value?(key, value) do
            {:cont, :ok}
          else
            {:halt, {:error, {:invalid_ctx, key}}}
          end
      end
    end)
  end

  defp valid_ctx_value?(:rpc_dir, value), do: is_binary(value) and value != ""
  defp valid_ctx_value?(:token, value), do: is_binary(value) and value != ""
  defp valid_ctx_value?(:tools, value), do: is_map(value)
  defp valid_ctx_value?(:max_calls, value), do: is_integer(value) and value > 0
  defp valid_ctx_value?(:max_result_bytes, value), do: is_integer(value) and value > 0
  defp valid_ctx_value?(:max_requests_per_sweep, value), do: is_integer(value) and value > 0
  defp valid_ctx_value?(:max_parallel_rpc, value), do: is_integer(value) and value > 0

  defp resolve_poll_interval(ctx, opts) do
    value =
      Keyword.get(opts, :poll_interval_ms) ||
        Map.get(ctx, :poll_interval_ms) ||
        @default_poll_interval_ms

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, {:invalid_ctx, :poll_interval_ms}}
    end
  end
end
