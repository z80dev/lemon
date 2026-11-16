defmodule LemonCore.AgentRuntime.Provider do
  @moduledoc """
  Shared contract for inspecting and operating on an agent runtime.

  Runtime consumers use core's registry without depending on a particular agent
  product. An agent implements the callbacks it can support and registers itself
  through `LemonCore.AgentRuntime`.

  Every callback is optional. A provider that implements none is equivalent to
  no provider at all: each consumer falls back to its documented response.

  Return shapes preserve existing runtime and control-plane payloads.

  Implementations may retain detailed failures internally, but callbacks used
  by background-command and side-query methods should prefer stable reason
  atoms. The control plane still treats every callback value as untrusted and
  never projects arbitrary reason terms or map fields onto the public wire.
  """

  @type task_id :: String.t()
  @type session_key :: String.t()

  @doc "Bind or unbind a live session user-prompt surface owned by a client connection."
  @callback user_prompt_bind(session_key(), pid(), boolean()) :: :ok | {:error, atom()}

  @doc "Bind a prompt surface with a finite maximum deadline (milliseconds)."
  @callback user_prompt_bind(session_key(), pid(), boolean(), keyword()) ::
              :ok | {:error, atom()}

  @doc "Resolve a pending question for an exact prompt/session/run and bound client."
  @callback user_prompt_resolve(String.t(), session_key(), String.t() | nil, map(), pid()) ::
              :ok | {:error, atom()}

  @doc "All known tasks as `{task_id, record}` pairs."
  @callback list_tasks() :: [{task_id(), map()}]

  @doc "One task: `{:ok, record, events}` when known."
  @callback get_task(task_id()) :: {:ok, map(), [map()]} | term()

  @doc """
  Agent Hub roster of a root session's task subagents (nested included):
  `{:ok, [agent]}` with bounded display fields and no prompts or paths.
  """
  @callback subagents_list(session_key()) :: {:ok, [map()]} | {:error, atom()}

  @doc "Bounded visible transcript of one subagent; `{:error, :not_found}` for foreign IDs."
  @callback subagent_transcript(session_key(), task_id()) :: {:ok, map()} | {:error, atom()}

  @doc "Operator steer/follow-up/revive of one subagent: `{:ok, delivery}`."
  @callback subagent_send(session_key(), task_id(), String.t()) ::
              {:ok, atom()} | {:error, atom()}

  @doc "Operator cancellation of one subagent."
  @callback subagent_cancel(session_key(), task_id()) :: :ok | {:error, atom()}

  @doc """
  Task-list progress for a session, including an `:actionable_count` key.

  Returns `nil` when the session has no task-list state.
  """
  @callback todo_progress(session_key()) :: map() | nil

  @doc "Feature-requirement progress for a working directory."
  @callback feature_progress(Path.t()) :: {:ok, map()} | term()

  @doc "Compacts a live session. `{:error, :session_not_found}` when it is not running."
  @callback compact_session(session_key(), keyword()) :: :ok | {:error, term()}

  @doc "Return a native session's owner PID without calling the session process."
  @callback native_session_owner(String.t()) :: pid() | nil

  @doc "Loads persisted native session messages for replay."
  @callback session_history(session_key(), Path.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Accept a stable-ID steer for an exact live run, acknowledging only after its
  session journal append. A stale run is rejected without starting another run.
  Unknown mutation outcomes must not be retried automatically.
  """
  @callback session_steer(session_key(), String.t(), String.t(), String.t()) ::
              {:ok, %{id: String.t(), accepted_after_turn: non_neg_integer()}}
              | {:error, atom()}

  @doc "Withdraw a journaled steer only while it remains queued and unbound."
  @callback session_withdraw_steer(session_key(), String.t()) :: :ok | {:error, atom()}

  @doc "Read pending, unbound steers from the live session's acceptance journal."
  @callback session_pending_steers(session_key()) :: {:ok, [map()]} | {:error, atom()}

  @doc """
  Materializes the selected native branch's complete todo list, never its cache.
  The revision is `{branch_generation, governing_entry_id}`; stopped sessions
  have generation zero. It is not a cross-session identity or replay cursor.
  """
  @callback session_todos(session_key(), Path.t()) ::
              {:ok, [map()], {non_neg_integer(), String.t() | nil}} | {:error, term()}
  @doc "Read selected-branch recovery input; cwd may be nil when the session is live."
  @callback session_recovery_snapshot(session_key(), Path.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Read at most `limit` native session broadcasts strictly after a versioned cursor.
  Entries contain `:cursor`, stable `:event_id` and `:events` (Core event projections,
  possibly empty). The returned `:cursor` is the last entry's cursor, or the input
  cursor for an empty page; `:has_more` indicates another page.

  Version 1 cursors identify a native owner/selected-branch epoch, not a run or
  global stream. Missing/replaced owners, branch changes and evicted cursors
  return `:cursor_expired`; unsupported versions return `:unsupported_cursor_version`.
  """
  @callback session_event_replay(session_key(), map(), pos_integer()) ::
              {:ok, %{events: [map()], cursor: map(), has_more: boolean()}}
              | {:error, atom()}

  @doc """
  Recover trusted native continuation context when no admitted-command snapshot
  is available. Accepts only a session identity, never a caller-selected path.

  Success includes the original, absolute existing `:cwd` and explicit
  `:task_child` boolean. Optional fields are `:resume` (`LemonCore.ResumeToken`),
  `:tool_policy`, `:profile_id` and runtime-only `:meta`. Managed product contexts
  and delegated children are forbidden; missing, ambiguous or corrupt authority
  returns `:context_unavailable`. Fork parentage alone does not imply a child.
  Live ordinary MCP configuration may be returned for continuation, but must not
  be persisted or exposed on the public wire. Persisted proofs and credentials
  must never be recovered through this callback.
  """
  @callback session_addressing_context(session_key()) ::
              {:ok, map()} | {:error, :context_unavailable | :forbidden}

  @doc "Read redacted process receipts for an exact native session owner."
  @callback session_process_receipts(String.t()) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Bounded summaries of the background processes a session and its live subagents
  own. A session with no live owner has none.
  """
  @callback session_jobs(session_key()) :: {:ok, map()} | {:error, term()}

  @doc """
  One scoped background process with a redacted output tail (`:tail_bytes`).
  Reading must not consume output the owning agent has yet to read.
  """
  @callback session_job(session_key(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Cancel a background process the session itself owns. `{:error, :outcome_unknown}`
  means termination was not confirmed and must not be retried automatically.
  """
  @callback session_job_cancel(session_key(), String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Forks native session state into an independent destination resume mapping."
  @callback session_fork(session_key(), Path.t(), session_key()) :: :ok | {:error, term()}

  @doc """
  Like `c:session_fork/3`, with options. `:entry_id` forks the history ending at
  that entry instead of at the current leaf.
  """
  @callback session_fork(session_key(), Path.t(), session_key(), keyword()) ::
              :ok | {:error, term()}

  @doc "Returns a bounded native tree page with string-keyed entries and branch summaries."
  @callback session_tree(session_key(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Switches the active branch of a native session to an entry. Options:
  `:summarize` (default false) asks a live session to summarize the abandoned
  branch in the background. Refuses a streaming session with `{:error, :busy}`.
  """
  @callback session_navigate(session_key(), Path.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Sets (binary) or clears (nil) the bookmark label of a native session entry."
  @callback session_label(session_key(), Path.t(), String.t(), String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Previews or executes a confirmation-bound native session rewind.

  Options are `:restore_files` (default false), `:dry_run` (default true),
  and `:confirmation_token`. Execution must reject missing or stale previews.
  """
  @callback session_rewind(session_key(), Path.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Explicitly create or reopen an empty native session without submitting a prompt."
  @callback session_create(session_key(), Path.t()) :: {:ok, map()} | {:error, term()}

  @doc "Inspect or explicitly enter, approve, or discard the native planning phase."
  @callback session_plan(session_key(), Path.t(), atom(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Per-category context-window usage of a native session's next request: total
  (provider-reported or estimated), model window, compaction budget, category
  splits and largest contributors. Counts and bounded labels only.
  """
  @callback session_context_usage(session_key(), Path.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Read-only native maintenance plan for an exact positive millisecond cutoff.
  The private plan contains the complete `:candidates` list (kind, id, bytes)
  and runtime-specific revisions. Core retains it; it is never a wire payload.
  """
  @callback session_maintenance_plan(pos_integer()) :: {:ok, map()} | {:error, term()}

  @doc """
  Execute a retained private plan under native admission and directory locks.
  Revalidate the complete candidate set and revisions before mutation. Returns
  archived_count, swept_count and verified, or a confirmation mismatch/partial
  failure. Core consumes confirmation before calling; never retry mutations.
  """
  @callback session_maintenance_execute(map()) :: {:ok, map()} | {:error, term()}

  @doc "Returns the tool policy for a named runtime mode."
  @callback tool_policy(atom()) :: map()

  @doc """
  Resolves a named persona for an internal runtime consumer.

  Returns its system instructions, optional model/role, and enforced tool policy.
  Instructions are private runtime data, not an operator status projection.
  """
  @callback resolve_subagent(Path.t(), String.t()) :: {:ok, map()} | {:error, atom()}

  @doc """
  File-defined slash commands available in a working directory, as
  `%{name, description, argument_hint}` display maps. Templates stay private.
  """
  @callback slash_commands(Path.t()) :: [map()]

  @doc """
  Prepare a user prompt for a local runtime, including live steer/redirect.
  Implementations must preserve internal origins and never discover source-local
  files for a named destination. Detailed templates remain private runtime data.
  """
  @callback prepare_prompt(Path.t() | nil, String.t(), map()) :: String.t()

  @doc "Starts an isolated durable background agent session."
  @callback background_start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Lists durable background sessions, optionally filtered by status."
  @callback background_list(keyword()) :: [map()] | {:error, term()}

  @doc "Returns one background session's sanitized lifecycle summary."
  @callback background_status(String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Returns one completed background session's visible answer."
  @callback background_result(String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Cancels one queued or running background session."
  @callback background_cancel(String.t()) :: :ok | {:error, term()}

  @doc "List background runs owned by one parent session key."
  @callback background_list_scoped(String.t(), keyword()) :: [map()] | {:error, term()}

  @doc "Read background status only when owned by one parent session key."
  @callback background_status_scoped(String.t(), String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Read a background result only when owned by one parent session key."
  @callback background_result_scoped(String.t(), String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Cancel a background run only when owned by one parent session key."
  @callback background_cancel_scoped(String.t(), String.t()) :: :ok | {:error, term()}

  @doc "Answers a bounded no-tools question against a frozen session context."
  @callback side_query(pid() | session_key() | map(), String.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Run-graph record for a run id."
  @callback run_graph(String.t()) :: {:ok, map()} | term()

  @doc "Progress snapshot for a session id and working directory."
  @callback progress_snapshot(String.t() | nil, Path.t() | nil) :: map()

  @doc "Loads extensions: `{:ok, extensions, load_errors, validation_errors}`."
  @callback load_extensions([Path.t()]) :: {:ok, [module()], [term()], [term()]}

  @doc "Provider specs declared by loaded extensions."
  @callback extension_providers([module()]) :: [map()]

  @doc "Display info for loaded extensions."
  @callback extension_info([module()]) :: [map()]

  @doc "Tool-name conflict report for a working directory."
  @callback tool_conflicts(Path.t(), keyword()) :: map()

  @doc "Default extension directories: global first, then project-local."
  @callback extension_dirs(Path.t()) :: [Path.t()]

  @doc "Whether the WASM sidecar supervisor is running."
  @callback wasm_sidecar_running?() :: boolean()

  @doc """
  Read at most 100 unresolved tool intent IDs/names from a native resume journal.
  Unknown outcomes remain unresolved; this read never executes or retries tools.
  """
  @callback interrupted_tool_calls(Path.t(), LemonCore.ResumeToken.t()) ::
              {:ok, [%{id: binary(), name: binary()}]} | {:error, term()}

  @optional_callbacks list_tasks: 0,
                      interrupted_tool_calls: 2,
                      user_prompt_bind: 3,
                      user_prompt_bind: 4,
                      user_prompt_resolve: 5,
                      get_task: 1,
                      subagents_list: 1,
                      subagent_transcript: 2,
                      subagent_send: 3,
                      subagent_cancel: 2,
                      todo_progress: 1,
                      feature_progress: 1,
                      compact_session: 2,
                      native_session_owner: 1,
                      session_history: 2,
                      session_steer: 4,
                      session_withdraw_steer: 2,
                      session_pending_steers: 1,
                      session_todos: 2,
                      session_recovery_snapshot: 2,
                      session_event_replay: 3,
                      session_addressing_context: 1,
                      session_process_receipts: 1,
                      session_jobs: 1,
                      session_job: 3,
                      session_job_cancel: 2,
                      session_fork: 3,
                      session_fork: 4,
                      session_tree: 3,
                      session_navigate: 4,
                      session_label: 4,
                      session_rewind: 4,
                      session_create: 2,
                      session_plan: 4,
                      session_context_usage: 2,
                      session_maintenance_plan: 1,
                      session_maintenance_execute: 1,
                      tool_policy: 1,
                      resolve_subagent: 2,
                      slash_commands: 1,
                      prepare_prompt: 3,
                      background_start: 2,
                      background_list: 1,
                      background_status: 1,
                      background_result: 1,
                      background_cancel: 1,
                      background_list_scoped: 2,
                      background_status_scoped: 2,
                      background_result_scoped: 2,
                      background_cancel_scoped: 2,
                      side_query: 3,
                      run_graph: 1,
                      progress_snapshot: 2,
                      load_extensions: 1,
                      extension_providers: 1,
                      extension_info: 1,
                      tool_conflicts: 2,
                      extension_dirs: 1,
                      wasm_sidecar_running?: 0
end
