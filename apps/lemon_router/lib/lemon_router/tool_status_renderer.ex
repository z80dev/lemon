defmodule LemonRouter.ToolStatusRenderer do
  @moduledoc """
  Renders the tool-status text for user-facing transports.

  Produces takopi-style output with Unicode symbols, elapsed time, and step counts:

      working · claude · 2m 30s · step 5

      ▸ read: `lib/foo.ex`
      ✓ grep: pattern
      ✗ `npm test` (exit 1)

  Channel-specific formatting (action limits, extra metadata) is delegated to
  `LemonRouter.ChannelAdapter`.
  """

  alias LemonRouter.ChannelAdapter

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
    adapter = ChannelAdapter.for(channel_id)
    {display_order, omitted_count} = adapter.limit_order(order)

    lines =
      Enum.map(display_order, fn id ->
        case Map.get(actions, id) do
          nil -> nil
          action -> format_action_line(adapter, action)
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

  defp format_action_line(adapter, action) when is_map(action) do
    title = truncate_one_line(action[:title] || action["title"] || "", 80)
    extra = adapter.format_action_extra(action, title)

    case action[:phase] || action["phase"] do
      :started ->
        "\u25b8 " <> title <> (extra || "")

      :updated ->
        "\u25b8 " <> title <> (extra || "")

      :completed ->
        ok? = (action[:ok] || action["ok"]) == true
        symbol = if ok?, do: "\u2713", else: "\u2717"

        if ok? do
          symbol <> " " <> title <> (extra || "")
        else
          preview = extract_result_preview(action[:detail] || action["detail"])
          base = symbol <> " " <> title <> (extra || "")

          if preview in [nil, ""] do
            base
          else
            prev = truncate_one_line(preview, 140)
            base <> " -> " <> prev
          end
        end

      other ->
        "\u25b8 " <> "[#{other}] " <> title <> (extra || "")
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
