defmodule LemonGateway.Tools.SmsListMessages do
  @moduledoc false

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "sms_list_messages",
      description:
        "List recent inbound SMS messages received by the shared inbox number. " <>
          "Useful for debugging or manual inspection (OTP flows generally use sms_wait_for_code).",
      label: "List SMS Messages",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max number of messages to return (default: 20)."
          },
          "since_ms" => %{
            "type" => "integer",
            "description" => "Only include messages received at/after this unix-ms timestamp."
          },
          "to" => %{
            "type" => "string",
            "description" => "Optional: destination number (E.164)."
          },
          "from_contains" => %{
            "type" => "string",
            "description" => "Optional: case-insensitive substring match on sender number/name."
          },
          "body_contains" => %{
            "type" => "string",
            "description" => "Optional: substring match on SMS body."
          },
          "include_claimed" => %{
            "type" => "boolean",
            "description" => "If true, include claimed messages. Default: false."
          },
          "only_mine" => %{
            "type" => "boolean",
            "description" =>
              "If true, only show messages claimed by this session. Default: false."
          }
        }
      },
      execute: &execute(&1, &2, &3, &4, session_key)
    }
  end

  def execute(_tool_call_id, params, _signal, _on_update, session_key) when is_map(params) do
    limit = parse_int(Map.get(params, "limit"), 20)
    since_ms = parse_int(Map.get(params, "since_ms"), nil)
    to = normalize_string(Map.get(params, "to"))
    from_contains = normalize_string(Map.get(params, "from_contains"))
    body_contains = normalize_string(Map.get(params, "body_contains"))
    include_claimed = parse_bool(Map.get(params, "include_claimed"), false)
    only_mine = parse_bool(Map.get(params, "only_mine"), false)

    opts =
      []
      |> maybe_put(:limit, limit)
      |> maybe_put(:since_ms, since_ms)
      |> maybe_put(:to, to)
      |> maybe_put(:from_contains, from_contains)
      |> maybe_put(:body_contains, body_contains)
      |> maybe_put(:include_claimed, include_claimed)

    messages =
      LemonGateway.Sms.Inbox.list_messages(opts)
      |> maybe_filter_only_mine(only_mine, session_key)

    %AgentToolResult{
      content: [%TextContent{type: :text, text: format_messages(messages)}],
      details: %{count: length(messages), messages: messages}
    }
  end

  def execute(_tool_call_id, _params, _signal, _on_update, _session_key) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: "Invalid parameters (expected object)."}],
      details: %{error: true}
    }
  end

  defp maybe_filter_only_mine(messages, true, session_key)
       when is_list(messages) and is_binary(session_key) and session_key != "" do
    Enum.filter(messages, fn msg -> msg["claimed_by"] == session_key end)
  end

  defp maybe_filter_only_mine(messages, _only_mine, _session_key), do: messages

  defp format_messages([]), do: "No messages."

  defp format_messages(messages) when is_list(messages) do
    header = "Messages: #{length(messages)}"

    lines =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {msg, idx} ->
        sid = msg["message_sid"]
        from = msg["from"]
        to = msg["to"]
        ts = msg["received_at_ms"]
        claimed_by = msg["claimed_by"]
        codes = msg["codes"] || []
        body = truncate(to_string(msg["body"] || ""), 200)

        base =
          [
            "#{idx}. MessageSid=#{sid}",
            "From=#{from}",
            "To=#{to}",
            "ReceivedAtMs=#{ts}",
            "Codes=#{inspect(codes)}",
            "ClaimedBy=#{claimed_by || "nil"}",
            "Body=#{inspect(body)}"
          ]
          |> Enum.join(" ")

        base
      end)

    Enum.join([header | lines], "\n")
  end

  defp truncate(str, max) when is_binary(str) and is_integer(max) and max > 0 do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp truncate(str, _max), do: str

  defp parse_int(nil, default), do: default
  defp parse_int(v, _default) when is_integer(v), do: v

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_v, default), do: default

  defp parse_bool(nil, default), do: default
  defp parse_bool(v, _default) when is_boolean(v), do: v

  defp parse_bool(v, default) when is_binary(v) do
    v = v |> String.trim() |> String.downcase()

    cond do
      v in ["1", "true", "yes", "on"] -> true
      v in ["0", "false", "no", "off"] -> false
      v == "" -> default
      true -> default
    end
  end

  defp parse_bool(_v, default), do: default

  defp normalize_string(nil), do: nil

  defp normalize_string(v) when is_binary(v) do
    v = String.trim(v)
    if v == "", do: nil, else: v
  end

  defp normalize_string(_), do: nil

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)
end
