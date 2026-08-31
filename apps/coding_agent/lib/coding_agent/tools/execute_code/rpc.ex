defmodule CodingAgent.Tools.ExecuteCode.Rpc do
  @moduledoc """
  The authenticated file-RPC pump shared by isolated and persistent Python
  execution.

  Requests and responses live only in a fresh, private directory. Every request
  must carry the directory's configured token; authentication happens before a
  request can consume a call or result-byte budget or reach tool lookup. A
  completed request is consumed, and responses are published atomically with a
  temporary file followed by rename.

  `serve/2` must run in the process that started the task because `Task.yield/2`
  requires task ownership. Persistent cells use `process_pending/2` to run the
  same parsing, authentication, policy, approval, dispatch, and accounting path.

  ## Result-channel files

  Besides `req-*.json` frames the rpc directory carries two script-authored
  file kinds, both published with the same atomic tmp+rename discipline:

    * `text-<n>.json` — the `text()` result blocks. They are never seen by the
      pump; `read_text_blocks/2` collects them after the run (or after a
      timeout/abort kill), which is what makes deliberate results survive a
      kill that discards partially captured stdout.
    * `notify-<n>.json` — the `notify()` streaming side channel. Every sweep
      consumes them (read + delete, the same hygiene as requests) and forwards
      each message through the ctx's `:on_update` callback as a partial tool
      update, capped at 4 KiB per message and 64 forwarded messages per run
      (the `@notify_*` constants below). The forwarded count rides in the pump
      stats, so the cap spans sweeps and the final drain; anything beyond is
      silently dropped, malformed frames are consumed without being forwarded
      or counted, and a nil callback consumes without forwarding so the files
      can never accumulate. `serve/2` and the RpcServer stop path run one
      notification-only drain after the script task finishes, so a `notify()`
      issued immediately before exit still reaches the conversation; requests
      are deliberately never drained (see `loop/3`).

  ## Concurrency

  One sweep claims requests serially — parse, authenticate, replay-check, and
  call-budget reservation all happen in the sweeping process in ascending id
  order, so accounting stays exact — and then dispatches the claimed,
  policy-allowed tool calls in bounded parallel waves of `:max_parallel_rpc`
  supervised tasks (see `dispatch_claimed/3` for why the tasks are linked and
  which supervisor owns them). Responses stay atomic per id, so ordering
  between requests never matters.

  ## Sweep death, claim markers, the claim ledger, and approvals

  A request becomes dispatch-bound by renaming `req-<id>.json` to an
  in-flight marker `req-<id>.claim` — and dispatch is GATED on that
  publication: the rename must succeed and the published marker must be a
  regular file, or the tool never runs and the id is answered with a
  publication-failure error. `write_response/3` removes the marker once the
  answer is published. Markers that are not regular files (a planted
  directory or symlink at a marker name) prove nothing and are ignored by
  recovery outright.

  A marker lives in the rpc directory, which the script can write — so it is
  durable evidence only against crashes, never against a hostile script: the
  script can delete or replace a marker after the publication gate. The
  marker is therefore only HALF the claim evidence. The other half is the
  host-side claim ledger: when the ctx carries `:on_claim`, the sweeping
  process feeds it one entry per spent call slot — first a `:reserved`
  entry the moment a request passes the replay and call-budget gates, fed
  BEFORE the sweep-local spend itself so no kill can spend a call the
  ledger cannot prove (and before the request's fate branch is even
  taken), then a disposition entry refining it: `:invalid`,
  `:unknown_tool`, or `:denied` for the requests answered inside the
  claim (never dispatched), and `:claimed` for the dispatch-bound path,
  sent BEFORE the marker is published. The
  ledger owner (the RpcServer, which keeps the entries in its own process
  state — memory the script cannot reach) holds them until the sweep's
  fate is decided. Every entry corresponds to exactly one spent call slot,
  which is what makes a sweep that dies holding answered-but-never-
  dispatched requests reconstructible: their stats mutations — the call
  charge, the error or denial, the replay memory — die with the sweep,
  and the reservation entry re-applies them exactly. Dispatch entries
  additionally make the ledger a SUPERSET of the published claims: a
  `:claimed` entry may name an id that was never dispatched (the sweep
  died between the send and the rename — recovery then answers that id
  with a conservative error and one charge), but every id that WAS
  dispatched is in the ledger no matter what the script later did to its
  marker. A script that deletes a marker therefore only destroys the
  on-disk half of its claim's evidence, never the claim itself.

  `recover_orphaned_claims/3` pays the debt of both halves, exactly once per
  id (markers first, ledger entries second, deduplicated by the stats'
  replay memory). Dispatch claims settle from evidence: for an unanswered
  claim, an error response plus the call reservation and error count
  reconstructed in the stats; for a claim beside an already-published
  successful response, the REAL accounting (ok status, result bytes, tool
  usage) restored from the response file and the claim itself — the
  LEDGER's tool name whenever the ledger recorded the id (host-owned beats
  script-writable, so a hostile script cannot forge the recorded tool
  identity by overwriting the marker body), and only the marker's own body
  for ids the ledger never saw. A `:claimed` entry whose marker is gone AND
  whose response is gone marks `accounting_loss: true` in the returned
  stats: the tool may have executed with side effects no surviving
  evidence can account for, so everything in those stats is a lower bound.
  Reservation entries settle exactly instead: a DISPOSITION entry
  (`:invalid`, `:unknown_tool`, `:denied`) was fed before its answer
  write, so a sweep killed in that window answered in the ledger but not
  on disk — settlement re-applies the mutations the dead sweep's stats
  lost (one call, one error or denial, the replay memory) and writes the
  kind's error response, never over a surviving one, because on abort no
  successor sweep exists to replay-refuse the leftover request and the
  server teardown deletes it: a caller blocked on that id must be
  released. An entry still bare `:reserved` (the sweep died between
  feeding the reservation and its fate branch) charges the call and the
  replay memory exactly and counts one error — the error-vs-denial split
  of a branch that never ran is unknowable, and `errors` is the
  conservative choice; the call budget is exact either way — and writes
  no response (a bare entry does not say the sweep answered anything).
  Every sweep starts with recovery, so a killed sweep's claimed ids always end
  answered — answered in writing, never re-dispatched, so a cancelled
  request still never executes its tool, and a replayed id is refused by
  the reconstructed replay memory even when its marker was destroyed. A
  marker whose deletion fails is retried a bounded number of times and
  then left inert (the id is already in the stats' replay memory, so no
  later sweep re-charges it; the workspace teardown owns the rest).

  Approval-requiring claims are additionally cancellation-safe: the approval
  id is allocated at claim time and an unlinked watcher cancels the pending
  prompt when the sweep or the dispatch task dies — after EACH death, exiting
  only when both are gone, so a prompt registered in the window between the
  first cancel and the task's own death is still cancelled (see
  `approval_context/3`). The exact guarantee — and its one boundary — is
  this: prompts are cancelled when the dispatch task dies, and a dispatch
  task has trap_exit forced off on entry so it dies with its sweep. But the
  forcing happens at entry only: nothing stops TOOL code on the approval
  path from re-enabling trap_exit afterwards, and such a task survives its
  sweep's death. The watcher then stays parked on the task until some other
  kill ends it — and until that happens the prompt outlives the script that
  triggered it. This is adversarial tool behavior, not a supported mode; the
  boundary (a trapping task whose late registration is still reaped, but
  only once the task itself dies) is demonstrated by `ExecuteCodeRpcTest`'s
  "a prompt registered after the sweep died cannot be orphaned" test, which
  re-enables trap_exit exactly this way.
  """

  require Logger

  alias CodingAgent.PrivateTmp
  alias CodingAgent.ToolExecutor
  alias CodingAgent.ToolPolicy
  alias CodingAgent.PythonRepl.Telemetry
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @authentication_error "rpc authentication failed"
  @invalid_request_error "invalid rpc request"
  @replay_error "rpc request already processed"
  @unexpected_error "rpc request failed"
  @interrupted_error "rpc dispatch interrupted"
  @claim_failed_error "rpc dispatch could not be marked in-flight"

  @default_max_requests_per_sweep 100
  @default_max_parallel_rpc 4

  # notify() forwarding caps: bytes are per message, the second is per run.
  # Both are deliberately generous for a human-readable progress channel and
  # deliberately small against a hostile flood.
  @notify_message_max_bytes 4_096
  @notify_max_per_run 64
  # A shim-written notify frame is ASCII JSON around one message, so anything
  # this large is not shim-written; it is dropped without being read.
  @notify_file_max_bytes 65_536

  @typedoc """
  The disposition kinds a claim-ledger entry can carry.

  `:reserved` is fed the moment a call slot is spent — before the
  request's fate is known. The disposition kinds refine it: `:invalid`,
  `:unknown_tool`, and `:denied` for requests answered inside the claim
  (never dispatched), `:claimed` for a dispatch-bound request (fed before
  its marker is published).
  """
  @type ledger_entry_kind :: :reserved | :invalid | :unknown_tool | :denied | :claimed

  @typedoc """
  One host-side claim-ledger entry: the ledger owner's evidence that one
  call slot was spent. `:tool` is nil wherever the tool name is unknown or
  unvalidated (`:reserved` and `:invalid`).
  """
  @type ledger_entry :: %{
          required(:kind) => ledger_entry_kind(),
          required(:tool) => String.t() | nil
        }

  # Must match `Config`'s `@default_max_text_bytes`; pinned by tests. Used only
  # when `read_text_blocks/2` is called without an explicit budget.
  @default_max_text_bytes 65_536
  # JSON envelope ({"n": 123, "text": ...}) around a block's text.
  @text_block_envelope_slack 256

  @typedoc """
  One authenticated, policy-allowed request claimed by a sweep, awaiting
  parallel dispatch. `:approval_id` is allocated at claim time so a doomed
  dispatch can cancel its approval prompt without a registration race.
  """
  @type claim :: %{
          required(:id) => integer(),
          required(:tool) => String.t(),
          required(:params) => map(),
          required(:approval?) => boolean(),
          optional(:approval_id) => binary()
        }

  @type ctx :: %{
          required(:tools) => %{String.t() => LemonAgent.Types.AgentTool.t()},
          required(:tool_policy) => map() | nil,
          required(:approval_context) => map() | nil,
          required(:max_calls) => pos_integer(),
          required(:max_result_bytes) => pos_integer(),
          required(:signal) => reference() | nil,
          required(:rpc_dir) => String.t(),
          required(:token) => binary(),
          required(:poll_interval_ms) => pos_integer(),
          optional(:max_requests_per_sweep) => pos_integer(),
          optional(:max_parallel_rpc) => pos_integer(),
          optional(:on_update) => (AgentToolResult.t() -> :ok) | nil,
          # Host-side claim ledger hook: invoked in the sweeping process
          # with (id, kind, tool) — first as a `:reserved` entry the
          # moment a call slot is spent, then with the request's
          # disposition (`:invalid` | `:unknown_tool` | `:denied` for the
          # answered-in-claim paths, `:claimed` before the claim marker is
          # published), so a ledger owner holds reconstructible evidence
          # for every spent call slot independently of the script-writable
          # marker and of the sweep's own stats (see the moduledoc).
          optional(:on_claim) => (integer(), ledger_entry_kind(), String.t() | nil -> any()) | nil
        }

  @type stats :: %{
          calls: non_neg_integer(),
          denied: non_neg_integer(),
          errors: non_neg_integer(),
          bytes: non_neg_integer(),
          tools_used: MapSet.t(String.t()),
          seen_ids: MapSet.t(integer()),
          notify_forwarded: non_neg_integer()
        }

  @doc """
  Returns zeroed pump statistics.
  """
  @spec initial_stats() :: stats()
  def initial_stats do
    %{
      calls: 0,
      denied: 0,
      errors: 0,
      bytes: 0,
      tools_used: MapSet.new(),
      seen_ids: MapSet.new(),
      notify_forwarded: 0
    }
  end

  @doc """
  Serve RPC requests until the script task finishes.

  Each poll processes at most `:max_requests_per_sweep` requests (100 by
  default). Regular request files and symlinks are selected in ascending id
  order; request directories are skipped for workspace teardown. Each selected
  request is answered or renamed into its in-flight claim marker (see the
  moduledoc), so later polls continue through the remaining files without
  reprocessing the head. `notify-*.json` files are consumed and forwarded on
  the same polls, and once more when the task finishes (`drain_notifications/2`).

  Returns `{:ok, task_result, stats}` when the task returned normally, or
  `{:exit, reason, stats}` when it died.
  """
  @spec serve(Task.t(), ctx()) :: {:ok | :exit, term(), stats()}
  def serve(%Task{} = task, ctx) do
    loop(task, ctx, initial_stats())
  end

  @doc """
  Process one bounded snapshot of pending requests and return updated statistics.

  At most `:max_requests_per_sweep` regular request files or symlinks are
  selected in ascending id order (100 by default); directories are skipped.
  Each selected request is answered or renamed into its in-flight claim
  marker, so the next sweep continues with the remaining ids. Authentication
  still occurs after selection, before any budget accounting or tool dispatch.
  Claimed requests are dispatched in parallel waves of at most
  `:max_parallel_rpc` (default #{@default_max_parallel_rpc}) supervised tasks.

  The sweep first recovers claim markers a previous sweep left behind (see
  `recover_orphaned_claims/3`) and then consumes `notify-*.json` frames under
  the stats' per-run forwarding cap. When the ctx carries `:on_claim`, every
  spent call slot is recorded with it — a `:reserved` entry first, fed
  before the slot is spent, then the request's disposition, with
  dispatch-bound claims recorded before their markers are published — the
  persistent server's claim ledger (see its moduledoc).

  This is the shared polling entry point for the persistent-cell RPC server.
  """
  @spec process_pending(ctx(), stats()) :: stats()
  def process_pending(ctx, stats) do
    stats = recover_orphaned_claims(ctx.rpc_dir, stats)

    stats = collect_notifications(ctx, stats)

    {stats, claimed} =
      ctx.rpc_dir
      |> pending_requests(max_requests_per_sweep(ctx))
      |> Enum.reduce({stats, []}, fn {id, path}, {acc, claimed} ->
        claim_request(id, path, ctx, acc, claimed)
      end)

    dispatch_claimed(claimed, ctx, stats)
  end

  @doc """
  Consume and forward any `notify-*.json` frames still on disk.

  The final-drain counterpart of `process_pending/2` for notifications only:
  `serve/2` calls it when the script task finishes and the RpcServer calls it
  on its stop path, so a `notify()` issued immediately before exit is still
  forwarded under the same per-run cap. Requests are deliberately never
  drained — see `loop/3` for why posthumous tool execution is forbidden.
  """
  @spec drain_notifications(ctx(), stats()) :: stats()
  def drain_notifications(ctx, stats) do
    collect_notifications(ctx, stats)
  end

  @doc """
  Answer the in-flight claims a dead sweep left behind.

  Claim evidence has two halves (see the moduledoc): the script-writable
  `req-<id>.claim` marker, and the host-side ledger the ctx's `:on_claim`
  hook feeds — one `%{id => %{kind: kind, tool: tool}}` entry per spent
  call slot. This function recovers BOTH, markers first and ledger entries
  second, deduplicated per id by the stats' replay memory.

  `req-<id>.claim` exists exactly while a claimed, call-budgeted request is
  being dispatched; `write_response/3` removes it as the answer is
  published. Sweeps never overlap, so a marker visible now proves its owning
  sweep is gone and the id can never be answered by it. Only REGULAR files
  count as markers (lstat, the same discipline as text blocks): a planted
  directory or symlink at a marker name is ignored outright — never
  answered, never charged — and left to the workspace teardown.

  Each recovered id receives the response the dead sweep owed — the error
  response, unless a successful response was already published, in which
  case the REAL accounting (ok status, result bytes, tool usage) is
  restored from the response file and the claim itself. The tool identity
  is the LEDGER's name whenever the ledger recorded the id — host-owned
  beats script-writable, so overwriting the marker body cannot forge the
  recorded tool — and the marker's renamed request body only for ids the
  ledger never saw. `stats` recovers the call reservation and the replay
  memory the dead sweep would have recorded, so the call budget, replay
  refusal, and trust classification stay exact across a killed sweep.

  A `:claimed` ledger entry whose marker is gone and whose response is gone
  marks `accounting_loss: true` in the returned stats: the script destroyed
  the on-disk evidence, so the tool's execution and side effects can no
  longer be reconstructed and the stats are a lower bound (consumers must
  treat that conservatively; ExecuteCode forces `trust: :untrusted`).
  Reservation entries settle exactly instead — one call, one error or
  denial, and the replay memory — so a sweep that dies after ANSWERING a
  request without dispatching it (invalid, unknown tool, policy-denied)
  still spends exactly one budget slot. Disposition entries additionally
  write their kind's error response, never over a surviving one: the
  entry was fed before the answer write, and on abort no successor sweep
  exists to replay-refuse the leftover request. A bare `:reserved` entry
  writes no response — it does not say the sweep answered anything; see
  the moduledoc for that fallback.

  Charging is exactly-once: the id is recorded in the stats' replay memory
  when its debt is paid, and a marker that survives its own deletion (the
  deletion is retried a bounded number of times) is treated as cleanup-only
  by every later sweep, so a sticky marker can never re-charge the budget.

  Called at the start of every sweep and by the RpcServer's cancel and
  abnormal-:DOWN paths, where the successor sweep may never run. It answers
  in writing; it never dispatches, so a cancelled request still never
  executes its tool.
  """
  @spec recover_orphaned_claims(String.t(), stats()) :: stats()
  def recover_orphaned_claims(rpc_dir, stats) when is_binary(rpc_dir),
    do: recover_orphaned_claims(rpc_dir, stats, %{})

  @spec recover_orphaned_claims(String.t(), stats(), %{optional(integer()) => ledger_entry()}) ::
          stats()
  def recover_orphaned_claims(rpc_dir, stats, claimed)
      when is_binary(rpc_dir) and is_map(claimed) do
    stats
    |> recover_orphaned_markers(rpc_dir, claimed)
    |> recover_ledger_claims(rpc_dir, claimed)
  end

  # The on-disk half of the claim evidence. A sweep that dies mid-flight
  # leaves one marker per claimed-but-unanswered id; a script that deleted
  # a marker leaves nothing here, which is exactly what the ledger half
  # below exists to cover. The ledger is passed in because it outranks the
  # marker BODY wherever both exist for an id: the body is script-writable,
  # so it can only supply the tool identity for ids the ledger never saw.
  defp recover_orphaned_markers(stats, rpc_dir, claimed) do
    rpc_dir
    |> Path.join("req-*.claim")
    |> Path.wildcard()
    |> Enum.filter(&regular_file?/1)
    |> Enum.map(fn path ->
      case Integer.parse(Path.basename(path, ".claim") |> String.replace_prefix("req-", "")) do
        {id, ""} -> {:marker, id, path}
        _ -> {:invalid, path}
      end
    end)
    |> Enum.sort_by(fn
      {:marker, id, path} -> {0, id, path}
      {:invalid, path} -> {1, path}
    end)
    |> Enum.reduce(stats, fn
      {:marker, id, path}, acc -> recover_claim(rpc_dir, id, path, acc, claimed)
      {:invalid, path}, acc -> consume_request(path) && acc
    end)
  end

  # The host-side half: the entries the ctx's :on_claim ledger recorded for
  # the dead sweep — one per spent call slot. `seen?/2` skips ids the marker
  # pass already paid, so the two halves never double-charge.
  defp recover_ledger_claims(stats, rpc_dir, claimed) do
    claimed
    |> Enum.sort()
    |> Enum.reduce(stats, fn {id, entry}, acc ->
      if seen?(acc, id), do: acc, else: recover_ledger_entry(rpc_dir, id, entry, acc)
    end)
  end

  # A `:claimed` entry is a superset of the published claims, so treat it as
  # claimed fact regardless of what remains on disk: the marker may have
  # been deleted by the script after the publication gate.
  defp recover_ledger_entry(rpc_dir, id, %{kind: :claimed, tool: tool}, stats)
       when is_binary(tool),
       do: recover_ledger_claim(rpc_dir, id, tool, stats)

  # A denied reservation: the disposition entry was fed BEFORE the denial
  # was written, so a sweep killed in that window answered in the ledger
  # but not on disk. Write the denial now — only when no response
  # survives, so the sweep's own answer (with its exact policy reason) is
  # never overwritten — because on abort no successor sweep exists to
  # replay-refuse the leftover request file. The stats debt is exactly one
  # spent call, one denial, and the replay memory; the exact policy reason
  # died with the sweep, so the tool-named fallback the sweep itself uses
  # is the reconstruction.
  defp recover_ledger_entry(rpc_dir, id, %{kind: :denied, tool: tool}, stats) do
    ensure_answered(rpc_dir, id, denied_error(tool))

    stats
    |> Map.update!(:calls, &(&1 + 1))
    |> Map.update!(:denied, &(&1 + 1))
    |> remember_id(id)
  end

  # An error-settled reservation (`:invalid`, `:unknown_tool`): the same
  # fed-before-the-write shape as the denial above — the kind's error is
  # written (only when absent), and the call slot, one error, and the
  # replay memory are charged exactly.
  defp recover_ledger_entry(rpc_dir, id, %{kind: :invalid}, stats) do
    ensure_answered(rpc_dir, id, @invalid_request_error)
    charge_error_reservation(stats, id)
  end

  defp recover_ledger_entry(rpc_dir, id, %{kind: :unknown_tool, tool: tool}, stats) do
    ensure_answered(rpc_dir, id, unknown_tool_error(tool))
    charge_error_reservation(stats, id)
  end

  # A reservation still bare `:reserved` — the sweep died between feeding
  # the entry and its fate branch, including between the feed and the
  # sweep-local spend itself (the window the feed-first ordering in
  # `claim_authenticated/6` closes): the call slot and the replay memory
  # are certain, so charge them exactly. The error-vs-denial split of a
  # branch that never ran is unknowable, and `errors` is the conservative
  # choice — the call budget is exact either way. NO response is written:
  # unlike the disposition kinds, a bare entry does not say the sweep
  # answered anything, so the request file belongs to the successor
  # sweep's replay refusal (or the abort teardown).
  defp recover_ledger_entry(_rpc_dir, id, %{kind: :reserved}, stats),
    do: charge_error_reservation(stats, id)

  # A ledger owner speaking a different contract version must not crash
  # recovery (the server would keep the pre-sweep snapshot and re-open the
  # budget gap this ledger exists to close): fail closed with the
  # reservation charge.
  defp recover_ledger_entry(_rpc_dir, id, _entry, stats),
    do: charge_error_reservation(stats, id)

  # The exact wording of the answered-in-claim errors, shared by the claim
  # path and disposition recovery so a reconstructed answer can never
  # drift from the one a live sweep writes. A denial's policy-specific
  # reason is NOT reconstructible (the policy lives in the ctx, not the
  # entry), so recovery falls back to the tool-named wording the sweep
  # itself uses.
  defp unknown_tool_error(tool_name) when is_binary(tool_name),
    do: "tool '#{tool_name}' is not available inside execute_code scripts"

  defp unknown_tool_error(_tool_name),
    do: "tool is not available inside execute_code scripts"

  defp denied_error(tool_name) when is_binary(tool_name),
    do: "tool '#{tool_name}' denied by policy"

  defp denied_error(_tool_name), do: "rpc tool call denied by policy"

  defp charge_error_reservation(stats, id) do
    stats
    |> Map.update!(:calls, &(&1 + 1))
    |> increment_errors()
    |> remember_id(id)
  end

  defp recover_ledger_claim(rpc_dir, id, tool, stats) do
    case successful_response(rpc_dir, id) do
      {:ok, content} ->
        # The dead sweep published the answer before dying and only the
        # marker was destroyed: the response plus the ledger's tool name
        # restore the real accounting exactly.
        stats
        |> Map.update!(:calls, &(&1 + 1))
        |> Map.update!(:bytes, &(&1 + byte_size(content)))
        |> remember_tool(tool)
        |> remember_id(id)

      :error ->
        # No marker, no response: the script destroyed every on-disk trace
        # of a claim the ledger proves happened. Answer once and charge
        # once, but the tool may have executed with side effects nothing
        # can account for anymore — the stats are a lower bound from here.
        ensure_answered(rpc_dir, id)

        stats
        |> Map.update!(:calls, &(&1 + 1))
        |> increment_errors()
        |> remember_id(id)
        |> Map.put(:accounting_loss, true)
    end
  end

  @doc """
  Consume and process one request id through the complete authenticated path.

  The function is intentionally reusable by a server that owns polling and
  lifecycle itself. Invalid or denied requests are always answered in writing.
  """
  @spec process_request(integer(), ctx(), stats()) :: stats()
  def process_request(id, ctx, stats) when is_integer(id) do
    {stats, claimed} = claim_request(id, request_path(ctx.rpc_dir, id), ctx, stats, [])
    dispatch_claimed(claimed, ctx, stats)
  end

  @doc """
  Read the `text-<n>.json` result blocks a script flushed into `rpc_dir`, in
  ascending block order.

  This runs *after* the script task is over (normally, timed out, or killed):
  blocks are written through per `text()` call, so whatever the script flushed
  before it died is exactly what lands in the tool result. Blocks are left in
  place for the rpc directory's normal teardown.

  The budget charges the ENCODED frame — `byte_size/1` of the file body
  actually read — which is exactly what the shim charged and exactly what the
  size gate admits, so the script-side and host-side accounts can never
  disagree: every in-budget block the shim wrote is delivered, and nothing
  the shim refused ever fits.

  Defensive posture (the files are script-authored): anything that is not a
  regular file — a planted symlink, like the `res-<id>.json` defense — any
  frame larger than the whole byte budget plus its JSON envelope, any
  undecodable body or body whose text is not valid UTF-8, and any block that
  would push the accumulated total past `max_text_bytes` (default
  #{@default_max_text_bytes}) is skipped without crashing.
  """
  @spec read_text_blocks(String.t(), keyword()) :: [String.t()]
  def read_text_blocks(rpc_dir, opts \\ []) when is_binary(rpc_dir) do
    max_bytes = Keyword.get(opts, :max_text_bytes, @default_max_text_bytes)

    {blocks, _bytes} =
      rpc_dir
      |> text_block_paths()
      |> Enum.reduce({[], 0}, fn {_id, path}, {acc, bytes} ->
        case read_text_block(path, bytes, max_bytes) do
          {:ok, text, size} -> {[text | acc], bytes + size}
          :skip -> {acc, bytes}
        end
      end)

    Enum.reverse(blocks)
  end

  @doc false
  @spec authenticated?(map(), binary() | nil) :: boolean()
  def authenticated?(%{"token" => provided}, expected)
      when is_binary(provided) and is_binary(expected) and byte_size(expected) > 0 do
    byte_size(provided) == byte_size(expected) and :crypto.hash_equals(provided, expected)
  end

  def authenticated?(_request, _expected), do: false

  @doc false
  @spec request_path(String.t(), integer()) :: String.t()
  def request_path(rpc_dir, id), do: Path.join(rpc_dir, "req-#{id}.json")

  @doc false
  @spec response_path(String.t(), integer()) :: String.t()
  def response_path(rpc_dir, id), do: Path.join(rpc_dir, "res-#{id}.json")

  defp loop(task, ctx, stats) do
    case Task.yield(task, ctx.poll_interval_ms) do
      {:ok, result} ->
        # Deliberately no final drain of requests: a script blocks until its
        # response file appears, so an unanswered request can only belong to a
        # script that was killed -- and running its tool now would be work
        # nobody is waiting for (and, after an abort, work that was explicitly
        # cancelled). Notifications are the exception: they are
        # fire-and-forget, so the frames flushed just before exit are still
        # forwarded.
        {:ok, result, drain_notifications(ctx, stats)}

      {:exit, reason} ->
        {:exit, reason, drain_notifications(ctx, stats)}

      nil ->
        loop(task, ctx, process_pending(ctx, stats))
    end
  end

  defp pending_requests(rpc_dir, max_requests_per_sweep) do
    rpc_dir
    |> Path.join("req-*.json")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("req-", "")) do
        {id, ""} -> {:request, id, path}
        _ -> {:invalid, path}
      end
    end)
    |> Enum.filter(fn
      {:request, _id, path} -> request_file?(path)
      {:invalid, path} -> request_file?(path)
    end)
    |> Enum.sort_by(fn
      {:request, id, path} -> {0, id, path}
      {:invalid, path} -> {1, path}
    end)
    |> Enum.take(max_requests_per_sweep)
    |> Enum.flat_map(fn
      {:request, id, path} -> [{id, path}]
      {:invalid, path} -> consume_request(path) && []
    end)
  end

  defp request_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] -> true
      _ -> false
    end
  end

  defp max_requests_per_sweep(ctx) do
    case Map.get(ctx, :max_requests_per_sweep, @default_max_requests_per_sweep) do
      max_requests_per_sweep
      when is_integer(max_requests_per_sweep) and max_requests_per_sweep > 0 ->
        max_requests_per_sweep

      _ ->
        @default_max_requests_per_sweep
    end
  end

  defp max_parallel_rpc(ctx) do
    case Map.get(ctx, :max_parallel_rpc, @default_max_parallel_rpc) do
      max_parallel_rpc when is_integer(max_parallel_rpc) and max_parallel_rpc > 0 ->
        max_parallel_rpc

      _ ->
        @default_max_parallel_rpc
    end
  end

  # ==========================================================================
  # Notification side channel (notify-*.json)
  # ==========================================================================

  defp collect_notifications(ctx, stats) do
    frames =
      ctx.rpc_dir
      |> Path.join("notify-*.json")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("notify-", "")) do
          {n, ""} -> {:frame, n, path}
          _ -> {:invalid, path}
        end
      end)
      |> Enum.sort_by(fn
        {:frame, n, path} -> {0, n, path}
        {:invalid, path} -> {1, path}
      end)

    forwarded =
      Enum.reduce(frames, forwarded_notifications(stats), fn
        {:frame, _n, path}, acc ->
          message = read_notification(path)
          # Consume first, always: a notification nobody can forward must still
          # be removed so the directory cannot accumulate them.
          consume_request(path)

          case message do
            # Malformed frames are consumed silently: not forwarded, and they
            # do not spend the per-run forwarding budget.
            nil ->
              acc

            msg when acc < @notify_max_per_run ->
              forward_notification(Map.get(ctx, :on_update), msg)
              acc + 1

            _msg ->
              acc
          end

        {:invalid, path}, acc ->
          consume_request(path)
          acc
      end)

    Map.put(stats, :notify_forwarded, forwarded)
  end

  defp forwarded_notifications(stats), do: Map.get(stats, :notify_forwarded, 0)

  # Reads one notification frame, or nil when it is not a regular file, is
  # larger than anything the shim would write, or does not decode to a
  # `{"msg": binary}` body. Undecodable frames are dropped silently.
  defp read_notification(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @notify_file_max_bytes <-
           File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"msg" => msg}} when is_binary(msg) <- Jason.decode(body) do
      cap_message_bytes(msg, @notify_message_max_bytes)
    else
      _ -> nil
    end
  end

  defp forward_notification(nil, _message), do: :ok

  defp forward_notification(on_update, message) when is_binary(message) do
    # A broken streaming callback must never take a sweep down with it: the
    # notification is advisory, the requests in the same sweep are not.
    on_update.(%AgentToolResult{content: [%TextContent{text: "notify: " <> message}]})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  # Byte-cap on a valid codepoint boundary: python's json.dump escapes
  # non-ASCII by default, so the common case is plain ASCII, but a hand-built
  # frame may end mid-codepoint after binary_part/3.
  defp cap_message_bytes(message, max_bytes) when byte_size(message) <= max_bytes, do: message

  defp cap_message_bytes(message, max_bytes) do
    message |> binary_part(0, max_bytes) |> chomp_invalid_trailing()
  end

  defp chomp_invalid_trailing(part) when byte_size(part) == 0, do: part

  defp chomp_invalid_trailing(part) do
    case :unicode.characters_to_binary(part, :utf8, :utf8) do
      fixed when is_binary(fixed) -> fixed
      _invalid_or_error -> chomp_invalid_trailing(binary_part(part, 0, byte_size(part) - 1))
    end
  end

  # ==========================================================================
  # Text result blocks (text-*.json)
  # ==========================================================================

  defp text_block_paths(rpc_dir) do
    rpc_dir
    |> Path.join("text-*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("text-", "")) do
        {n, ""} -> [{n, path}]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  # The charge is the encoded frame size (`byte_size/1` of the body read),
  # matching the shim's `len(json.dumps(frame))` charge and the lstat size
  # gate above — one currency on both sides of the bridge.
  defp read_text_block(path, accumulated, max_bytes) do
    with {:ok, %File.Stat{type: :regular, size: size}}
         when size <= max_bytes + @text_block_envelope_slack <- File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, text} <- decode_text_block(body),
         :ok <- within_budget(body, accumulated, max_bytes) do
      {:ok, text, byte_size(body)}
    else
      _ -> :skip
    end
  end

  # Only decodable frames whose text is valid UTF-8 count. Shim-written
  # frames always are — the shim normalizes lone surrogates — so this never
  # drops a block the script paid for; a hand-built frame that decodes to
  # non-UTF-8 text could not be re-encoded into the tool result safely.
  defp decode_text_block(body) do
    with {:ok, %{"text" => text}} when is_binary(text) <- Jason.decode(body),
         true <- String.valid?(text) do
      {:ok, text}
    else
      _ -> :error
    end
  end

  defp within_budget(body, accumulated, max_bytes)
       when accumulated + byte_size(body) <= max_bytes,
       do: :ok

  defp within_budget(_body, _accumulated, _max_bytes), do: :error

  # ==========================================================================
  # Claiming (serial, in the sweeping process)
  # ==========================================================================

  # Claiming keeps every stats mutation in the single process that runs the
  # sweep, in ascending request id order. That is what keeps replay detection
  # (`seen?/2`) and the `max_calls` budget exact under parallel dispatch: an id
  # is remembered, and a call slot is reserved, before any task starts, so two
  # concurrent sweeps can never double-dispatch one id and the budget can never
  # be overshot by racing claims. (Sweeps themselves never overlap: serve/2
  # polls sequentially and RpcServer awaits each sweep task before rescheduling.)
  #
  # A request file is consumed only after its fate is durable: answered-in-
  # claim paths write the response first and delete second, and the one path
  # that defers the answer (dispatch) renames the request into its in-flight
  # claim marker — after first recording the claim in the host-side ledger
  # via `:on_claim` — so a sweep that dies mid-flight always leaves enough
  # evidence (marker, ledger, or both) for `recover_orphaned_claims/3` to
  # answer every claimed id, even when the script deletes the marker. The
  # ledger's reservation entry (fed the moment the call slot is spent,
  # before the fate branch) extends the same durability to the answered-in-
  # claim paths: a sweep that dies after ANSWERING such a request leaves a
  # reconstructible record of the spend, so the budget can never re-spend
  # that slot after recovery.
  defp claim_request(id, request, ctx, stats, claimed) do
    if response_present?(response_path(ctx.rpc_dir, id)) do
      consume_request(request)
      {remember_id(stats, id), claimed}
    else
      parsed = parse_request(request)
      authenticate_and_claim(id, request, parsed, ctx, stats, claimed)
    end
  end

  # The in-flight claim marker: the request renamed out of the `req-*.json`
  # namespace at the moment it becomes dispatch-bound. `write_response/3`
  # removes it once the answer is published; any marker that survives proves
  # its sweep died owing that answer.
  defp claim_marker_path(rpc_dir, id), do: Path.join(rpc_dir, "req-#{id}.claim")

  # Publish the in-flight claim marker: the request renamed out of the
  # `req-*.json` namespace at the moment it becomes dispatch-bound, and the
  # published marker must be a REGULAR file — that is the only shape
  # `recover_orphaned_claims/3` trusts on disk, so it is the only shape that
  # may authorize a dispatch. Publication is the gate: when the rename fails
  # (a planted object already sits at the marker name) or the renamed object
  # is not a regular file (a symlinked request), the request is consumed and
  # answered with `@claim_failed_error` — its tool NEVER runs, because a
  # dispatch whose claim no later sweep would recover would strand the id.
  # The already-reserved call is spent, so the answer is an error. The
  # ledger entry fed before this call still stands (superset): a publication
  # failure only ever over-answers conservatively, never under-answers.
  #
  # The published marker itself is script-deletable AFTER this gate — that
  # is precisely why the claim was recorded in the ledger first; see
  # `notify_claim/3` and the moduledoc.
  defp mark_in_flight(rpc_dir, id, request) do
    marker = claim_marker_path(rpc_dir, id)

    case File.rename(request, marker) do
      :ok ->
        case File.lstat(marker) do
          {:ok, %File.Stat{type: :regular}} ->
            :ok

          # A symlinked request renames into a symlinked marker: not a
          # trustworthy claim shape, so it is consumed like any failure.
          _not_regular ->
            consume_request(marker)
            {:error, :not_regular}
        end

      _rename_failed ->
        # A planted object at the marker name (or any rename failure) must
        # never fall back to leaving the request reclaimable: that would
        # re-dispatch a counted call. Consume it and answer the id.
        consume_request(request)
        {:error, :rename}
    end
  end

  # Recovery body of `recover_orphaned_claims/2`: pay one dead claim's debt
  # exactly once. `seen?` is the idempotency gate — the id entered the stats'
  # replay memory when its debt was paid, so a marker that outlived its own
  # deletion (deletion retried, still failing) is cleanup-only from here on.
  defp recover_claim(rpc_dir, id, marker, stats, claimed) do
    if seen?(stats, id) do
      ensure_answered(rpc_dir, id)
      discard_marker(marker)
      stats
    else
      stats =
        case successful_response(rpc_dir, id) do
          {:ok, content} ->
            # The dead sweep died between publishing a successful response
            # and retiring its marker: restore the REAL accounting — the ok
            # status, the result bytes, the tool usage — instead of
            # inventing an error the script never saw. The tool identity is
            # the LEDGER's name when the ledger recorded the id (host-owned
            # beats script-writable: the marker body sits in the rpc
            # directory, where a hostile script can forge it) and the
            # marker's own body only for ids the ledger never saw.
            stats
            |> Map.update!(:calls, &(&1 + 1))
            |> Map.update!(:bytes, &(&1 + byte_size(content)))
            |> remember_tool(ledger_tool(claimed, id, marker))
            |> remember_id(id)

          :error ->
            ensure_answered(rpc_dir, id)

            stats
            |> Map.update!(:calls, &(&1 + 1))
            |> increment_errors()
            |> remember_id(id)
        end

      discard_marker(marker)
      stats
    end
  end

  # The tool identity for a recovered marker: the ledger's name when it has
  # one for the id, else the marker body's own claim. The ledger entry was
  # recorded before the marker was published, so a ledger-covered marker is
  # provably the same claim the host already knows the tool for.
  defp ledger_tool(claimed, id, marker) do
    case claimed do
      %{^id => %{kind: :claimed, tool: tool}} when is_binary(tool) -> tool
      _ledger_never_saw_it -> claimed_tool(marker)
    end
  end

  # The answer a dead sweep owed, written only when nobody answered yet —
  # a surviving response (the sweep's own, with its exact wording) always
  # wins. Defaults to the interrupted error; disposition recovery passes
  # the kind's own message, so a caller blocked on an id whose sweep died
  # between the disposition feed and its answer write is released with
  # the answer the sweep meant to write (on abort there is no successor
  # sweep to replay-refuse the leftover request).
  defp ensure_answered(rpc_dir, id, message \\ @interrupted_error) do
    unless response_present?(response_path(rpc_dir, id)) do
      write_response(rpc_dir, id, %{"id" => id, "ok" => false, "error" => message})
    end

    :ok
  end

  # A successful response the dead sweep published before dying: its content
  # is the accounting evidence the lost stats would have carried.
  defp successful_response(rpc_dir, id) do
    path = response_path(rpc_dir, id)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"ok" => true, "content" => content}} when is_binary(content) <-
           Jason.decode(body) do
      {:ok, content}
    else
      _ -> :error
    end
  end

  # The marker IS the claimed request renamed in place, so it still carries
  # the tool name needed to restore tool-use accounting.
  defp claimed_tool(marker) do
    with {:ok, body} <- File.read(marker),
         {:ok, %{"tool" => tool}} when is_binary(tool) <- Jason.decode(body) do
      tool
    else
      _ -> nil
    end
  end

  defp remember_tool(stats, tool_name) when is_binary(tool_name),
    do: Map.update!(stats, :tools_used, &MapSet.put(&1, tool_name))

  defp remember_tool(stats, _unreadable), do: stats

  # Bounded marker deletion: failures (permissions, type errors) are
  # persistent within a run, so retrying more would only stall the sweep.
  # The id is already in the replay memory by now, so a surviving marker is
  # inert cleanup work for the next sweep and, in the end, the workspace
  # teardown — never a repeat charge.
  @claim_marker_delete_attempts 3

  defp discard_marker(marker) do
    if File.rm(marker) == :ok do
      :ok
    else
      Enum.each(2..@claim_marker_delete_attempts, fn _attempt ->
        _ = File.rm(marker)
      end)

      :ok
    end
  end

  defp regular_file?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

  # Only a regular file published by the atomic rename counts as an answered
  # id. `File.exists?/1` follows symlinks, so a planted `res-<id>.json`
  # symlink must not masquerade as an already-written response and swallow
  # the request; the responder replaces such a link instead of following it.
  defp response_present?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  defp parse_request(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp authenticate_and_claim(id, request, {:ok, body}, ctx, stats, claimed) do
    if authenticated?(body, Map.get(ctx, :token)) do
      safely_claim_authenticated(id, request, body, ctx, stats, claimed)
    else
      authentication_failed(id, request, ctx, stats, claimed)
    end
  end

  defp authenticate_and_claim(id, request, :error, ctx, stats, claimed),
    do: authentication_failed(id, request, ctx, stats, claimed)

  defp authentication_failed(id, request, ctx, stats, claimed) do
    respond_error(ctx, id, @authentication_error)
    consume_request(request)
    maybe_emit_bridge_denial(ctx)
    {%{stats | denied: stats.denied + 1}, claimed}
  end

  defp safely_claim_authenticated(id, request, body, ctx, stats, claimed) do
    claim_authenticated(id, request, body, ctx, stats, claimed)
  rescue
    _error ->
      respond_error(ctx, id, @unexpected_error)
      consume_request(request)
      {stats |> remember_id(id) |> increment_errors(), claimed}
  catch
    _kind, _value ->
      respond_error(ctx, id, @unexpected_error)
      consume_request(request)
      {stats |> remember_id(id) |> increment_errors(), claimed}
  end

  defp claim_authenticated(id, request, body, ctx, stats, claimed) do
    cond do
      seen?(stats, id) ->
        respond_error(ctx, id, @replay_error)
        consume_request(request)
        {increment_errors(stats), claimed}

      stats.calls >= ctx.max_calls ->
        respond_error(
          ctx,
          id,
          "rpc call limit exceeded (max #{ctx.max_calls} calls per script)"
        )

        consume_request(request)
        {stats |> remember_id(id) |> increment_errors(), claimed}

      true ->
        # Feed-first ordering: the reservation entry is enqueued to the
        # ledger owner BEFORE the sweep-local spend runs, so no kill can
        # spend a call slot the ledger cannot prove. The only kill shapes
        # are both exact — dead before the send (nothing happened: no
        # charge, no entry, the request file remains for the successor
        # sweep) and dead after it (entry exists, stats never mutated:
        # settlement charges the bare reservation exactly once). The send
        # enqueues immediately, nothing between it and the spend can raise
        # (`remember_id/2` and `Map.update!/2` are total on the host-owned
        # stats), and a sweep that RETURNS settles its entries by its own
        # stats — the ledger only ever charges a sweep that died. The
        # disposition entries below refine the reservation once the fate
        # branch is known.
        notify_ledger(ctx, id, :reserved, nil)

        stats = stats |> remember_id(id) |> Map.update!(:calls, &(&1 + 1))

        case parse_call(body) do
          {:ok, tool_name, params} ->
            claim_tool(id, request, tool_name, params, ctx, stats, claimed)

          :error ->
            # Fed before the answer write: a sweep that dies past this send
            # settles with the exact disposition, and one that dies before
            # it settles the still-`:reserved` entry (exact call charge,
            # conservative error split).
            notify_ledger(ctx, id, :invalid, nil)
            respond_error(ctx, id, @invalid_request_error)
            consume_request(request)
            {increment_errors(stats), claimed}
        end
    end
  end

  defp parse_call(%{"tool" => tool} = request) when is_binary(tool) do
    case Map.get(request, "params") || %{} do
      params when is_map(params) -> {:ok, tool, params}
      _ -> :error
    end
  end

  defp parse_call(_request), do: :error

  defp claim_tool(id, request, tool_name, params, ctx, stats, claimed) do
    cond do
      not Map.has_key?(ctx.tools, tool_name) ->
        notify_ledger(ctx, id, :unknown_tool, tool_name)
        respond_error(ctx, id, unknown_tool_error(tool_name))
        consume_request(request)
        {increment_errors(stats), claimed}

      denied_by_policy?(ctx.tool_policy, tool_name) ->
        reason =
          ToolPolicy.denial_reason(ctx.tool_policy, tool_name) ||
            denied_error(tool_name)

        notify_ledger(ctx, id, :denied, tool_name)
        respond_error(ctx, id, reason)
        consume_request(request)
        {%{stats | denied: stats.denied + 1}, claimed}

      true ->
        # The reservation entry above is refined to a dispatch claim BEFORE
        # the marker is published (a local `send` enqueues immediately, so
        # a sweep killed anywhere past this point has already delivered its
        # ledger entry). That keeps the ledger a SUPERSET of the published
        # claims — the script can delete or replace the on-disk marker
        # after the gate below, but it cannot un-claim what the ledger
        # already recorded.
        notify_ledger(ctx, id, :claimed, tool_name)

        # Publication is the dispatch gate: the tool runs only behind a
        # published, regular-file claim marker. Any publication failure is
        # answered with `@claim_failed_error` and counted as an error — the
        # call slot was already reserved, and a dispatch whose marker no
        # later sweep would recover would strand the id.
        case mark_in_flight(ctx.rpc_dir, id, request) do
          :ok ->
            claim = %{
              id: id,
              tool: tool_name,
              params: params,
              approval?: approval_required?(ctx, tool_name),
              approval_id: LemonCore.Id.approval_id()
            }

            {stats, [claim | claimed]}

          {:error, _reason} ->
            respond_error(ctx, id, @claim_failed_error)
            consume_request(request)
            {increment_errors(stats), claimed}
        end
    end
  end

  # The host-side claim-ledger hook: one send per entry — the `:reserved`
  # entry the moment a call slot is spent, then the disposition entry
  # (`:invalid`/`:unknown_tool`/`:denied`/`:claimed`) once the request's
  # fate is known. Must stay cheap and never raise into the claiming path;
  # a broken hook is swallowed like a broken notification forwarder — the
  # ledger entry is the load-bearing part.
  defp notify_ledger(ctx, id, kind, tool) do
    case Map.get(ctx, :on_claim) do
      on_claim when is_function(on_claim, 3) ->
        on_claim.(id, kind, tool)
        :ok

      _none ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  defp denied_by_policy?(nil, _tool_name), do: false
  defp denied_by_policy?(policy, tool_name), do: not ToolPolicy.allowed?(policy, tool_name)

  # ==========================================================================
  # Parallel dispatch
  # ==========================================================================

  # Claimed requests are dispatched as supervised tasks in waves of at most
  # `max_parallel_rpc`, awaited by the sweeping process.
  #
  # Supervisor choice: the existing `CodingAgent.TaskSupervisor` already owns
  # every other execute_code task (script task, session facade, RpcServer sweep
  # tasks); these are the same kind of short-lived, isolated work, and a
  # dedicated supervisor would add process-tree surface without changing any
  # failure semantics.
  #
  # Link choice: tasks are started with `Task.Supervisor.async/2` (linked to
  # the sweeping process), not `async_nolink/2`. A killed sweep — abort,
  # caller death, server stop — therefore tears down its in-flight tool tasks
  # exactly like the previous inline execution, leaving no orphaned tool side
  # effects. Its claimed ids are answered by `recover_orphaned_claims/2`, and
  # any approval prompt a killed task left pending is cancelled by that
  # claim's watcher (see `approval_context/3`). The converse (a crashed task
  # killing the sweep) is contained twice: `guarded/1` already converts
  # raises/throws/exits from the tool and approval path into error responses,
  # and RpcServer's sweep containment keeps the previous stats when a sweep
  # dies any other way.
  #
  # Approvals stay on the existing `ToolExecutor.execute_with_approval/4` path,
  # inside each task. That path is function-call based with no process-affine
  # state: `approval_request_fun` (or `LemonCore.ExecApprovals.request/1`)
  # serializes through its own ETS/PubSub store, so each of N concurrent
  # gated calls produces exactly one prompt request — never duplicated, never
  # lost — and a pre-existing approval satisfies concurrent requests without
  # prompting again.
  #
  # Accounting stays serial: only the tool execution (the slow part) is
  # parallel; the result-byte budget check and the atomic response write
  # happen in the sweeping process as each task returns, so two concurrent
  # results cannot both spend the same remaining bytes.
  defp dispatch_claimed([], _ctx, stats), do: stats

  defp dispatch_claimed(claimed, ctx, stats) do
    claimed
    |> Enum.reverse()
    |> Enum.chunk_every(max_parallel_rpc(ctx))
    |> Enum.reduce(stats, fn wave, acc -> run_wave(wave, ctx, acc) end)
  end

  defp run_wave(wave, ctx, stats) do
    sweep_pid = self()

    wave
    |> Enum.map(fn claim ->
      task =
        Task.Supervisor.async(CodingAgent.TaskSupervisor, fn ->
          run_claim(claim, ctx, sweep_pid)
        end)

      {claim, task}
    end)
    |> Enum.reduce(stats, fn {claim, task}, acc -> await_claim(claim, task, ctx, acc) end)
  end

  # Runs in the task process: everything up to (but not including) the
  # result-byte accounting and the response write, both of which stay with the
  # sweeping process.
  defp run_claim(claim, ctx, sweep_pid) do
    # A dispatch task must die with its sweep (the linked teardown above), so
    # it may not trap exits — the flag is forced off on entry, before any
    # tool code runs. `watch_approval/3` relies on this: the task's DOWN is
    # what closes the register-after-cancel window, so a trapping task would
    # leave the watcher waiting forever.
    Process.flag(:trap_exit, false)
    tool = Map.fetch!(ctx.tools, claim.tool)
    inner = fn -> run_inner(tool, claim.id, claim.params, ctx.signal) end

    # The approval layer is wrapped too: nothing on the call path may take the
    # task down, or the script would block forever on a response that is never
    # written.
    guarded(fn ->
      if claim.approval? do
        ToolExecutor.execute_with_approval(
          claim.tool,
          claim.params,
          inner,
          approval_context(ctx.approval_context, claim, sweep_pid)
        )
      else
        inner.()
      end
    end)
    |> normalize(claim.approval?)
  end

  # Cancellation-safe approval context for one dispatch task.
  #
  # The approval id was allocated at claim time (in the sweeping process,
  # before this task existed), so it always names this one prompt: the wrapper
  # hands the id to the request function, and the watcher below cancels that
  # id after EACH monitored death. Prompts die with their dispatch task,
  # which dies with its sweep because trap_exit is forced off on entry —
  # with exactly one boundary, as the moduledoc states: tool code on the
  # approval path that re-enables trap_exit AFTER entry keeps its task
  # (and its prompt) alive past the sweep's death until some other kill
  # ends it; adversarial behavior, not a supported mode, and the watcher
  # still reaps the prompt once that task dies.
  defp approval_context(nil, _claim, _sweep_pid), do: %{}

  defp approval_context(context, claim, sweep_pid) when is_map(context) do
    original = Map.get(context, :approval_request_fun) || (&LemonCore.ExecApprovals.request/1)
    # Test seam (same pattern as :approval_request_fun above): invoked in
    # the watcher after each cancel attempt, so tests can observe the
    # watcher's first cancel and pin cancel-vs-register interleavings.
    on_cancel = Map.get(context, :approval_watcher_on_cancel)
    approval_id = claim.approval_id

    Map.put(context, :approval_request_fun, fn params ->
      task_pid = self()
      watcher = spawn(fn -> watch_approval(approval_id, sweep_pid, task_pid, on_cancel) end)

      try do
        original.(Map.put(params, :approval_id, approval_id))
      after
        # Normal completion: the prompt resolved (or was never registered),
        # so the watcher must not sit around monitoring dead processes.
        Process.exit(watcher, :kill)
      end
    end)
  end

  # Unlinked on purpose: it must survive both the sweeping process and the
  # dispatch task it watches, because either death can orphan a pending
  # approval.
  #
  # Closing the register-after-cancel window (the chosen rule, per the
  # preallocated approval id): the watcher cancels after EVERY death and
  # exits only once both monitored processes are gone. The first death (say,
  # the sweep's) may cancel before the dispatch task's own
  # `ExecApprovals.request/1` has inserted the pending record — the cancel
  # finds nothing. The task is then killed asynchronously and MAY complete
  # that insertion first; because the watcher is still waiting for the task's
  # DOWN, its second cancel runs strictly after the task is dead — after any
  # late registration — and removes the record. Both cancels go through the
  # atomic `ExecApprovals.cancel/2`, so the loser of a race against a user
  # resolution is a `{:error, :not_pending}` no-op and can never disturb a
  # decided approval.
  #
  # This holds because dispatch tasks do not trap exits (run_claim forces the
  # flag off on entry), so a dead sweep reliably kills them; the wrapper's
  # `after` still reaps the watcher on normal completion, and a watcher whose
  # monitored processes all died exits by itself.
  defp watch_approval(approval_id, sweep_pid, task_pid, on_cancel \\ nil) do
    refs = %{
      Process.monitor(sweep_pid) => :sweep,
      Process.monitor(task_pid) => :task
    }

    watch_approval_loop(approval_id, refs, on_cancel)
  end

  defp watch_approval_loop(_approval_id, refs, _on_cancel) when map_size(refs) == 0, do: :ok

  defp watch_approval_loop(approval_id, refs, on_cancel) do
    receive do
      {:DOWN, ref, :process, _pid, _reason} ->
        _ = LemonCore.ExecApprovals.cancel(approval_id, "execute_code dispatch ended")
        if on_cancel, do: on_cancel.()
        watch_approval_loop(approval_id, Map.delete(refs, ref), on_cancel)
    end
  end

  defp await_claim(claim, task, ctx, stats) do
    outcome = await_task(task)

    case outcome do
      {:approval_blocked, phrase} ->
        respond_error(ctx, claim.id, "#{phrase} for '#{claim.tool}'")
        %{stats | denied: stats.denied + 1}

      {:error, message} ->
        respond_error(ctx, claim.id, message)
        increment_errors(stats)

      {:ok, content} ->
        account(claim.id, claim.tool, content, ctx, stats)
    end
  end

  defp await_task(task) do
    case Task.yield(task, :infinity) do
      {:ok, outcome} -> outcome
      {:exit, _reason} -> {:error, @unexpected_error}
    end
  end

  defp approval_required?(%{tool_policy: nil}, _tool_name), do: false
  defp approval_required?(%{approval_context: nil}, _tool_name), do: false

  defp approval_required?(ctx, tool_name),
    do: ToolPolicy.requires_approval?(ctx.tool_policy, tool_name)

  defp account(id, tool_name, content, ctx, stats) do
    size = byte_size(content)
    remaining = ctx.max_result_bytes - stats.bytes

    if size > remaining do
      respond_error(
        ctx,
        id,
        "rpc result byte budget exceeded (result #{size} bytes, #{remaining} bytes remaining of #{ctx.max_result_bytes})"
      )

      increment_errors(stats)
    else
      respond_ok(ctx, id, content)

      %{
        stats
        | bytes: stats.bytes + size,
          tools_used: MapSet.put(stats.tools_used, tool_name)
      }
    end
  end

  defp run_inner(tool, id, params, signal) do
    tool.execute.("exec_code_rpc_#{id}", params, signal, nil)
  end

  # An inner tool that raises or throws must never take the pump down with it:
  # the script gets a ToolError and keeps running.
  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, value -> {:error, "#{kind}: #{inspect(value)}"}
  end

  defp normalize(%AgentToolResult{} = result, approval?) do
    case approval? && approval_block_reason(result.details) do
      phrase when is_binary(phrase) -> {:approval_blocked, phrase}
      _ -> {:ok, content_text(result.content)}
    end
  end

  defp normalize({:ok, %AgentToolResult{} = result}, approval?), do: normalize(result, approval?)
  defp normalize({:ok, text}, _approval?) when is_binary(text), do: {:ok, text}
  defp normalize({:ok, other}, _approval?), do: {:ok, inspect(other)}
  defp normalize({:error, reason}, _approval?) when is_binary(reason), do: {:error, reason}
  defp normalize({:error, reason}, _approval?), do: {:error, inspect(reason)}
  defp normalize(other, _approval?), do: {:ok, inspect(other)}

  defp approval_block_reason(details) when is_map(details) do
    cond do
      Map.get(details, :denied) == true -> "approval denied"
      Map.get(details, :timeout) == true -> "approval timed out"
      Map.has_key?(details, :approval_error) -> "approval failed"
      true -> nil
    end
  end

  defp approval_block_reason(_details), do: nil

  defp maybe_emit_bridge_denial(ctx) do
    if Map.get(ctx, :persistent_repl?) == true, do: Telemetry.bridge_denied(:authentication)
  end

  defp content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %TextContent{text: text} when is_binary(text) -> text
      _ -> "[non-text content omitted]"
    end)
    |> Enum.join("\n")
  end

  defp content_text(_), do: ""

  defp respond_ok(ctx, id, content) do
    write_response(ctx.rpc_dir, id, %{"id" => id, "ok" => true, "content" => content})
  end

  defp respond_error(ctx, id, message) do
    write_response(ctx.rpc_dir, id, %{"id" => id, "ok" => false, "error" => message})
  end

  # The response body is reserved as a private 0600 file (hidden, random
  # name) and published by same-directory rename: a half-written response is
  # never visible under `res-<id>.json`, the published inode is owner-only,
  # and a planted symlink at the final name is replaced, not followed.
  # Publishing also retires the id's in-flight claim marker, if any: from
  # here on, the marker's recovery path (should the sweep die now) treats the
  # id as answered and only cleans up.
  defp write_response(rpc_dir, id, payload) do
    name = "res-#{id}.json"

    try do
      case PrivateTmp.write_file(rpc_dir, name, Jason.encode!(payload)) do
        :ok ->
          discard_claim_marker(rpc_dir, id)

        {:error, reason} ->
          Logger.warning("execute_code rpc response write failed: #{inspect(reason)}")
          :ok
      end
    rescue
      error ->
        Logger.warning("execute_code rpc response write failed: #{Exception.message(error)}")
        :ok
    end
  end

  defp discard_claim_marker(rpc_dir, id) do
    _ = File.rm(claim_marker_path(rpc_dir, id))
    :ok
  end

  # Never recurse through a request path. If selection races with replacement
  # by a directory, File.rm/1 returns :eisdir and the directory remains for
  # workspace teardown.
  defp consume_request(path) do
    _ = File.rm(path)
    :ok
  end

  defp seen?(stats, id), do: MapSet.member?(Map.get(stats, :seen_ids, MapSet.new()), id)

  defp remember_id(stats, id) do
    Map.put(stats, :seen_ids, MapSet.put(Map.get(stats, :seen_ids, MapSet.new()), id))
  end

  defp increment_errors(stats), do: %{stats | errors: stats.errors + 1}
end
