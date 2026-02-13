defmodule LemonGateway.Tools.SmsWaitForCode do
  @moduledoc false

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "sms_wait_for_code",
      description:
        "Wait for an incoming SMS and extract a verification code (default: 4-8 digits). " <>
          "Useful for website registration/verification flows using the shared inbox number.",
      label: "Wait For SMS Code",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "How long to wait (milliseconds). Default: 60000."
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

  def execute(_tool_call_id, params, _signal, _on_update, session_key) when is_map(params) do
    timeout_ms = parse_int(Map.get(params, "timeout_ms"), 60_000)
    since_ms = parse_int(Map.get(params, "since_ms"), nil)
    to = normalize_string(Map.get(params, "to"))
    from_contains = normalize_string(Map.get(params, "from_contains"))
    body_contains = normalize_string(Map.get(params, "body_contains"))
    regex = normalize_string(Map.get(params, "regex"))
    claim = parse_bool(Map.get(params, "claim"), true)

    opts =
      []
      |> maybe_put(:timeout_ms, timeout_ms)
      |> maybe_put(:since_ms, since_ms)
      |> maybe_put(:to, to)
      |> maybe_put(:from_contains, from_contains)
      |> maybe_put(:body_contains, body_contains)
      |> maybe_put(:regex, regex)
      |> maybe_put(:claim, claim)

    case LemonGateway.Sms.Inbox.wait_for_code(session_key, opts) do
      {:ok, %{code: code, message: msg}} ->
        from = msg["from"] || msg[:from]
        to = msg["to"] || msg[:to]
        sid = msg["message_sid"] || msg[:message_sid]
        ts = msg["received_at_ms"] || msg[:received_at_ms]

        %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text:
                "Code: #{code}\nFrom: #{from}\nTo: #{to}\nMessageSid: #{sid}\nReceivedAtMs: #{ts}"
            }
          ],
          details: %{code: code, message: msg}
        }

      {:error, :timeout} ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: "Timed out waiting for an SMS code."}],
          details: %{timeout: true, error: true}
        }

      {:error, reason} ->
        %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text: "Failed waiting for an SMS code: #{inspect(reason)}"
            }
          ],
          details: %{error: true, reason: reason}
        }
    end
  end

  def execute(_tool_call_id, _params, _signal, _on_update, _session_key) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: "Invalid parameters (expected object)."}],
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
