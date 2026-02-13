defmodule LemonGateway.Tools.SmsClaimMessage do
  @moduledoc false

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "sms_claim_message",
      description:
        "Claim an inbound SMS message by MessageSid for this session. " <>
          "Normally sms_wait_for_code auto-claims the message it returns.",
      label: "Claim SMS Message",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "message_sid" => %{
            "type" => "string",
            "description" => "The Twilio MessageSid (e.g. SM...)."
          }
        },
        "required" => ["message_sid"]
      },
      execute: &execute(&1, &2, &3, &4, session_key)
    }
  end

  def execute(_tool_call_id, params, _signal, _on_update, session_key) when is_map(params) do
    message_sid = normalize_string(Map.get(params, "message_sid"))

    cond do
      not is_binary(message_sid) or message_sid == "" ->
        error_result("Missing required parameter: message_sid")

      not is_binary(session_key) or session_key == "" ->
        error_result("sms_claim_message requires a session key (internal).")

      true ->
        case LemonGateway.Sms.Inbox.claim_message(session_key, message_sid) do
          :ok ->
            %AgentToolResult{
              content: [%TextContent{type: :text, text: "Claimed message: #{message_sid}"}],
              details: %{ok: true, message_sid: message_sid}
            }

          {:error, :not_found} ->
            error_result("Message not found: #{message_sid}")

          {:error, :already_claimed} ->
            error_result("Message is already claimed: #{message_sid}")

          {:error, reason} ->
            error_result("Failed to claim message: #{inspect(reason)}")
        end
    end
  end

  def execute(_tool_call_id, _params, _signal, _on_update, _session_key) do
    error_result("Invalid parameters (expected object).")
  end

  defp error_result(text) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: text}],
      details: %{error: true}
    }
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(v) when is_binary(v) do
    v = String.trim(v)
    if v == "", do: nil, else: v
  end

  defp normalize_string(_), do: nil
end
