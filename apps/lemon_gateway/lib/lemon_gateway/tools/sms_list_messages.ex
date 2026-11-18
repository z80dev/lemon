defmodule LemonGateway.Tools.SmsListMessages do
  @moduledoc """
  LemonAgent tool for listing and filtering inbound SMS messages.

  Lists only messages bound to the calling session by its inbox reservation
  (see `LemonGateway.Sms.Inbox`). Calling it takes or renews the reservation;
  while another session holds it, no content is returned. Message bodies are
  attacker-controlled, so results are marked untrusted.
  """

  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "sms_list_messages",
      description:
        "List inbound SMS messages received for this session while it held the shared inbox " <>
          "reservation. Reserves the inbox. OTP flows generally use sms_wait_for_code.",
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

  def execute(_tool_call_id, params, _signal, _on_update, session_key) do
    params
    |> list(session_key)
    |> ToolResultTrust.untrusted(:webhook)
  end

  defp list(params, session_key)
       when not is_binary(session_key) or session_key == "" or not is_map(params) do
    if is_map(params),
      do: error_result("sms_list_messages requires a session key (internal)."),
      else: error_result("Invalid parameters (expected object).")
  end

  defp list(params, session_key) do
    if parse_bool(Map.get(params, "include_claimed"), false) do
      error_result("include_claimed is not available to agent sessions.")
    else
      opts =
        []
        |> maybe_put(:limit, parse_int(Map.get(params, "limit"), 20))
        |> maybe_put(:since_ms, parse_int(Map.get(params, "since_ms"), nil))
        |> maybe_put(:to, normalize_string(Map.get(params, "to")))
        |> maybe_put(:from_contains, normalize_string(Map.get(params, "from_contains")))
        |> maybe_put(:body_contains, normalize_string(Map.get(params, "body_contains")))

      case LemonGateway.Sms.Inbox.list_session_messages(session_key, opts) do
        {:ok, messages} ->
          only_mine = parse_bool(Map.get(params, "only_mine"), false)
          messages = maybe_filter_only_mine(messages, only_mine, session_key)

          %AgentToolResult{
            content: [%TextContent{type: :text, text: format_messages(messages)}],
            details: %{
              count: length(messages),
              message_sids: Enum.map(messages, & &1["message_sid"])
            }
          }

        {:error, reason} ->
          error_result(LemonGateway.Sms.Inbox.error_text(reason))
      end
    end
  end

  defp error_result(text) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: text}],
      details: %{error: true}
    }
  end

  defp maybe_filter_only_mine(messages, true, session_key),
    do: Enum.filter(messages, fn msg -> msg["claimed_by"] == session_key end)

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
