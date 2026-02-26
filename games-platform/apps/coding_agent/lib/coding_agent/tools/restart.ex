defmodule CodingAgent.Tools.Restart do
  @moduledoc """
  Restart the Lemon agent process.

  This tool is intended for development workflows where the agent is running
  under the Lemon TUI (debug_agent_rpc). It exits the BEAM with a special
  exit code that the TUI treats as "restart requested", causing it to spawn a
  fresh `mix run ...` process and pick up the latest code on disk.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.UI.Context, as: UIContext

  @restart_exit_code 75

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    %AgentTool{
      name: "restart",
      description:
        "Restart the Lemon agent process (development). Exits the agent and lets the TUI respawn it so code changes are recompiled.",
      label: "Restart Agent",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "reason" => %{
            "type" => "string",
            "description" => "Optional reason to display for the restart."
          },
          "confirm" => %{
            "type" => "boolean",
            "description" =>
              "Whether to ask the user to confirm before restarting (default: true when UI is available)."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, opts)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          keyword()
        ) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update, opts) do
    reason = Map.get(params, "reason")
    confirm? = Map.get(params, "confirm")

    ui_context = Keyword.get(opts, :ui_context)

    # Safety: In non-TUI contexts (e.g. gateway/Telegram), halting the VM would take down the node.
    # Allow only when running under the DebugRPC UI (TUI) unless explicitly enabled via env var.
    allow_env? = System.get_env("LEMON_ALLOW_RESTART_TOOL") == "1"
    allow_debug_ui? = match?(%UIContext{module: CodingAgent.UI.DebugRPC}, ui_context)

    reason_text =
      case reason do
        r when is_binary(r) ->
          r = String.trim(r)
          if r == "", do: nil, else: r

        _ ->
          nil
      end

    if not allow_env? and not allow_debug_ui? do
      %AgentToolResult{
        content: [
          %TextContent{
            text:
              "Restart is only supported when running under the Lemon TUI debug RPC. " <>
                "On Telegram/gateway this would stop the whole node; use your service manager (systemd/k8s) to restart and deploy a new version."
          }
        ],
        details: %{restarted: false, denied: true}
      }
    else
      needs_confirm? =
        case confirm? do
          true -> true
          false -> false
          _ -> not is_nil(ui_context) and UIContext.has_ui?(ui_context)
        end

      if needs_confirm? and not is_nil(ui_context) and UIContext.has_ui?(ui_context) do
        message =
          case reason_text do
            r when is_binary(r) ->
              "Restart the Lemon agent now?\n\nReason: #{r}\n\nThis will stop all running sessions."

            _nil ->
              "Restart the Lemon agent now?\n\nThis will stop all running sessions."
          end

        case UIContext.confirm(ui_context, "Restart Agent", message) do
          {:ok, true} -> do_restart(ui_context, reason_text)
          {:ok, false} -> cancelled()
          {:error, _} -> do_restart(ui_context, reason_text)
        end
      else
        do_restart(ui_context, reason_text)
      end
    end
  end

  defp cancelled do
    %AgentToolResult{
      content: [%TextContent{text: "Restart cancelled."}],
      details: %{restarted: false}
    }
  end

  defp do_restart(ui_context, reason_text) do
    if ui_context do
      msg =
        case reason_text do
          r when is_binary(r) -> "Restarting agent: #{r}"
          _nil -> "Restarting agent..."
        end

      _ = UIContext.notify(ui_context, msg, :warning)
    end

    # Return a tool result so the user sees what happened, then exit shortly after.
    Task.start(fn ->
      Process.sleep(200)
      System.halt(@restart_exit_code)
    end)

    %AgentToolResult{
      content: [%TextContent{text: "Restart requested. The agent will reconnect shortly."}],
      details: %{restarted: true, exit_code: @restart_exit_code, reason: reason_text}
    }
  end
end
