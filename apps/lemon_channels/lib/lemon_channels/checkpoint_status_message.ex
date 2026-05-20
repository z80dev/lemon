defmodule LemonChannels.CheckpointStatusMessage do
  @moduledoc false

  alias LemonCore.Checkpoint
  alias LemonCore.Introspection

  @checkpoint_events [:checkpoint_created, :checkpoint_restored, :checkpoint_deleted]

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
        diff_text(checkpoint_id)

      ["diff"] ->
        "Usage: /checkpoint diff <checkpoint_id>"

      ["restore", checkpoint_id, "confirm" | _] ->
        restore_text(checkpoint_id, opts)

      ["restore", checkpoint_id | _] ->
        "Restore requires confirmation. Use /checkpoint restore #{checkpoint_id} confirm"

      ["restore"] ->
        "Usage: /checkpoint restore <checkpoint_id> confirm"

      _ ->
        "Usage: /checkpoint status | /checkpoint events [limit] | /checkpoint diff <checkpoint_id> | /checkpoint restore <checkpoint_id> confirm"
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
        diff_text(checkpoint_id)

      ["diff"] ->
        "Usage: /rollback diff <checkpoint_id>"

      ["restore", checkpoint_id, "confirm" | _] ->
        restore_text(checkpoint_id, opts)

      ["restore", checkpoint_id | _] ->
        "Rollback requires confirmation. Use /rollback restore #{checkpoint_id} confirm"

      ["restore"] ->
        "Usage: /rollback restore <checkpoint_id> confirm"

      [checkpoint_id, "confirm" | _] ->
        restore_text(checkpoint_id, opts)

      [checkpoint_id | _] ->
        "Rollback requires confirmation. Use /rollback #{checkpoint_id} confirm"
    end
  end

  @spec text(keyword()) :: String.t()
  def text(opts \\ []) do
    summary = LemonCore.Doctor.CheckpointDiagnostics.summary(opts)

    lines = [
      "Checkpoint Status",
      "Total: #{summary.count}",
      "Filesystem: #{summary.filesystem_count}",
      "Invalid: #{summary.invalid_count}",
      "Newest: #{summary.newest || "none"}",
      "Recent: #{recent_line(summary.recent)}",
      "Events: #{event_counts_line(opts)}",
      "Recent events: #{recent_events_line(opts)}",
      "Actions: /checkpoint diff <id>; /checkpoint restore <id> confirm. Chat output is redacted; use TUI/control-plane for full diffs."
    ]

    Enum.join(lines, "\n")
  end

  @spec event_text(LemonCore.Event.t() | map()) :: String.t() | nil
  def event_text(%{type: type, payload: payload}) when type in @checkpoint_events do
    "Checkpoint Event\n#{event_summary(%{event_type: type, payload: payload || %{}})}"
  end

  def event_text(_event), do: nil

  defp events_text(args, opts) do
    limit = args |> List.first() |> parse_event_limit()

    case checkpoint_events(opts, limit) do
      [] ->
        "Checkpoint Events\nnone"

      events ->
        [
          "Checkpoint Events",
          "Limit: #{limit}",
          "Events:",
          events |> Enum.map(&("- " <> event_summary(&1))) |> Enum.join("\n")
        ]
        |> Enum.join("\n")
    end
  end

  defp diff_text(checkpoint_id) do
    case Checkpoint.diff_filesystem(checkpoint_id) do
      {:ok, %{changed: [], checkpoint_id: id}} ->
        "Checkpoint Diff\n#{id}\nNo filesystem changes."

      {:ok, %{checkpoint_id: id, changed: changed}} ->
        [
          "Checkpoint Diff",
          id,
          "Changed paths: #{length(changed)}",
          "Output is redacted in chat. Use TUI /checkpoint diff or control-plane checkpoint.diff for full content."
        ]
        |> Enum.join("\n")

      {:error, :not_found} ->
        "Checkpoint not found: #{checkpoint_id}"

      {:error, reason} ->
        "Checkpoint diff failed: #{inspect(reason)}"
    end
  end

  defp restore_text(checkpoint_id, opts) do
    event_opts =
      opts
      |> Keyword.take([:run_id, :session_key, :agent_id, :parent_run_id])

    case Checkpoint.restore_filesystem(checkpoint_id, event_opts) do
      {:ok, %{checkpoint_id: id, restored: restored}} ->
        "Checkpoint Restored\n#{id}\nRestored paths: #{length(restored)}\nOutput is redacted in chat."

      {:error, :not_found} ->
        "Checkpoint not found: #{checkpoint_id}"

      {:error, reason} ->
        "Checkpoint restore failed: #{inspect(reason)}"
    end
  end

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
    events = checkpoint_events(opts, 100)

    [
      "created #{count_events(events, :checkpoint_created)}",
      "restored #{count_events(events, :checkpoint_restored)}",
      "deleted #{count_events(events, :checkpoint_deleted)}"
    ]
    |> Enum.join(", ")
  end

  defp recent_events_line(opts) do
    case checkpoint_events(opts, 5) do
      [] ->
        "none"

      events ->
        events
        |> Enum.map(&event_summary/1)
        |> Enum.join(", ")
    end
  end

  defp checkpoint_events(opts, limit) do
    filters = checkpoint_event_filters(opts)

    @checkpoint_events
    |> Enum.flat_map(fn event_type ->
      filters
      |> Keyword.put(:event_type, event_type)
      |> Keyword.put(:limit, limit)
      |> Introspection.list()
    end)
    |> Enum.sort_by(&event_ts/1, :desc)
    |> Enum.take(limit)
  rescue
    _ -> []
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
