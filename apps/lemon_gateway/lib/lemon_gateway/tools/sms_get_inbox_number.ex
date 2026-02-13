defmodule LemonGateway.Tools.SmsGetInboxNumber do
  @moduledoc false

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, _opts \\ []) do
    %AgentTool{
      name: "sms_get_inbox_number",
      description: "Return the configured SMS inbox phone number (E.164) for verification flows.",
      label: "Get SMS Inbox Number",
      parameters: %{
        "type" => "object",
        "properties" => %{}
      },
      execute: &execute/4
    }
  end

  def execute(_tool_call_id, _params, _signal, _on_update) do
    case LemonGateway.Sms.Inbox.inbox_number() do
      n when is_binary(n) and n != "" ->
        %AgentToolResult{
          content: [%TextContent{type: :text, text: n}],
          details: %{inbox_number: n}
        }

      _ ->
        %AgentToolResult{
          content: [
            %TextContent{
              type: :text,
              text:
                "SMS inbox number is not configured. Set TWILIO_INBOX_NUMBER (E.164, e.g. +15551234567)."
            }
          ],
          details: %{error: true}
        }
    end
  end
end
