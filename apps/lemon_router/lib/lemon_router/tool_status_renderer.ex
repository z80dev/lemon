defmodule LemonRouter.ToolStatusRenderer do
  @moduledoc """
  Renders the tool-status text for user-facing transports.

  Produces takopi-style output with Unicode symbols, elapsed time, and step counts:

      working · claude · 2m 30s · step 5

      ▸ read: `lib/foo.ex`
      ✓ grep: pattern
      ✗ `npm test` (exit 1)

  Rendering is semantic and channel-agnostic; channel presentation is handled
  by `:lemon_channels`.
  """

  @doc """
  Render with default opts (no elapsed/engine/action_count).
  """
  @spec render(String.t() | nil, map(), [String.t()]) :: String.t()
  def render(channel_id, actions, order) do
    render(channel_id, actions, order, %{})
  end

  @doc """
  Render with opts map supporting `:elapsed_ms`, `:engine`, `:action_count`.
  """
  @spec render(String.t() | nil, map(), [String.t()], map()) :: String.t()
  def render(_channel_id, _actions, [], _opts) do
    "working"
  end

  def render(channel_id, actions, order, opts) when is_map(actions) and is_list(order) do
    _channel_id = channel_id
    display_order = order
    omitted_count = 0

    lines =
      Enum.map(display_order, fn id ->
        case Map.get(actions, id) do
          nil -> nil
          action -> format_action_line(action, actions)
        end
      end)
      |> Enum.reject(&is_nil/1)

    lines =
      case omitted_count do
        n when is_integer(n) and n > 0 ->
          ["(#{n} #{tool_word(n)} omitted)" | lines]

        _ ->
          lines
      end

    header = build_header(opts)

    Enum.join([header | lines], "\n")
  end

  defp build_header(opts) do
    elapsed_ms = Map.get(opts, :elapsed_ms)
    engine = Map.get(opts, :engine)
    action_count = Map.get(opts, :action_count)

    parts = ["working"]

    parts =
      if is_binary(engine) and engine != "" do
        parts ++ [engine]
      else
        parts
      end

    parts =
      if is_integer(elapsed_ms) and elapsed_ms > 0 do
        parts ++ [format_elapsed(elapsed_ms)]
      else
        parts
      end

    parts =
      if is_integer(action_count) and action_count > 0 do
        parts ++ ["step #{action_count}"]
      else
        parts
      end

    Enum.join(parts, " \u00b7 ")
  end

  defp format_elapsed(ms) when is_integer(ms) and ms >= 0 do
    total_seconds = div(ms, 1000)

    cond do
      total_seconds < 60 ->
        "#{total_seconds}s"

      true ->
        minutes = div(total_seconds, 60)
        seconds = rem(total_seconds, 60)

        if seconds == 0 do
          "#{minutes}m"
        else
          "#{minutes}m #{seconds}s"
        end
    end
  end

  defp tool_word(1), do: "tool"
  defp tool_word(_n), do: "tools"

  defp format_action_line(action, actions) when is_map(action) do
    title = truncate_one_line(action[:title] || action["title"] || "", 80)
    extra = nil
    indent = String.duplicate("  ", action_depth(action, actions))

    case action[:phase] || action["phase"] do
      :started ->
        indent <> "\u25b8 " <> title <> (extra || "")

      :updated ->
        indent <> "\u25b8 " <> title <> (extra || "")

      :completed ->
        ok? = (action[:ok] || action["ok"]) == true
        symbol = if ok?, do: "\u2713", else: "\u2717"
        preview = extract_result_preview(action[:detail] || action["detail"])
        base = indent <> symbol <> " " <> title <> (extra || "")

        if ok? or preview in [nil, ""] do
          base
        else
          prev = truncate_one_line(preview, 140)
          base <> " -> " <> prev
        end

      other ->
        indent <> "\u25b8 " <> "[#{other}] " <> title <> (extra || "")
    end
  end

  defp action_depth(action, actions) when is_map(action) and is_map(actions) do
    do_action_depth(action_parent_id(action), actions, MapSet.new(), 0)
  end

  defp action_depth(_action, _actions), do: 0

  defp do_action_depth(nil, _actions, _seen, depth), do: depth

  defp do_action_depth(_parent_id, _actions, _seen, depth) when depth >= 6, do: depth

  defp do_action_depth(parent_id, actions, seen, depth) do
    cond do
      not is_binary(parent_id) or parent_id == "" ->
        depth

      MapSet.member?(seen, parent_id) ->
        depth

      true ->
        case Map.get(actions, parent_id) do
          nil ->
            depth

          parent_action ->
            seen = MapSet.put(seen, parent_id)
            do_action_depth(action_parent_id(parent_action), actions, seen, depth + 1)
        end
    end
  end

  defp action_parent_id(action) when is_map(action) do
    detail = action[:detail] || action["detail"] || %{}

    case detail do
      detail when is_map(detail) ->
        detail[:parent_tool_use_id] || detail["parent_tool_use_id"]

      _ ->
        nil
    end
  end

  defp extract_result_preview(detail) when is_map(detail) do
    preview =
      detail[:result_preview] ||
        detail["result_preview"] ||
        detail[:result] ||
        detail["result"]

    LemonRouter.ToolPreview.to_text(preview)
  rescue
    _ -> nil
  end

  defp extract_result_preview(_), do: nil

  defp truncate_one_line(text, max_len) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_len)
  end

  defp truncate_one_line(other, _max_len) do
    LemonRouter.ToolPreview.to_text(other) || inspect(other)
  rescue
    _ -> inspect(other)
  end
end
