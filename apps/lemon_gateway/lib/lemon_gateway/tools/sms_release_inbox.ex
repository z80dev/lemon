defmodule LemonGateway.Tools.SmsReleaseInbox do
  @moduledoc """
  LemonAgent tool that releases the calling session's SMS inbox reservation.

  Reservations never expire, so this is how a session hands the shared number
  back. Messages already bound to the session stay visible only to it, and the
  number stays bound to it for the handoff grace period after release; texts
  arriving later go to whichever session reserves next, or to none.
  """

  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonGateway.Sms.Inbox

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = Keyword.get(opts, :session_key)

    %AgentTool{
      name: "sms_release_inbox",
      description:
        "Release this session's reservation of the shared SMS inbox once its verification " <>
          "flow is finished, so other sessions can use the number.",
      label: "Release SMS Inbox",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: &execute(&1, &2, &3, &4, session_key)
    }
  end

  def execute(_tool_call_id, _params, _signal, _on_update, session_key) do
    result =
      case Inbox.release(session_key) do
        :ok ->
          %AgentToolResult{
            content: [%TextContent{type: :text, text: "SMS inbox released."}],
            details: %{ok: true}
          }

        {:error, reason} ->
          %AgentToolResult{
            content: [%TextContent{type: :text, text: Inbox.error_text(reason)}],
            details: %{error: true}
          }
      end

    ToolResultTrust.untrusted(result, :webhook)
  end
end
