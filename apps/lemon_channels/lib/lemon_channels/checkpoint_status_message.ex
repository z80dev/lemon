defmodule LemonChannels.CheckpointStatusMessage do
  @moduledoc """
  Chat `/checkpoint` and `/rollback` surface.

  Access is scoped to `:checkpoint_owner`, the native session id that owns the
  chat's checkpoints; callers resolve it with `owner_for_session_key/1`, which
  accepts a native session only when `LemonCore.NativeSessionOwner` binds it to
  this chat's session key, never from chat input or from history alone.
  Without an owner no checkpoint is reachable.

  Restore previews first: `restore <id>` issues a random single-use token
  bound to the caller (`:session_key` plus `:sender_id`), the checkpoint
  revision, the selected roots and the current tree, valid for five minutes.
  Only `restore <id> <token>` from the same caller restores files, once.
  """

  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonCore.{NativeSessionOwner, ResumeToken}
  alias LemonAgent.Checkpoint
  alias LemonAgent.Doctor.CheckpointDiagnostics
  alias LemonCore.Introspection

  @checkpoint_events [:checkpoint_created, :checkpoint_restored, :checkpoint_deleted]

  @doc """
  The native session that owns a chat session's checkpoints: the session of
  the chat's most recent completed run, as recorded by the router, provided
  that native session is bound to this same session key. A run that names
  another chat's native session therefore never makes its checkpoints
  reachable. Chat state that a user can select (such as `/resume` choices) is
  deliberately not used.
  """
  @spec owner_for_session_key(term()) :: String.t() | nil
  def owner_for_session_key(session_key) when is_binary(session_key) and session_key != "" do
    case ResumeSelection.list_recent_sessions(session_key, limit: 1) do
      [%{resume: %ResumeToken{engine: "lemon", value: owner} = resume} | _]
      when is_binary(owner) and owner != "" ->
        if NativeSessionOwner.owned_by?(resume, session_key), do: owner

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def owner_for_session_key(_session_key), do: nil

  @spec handle(String.t() | nil, keyword()) :: String.t()
  def handle(args, opts \\ [])

  def handle(args, opts) when args in [nil, ""] do
    text(opts)
  end

  def handle(args, opts) when is_binary(args) do
    case String.split(args, ~r/\s+/, trim: true) do
      [] ->
        text(opts)

      ["status" | _] ->
        text(opts)

      ["events" | rest] ->
        events_text(rest, opts)

      ["diff", checkpoint_id | _] ->
        diff_text(checkpoint_id, opts)

      ["diff"] ->
        "Usage: /checkpoint diff <checkpoint_id>"

      ["restore", checkpoint_id, token | _] ->
        restore_text(checkpoint_id, token, "/checkpoint restore", opts)

      ["restore", checkpoint_id] ->
        preview_text(checkpoint_id, "/checkpoint restore", opts)

      ["restore"] ->
        "Usage: /checkpoint restore <checkpoint_id> [token]"

      _ ->
        "Usage: /checkpoint status | /checkpoint events [limit] | /checkpoint diff <checkpoint_id> | /checkpoint restore <checkpoint_id> [token]"
    end
  end

  @spec handle_rollback(String.t() | nil, keyword()) :: String.t()
  def handle_rollback(args, opts \\ [])

  def handle_rollback(args, opts) when args in [nil, ""] do
    text(opts)
  end

  def handle_rollback(args, opts) when is_binary(args) do
    case String.split(args, ~r/\s+/, trim: true) do
      [] ->
        text(opts)

      ["status" | _] ->
        text(opts)

      ["events" | rest] ->
        events_text(rest, opts)

      ["diff", checkpoint_id | _] ->
        diff_text(checkpoint_id, opts)

      ["diff"] ->
        "Usage: /rollback diff <checkpoint_id>"

      ["restore", checkpoint_id, token | _] ->
        restore_text(checkpoint_id, token, "/rollback restore", opts)

      ["restore", checkpoint_id] ->
        preview_text(checkpoint_id, "/rollback restore", opts)

      ["restore"] ->
        "Usage: /rollback restore <checkpoint_id> [token]"

      [checkpoint_id, token | _] ->
        restore_text(checkpoint_id, token, "/rollback", opts)

      [checkpoint_id] ->
        preview_text(checkpoint_id, "/rollback", opts)
    end
  end

  @spec text(keyword()) :: String.t()
  def text(opts \\ []) do
    summary = CheckpointDiagnostics.summary({:session, checkpoint_owner(opts)}, opts)

    lines = [
      "Checkpoint Status",
      "Total: #{summary.count}",
      "Filesystem: #{summary.filesystem_count}",
      "Invalid: #{summary.invalid_count}",
      "Newest: #{summary.newest || "none"}",
      "Recent: #{recent_line(summary.recent)}",
      "Events: #{event_counts_line(opts)}",
      "Recent events: #{recent_events_line(opts)}",
      "Actions: /checkpoint diff <id>; /checkpoint restore <id> (preview, then confirm with its token). Chat output is redacted."
    ]

    Enum.join(lines, "\n")
  end

  defp events_text(args, opts) do
    limit = args |> List.first() |> parse_event_limit()

    case checkpoint_events(opts, limit) do
      [] ->
        "Checkpoint Events\nnone"

      {:error, _} ->
        "Checkpoint Events\nunavailable"

      events when is_list(events) ->
        [
          "Checkpoint Events",
          "Limit: #{limit}",
          "Events:",
          events |> Enum.map(&("- " <> event_summary(&1))) |> Enum.join("\n")
        ]
        |> Enum.join("\n")
    end
  end

  defp checkpoint_owner(opts), do: Keyword.get(opts, :checkpoint_owner)

  # The confirmation caller: the chat session and the sender within it.
  defp confirmation_caller(opts) do
    case Keyword.get(opts, :session_key) do
      key when is_binary(key) and key != "" ->
        {:chat, key, opts |> Keyword.get(:sender_id) |> normalize_sender()}

      _ ->
        nil
    end
  end

  defp normalize_sender(nil), do: nil
  defp normalize_sender(sender) when is_binary(sender), do: sender
  defp normalize_sender(sender) when is_integer(sender), do: Integer.to_string(sender)
  defp normalize_sender(_sender), do: nil

  defp diff_text(checkpoint_id, opts) do
    case Checkpoint.diff_filesystem(checkpoint_id, checkpoint_owner(opts)) do
      {:ok, %{changed: [], checkpoint_id: id}} ->
        "Checkpoint Diff\n#{id}\nNo filesystem changes."

      {:ok, %{checkpoint_id: id, changed: changed}} ->
        [
          "Checkpoint Diff",
          id,
          "Changed paths: #{length(changed)}",
          "Output is redacted in chat."
        ]
        |> Enum.join("\n")

      {:error, reason} ->
        failure_text("diff", checkpoint_id, reason)
    end
  end

  defp preview_text(checkpoint_id, confirm_command, opts) do
    case Checkpoint.restore_preview(checkpoint_id, checkpoint_owner(opts),
           caller: confirmation_caller(opts)
         ) do
      {:ok, %{checkpoint_id: id, changed: changed, confirm_token: token}} ->
        [
          "Restore Preview",
          id,
          "Changed paths: #{length(changed)}",
          "Restoring replaces the current files with the checkpoint copy.",
          "Confirm with: #{confirm_command} #{id} #{token}",
          "The token works once, only for you, for five minutes, and only while these files are unchanged. Output is redacted in chat."
        ]
        |> Enum.join("\n")

      {:error, reason} ->
        failure_text("restore preview", checkpoint_id, reason)
    end
  end

  defp restore_text(checkpoint_id, token, preview_command, opts) do
    event_opts =
      opts
      |> Keyword.take([:run_id, :session_key, :agent_id, :parent_run_id])
      |> Keyword.put(:caller, confirmation_caller(opts))

    case Checkpoint.confirmed_restore_filesystem(
           checkpoint_id,
           checkpoint_owner(opts),
           token,
           event_opts
         ) do
      {:ok, %{checkpoint_id: id, restored: restored}} ->
        "Checkpoint Restored\n#{id}\nRestored paths: #{length(restored)}\nOutput is redacted in chat."

      {:error, reason}
      when reason in [:confirmation_required, :invalid_confirmation, :stale_confirmation] ->
        "Restore confirmation is missing, spent, expired or stale; nothing was restored. " <>
          "Preview again with #{preview_command} #{checkpoint_id}"

      {:error, reason} ->
        failure_text("restore", checkpoint_id, reason)
    end
  end

  # Another session's checkpoint is indistinguishable from a missing one. Other
  # failures are reduced to a bounded label so host paths never reach chat.
  defp failure_text(_action, checkpoint_id, :not_found) do
    if Checkpoint.valid_id?(checkpoint_id),
      do: "Checkpoint not found in this chat's session: #{checkpoint_id}",
      else: "Checkpoint not found in this chat's session."
  end

  defp failure_text(action, _checkpoint_id, reason) do
    "Checkpoint #{action} failed: #{failure_label(reason)}"
  end

  defp failure_label(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp failure_label(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp failure_label(_reason), do: "error"

  defp recent_line([]), do: "none"

  defp recent_line(recent) do
    recent
    |> Enum.take(5)
    |> Enum.map(fn checkpoint ->
      [
        checkpoint.checkpoint_id,
        checkpoint.kind,
        checkpoint.tool,
        path_count(checkpoint)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    end)
    |> Enum.join(", ")
  end

  defp path_count(%{path_count: count}) when is_integer(count), do: "(#{count} paths)"
  defp path_count(_checkpoint), do: nil

  defp event_counts_line(opts) do
    case checkpoint_events(opts, 100) do
      {:error, _} ->
        "unavailable"

      events when is_list(events) ->
        [
          "created #{count_events(events, :checkpoint_created)}",
          "restored #{count_events(events, :checkpoint_restored)}",
          "deleted #{count_events(events, :checkpoint_deleted)}"
        ]
        |> Enum.join(", ")
    end
  end

  defp recent_events_line(opts) do
    case checkpoint_events(opts, 5) do
      [] ->
        "none"

      {:error, _} ->
        "unavailable"

      events when is_list(events) ->
        events
        |> Enum.map(&event_summary/1)
        |> Enum.join(", ")
    end
  end

  defp checkpoint_events(opts, limit) do
    filters = checkpoint_event_filters(opts)

    @checkpoint_events
    |> Enum.reduce_while([], fn event_type, events ->
      case filters
           |> Keyword.put(:event_type, event_type)
           |> Keyword.put(:limit, limit)
           |> Introspection.list() do
        matching when is_list(matching) -> {:cont, matching ++ events}
        {:error, _} -> {:halt, {:error, :introspection_unavailable}}
      end
    end)
    |> case do
      events when is_list(events) ->
        events |> Enum.sort_by(&event_ts/1, :desc) |> Enum.take(limit)

      {:error, _} = error ->
        error
    end
  rescue
    _ -> {:error, :introspection_unavailable}
  catch
    :exit, _ -> {:error, :introspection_unavailable}
  end

  defp checkpoint_event_filters(opts) do
    case Keyword.get(opts, :event_filters) do
      filters when is_list(filters) ->
        filters

      _ ->
        Keyword.take(opts, [:run_id, :session_key, :agent_id, :parent_run_id])
    end
  end

  defp parse_event_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> limit |> max(1) |> min(20)
      _ -> 10
    end
  end

  defp parse_event_limit(_), do: 10

  defp count_events(events, event_type) do
    Enum.count(events, &(normalize_event_type(&1.event_type) == event_type))
  end

  defp event_summary(event) do
    payload = event.payload || %{}
    event_name = event.event_type |> normalize_event_type() |> event_label()
    checkpoint_id = payload_value(payload, :checkpoint_id) || "unknown"
    restored_count = payload_value(payload, :restored_count)
    path_count = payload_value(payload, :path_count)
    count = if is_integer(restored_count), do: restored_count, else: path_count

    [event_name, checkpoint_id, event_path_count(count)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp event_path_count(count) when is_integer(count), do: "(#{count} paths)"
  defp event_path_count(_), do: nil

  defp event_label(:checkpoint_created), do: "created"
  defp event_label(:checkpoint_restored), do: "restored"
  defp event_label(:checkpoint_deleted), do: "deleted"
  defp event_label(other), do: to_string(other)

  defp normalize_event_type(value) when is_atom(value), do: value
  defp normalize_event_type("checkpoint_created"), do: :checkpoint_created
  defp normalize_event_type("checkpoint_restored"), do: :checkpoint_restored
  defp normalize_event_type("checkpoint_deleted"), do: :checkpoint_deleted
  defp normalize_event_type(value) when is_binary(value), do: :unknown
  defp normalize_event_type(_), do: :unknown

  defp event_ts(%{ts_ms: ts_ms}) when is_integer(ts_ms), do: ts_ms
  defp event_ts(_), do: 0

  defp payload_value(payload, key) do
    Map.get(payload, key) || Map.get(payload, to_string(key))
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
