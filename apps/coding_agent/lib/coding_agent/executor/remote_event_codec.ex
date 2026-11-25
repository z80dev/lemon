defmodule CodingAgent.Executor.RemoteEventCodec do
  @moduledoc """
  Bounded, allowlisted live execution events at the named-node JSON boundary.

  Invocation/run/session identity is supplied by the broker, never by event data.
  Size never fails a run: deltas split at UTF-8 boundaries (`take_delta/2`) and
  oversized display data is elided to the event budget. Approval requests are
  the exception and are refused rather than shown altered.
  Terminal completions continue to use `RemoteRequestCodec`.
  """

  import Bitwise, only: [&&&: 2]

  alias LemonCore.JSONPayload
  alias CodingAgent.Executor.Event

  @max_bytes 64 * 1_024
  @checkpoints %{
    "checkpoint_created" => :checkpoint_created,
    "checkpoint_restored" => :checkpoint_restored,
    "checkpoint_deleted" => :checkpoint_deleted
  }
  @identity_fields ~w(name tool_call_id task_id parent_action_id parent_tool_call_id)
  @checkpoint_fields [
    {:checkpoint_id, "checkpointId"},
    {:checkpoint_kind, "checkpointKind"},
    {:tool, "tool"},
    {:action, "action"},
    {:path_count, "pathCount"},
    {:paths, "paths"},
    {:restored_count, "restoredCount"}
  ]

  def max_bytes, do: @max_bytes

  @doc """
  Encodes a whole delta, or fails when it does not fit `max_bytes`.

  The worker streams deltas through `take_delta/2`, which splits instead.
  """
  def encode_delta(text, max_bytes \\ @max_bytes)

  def encode_delta(text, max_bytes) when is_binary(text),
    do: bounded(%{"type" => "delta", "text" => text}, max_bytes)

  def encode_delta(_text, _max_bytes), do: {:error, {:not_json_safe, :invalid_delta}}

  @doc """
  Encodes the longest prefix of `text` that fits `max_bytes` as one delta event.

  The cut lands on a UTF-8 boundary and the remainder is returned for the next
  event, so a delta of any size streams without being rejected.
  """
  @spec take_delta(binary(), pos_integer()) :: {:ok, map(), binary()} | {:error, term()}
  def take_delta(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    take_delta(text, max_bytes, min(byte_size(text), max_bytes))
  end

  defp take_delta(text, max_bytes, take) do
    {head, rest} = split_utf8(text, take)

    case encode_delta(head, max_bytes) do
      {:ok, event} -> {:ok, event, rest}
      {:error, {:max_bytes, _}} when take > 1 -> take_delta(text, max_bytes, div(take, 2))
      {:error, _reason} = error -> error
    end
  end

  # Cuts at or below `take` bytes without splitting a codepoint, but always
  # keeps at least the first codepoint so the stream makes progress.
  defp split_utf8(text, take) when take >= byte_size(text), do: {text, ""}

  defp split_utf8(text, take) do
    cut =
      case utf8_boundary(text, take) do
        0 -> text |> String.next_codepoint() |> elem(0) |> byte_size()
        cut -> cut
      end

    {binary_part(text, 0, cut), binary_part(text, cut, byte_size(text) - cut)}
  end

  defp utf8_boundary(_text, 0), do: 0

  defp utf8_boundary(text, take) do
    if (:binary.at(text, take) &&& 0xC0) == 0x80, do: utf8_boundary(text, take - 1), else: take
  end

  def encode_engine(event, max_bytes \\ @max_bytes)

  def encode_engine(%{__event__: :started} = event, max_bytes) do
    elided(max_bytes, fn limits ->
      %{"type" => "started", "title" => elide(event[:title], limits)}
    end)
  end

  def encode_engine(%{__event__: :action_event, action: action} = event, max_bytes)
      when is_map(action) do
    elided(max_bytes, fn limits ->
      %{
        "type" => "action",
        "action" => %{
          id: action[:id],
          kind: action[:kind],
          title: elide(action[:title], limits),
          detail: elide_detail(action[:detail], limits)
        },
        "phase" => event[:phase],
        "ok" => event[:ok],
        "message" => elide(event[:message], limits),
        "level" => event[:level]
      }
    end)
  end

  def encode_engine(_event, _max_bytes), do: :ignore

  def encode_checkpoint(type, payload, max_bytes \\ @max_bytes) do
    elided(max_bytes, fn limits ->
      @checkpoint_fields
      |> Map.new(fn {key, wire} -> {wire, elide(Map.get(payload, key), limits)} end)
      |> Map.put("type", Atom.to_string(type))
    end)
  end

  # Approval requests are decided by an operator from exactly what is shown:
  # they are never elided, and one that does not fit is refused.
  def encode_approval(pending, max_bytes \\ @max_bytes) do
    bounded(
      %{
        "type" => "approval_requested",
        "approvalId" => pending.id,
        "tool" => pending.tool,
        "action" => pending.action,
        "rationale" => pending.rationale,
        "expiresAtMs" => pending.expires_at_ms,
        "onceOnly" => Map.get(pending, :once_only) == true
      },
      max_bytes
    )
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
      action =
        Event.action(%{
          id: action["id"],
          kind: action["kind"],
          title: action["title"],
          detail: action["detail"]
        })

      phase = %{"started" => :started, "updated" => :updated, "completed" => :completed}[phase]

      {:ok,
       {:engine,
        Event.action_event(%{
          engine: "lemon",
          action: action,
          phase: phase,
          ok: event["ok"],
          message: event["message"],
          level: event["level"]
        })}}
    else
      {:error, :invalid_action}
    end
  end

  defp decode_event(
         %{"type" => "approval_requested", "approvalId" => id, "tool" => tool, "action" => action} =
           event
       )
       when is_binary(id) and id != "" and is_binary(tool) and tool != "" and is_map(action) do
    expires = event["expiresAtMs"]
    once_only = event["onceOnly"]

    # `onceOnly` is required: a dropped flag would let the controller answer a
    # once-only request from, or install, a standing grant.
    if (is_nil(expires) or is_integer(expires)) and is_boolean(once_only) do
      {:ok,
       {:approval,
        %{
          approval_id: id,
          tool: tool,
          action: action,
          rationale: event["rationale"],
          expires_at_ms: expires,
          once_only: once_only
        }}}
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

  defp bounded(event, max_bytes) do
    try do
      {normalized, _count} = normalize(event, 0, 0)
      JSONPayload.round_trip(normalized, max_bytes: max_bytes)
    catch
      {:event_limit, reason} -> {:error, reason}
    end
  end

  # Display data (titles, messages, action detail such as tool args, results and
  # structured details, checkpoint paths) is elided to fit rather than failing
  # the run: progressively tighter string, collection and depth limits, and
  # finally a detail reduced to its identifying fields. Only a budget too small
  # for the identifying fields themselves is an error.
  defp elided(max_bytes, build) do
    Enum.reduce_while(elision_levels(max_bytes), nil, fn limits, _acc ->
      case bounded(build.(limits), max_bytes) do
        {:ok, _event} = ok -> {:halt, ok}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  defp elision_levels(max_bytes) do
    [
      nil,
      %{string: div(max_bytes, 2), items: 200, depth: 8},
      %{string: div(max_bytes, 8), items: 50, depth: 6},
      %{string: div(max_bytes, 32), items: 10, depth: 4},
      %{string: 128, items: 3, depth: 2},
      :identity
    ]
  end

  defp elide_detail(detail, :identity) when is_map(detail) do
    detail
    |> Enum.filter(fn {key, value} -> to_string(key) in @identity_fields and is_binary(value) end)
    |> Map.new(fn {key, value} -> {key, elide(value, :identity)} end)
    |> Map.put(:elided, true)
  end

  defp elide_detail(_detail, :identity), do: %{elided: true}
  defp elide_detail(detail, limits), do: elide(detail, limits)

  defp elide(value, nil), do: value
  defp elide(value, :identity), do: elide(value, %{string: 128, items: 0, depth: 0})

  defp elide(value, limits), do: elide(value, limits, 0)

  defp elide(value, %{string: max}, _depth) when is_binary(value) and byte_size(value) > max do
    LemonAi.Text.truncate_middle_utf8(value, max,
      marker: fn removed -> "… [#{removed} bytes omitted] …" end
    )
  end

  defp elide(value, _limits, _depth) when is_binary(value), do: value

  # Collections past the depth limit keep their JSON type but lose their items.
  defp elide(value, %{depth: max}, depth) when is_list(value) and depth >= max, do: []
  defp elide(value, %{depth: max}, depth) when is_map(value) and depth >= max, do: %{}

  # Typed results keep their visible fields (see normalize/3) before eliding.
  defp elide(%LemonAgent.Types.AgentToolResult{} = result, limits, depth),
    do: elide(Map.take(result, [:content, :details, :is_error, :trust]), limits, depth)

  defp elide(%LemonAi.Types.TextContent{} = text, limits, depth),
    do: elide(Map.take(text, [:type, :text]), limits, depth)

  defp elide(%LemonAi.Types.ImageContent{} = image, limits, depth),
    do: elide(Map.take(image, [:type, :data, :mime_type]), limits, depth)

  defp elide(%_{} = value, _limits, _depth), do: value

  defp elide(value, %{items: items} = limits, depth) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(items)
    |> Map.new(fn {key, item} -> {key, elide(item, limits, depth + 1)} end)
  end

  defp elide(value, %{items: items} = limits, depth) when is_list(value) do
    value |> Enum.take(items) |> Enum.map(&elide(&1, limits, depth + 1))
  end

  defp elide(value, _limits, _depth), do: value

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
    {items, count} =
      Enum.reduce(value, {[], count + 1}, fn item, {acc, count} ->
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
