defmodule LemonGateway.Tools.SmsGetInboxNumber do
  @moduledoc """
  LemonAgent tool that returns the configured SMS inbox phone number.

  Reading the number reserves the shared inbox for the calling session (see
  `LemonGateway.Sms.Inbox`), so texts triggered with it are routed only to this
  session. While another session holds the reservation the number is withheld.
  """

  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonGateway.Sms.Inbox

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "sms_get_inbox_number",
      description:
        "Reserve the shared SMS inbox for this session and return its phone number (E.164) " <>
          "for verification flows. The number stays reserved for this session until it calls " <>
          "sms_release_inbox; call that when the flow is done.",
      label: "Get SMS Inbox Number",
      parameters: %{
        "type" => "object",
        "properties" => %{}
      },
      execute: &execute(&1, &2, &3, &4, session_key)
    }
  end

  def execute(_tool_call_id, _params, _signal, _on_update, session_key) do
    ToolResultTrust.untrusted(number_result(session_key), :webhook)
  end

  defp number_result(session_key) do
    with n when is_binary(n) and n != "" <- Inbox.inbox_number(),
         :ok <- Inbox.reserve(session_key) do
      %AgentToolResult{
        content: [%TextContent{type: :text, text: n}],
        details: %{inbox_number: n}
      }
    else
      {:error, reason} ->
        error_result(Inbox.error_text(reason))

      _ ->
        error_result(
          "SMS inbox number is not configured. Set TWILIO_INBOX_NUMBER (E.164, e.g. +15551234567)."
        )
    end
  end

  defp error_result(text) do
    %AgentToolResult{content: [%TextContent{type: :text, text: text}], details: %{error: true}}
  end
end
