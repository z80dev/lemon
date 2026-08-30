defmodule LemonCore.SessionLifecycle do
  @moduledoc """
  Shared session lifecycle service for operator surfaces.

  The service composes the canonical run history, chat state, and policy stores
  rather than creating a second conversation store. It adds bounded
  search/listing, title/pin/archive metadata, redacted portable exports, and a
  confirmation-bound prune flow.

  Session discovery ignores malformed legacy index rows so one damaged record
  cannot hide otherwise valid sessions from operator surfaces.

  Pruning is intentionally guarded: previews are dry-run by default, archived
  sessions are the default (and safest) candidate set, pinned sessions are
  excluded unless explicitly requested, and execution requires the token from
  a preview of the exact current candidate set.
  """

  alias LemonCore.{ChatStateStore, PolicyStore, RunStore, SessionMetadataStore}
  alias LemonCore.Doctor.SupportBundle

  @default_limit 100
  @max_limit 500
  @default_history_limit 50
  @max_history_limit 200
  @max_export_bytes 750_000
  @max_export_text_bytes 16_000
  @max_export_collection_items 100
  @max_export_depth 6
  @export_version 1
  @prune_version 1
  @sensitive_key_fragments ~w(api_key apikey authorization bearer credential master_key oauth password private_key secret token wallet_key)

  @type session_row :: %{
          session_key: String.t(),
          agent_id: String.t() | nil,
          origin: atom() | String.t(),
          created_at_ms: integer() | nil,
          updated_at_ms: integer() | nil,
          run_count: non_neg_integer(),
          title: String.t() | nil,
          pinned: boolean(),
          archived: boolean(),
          metadata_updated_at_ms: integer() | nil
        }

  @doc "List durable sessions with bounded lifecycle filters and text search."
  @spec list(keyword()) :: %{
          sessions: [session_row()],
          total: non_neg_integer(),
          matched: non_neg_integer()
        }
  def list(opts \\ []) do
    limit = bounded_integer(Keyword.get(opts, :limit), @default_limit, 1, @max_limit)
    offset = bounded_integer(Keyword.get(opts, :offset), 0, 0, 1_000_000)
    query = normalize_query(Keyword.get(opts, :query))

    all_sessions = all_sessions()

    sessions =
      all_sessions
      |> filter_equal(:agent_id, Keyword.get(opts, :agent_id))
      |> filter_boolean(:pinned, Keyword.get(opts, :pinned, :all))
      |> filter_boolean(:archived, Keyword.get(opts, :archived, :all))
      |> filter_query(query, opts)
      |> Enum.sort_by(fn row -> {not row.pinned, -(row.updated_at_ms || 0)} end)

    matched = length(sessions)

    %{
      sessions: sessions |> Enum.drop(offset) |> Enum.take(limit),
      total: length(all_sessions),
      matched: matched
    }
  rescue
    _ -> %{sessions: [], total: 0, matched: 0}
  catch
    :exit, _ -> %{sessions: [], total: 0, matched: 0}
  end

  @doc "Fetch one durable session row, or `nil` when the session is unknown."
  @spec get(String.t()) :: session_row() | nil
  def get(session_key) when is_binary(session_key) do
    RunStore.list_sessions()
    |> Enum.find_value(fn
      {^session_key, session} when is_map(session) -> merge_metadata(session)
      {_key, %{session_key: ^session_key} = session} -> merge_metadata(session)
      _other -> nil
    end)
  end

  @doc "Patch title, pin, or archive state for an existing durable session."
  @spec patch(String.t(), map()) :: {:ok, session_row()} | {:error, term()}
  def patch(session_key, attrs) when is_binary(session_key) and is_map(attrs) do
    if get(session_key) do
      with {:ok, _metadata} <- SessionMetadataStore.patch(session_key, attrs),
           %{} = session <- get(session_key) do
        {:ok, session}
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc "Return structured run history suitable for chat resume or inspection."
  @spec history(String.t(), keyword()) :: [map()]
  def history(session_key, opts \\ []) when is_binary(session_key) do
    limit =
      bounded_integer(Keyword.get(opts, :limit), @default_history_limit, 1, @max_history_limit)

    redact? = Keyword.get(opts, :redact, true) != false

    RunStore.history(session_key, limit: limit)
    |> Enum.map(fn {run_id, data} -> format_run(run_id, data, redact?) end)
    |> Enum.sort_by(&(&1.started_at_ms || 0), :asc)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Build an always-redacted JSON or Markdown export with integrity metadata."
  @spec export(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(session_key, opts \\ []) when is_binary(session_key) do
    with %{} = session <- get(session_key),
         {:ok, format} <- normalize_export_format(Keyword.get(opts, :format, :json)) do
      runs = history(session_key, limit: @max_history_limit, redact: true)
      exported_at_ms = System.system_time(:millisecond)

      {payload, content, omitted_run_count} =
        fit_export(session, runs, exported_at_ms, format)

      digest = sha256(content)

      {:ok,
       %{
         format: format,
         content: content,
         sha256: digest,
         filename: export_filename(session_key, format),
         bytes: byte_size(content),
         run_count: length(payload["runs"]),
         available_run_count: length(runs),
         omitted_run_count: omitted_run_count,
         redacted: true,
         cleanup: export_cleanup(omitted_run_count),
         exported_at_ms: exported_at_ms
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Preview or execute a confirmation-bound stale-session prune."
  @spec prune(keyword()) :: {:ok, map()} | {:error, term()}
  def prune(opts) when is_list(opts) do
    with {:ok, older_than_ms} <- require_timestamp(Keyword.get(opts, :older_than_ms)) do
      archived_only = Keyword.get(opts, :archived_only, true) != false
      include_pinned = Keyword.get(opts, :include_pinned, false) == true
      dry_run = Keyword.get(opts, :dry_run, true) != false

      candidates = prune_candidates(older_than_ms, archived_only, include_pinned)
      token = prune_token(older_than_ms, archived_only, include_pinned, candidates)

      if dry_run do
        {:ok,
         prune_result(candidates, token, older_than_ms, archived_only, include_pinned, true, [])}
      else
        execute_prune(
          candidates,
          token,
          Keyword.get(opts, :confirm_token),
          older_than_ms,
          archived_only,
          include_pinned
        )
      end
    end
  end

  @doc "Delete all core-owned state for one session and verify it is gone."
  @spec delete(String.t()) :: {:ok, map()} | {:error, term()}
  def delete(session_key) when is_binary(session_key), do: delete(session_key, [])

  @doc false
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(session_key, opts) when is_binary(session_key) and is_list(opts) do
    existed = get(session_key) != nil
    run_delete_fun = Keyword.get(opts, :run_delete_fun, &RunStore.delete_session/1)
    canonical_verify_fun = Keyword.get(opts, :canonical_verify_fun, &verify_canonical_deleted/1)

    snapshots = %{
      chat: ChatStateStore.get(session_key),
      policy: PolicyStore.get_session(session_key),
      metadata: SessionMetadataStore.fetch(session_key)
    }

    result =
      with :ok <- normalize_delete_result(ChatStateStore.delete(session_key)),
           :ok <- normalize_delete_result(PolicyStore.delete_session(session_key)),
           :ok <- normalize_delete_result(SessionMetadataStore.delete(session_key)),
           :ok <- verify_ancillary_deleted(session_key),
           :ok <- normalize_delete_result(run_delete_fun.(session_key)),
           :ok <- canonical_verify_fun.(session_key) do
        {:ok, %{session_key: session_key, existed: existed, verified: true}}
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        # Canonical run deletion is the final mutation. If that commit or its
        # verification fails, we can restore the ancillary snapshots, but we
        # deliberately do not claim the run history itself was recoverable.
        restore_ancillary_state(session_key, snapshots)
        {:error, reason}
    end
  end

  defp all_sessions do
    RunStore.list_sessions()
    |> Enum.flat_map(fn
      {_key, session} when is_map(session) ->
        case read(session, :session_key) do
          session_key when is_binary(session_key) and session_key != "" ->
            [merge_metadata(session)]

          _invalid_or_legacy_row ->
            []
        end

      _other ->
        []
    end)
  end

  defp merge_metadata(session) do
    session_key = read(session, :session_key)
    metadata = SessionMetadataStore.get(session_key)

    %{
      session_key: session_key,
      agent_id: read(session, :agent_id),
      origin: read(session, :origin) || :unknown,
      created_at_ms: read(session, :created_at_ms),
      updated_at_ms: read(session, :updated_at_ms),
      run_count: integer_or_zero(read(session, :run_count)),
      title: metadata.title,
      pinned: metadata.pinned,
      archived: metadata.archived,
      metadata_updated_at_ms:
        if(
          metadata.updated_at_ms == metadata.created_at_ms and metadata.title == nil and
            not metadata.pinned and not metadata.archived,
          do: nil,
          else: metadata.updated_at_ms
        )
    }
  end

  defp filter_equal(rows, _field, nil), do: rows
  defp filter_equal(rows, _field, ""), do: rows

  defp filter_equal(rows, field, expected),
    do: Enum.filter(rows, &(Map.get(&1, field) == expected))

  defp filter_boolean(rows, _field, value) when value in [:all, nil], do: rows

  defp filter_boolean(rows, field, value) when is_boolean(value),
    do: Enum.filter(rows, &(Map.get(&1, field) == value))

  defp filter_boolean(rows, _field, _value), do: rows

  defp filter_query(rows, nil, _opts), do: rows

  defp filter_query(rows, query, opts) do
    history_limit =
      bounded_integer(Keyword.get(opts, :search_history_limit), 25, 1, @default_history_limit)

    Enum.filter(rows, fn row ->
      row_text =
        [row.session_key, row.agent_id, row.origin, row.title]
        |> Enum.reject(&is_nil/1)
        |> Enum.map_join("\n", &to_string/1)
        |> String.downcase()

      String.contains?(row_text, query) or history_matches?(row.session_key, query, history_limit)
    end)
  end

  defp history_matches?(session_key, query, limit) do
    RunStore.history(session_key, limit: limit)
    |> Enum.any?(fn {_run_id, data} ->
      summary = read(data, :summary) || %{}
      completed = read(summary, :completed) || %{}

      [read(summary, :prompt), read(completed, :answer)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map_join("\n", &redact_text/1)
      |> String.downcase()
      |> String.contains?(query)
    end)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp format_run(run_id, data, redact?) do
    summary = read(data, :summary) || %{}
    completed = read(summary, :completed) || %{}
    events = normalize_list(read(data, :events))

    %{
      run_id: to_string(run_id),
      started_at_ms: read(data, :started_at) || read(summary, :started_at),
      engine: read(summary, :engine),
      prompt: maybe_redact(read(summary, :prompt), redact?),
      answer: maybe_redact(read(completed, :answer), redact?),
      ok: read(completed, :ok),
      error: sanitize_term(read(completed, :error), redact?),
      duration_ms: read(summary, :duration_ms),
      tools: extract_tools(events, redact?),
      event_count: length(events)
    }
  end

  defp extract_tools(events, redact?) do
    events
    |> Enum.filter(&action_event?/1)
    |> Enum.take(200)
    |> Enum.map(fn event ->
      action = read(event, :action) || %{}

      %{
        title: maybe_redact(read(action, :title), redact?),
        kind: stringify(read(action, :kind)),
        phase: stringify(read(event, :phase)),
        ok: read(event, :ok),
        detail: sanitize_term(read(action, :detail), redact?),
        message: maybe_redact(read(event, :message), redact?)
      }
    end)
  end

  defp action_event?(event) when is_map(event),
    do: read(event, :__event__) == :action_event or is_map(read(event, :action))

  defp action_event?(_event), do: false

  defp export_session(session) do
    %{
      "sessionKey" => session.session_key,
      "agentId" => session.agent_id,
      "origin" => stringify(session.origin),
      "title" => maybe_redact(session.title, true),
      "pinned" => session.pinned,
      "archived" => session.archived,
      "createdAtMs" => session.created_at_ms,
      "updatedAtMs" => session.updated_at_ms,
      "runCount" => session.run_count
    }
  end

  defp export_run(run) do
    %{
      "runId" => run.run_id,
      "startedAtMs" => run.started_at_ms,
      "engine" => run.engine,
      "prompt" => run.prompt,
      "answer" => run.answer,
      "ok" => run.ok,
      "error" => run.error,
      "durationMs" => run.duration_ms,
      "tools" => Enum.map(run.tools, &stringify_keys/1),
      "eventCount" => run.event_count
    }
  end

  defp encode_export(payload, :json), do: Jason.encode!(payload, pretty: true) <> "\n"

  defp encode_export(payload, :markdown) do
    session = payload["session"]
    title = session["title"] || session["sessionKey"]

    runs =
      payload["runs"]
      |> Enum.map_join("\n\n", fn run ->
        tools =
          run["tools"]
          |> Enum.map_join("\n", fn tool ->
            "- `#{markdown_escape(tool["kind"] || "tool")}` #{markdown_escape(tool["title"] || "Tool call")} (#{markdown_escape(tool["phase"] || "unknown")})"
          end)

        """
        ## Run #{markdown_escape(run["runId"])}

        **Prompt**

        #{markdown_block(run["prompt"])}

        **Answer**

        #{markdown_block(run["answer"])}

        **Tools**

        #{if tools == "", do: "_No tool calls recorded._", else: tools}
        """
        |> String.trim()
      end)

    """
    # #{markdown_escape(title)}

    - Session: `#{markdown_escape(session["sessionKey"])}`
    - Agent: `#{markdown_escape(session["agentId"] || "unknown")}`
    - Runs: #{length(payload["runs"])}
    - Redacted export: yes

    #{runs}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp fit_export(session, runs, exported_at_ms, format) do
    do_fit_export(session, Enum.map(runs, &export_run/1), exported_at_ms, format, 0)
  end

  defp do_fit_export(session, runs, exported_at_ms, format, omitted_run_count) do
    payload = %{
      "version" => @export_version,
      "exportedAtMs" => exported_at_ms,
      "redacted" => true,
      "cleanup" => export_cleanup(omitted_run_count),
      "session" => export_session(session),
      "runs" => runs
    }

    content = encode_export(payload, format)

    if byte_size(content) <= @max_export_bytes or runs == [] do
      {payload, content, omitted_run_count}
    else
      do_fit_export(session, tl(runs), exported_at_ms, format, omitted_run_count + 1)
    end
  end

  defp prune_candidates(older_than_ms, archived_only, include_pinned) do
    all_sessions()
    |> filter_boolean(:archived, if(archived_only, do: true, else: :all))
    |> Enum.filter(fn row ->
      is_integer(row.updated_at_ms) and row.updated_at_ms < older_than_ms
    end)
    |> Enum.filter(fn row -> include_pinned or not row.pinned end)
    |> Enum.sort_by(& &1.session_key)
  end

  defp prune_token(older_than_ms, archived_only, include_pinned, candidates) do
    payload =
      {@prune_version, older_than_ms, archived_only, include_pinned,
       Enum.map(candidates, fn row ->
         {row.session_key, row.updated_at_ms, row.metadata_updated_at_ms, row.title, row.pinned,
          row.archived}
       end)}

    payload |> :erlang.term_to_binary() |> sha256()
  end

  defp execute_prune(_candidates, _token, confirm, _older, _archived, _pinned)
       when not is_binary(confirm) or confirm == "",
       do: {:error, :confirmation_required}

  defp execute_prune(candidates, token, confirm, older_than_ms, archived_only, include_pinned) do
    if secure_equal?(token, confirm) do
      {deleted, failures} =
        Enum.reduce(candidates, {[], []}, fn row, {deleted, failures} ->
          case delete(row.session_key) do
            {:ok, _} ->
              {[row.session_key | deleted], failures}

            {:error, reason} ->
              {deleted, [%{session_key: row.session_key, reason: reason} | failures]}
          end
        end)

      result =
        prune_result(
          candidates,
          token,
          older_than_ms,
          archived_only,
          include_pinned,
          false,
          Enum.reverse(deleted)
        )
        |> Map.put(:failures, Enum.reverse(failures))

      if failures == [], do: {:ok, result}, else: {:error, {:partial_failure, result}}
    else
      {:error, :confirmation_mismatch}
    end
  end

  defp prune_result(
         candidates,
         token,
         older_than_ms,
         archived_only,
         include_pinned,
         dry_run,
         deleted
       ) do
    %{
      dry_run: dry_run,
      older_than_ms: older_than_ms,
      archived_only: archived_only,
      include_pinned: include_pinned,
      confirmation_token: token,
      candidate_session_keys: Enum.map(candidates, & &1.session_key),
      candidate_count: length(candidates),
      deleted_session_keys: deleted,
      deleted_count: length(deleted),
      verified: not dry_run and length(deleted) == length(candidates)
    }
  end

  defp verify_ancillary_deleted(session_key) do
    chat_gone? = is_nil(ChatStateStore.get(session_key))
    policy_gone? = is_nil(PolicyStore.get_session(session_key))
    metadata_gone? = default_metadata?(SessionMetadataStore.get(session_key))

    if chat_gone? and policy_gone? and metadata_gone? do
      :ok
    else
      {:error, :ancillary_deletion_not_verified}
    end
  end

  defp verify_canonical_deleted(session_key) do
    if get(session_key) == nil and RunStore.history(session_key, limit: 1) == [] do
      :ok
    else
      {:error, :canonical_deletion_not_verified}
    end
  end

  defp default_metadata?(metadata),
    do: metadata.title == nil and not metadata.pinned and not metadata.archived

  defp restore_ancillary_state(session_key, snapshots) do
    case snapshots.chat do
      nil -> :ok
      state -> ChatStateStore.put(session_key, state)
    end

    case snapshots.policy do
      nil -> :ok
      policy -> PolicyStore.put_session(session_key, policy)
    end

    case snapshots.metadata do
      nil -> :ok
      metadata -> SessionMetadataStore.restore(metadata)
    end

    :ok
  end

  defp normalize_delete_result(:ok), do: :ok
  defp normalize_delete_result({:error, reason}), do: {:error, reason}
  defp normalize_delete_result(other), do: {:error, {:unexpected_delete_result, other}}

  defp sanitize_term(value, false), do: value
  defp sanitize_term(value, true), do: sanitize_redacted(value, 0)

  defp sanitize_redacted(_value, depth) when depth >= @max_export_depth,
    do: "[OMITTED: depth limit]"

  defp sanitize_redacted(nil, _depth), do: nil

  defp sanitize_redacted(value, _depth) when is_binary(value),
    do: value |> redact_text() |> truncate_export_text()

  defp sanitize_redacted(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_redacted(value, _depth) when is_number(value) or is_boolean(value), do: value

  defp sanitize_redacted(%{__struct__: _} = value, depth),
    do: value |> Map.from_struct() |> sanitize_redacted(depth)

  defp sanitize_redacted(value, depth) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      key_string = to_string(key)

      safe =
        if sensitive_key?(key_string),
          do: "[REDACTED]",
          else: sanitize_redacted(nested, depth + 1)

      {key_string, safe}
    end)
    |> Enum.take(@max_export_collection_items)
    |> Map.new()
  end

  defp sanitize_redacted(value, depth) when is_list(value),
    do:
      value
      |> Enum.take(@max_export_collection_items)
      |> Enum.map(&sanitize_redacted(&1, depth + 1))

  defp sanitize_redacted(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> sanitize_redacted(depth + 1)

  defp sanitize_redacted(value, _depth),
    do: value |> inspect(limit: 100) |> redact_text() |> truncate_export_text()

  defp sensitive_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp maybe_redact(value, false), do: value

  defp maybe_redact(value, true) when is_binary(value),
    do: value |> redact_text() |> truncate_export_text()

  defp maybe_redact(value, true), do: sanitize_term(value, true)

  defp redact_text(text), do: SupportBundle.redact_text(text)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_export_format(value) when value in [:json, "json"], do: {:ok, :json}

  defp normalize_export_format(value) when value in [:markdown, "markdown", "md"],
    do: {:ok, :markdown}

  defp normalize_export_format(_value), do: {:error, :unsupported_format}

  defp export_cleanup(omitted_run_count) do
    %{
      "redactsSensitiveText" => true,
      "redactsSensitiveKeys" => true,
      "includesSelectedToolFields" => true,
      "includesRawEvents" => false,
      "includesRunRecords" => false,
      "includesCredentials" => false,
      "includesSecretValues" => false,
      "maxBytes" => @max_export_bytes,
      "omittedRunCount" => omitted_run_count,
      "truncatedForByteLimit" => omitted_run_count > 0
    }
  end

  defp export_filename(session_key, format) do
    safe = String.replace(session_key, ~r/[^A-Za-z0-9._-]+/, "-")
    extension = if format == :json, do: "json", else: "md"
    "lemon-session-#{safe}.#{extension}"
  end

  defp markdown_block(nil), do: "_Not recorded._"

  defp markdown_block(value) do
    value
    |> to_string()
    |> String.replace("```", "` ` `")
    |> then(&"```text\n#{&1}\n```")
  end

  defp markdown_escape(nil), do: ""

  defp markdown_escape(value),
    do: value |> to_string() |> String.replace(~r/([`*_{}\[\]<>#])/, "\\\\1")

  defp normalize_query(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      query -> query
    end
  end

  defp normalize_query(_value), do: nil

  defp require_timestamp(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp require_timestamp(_value), do: {:error, :invalid_older_than_ms}

  defp bounded_integer(value, _default, min, max) when is_integer(value),
    do: value |> max(min) |> min(max)

  defp bounded_integer(_value, default, _min, _max), do: default

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp integer_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_zero(_value), do: 0

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)

  defp read(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp read(_map, _key), do: nil

  defp truncate_export_text(text) when byte_size(text) <= @max_export_text_bytes, do: text

  defp truncate_export_text(text) do
    prefix = binary_part(text, 0, @max_export_text_bytes)
    String.replace_invalid(prefix) <> "…[TRUNCATED]"
  end

  defp sha256(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
