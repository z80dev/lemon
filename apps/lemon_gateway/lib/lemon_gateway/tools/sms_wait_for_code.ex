defmodule LemonGateway.Tools.SmsWaitForCode do
  @moduledoc """
  LemonAgent tool that polls the SMS inbox for incoming verification codes.

  Waits up to a configurable timeout for a new SMS containing a numeric code
  (default 4-8 digits, or a custom regex). Automatically claims the matched
  message for the current session to prevent duplicate consumption.

  Takes or renews the session's exclusive inbox reservation for the whole wait
  (see `LemonGateway.Sms.Inbox`) and only returns messages that arrived while
  this session held it. Results are marked untrusted.
  """

  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonGateway.Sms.Inbox

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "sms_wait_for_code",
      timeout_ms: :infinity,
      description:
        "Wait for an incoming SMS and extract a verification code (default: 4-8 digits). " <>
          "Reserves the shared inbox number for this session; call sms_get_inbox_number " <>
          "before triggering the SMS so it is routed here.",
      label: "Wait For SMS Code",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "How long to wait (milliseconds). Default: 60000, max: 600000."
          },
          "since_ms" => %{
            "type" => "integer",
            "description" => "Only consider messages received at/after this unix-ms timestamp."
          },
          "to" => %{
            "type" => "string",
            "description" =>
              "Optional: the destination number (E.164). Defaults to TWILIO_INBOX_NUMBER if set."
          },
          "from_contains" => %{
            "type" => "string",
            "description" => "Optional: case-insensitive substring match on sender number/name."
          },
          "body_contains" => %{
            "type" => "string",
            "description" => "Optional: substring match on SMS body."
          },
          "regex" => %{
            "type" => "string",
            "description" =>
              "Optional: regex string to extract the code (e.g. \"\\\\b\\\\d{6}\\\\b\")."
          },
          "claim" => %{
            "type" => "boolean",
            "description" =>
              "If true, mark the matched message as claimed by this session. Default: true."
          }
        }
      },
      execute: &execute(&1, &2, &3, &4, session_key)
    }
  end

  def execute(_tool_call_id, params, _signal, _on_update, session_key) do
    params
    |> wait(session_key)
    |> ToolResultTrust.untrusted(:webhook)
  end

  defp wait(params, _session_key) when not is_map(params),
    do: error_result("Invalid parameters (expected object).")

  defp wait(_params, session_key) when not is_binary(session_key) or session_key == "",
    do: error_result("sms_wait_for_code requires a session key (internal).")

  defp wait(params, session_key) do
    opts =
      []
      |> maybe_put(:since_ms, parse_int(Map.get(params, "since_ms"), nil))
      |> maybe_put(:timeout_ms, parse_int(Map.get(params, "timeout_ms"), 60_000))
      |> maybe_put(:to, normalize_string(Map.get(params, "to")))
      |> maybe_put(:from_contains, normalize_string(Map.get(params, "from_contains")))
      |> maybe_put(:body_contains, normalize_string(Map.get(params, "body_contains")))
      |> maybe_put(:regex, normalize_string(Map.get(params, "regex")))
      |> maybe_put(:claim, parse_bool(Map.get(params, "claim"), true))

    case Inbox.wait_for_code(session_key, opts) do
      {:ok, %{code: code, message: msg}} ->
        from = msg["from"]
        to = msg["to"]
        sid = msg["message_sid"]
        ts = msg["received_at_ms"]

        %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text:
                "Code: #{code}\nFrom: #{from}\nTo: #{to}\nMessageSid: #{sid}\nReceivedAtMs: #{ts}"
            }
          ],
          details: %{code: code, message_sid: sid}
        }

      {:error, :timeout} ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "Timed out waiting for an SMS code."}],
          details: %{timeout: true, error: true}
        }

      {:error, reason} ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: Inbox.error_text(reason)}],
          details: %{error: true, reason: reason}
        }
    end
  end

  defp error_result(text) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: text}],
      details: %{error: true}
    }
  end

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
