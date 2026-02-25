defmodule LemonRouter.ToolStatusRenderer do
  @moduledoc """
  Renders the "Tool calls" status text for user-facing transports.

  This is used by `LemonRouter.ToolStatusCoalescer` to build the editable status
  message shown in transports like Telegram.

  Channel-specific formatting (action limits, extra metadata) is delegated to
  `LemonRouter.ChannelAdapter`.
  """

  alias LemonRouter.ChannelAdapter

  @spec render(String.t() | nil, map(), [String.t()]) :: String.t()
  def render(_channel_id, _actions, []) do
    "Tool calls:\n- (none yet)"
  end

  def render(channel_id, actions, order) when is_map(actions) and is_list(order) do
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
          ["- (#{n} #{tool_word(n)} omitted)" | lines]

        _ ->
          lines
      end

    Enum.join(["Tool calls:" | lines], "\n")
  end

  defp tool_word(1), do: "tool"
  defp tool_word(_n), do: "tools"

  defp format_action_line(adapter, action) when is_map(action) do
    title = truncate_one_line(action[:title] || action["title"] || "", 80)
    extra = adapter.format_action_extra(action, title)

    case action[:phase] || action["phase"] do
      :started ->
        "- [running] " <> title <> (extra || "")

      :updated ->
        "- [running] " <> title <> (extra || "")

      :completed ->
        label = if (action[:ok] || action["ok"]) == true, do: "ok", else: "err"
        preview = extract_result_preview(action[:detail] || action["detail"])

        base = "- [#{label}] " <> title <> (extra || "")

        if preview in [nil, ""] do
          base
        else
          prev = truncate_one_line(preview, 140)
          base <> " -> " <> prev
        end

      other ->
        "- [#{other}] " <> title <> (extra || "")
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
