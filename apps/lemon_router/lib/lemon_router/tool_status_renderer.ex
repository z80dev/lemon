defmodule LemonRouter.ToolStatusRenderer do
  @moduledoc """
  Renders the "Tool calls" status text for user-facing transports.

  This is used by `LemonRouter.ToolStatusCoalescer` to build the editable status
  message shown in transports like Telegram.
  """

  @telegram_recent_action_limit 5

  @spec render(String.t() | nil, map(), [String.t()]) :: String.t()
  def render(_channel_id, _actions, []) do
    "Tool calls:\n- (none yet)"
  end

  def render(channel_id, actions, order) when is_map(actions) and is_list(order) do
    {display_order, omitted_count} = limit_order_for_channel(channel_id, order)

    lines =
      Enum.map(display_order, fn id ->
        case Map.get(actions, id) do
          nil -> nil
          action -> format_action_line(channel_id, action)
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

  defp limit_order_for_channel("telegram", order) when is_list(order) do
    if length(order) > @telegram_recent_action_limit do
      display_order = Enum.take(order, -@telegram_recent_action_limit)
      omitted_count = length(order) - length(display_order)
      {display_order, omitted_count}
    else
      {order, 0}
    end
  end

  defp limit_order_for_channel(_channel_id, order), do: {order, 0}

  defp tool_word(1), do: "tool"
  defp tool_word(_n), do: "tools"

  defp format_action_line(channel_id, action) when is_map(action) do
    title = truncate_one_line(action[:title] || action["title"] || "", 80)
    extra = if channel_id == "telegram", do: format_task_extra(action, title), else: nil

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

  # Telegram users otherwise see just "task". Provide context for Task/subagent tool calls.
  defp format_task_extra(action, rendered_title) do
    kind = normalize_kind(action[:kind] || action["kind"])
    detail = action[:detail] || action["detail"] || %{}
    args = extract_args(detail)
    tool_name = normalize_optional_string(map_get_any(detail, [:name, "name"]))

    task_like? =
      kind == "subagent" or
        String.downcase(tool_name || "") == "task" or
        generic_task_title?(rendered_title)

    if not task_like? do
      nil
    else
      # We show:
      # - selected task engine (default: internal) if args are present
      # - role if present
      # - caller engine (from gateway event) if present and differs
      # - prompt/description snippet when title is generic (task/Task)
      task_engine =
        cond do
          is_map(args) and map_size(args) > 0 ->
            normalize_optional_string(map_get_any(args, [:engine, "engine"])) || "internal"

          kind == "subagent" ->
            # Task tool defaults to internal if not explicitly overridden.
            "internal"

          true ->
            nil
        end

      role = normalize_optional_string(map_get_any(args, [:role, "role"]))
      desc = normalize_optional_string(map_get_any(args, [:description, "description"]))
      prompt = normalize_optional_string(map_get_any(args, [:prompt, "prompt"]))
      async = map_get_any(args, [:async, "async"])
      task_id = normalize_optional_string(map_get_any(args, [:task_id, "task_id"]))

      caller_engine = normalize_optional_string(action[:caller_engine] || action["caller_engine"])

      meta =
        []
        |> maybe_add_kv("engine", task_engine)
        |> maybe_add_kv("role", role)
        |> maybe_add_flag("async", async == true)
        |> maybe_add_kv("task_id", task_id)
        |> maybe_add_via(caller_engine, task_engine)
        |> Enum.join(" ")

      snippet =
        if generic_task_title?(rendered_title) do
          cond do
            is_binary(desc) and desc != "" ->
              " desc: " <> quote_snip(desc, 120)

            is_binary(prompt) and prompt != "" ->
              " prompt: " <> quote_snip(prompt, 120)

            true ->
              ""
          end
        else
          ""
        end

      if meta == "" and snippet == "" do
        nil
      else
        " (" <> meta <> ")" <> snippet
      end
    end
  rescue
    _ -> nil
  end

  defp maybe_add_kv(parts, _k, v) when v in [nil, ""], do: parts
  defp maybe_add_kv(parts, k, v), do: parts ++ ["#{k}=#{v}"]

  defp maybe_add_flag(parts, _flag, false), do: parts
  defp maybe_add_flag(parts, flag, true), do: parts ++ [flag]

  defp maybe_add_via(parts, nil, _task_engine), do: parts

  defp maybe_add_via(parts, caller_engine, nil) do
    if caller_engine != "" do
      parts ++ ["via=#{caller_engine}"]
    else
      parts
    end
  end

  defp maybe_add_via(parts, caller_engine, task_engine) do
    if caller_engine != "" and caller_engine != task_engine do
      parts ++ ["via=#{caller_engine}"]
    else
      parts
    end
  end

  defp extract_args(detail) when is_map(detail) do
    args = map_get_any(detail, [:args, "args"])
    if is_map(args), do: args, else: %{}
  end

  defp extract_args(_), do: %{}

  defp generic_task_title?(title) when is_binary(title) do
    t = title |> String.trim()
    down = String.downcase(t)
    down == "task" or down == "task:" or down == "task tool" or down == "run task"
  end

  defp generic_task_title?(_), do: false

  defp quote_snip(text, max_len) when is_binary(text) do
    snip = truncate_one_line(text, max_len)
    "\"" <> snip <> "\""
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(_), do: ""

  defp extract_result_preview(detail) when is_map(detail) do
    preview =
      detail[:result_preview] ||
        detail["result_preview"] ||
        detail[:result] ||
        detail["result"]

    # The action detail may contain rich structs (AgentToolResult/TextContent) or
    # `inspect/1` output of those structs. For user-facing transports (Telegram),
    # render only the underlying text.
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

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(s) when is_binary(s), do: String.trim(s)

  defp normalize_optional_string(other) do
    (LemonRouter.ToolPreview.to_text(other) || inspect(other))
    |> String.trim()
  rescue
    _ -> inspect(other) |> String.trim()
  end

  defp map_get_any(map, [k1, k2]) when is_map(map) do
    Map.get(map, k1) || Map.get(map, k2)
  end

  defp map_get_any(_map, _keys), do: nil
end
