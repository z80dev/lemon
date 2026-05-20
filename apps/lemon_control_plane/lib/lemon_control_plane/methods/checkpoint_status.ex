defmodule LemonControlPlane.Methods.CheckpointStatus do
  @moduledoc """
  Handler for `checkpoint.status`.

  Returns redacted checkpoint-store metadata for operator diagnostics. This is
  read-only and never returns file contents, raw checkpoint paths, or raw
  session identifiers.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Introspection

  @checkpoint_events [:checkpoint_created, :checkpoint_restored, :checkpoint_deleted]

  @impl true
  def name, do: "checkpoint.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    {:ok,
     params
     |> opts()
     |> LemonCore.Doctor.CheckpointDiagnostics.summary()
     |> Map.put(:events, checkpoint_events(params))
     |> stringify_keys()}
  rescue
    error ->
      {:error,
       {
         :internal_error,
         "Failed to build checkpoint status",
         Exception.message(error)
       }}
  end

  defp opts(params) do
    []
    |> maybe_put(:checkpoint_dir, get_param(params, "checkpointDir"))
    |> maybe_put(:limit, get_param(params, "limit"))
  end

  defp checkpoint_events(params) do
    limit = event_limit(get_param(params, "eventLimit"))
    events = lifecycle_events(params, 100)

    %{
      counts: event_counts(events),
      recent: events |> Enum.take(limit) |> Enum.map(&format_event/1),
      cleanup: %{
        includes_raw_paths: false,
        includes_raw_session_ids: false,
        includes_file_contents: false,
        includes_raw_payload: false
      }
    }
  rescue
    error ->
      %{
        counts: event_counts([]),
        recent: [],
        cleanup: %{
          includes_raw_paths: false,
          includes_raw_session_ids: false,
          includes_file_contents: false,
          includes_raw_payload: false
        },
        error: Exception.message(error)
      }
  end

  defp lifecycle_events(params, limit) do
    params
    |> event_filters()
    |> Keyword.put(:event_type, @checkpoint_events)
    |> Keyword.put(:limit, limit)
    |> Introspection.list()
    |> Enum.sort_by(&event_ts/1, :desc)
  end

  defp event_filters(params) do
    []
    |> maybe_put(:run_id, get_param(params, "runId"))
    |> maybe_put(:session_key, get_param(params, "sessionKey"))
    |> maybe_put(:agent_id, get_param(params, "agentId"))
  end

  defp event_counts(events) do
    %{
      created: count_events(events, :checkpoint_created),
      restored: count_events(events, :checkpoint_restored),
      deleted: count_events(events, :checkpoint_deleted)
    }
  end

  defp count_events(events, event_type) do
    Enum.count(events, &(normalize_event_type(Map.get(&1, :event_type)) == event_type))
  end

  defp format_event(event) do
    payload = Map.get(event, :payload) || %{}

    %{
      type: event |> Map.get(:event_type) |> normalize_event_type() |> event_label(),
      ts_ms: Map.get(event, :ts_ms),
      checkpoint_id: payload_value(payload, :checkpoint_id),
      checkpoint_kind: payload_value(payload, :checkpoint_kind),
      tool: payload_value(payload, :tool),
      action: payload_value(payload, :action),
      path_count: payload_count(payload),
      session_hash: payload |> payload_value(:session_id) |> hash_value()
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp payload_count(payload) do
    case payload_value(payload, :restored_count) do
      count when is_integer(count) -> count
      _ -> payload_value(payload, :path_count)
    end
  end

  defp event_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(20)

  defp event_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> event_limit(parsed)
      _ -> 5
    end
  end

  defp event_limit(_), do: 5

  defp get_param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: to_string(value)
  defp stringify_keys(value), do: value

  defp normalize_event_type(value) when is_atom(value), do: value
  defp normalize_event_type("checkpoint_created"), do: :checkpoint_created
  defp normalize_event_type("checkpoint_restored"), do: :checkpoint_restored
  defp normalize_event_type("checkpoint_deleted"), do: :checkpoint_deleted
  defp normalize_event_type(_), do: :unknown

  defp event_label(:checkpoint_created), do: "created"
  defp event_label(:checkpoint_restored), do: "restored"
  defp event_label(:checkpoint_deleted), do: "deleted"
  defp event_label(other), do: to_string(other)

  defp event_ts(%{ts_ms: ts_ms}) when is_integer(ts_ms), do: ts_ms
  defp event_ts(_), do: 0

  defp payload_value(payload, key) do
    Map.get(payload, key) || Map.get(payload, to_string(key))
  end

  defp hash_value(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_value(_), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
