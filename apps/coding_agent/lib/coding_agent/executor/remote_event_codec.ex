defmodule CodingAgent.Executor.RemoteEventCodec do
  @moduledoc """
  Bounded, allowlisted live execution events at the named-node JSON boundary.

  Invocation/run/session identity is supplied by the broker, never by event data.
  Terminal completions continue to use `RemoteRequestCodec`.
  """

  alias LemonCore.JSONPayload
  alias LemonGateway.Event

  @max_bytes 64 * 1_024
  @checkpoints %{
    "checkpoint_created" => :checkpoint_created,
    "checkpoint_restored" => :checkpoint_restored,
    "checkpoint_deleted" => :checkpoint_deleted
  }
  @checkpoint_fields [
    {:checkpoint_id, "checkpointId"}, {:checkpoint_kind, "checkpointKind"},
    {:tool, "tool"}, {:action, "action"}, {:path_count, "pathCount"},
    {:paths, "paths"}, {:restored_count, "restoredCount"}
  ]

  def max_bytes, do: @max_bytes

  def encode_delta(text) when is_binary(text), do: bounded(%{"type" => "delta", "text" => text})
  def encode_delta(_text), do: {:error, {:not_json_safe, :invalid_delta}}

  def encode_engine(%{__event__: :started} = event) do
    bounded(%{"type" => "started", "title" => event[:title]})
  end

  def encode_engine(%{__event__: :action_event, action: action} = event) when is_map(action) do
    bounded(%{
      "type" => "action",
      "action" => Map.take(action, [:id, :kind, :title, :detail]),
      "phase" => event[:phase], "ok" => event[:ok],
      "message" => event[:message], "level" => event[:level]
    })
  end

  def encode_engine(_event), do: :ignore

  def encode_checkpoint(type, payload) do
    fields = Map.new(@checkpoint_fields, fn {key, wire} -> {wire, Map.get(payload, key)} end)
    bounded(Map.put(fields, "type", Atom.to_string(type)))
  end

  def encode_approval(pending) do
    bounded(%{
      "type" => "approval_requested", "approvalId" => pending.id,
      "tool" => pending.tool, "action" => pending.action,
      "rationale" => pending.rationale, "expiresAtMs" => pending.expires_at_ms
    })
  end

  def decode(event) when is_map(event) do
    with {:ok, _stats} <- JSONPayload.validate(event, max_bytes: @max_bytes) do
      decode_event(event)
    end
  end

  def decode(_event), do: {:error, :invalid_event}

  defp decode_event(%{"type" => "delta", "text" => text}) when is_binary(text),
    do: {:ok, {:delta, text}}

  defp decode_event(%{"type" => "started"} = event) do
    {:ok, {:engine, Event.started(%{engine: "lemon", resume: nil, title: event["title"]})}}
  end

  defp decode_event(%{"type" => "action", "action" => action, "phase" => phase} = event)
       when is_map(action) and phase in ["started", "updated", "completed"] do
    if Enum.all?(["id", "kind", "title"], &is_binary(action[&1])) do
      action = Event.action(%{
        id: action["id"], kind: action["kind"], title: action["title"], detail: action["detail"]
      })
      phase = %{"started" => :started, "updated" => :updated, "completed" => :completed}[phase]
      {:ok, {:engine, Event.action_event(%{
        engine: "lemon", action: action, phase: phase, ok: event["ok"],
        message: event["message"], level: event["level"]
      })}}
    else
      {:error, :invalid_action}
    end
  end

  defp decode_event(%{"type" => "approval_requested", "approvalId" => id,
                      "tool" => tool, "action" => action} = event)
       when is_binary(id) and id != "" and is_binary(tool) and tool != "" and is_map(action) do
    expires = event["expiresAtMs"]
    if is_nil(expires) or is_integer(expires) do
      {:ok, {:approval, %{approval_id: id, tool: tool, action: action,
                          rationale: event["rationale"], expires_at_ms: expires}}}
    else
      {:error, :invalid_approval}
    end
  end

  defp decode_event(%{"type" => type, "checkpointId" => id} = event)
       when is_map_key(@checkpoints, type) and is_binary(id) do
    payload = Map.new(@checkpoint_fields, fn {key, wire} -> {key, event[wire]} end)
    {:ok, {:checkpoint, Map.fetch!(@checkpoints, type), payload}}
  end

  defp decode_event(_event), do: {:error, :invalid_event}

  defp bounded(event) do
    try do
      {normalized, _count} = normalize(event, 0, 0)
      JSONPayload.round_trip(normalized, max_bytes: @max_bytes)
    catch
      {:event_limit, reason} -> {:error, reason}
    end
  end

  # Explicit visible struct fields only: never Codec.json_safe/1's inspected
  # fallback, arbitrary BEAM structs, text/thinking signatures or callbacks.
  defp normalize(_value, depth, _count) when depth > 32,
    do: throw({:event_limit, {:max_depth, 32}})
  defp normalize(_value, _depth, count) when count >= 10_000,
    do: throw({:event_limit, {:max_items, 10_000}})

  defp normalize(%LemonAgent.Types.AgentToolResult{} = result, depth, count),
    do: normalize(Map.take(result, [:content, :details, :is_error, :trust]), depth, count)
  defp normalize(%LemonAi.Types.TextContent{} = text, depth, count),
    do: normalize(Map.take(text, [:type, :text]), depth, count)
  defp normalize(%LemonAi.Types.ImageContent{} = image, depth, count),
    do: normalize(Map.take(image, [:type, :data, :mime_type]), depth, count)
  defp normalize(%LemonAi.Types.Usage{} = usage, depth, count),
    do: normalize(Map.from_struct(usage), depth, count)
  defp normalize(%LemonAi.Types.Cost{} = cost, depth, count),
    do: normalize(Map.from_struct(cost), depth, count)
  defp normalize(%_{} = _value, _depth, count), do: {:omit, count + 1}

  defp normalize(value, depth, count) when is_map(value) do
    Enum.reduce(value, {%{}, count + 1}, fn {key, item}, {acc, count} ->
      {item, count} = normalize(item, depth + 1, count)
      if item == :omit, do: {acc, count}, else: {Map.put(acc, key, item), count}
    end)
  end

  defp normalize(value, depth, count) when is_list(value) do
    {items, count} = Enum.reduce(value, {[], count + 1}, fn item, {acc, count} ->
      {item, count} = normalize(item, depth + 1, count)
      if item == :omit, do: {acc, count}, else: {[item | acc], count}
    end)
    {Enum.reverse(items), count}
  end

  defp normalize(value, _depth, count)
       when is_binary(value) or is_number(value) or is_atom(value),
       do: {value, count + 1}
  defp normalize(_value, _depth, count), do: {:omit, count + 1}
end
