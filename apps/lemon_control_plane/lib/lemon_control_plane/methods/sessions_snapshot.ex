defmodule LemonControlPlane.Methods.SessionsSnapshot do
  @moduledoc """
  Bounded, read-only recovery from existing domain owners.

  `status: "ok"` contains an opaque identity and a snapshot. `status: "retry"`
  contains no snapshot: an owner changed during collection, or expectedIdentity
  no longer matches. Reconciliation compares two complete collections; it is not
  a transaction across owners. There is no durable/global event cursor. Clients
  must fence the selected session/request generation and retry when relevant
  connection events arrive while the request is pending. Never append subsequent
  unsequenced text deltas to a replacement answer; refresh it from this authority.

  Revision is an equality token, not an ordered counter. A live attempt is an
  opaque native execution-instance token; retained attempts use their fixed run
  ID (or nil when no attempt can be authoritatively associated). Unavailable
  domain reads remain unavailable, not an invented empty/idle state. Collections
  report truncation; complete tool receipts take precedence over started rows.

  `continuationFrom` optionally binds an acknowledged run ID and a previously
  accepted identity. `continuation` is true only for that run's canonical terminal
  on the same native session with the old leaf in its full selected journal.
  Live execution tokens must match for the same run; retained-owner handoff may
  replace the token with that run's fixed ID. Revisions and leaves may advance.
  This proves branch continuity, not client selection: clients still fence their
  pre-read projection, events and selection before advancing known-unsent work.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.{ChatHistory, ExecApprovalsGet, NativeSessions}
  alias LemonCore.{AgentRuntime, ExecApprovalStore, RunHistoryStore, RunStore, SessionLifecycle}

  @max_bytes 131_072
  @identity_fields ~w(sessionKey sessionId branchId revision runId attempt)
  @row_fields ~w(id role content timestampMs ok truncated toolCallId toolName title
    arguments phase cancelled durationMs details runId)
  @argument_fields ~w(command query pattern limit offset timeout timeout_ms max_output_chars)
  @detail_fields ~w(status exit_code exitCode truncated timed_out timedOut background
    process_id processId run_id runId session_id sessionId session_key sessionKey
    tool_call_id toolCallId action_id actionId name count total duration_ms durationMs
    cancelled outcome reason execution_duration_ms)
  @approval_action_fields ~w(title plan command_hash commandHash cwd_hash cwdHash env_keys
    checkpoint_hash kind reason authorization_url)
  @todo_fields ~w(id content status priority dependencies)
  @public_key_atoms Map.new(
                      @argument_fields ++
                        @detail_fields ++ @approval_action_fields ++ @todo_fields,
                      &{&1, String.to_atom(&1)}
                    )

  @impl true
  def name, do: "sessions.snapshot"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx) do
    params = params || %{}

    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, limit} <- NativeSessions.integer(params, "limit", 50, 1, 100),
         {:ok, cwd} <- cwd(params),
         :ok <- expected(params["expectedIdentity"]),
         {:ok, continuation} <- continuation(params["continuationFrom"]),
         :ok <- authorize(ctx, key),
         {:ok, first} <- collect(key, cwd, limit, ctx, continuation),
         {:ok, second} <- collect(key, cwd, limit, ctx, continuation),
         :ok <- authorize(ctx, key) do
      cond do
        first != second ->
          retry(key, second["identity"], "snapshot_raced")

        params["expectedIdentity"] not in [nil, second["identity"]] ->
          retry(key, second["identity"], "identity_changed")

        true ->
          {:ok, second}
      end
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  defp cwd(%{"cwd" => _} = params), do: NativeSessions.string(params, "cwd", 4096)
  defp cwd(_), do: {:ok, nil}

  defp expected(nil), do: :ok

  defp expected(value) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(@identity_fields) and
         Enum.all?(value, fn {_k, v} -> is_nil(v) or (is_binary(v) and byte_size(v) <= 1024) end),
       do: :ok,
       else: NativeSessions.invalid("expectedIdentity must be a snapshot identity")
  end

  defp expected(_), do: NativeSessions.invalid("expectedIdentity must be a snapshot identity")

  defp continuation(nil), do: {:ok, nil}

  defp continuation(%{"identity" => identity, "runId" => run_id} = value) do
    with true <- map_size(value) == 2 and is_map(identity),
         :ok <- expected(identity),
         {:ok, ^run_id} <- NativeSessions.string(value, "runId", 1024) do
      {:ok, value}
    else
      _ -> NativeSessions.invalid("continuationFrom must contain a snapshot identity and runId")
    end
  end

  defp continuation(_),
    do: NativeSessions.invalid("continuationFrom must contain a snapshot identity and runId")

  defp authorize(%{auth: %{role: :operator} = auth}, _key) do
    Authorize.authorize(auth, name(), scopes())
  end

  defp authorize(_, _), do: {:error, {:forbidden, "Operator read authorization required", nil}}

  defp collect(key, cwd, limit, ctx, continuation) do
    case SessionLifecycle.fetch(key) do
      {:ok, session} when is_nil(session) or is_map(session) ->
        # Fresh admitted runs have a native owner before their first finalized
        # run creates the durable lifecycle index. That index is not live authority.
        case AgentRuntime.call(:session_recovery_snapshot, [key, cwd], {:error, :unavailable}) do
          {:ok, native} when is_map(native) ->
            compose(key, native, limit, ctx, continuation)

          {:error, :session_not_found} when is_nil(session) ->
            {:error, {:not_found, "Session not found", nil}}

          _ ->
            unavailable()
        end

      _ ->
        unavailable()
    end
  end

  defp compose(key, native, limit, ctx, continuation) do
    entries = native.entries
    {run_id, run, run_status} = current_run(key, native)
    completed = committed_completion(run)
    terminal = is_map(completed)
    streaming = native.streaming and not terminal
    phase = phase(native, completed, streaming, run_status)

    repaired =
      if terminal,
        do: LemonControlPlane.ACP.History.reconcile_answers(entries, [{run_id, run}]),
        else: entries

    rows = ChatHistory.native_messages(repaired, true)
    rows = append_partial(rows, native.partial, run_id, streaming)
    rows = tag_current_turn(rows, run_id)

    event_rows =
      if terminal,
        do: Enum.map(ChatHistory.run_messages(run_id, run), &Map.put(&1, "runId", run_id)),
        else: []

    actions = actions(rows ++ event_rows, run_id, streaming)
    messages = rows |> Enum.take(-limit) |> Enum.map(&snapshot_row/1)
    {messages, messages_cut} = fit(messages, 40_960, true)
    {actions, actions_cut} = actions |> Enum.map(&snapshot_row/1) |> fit(16_384, false)
    approvals = approvals(key, run_id, ctx)
    children = children(key, native.session_id)
    processes = processes(native.session_id)
    todos = todos(key, native.cwd)
    plan = plan(native.plan)
    answer_text = if terminal, do: field(completed, :answer) || "", else: answer(rows)

    answer = %{
      "text" => text(answer_text, 16_384),
      "canonical" => terminal,
      "truncated" => byte_size(safe_text(answer_text)) > 16_384
    }

    identity = %{
      "sessionKey" => key,
      "sessionId" => native.session_id,
      "branchId" => native.branch_id,
      "runId" => run_id,
      "attempt" => Map.get(native, :attempt) || run_id,
      "revision" =>
        digest({native.revision, run_id, run, approvals, children, processes, todos, plan})
    }

    result = %{
      "status" => "ok",
      "sessionKey" => key,
      "identity" => identity,
      "continuation" => continues_run?(continuation, native, identity, terminal),
      "consistency" => %{
        "boundary" => "stable_owner_reads",
        "atomic" => false,
        "eventCursor" => nil,
        "runStatus" => run_status
      },
      "snapshot" => %{
        "phase" => phase,
        "terminal" => terminal,
        "answer" => answer,
        "messages" => messages,
        "messagesTruncated" =>
          messages_cut or length(rows) > limit or Enum.any?(messages, & &1["truncated"]),
        "actions" => actions,
        "actionsTruncated" => actions_cut or Enum.any?(actions, & &1["truncated"]),
        "approvals" => approvals,
        "children" => children,
        "processes" => processes,
        "todos" => todos,
        "plan" => plan
      }
    }

    if byte_size(Jason.encode!(result)) <= @max_bytes, do: {:ok, result}, else: unavailable()
  end

  defp continues_run?(%{"identity" => previous, "runId" => run_id}, native, identity, true) do
    live_attempt = Map.get(native, :attempt)
    retained = Map.get(native, :live) == false and not Map.has_key?(native, :attempt)

    is_binary(previous["sessionId"]) and previous["sessionId"] != "" and
      previous["sessionKey"] == identity["sessionKey"] and
      previous["sessionId"] == identity["sessionId"] and
      is_binary(previous["revision"]) and previous["revision"] != "" and
      run_id == identity["runId"] and
      is_binary(identity["branchId"]) and identity["branchId"] != "" and
      is_binary(identity["attempt"]) and identity["attempt"] != "" and
      ((Map.get(native, :live) == true and is_binary(live_attempt) and live_attempt != "") or
         retained) and
      is_binary(previous["branchId"]) and
      Enum.any?(native.entries, &(field(&1, :id) == previous["branchId"])) and
      (previous["runId"] != run_id or
         (is_binary(previous["attempt"]) and previous["attempt"] != "" and
            (previous["attempt"] == identity["attempt"] or
               (retained and identity["attempt"] == run_id))))
  end

  defp continues_run?(_, _, _, _), do: false

  defp current_run(key, %{run_id: id} = native) when is_binary(id) do
    case RunStore.fetch(id) do
      {:ok, run} when is_map(run) ->
        owned =
          is_nil(field(run, :summary)) or
            (field(run, :session_key) || field(field(run, :summary), :session_key)) == key

        cond do
          not owned ->
            {nil, nil, "unavailable"}

          native.streaming ->
            {id, run, "ok"}

          elem(match_branch_run(native.entries, [{id, run}], native.session_id, key), 0) == id ->
            {id, run, "ok"}

          # An idle live session retains its invocation run_id after rewind.
          # That ID cannot select an answer from the abandoned branch.
          true ->
            current_run(key, Map.delete(native, :run_id))
        end

      {:ok, nil} ->
        if native.streaming,
          do: {id, nil, "unavailable"},
          else: current_run(key, Map.delete(native, :run_id))

      _ ->
        {if(native.streaming, do: id), nil, "unavailable"}
    end
  end

  defp current_run(key, native) do
    case RunHistoryStore.fetch(key, limit: 200) do
      {:ok, runs} -> match_branch_run(native.entries, runs, native.session_id, key)
      _ -> {nil, nil, "unavailable"}
    end
  end

  # Managed user entries bind the logical invocation before execution; event
  # receipt timestamps can legitimately follow the user's creation timestamp.
  defp match_branch_run(entries, runs, native_id, key) do
    user =
      Enum.reduce(entries, nil, fn entry, latest ->
        if field(field(entry, :message), :role) in [:user, "user"], do: entry, else: latest
      end)

    message = field(user, :message)

    case field(message, :lemonRun) do
      %{"id" => id, "sessionKey" => ^key, "sessionId" => ^native_id}
      when is_binary(id) and id != "" ->
        case Enum.filter(runs, fn {run_id, run} ->
               run_id == id and field(field(run, :summary), :session_key) == key
             end) do
          [{^id, run}] -> {id, run, "ok"}
          _ -> {nil, nil, "unknown"}
        end

      nil ->
        if is_map(message) and
             (Map.has_key?(message, "lemonRun") or Map.has_key?(message, :lemonRun)),
           do: {nil, nil, "unknown"},
           else: match_legacy_branch_run(entries, runs)

      _ ->
        {nil, nil, "unknown"}
    end
  end

  # The selected branch, not the latest session run, determines offline identity.
  # Match the exact prompt and start interval just as ACP history reconciliation
  # does; ambiguity is unknown, never an abandoned branch's answer.
  defp match_legacy_branch_run(entries, runs) do
    users = Enum.filter(entries, &(field(field(&1, :message), :role) in [:user, "user"]))

    case Enum.take(users, -2) do
      [] ->
        {nil, nil, "ok"}

      users ->
        user = List.last(users)
        previous = if length(users) == 2, do: entry_ms(hd(users))
        timestamp = entry_ms(user)
        prompt = message_text(field(user, :message))

        matches =
          Enum.filter(runs, fn {_id, run} ->
            started = milliseconds(field(run, :started_at))

            field(field(run, :summary), :prompt) == prompt and is_integer(started) and
              is_integer(timestamp) and started <= timestamp and
              (is_nil(previous) or started > previous)
          end)

        case matches do
          [{id, run}] -> {id, run, "ok"}
          _ -> {nil, nil, "unknown"}
        end
    end
  end

  # RunStore summaries are immutable and published only by synchronous finalize.
  # A malformed completion map is unknown, not proof of a terminal transition.
  defp committed_completion(run) do
    completed = field(field(run, :summary), :completed)
    if is_map(completed) and is_boolean(field(completed, :ok)), do: completed
  end

  defp phase(_native, completed, _streaming, _status) when is_map(completed) do
    cond do
      cancelled?(completed) -> "cancelled"
      field(completed, :ok) == true -> "completed"
      true -> "failed"
    end
  end

  defp phase(_native, _completed, true, _status), do: "running"
  defp phase(%{entries: []}, _completed, false, "ok"), do: "idle"
  defp phase(_, _, _, _), do: "unknown"

  defp cancelled?(completed) do
    error = field(completed, :error)

    field(field(completed, :meta), :cancelled) == true or
      Enum.any?([error, field(error, :reason), field(error, :type)], fn reason ->
        reason in [
          :aborted,
          :cancelled,
          :canceled,
          :acp_cancel,
          "aborted",
          "cancelled",
          "canceled",
          "acp_cancel"
        ]
      end)
  end

  defp append_partial(rows, partial, run_id, true) when is_map(partial) do
    entry = %{type: :message, id: "snapshot:#{run_id}:partial", message: partial}
    rows ++ ChatHistory.native_messages([entry], true)
  end

  defp append_partial(rows, _, _, _), do: rows

  defp tag_current_turn(rows, nil), do: rows

  defp tag_current_turn(rows, run_id) do
    last_user =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _} -> row["role"] == "user" end)
      |> List.last()

    case last_user do
      {_row, index} ->
        rows
        |> Enum.with_index()
        |> Enum.map(fn {row, offset} ->
          if offset >= index, do: Map.put(row, "runId", run_id), else: row
        end)

      nil ->
        rows
    end
  end

  defp actions(rows, run_id, streaming) do
    rows
    |> Enum.filter(&(&1["role"] in ["tool_use", "tool_result"]))
    |> Enum.reduce(%{}, fn row, actions ->
      id = row["toolCallId"]
      old = Map.get(actions, id)

      if old && old["phase"] == "completed" && row["phase"] != "completed",
        do: actions,
        else: Map.put(actions, id, row)
    end)
    |> Map.values()
    |> Enum.sort_by(&(&1["toolCallId"] || ""))
    |> Enum.map(fn row ->
      active_attempt = streaming and is_binary(run_id) and row["runId"] == run_id

      if not active_attempt and row["phase"] == "started",
        do: row |> Map.put("phase", "unknown") |> Map.put("ok", nil),
        else: row
    end)
  end

  defp approvals(key, run_id, %{auth: auth}) do
    if Authorize.authorize(auth, "exec.approvals.get", [:approvals]) == :ok do
      read(fn ->
        now = LemonCore.Clock.now_ms()
        {:ok, pending} = ExecApprovalStore.fetch_pending_list()

        items =
          pending
          |> Enum.filter(fn {_id, p} ->
            expiry = field(p, :expires_at_ms)

            field(p, :session_key) == key and field(p, :run_id) == run_id and
              (is_nil(expiry) or (is_integer(expiry) and expiry > now))
          end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {_id, p} ->
            projected = ExecApprovalsGet.format_pending(p)

            Map.put(
              projected,
              "action",
              public_fields(projected["action"], @approval_action_fields)
            )
          end)

        collection(items, 8_192)
      end)
    else
      %{"status" => "forbidden"}
    end
  end

  defp children(key, owner) do
    case AgentRuntime.call(:list_tasks, [], :unavailable) do
      tasks when is_list(tasks) ->
        items =
          tasks
          |> Enum.filter(fn {_id, record} ->
            (field(record, :session_key) == key and
               field(record, :parent_session_id) == owner) or
              field(record, :parent_session_key) == key
          end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {id, record} ->
            status = field(record, :status)

            %{
              "taskId" => id,
              "runId" => field(record, :run_id),
              "parentRunId" => field(record, :parent_run_id),
              "status" => label(status),
              "terminal" => status in [:completed, :error, :cancelled, :timeout, :aborted],
              "sessionId" => field(record, :session_id),
              "answer" => child_answer(field(record, :result))
            }
          end)

        collection(items, 8_192)

      _ ->
        %{"status" => "unavailable"}
    end
  end

  defp child_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp child_answer(%{"answer" => answer}) when is_binary(answer), do: answer
  defp child_answer(answer) when is_binary(answer), do: answer
  defp child_answer(_), do: nil

  defp processes(owner) do
    case AgentRuntime.call(:session_process_receipts, [owner], {:error, :unavailable}) do
      {:ok, receipts} when is_list(receipts) ->
        items =
          Enum.map(receipts, fn receipt ->
            %{
              "identity" => field(receipt, :identity),
              "classification" => label(field(receipt, :classification)),
              "reason" => label(field(receipt, :reason)),
              "status" => label(field(receipt, :status))
            }
          end)

        collection(items, 8_192)

      _ ->
        %{"status" => "unavailable"}
    end
  end

  defp todos(key, cwd) do
    case AgentRuntime.call(:session_todos, [key, cwd], {:error, :unavailable}) do
      {:ok, items, revision} when is_list(items) ->
        items = Enum.map(items, &public_fields(&1, @todo_fields))
        collection(items, 8_192) |> Map.put("revision", clean_revision(revision))

      _ ->
        %{"status" => "unavailable"}
    end
  end

  defp clean_revision({generation, entry}),
    do: [generation, if(is_binary(entry), do: text(entry, 1024))]

  defp clean_revision(_), do: nil

  defp plan(value) when is_map(value) do
    content = field(value, :content)

    if is_nil(content) and not is_nil(field(value, :path)) do
      %{"status" => "unavailable"}
    else
      %{
        "status" => "ok",
        "value" => %{
          "mode" => field(value, :mode),
          "content" => if(is_binary(content), do: text(content, 8_192)),
          "truncated" => is_binary(content) and byte_size(safe_text(content)) > 8_192
        }
      }
    end
  end

  defp plan(_), do: %{"status" => "unavailable"}

  defp collection(items, budget) do
    projected = items |> Enum.take(100) |> Enum.map(&clean(&1, 0))
    {bounded, cut} = fit(projected, budget, false)

    %{
      "status" => "ok",
      "items" => bounded,
      "truncated" => cut or length(items) > 100 or Enum.any?(items, &clipped?/1)
    }
  end

  defp fit(items, budget, newest) do
    ordered = if newest, do: Enum.reverse(items), else: items

    {kept, _left, cut} =
      Enum.reduce(ordered, {[], budget - 2, false}, fn item, {kept, left, cut} ->
        size = byte_size(Jason.encode!(item)) + 1
        if size <= left, do: {[item | kept], left - size, cut}, else: {kept, left, true}
      end)

    {if(newest, do: kept, else: Enum.reverse(kept)), cut}
  end

  defp snapshot_row(row) do
    public =
      row
      |> Map.take(@row_fields)
      |> Map.put("arguments", public_fields(row["arguments"], @argument_fields))
      |> Map.put("details", public_fields(row["details"], @detail_fields))

    projected = clean(public, 0)
    Map.put(projected, "truncated", row["truncated"] == true or clipped?(public))
  end

  defp public_fields(value, fields) when is_map(value) do
    Enum.flat_map(fields, fn key ->
      found =
        case Map.fetch(value, key) do
          :error -> Map.fetch(value, Map.fetch!(@public_key_atoms, key))
          present -> present
        end

      case found do
        {:ok, item} -> [{key, public_scalar(item)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp public_fields(_, _), do: %{}

  defp public_scalar(value) when is_binary(value) or is_number(value) or is_atom(value), do: value

  defp public_scalar(value) when is_list(value),
    do: Enum.map(Enum.take(value, 100), &public_scalar/1)

  defp public_scalar(_), do: nil

  defp clipped?(value) when is_binary(value), do: byte_size(safe_text(value)) > 4_096

  defp clipped?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, item} -> clipped?(item) end)

  defp clipped?(value) when is_list(value),
    do: length(value) > 100 or Enum.any?(value, &clipped?/1)

  defp clipped?(_), do: false

  defp clean(_, depth) when depth > 6, do: nil

  defp clean(value, depth) when is_map(value) do
    value
    |> Enum.reject(fn {key, _} ->
      to_string(key) in [
        "__struct__",
        "path",
        "cwd",
        "owner",
        "pid",
        "thinking",
        "state",
        "config",
        "callback"
      ]
    end)
    |> Enum.take(40)
    |> Map.new(fn {key, value} ->
      key = to_string(key)

      {key,
       if(LemonCore.Redact.sensitive_key?(key), do: "[REDACTED]", else: clean(value, depth + 1))}
    end)
  end

  defp clean(value, depth) when is_list(value),
    do: value |> Enum.take(100) |> Enum.map(&clean(&1, depth + 1))

  defp clean(value, _) when is_binary(value), do: text(value, 4_096)
  defp clean(value, _) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp clean(value, _) when is_atom(value), do: Atom.to_string(value)
  defp clean(_, _), do: nil

  defp answer(rows) do
    # A newly selected user turn may not have produced any assistant text yet.
    # Never present the previous turn's answer as this attempt's answer-so-far.
    rows
    |> Enum.reverse()
    |> Enum.take_while(&(&1["role"] != "user"))
    |> Enum.find(&(&1["role"] == "assistant"))
    |> field(:content)
    |> then(&(&1 || ""))
  end

  defp message_text(message) do
    case field(message, :content) do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        blocks
        |> Enum.filter(&(field(&1, :type) in [:text, "text"]))
        |> Enum.map(&(field(&1, :text) || ""))
        |> Enum.join("\n")

      _ ->
        ""
    end
  end

  defp field(value, key) when is_map(value),
    do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp field(_, _), do: nil

  defp entry_ms(entry),
    do: milliseconds(field(field(entry, :message), :timestamp) || field(entry, :timestamp))

  defp milliseconds(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp milliseconds(value) when is_integer(value) and value > 0 and value < 100_000_000_000,
    do: value * 1000

  defp milliseconds(value) when is_integer(value), do: value
  defp milliseconds(_), do: nil
  defp label(nil), do: nil
  defp label(value) when is_atom(value), do: Atom.to_string(value)
  defp label(value) when is_binary(value), do: text(value, 128)
  defp label(_), do: "unknown"
  defp safe_text(value) when is_binary(value), do: LemonCore.Redact.text(value)
  defp safe_text(_), do: ""
  defp text(value, limit), do: value |> safe_text() |> String.slice(0, limit) |> clip(limit)
  defp clip(value, limit) when byte_size(value) <= limit, do: value

  defp clip(value, limit),
    do:
      value
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, fn char, {chars, size} ->
        if size + byte_size(char) <= limit,
          do: {:cont, {[char | chars], size + byte_size(char)}},
          else: {:halt, {chars, size}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

  defp digest(value),
    do:
      value
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp retry(key, identity, reason),
    do:
      {:ok,
       %{
         "status" => "retry",
         "sessionKey" => key,
         "identity" => identity,
         "reason" => reason,
         "retrySafe" => true
       }}

  defp unavailable, do: {:error, {:unavailable, "Session snapshot authority unavailable", nil}}

  defp read(fun) do
    fun.()
  rescue
    _ -> %{"status" => "unavailable"}
  catch
    _, _ -> %{"status" => "unavailable"}
  end
end
