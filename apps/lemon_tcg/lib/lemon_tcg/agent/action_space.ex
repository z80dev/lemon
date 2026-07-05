defmodule LemonTcg.Agent.ActionSpace do
  @moduledoc """
  `LemonSim.Kernel.ActionSpace` for a live desk session.

  Desk tools come from `LemonTcg.Agent.Tools` bound to the desk pid in
  `state.meta.desk`; this module adds the two session-control terminals:
  `tcg_live_wait` (end the turn, optionally sleeping `:turn_interval_ms`
  before the next market look) and `tcg_live_close_session`.
  """

  @behaviour LemonSim.Kernel.ActionSpace

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonCore.MapHelpers
  alias LemonTcg.Agent.Tools

  @impl true
  def tools(state, opts) do
    world = state.world

    if MapHelpers.get_key(world, :status) == "in_progress" do
      desk = Map.fetch!(state.meta, :desk)
      {:ok, Tools.build(desk) ++ [wait_tool(opts), close_session_tool()]}
    else
      {:ok, []}
    end
  end

  @doc "Support tools are the desk's read-only tools."
  def support_tool?(tool), do: Tools.support_tool?(tool)

  defp wait_tool(opts) do
    interval_ms = Keyword.get(opts, :turn_interval_ms, 0)

    %AgentTool{
      name: "tcg_live_wait",
      description:
        "End this turn and check the market again next turn. Use when there is " <>
          "nothing worth doing at current prices.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "reason" => %{"type" => "string", "description" => "Why you are waiting."}
        },
        "required" => [],
        "additionalProperties" => false
      },
      label: "Wait",
      execute: fn _id, params, _signal, _on_update ->
        if interval_ms > 0, do: Process.sleep(interval_ms)

        event_result(
          "Turn ended. Market will be re-checked next turn.",
          "tcg_live_waited",
          %{"reason" => Map.get(params, "reason", "")}
        )
      end
    }
  end

  defp close_session_tool do
    %AgentTool{
      name: "tcg_live_close_session",
      description:
        "Close the trading session permanently. Use when the session goal is met " <>
          "or continuing would only lose money.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "reason" => %{"type" => "string", "description" => "Why you are closing."}
        },
        "required" => [],
        "additionalProperties" => false
      },
      label: "Close Session",
      execute: fn _id, params, _signal, _on_update ->
        event_result(
          "Session closed.",
          "tcg_live_session_closed",
          %{"reason" => Map.get(params, "reason", "")}
        )
      end
    }
  end

  defp event_result(text, kind, payload) do
    {:ok,
     %AgentToolResult{
       content: [AgentCore.text_content(text)],
       details: %{"event" => %{"kind" => kind, "payload" => payload}},
       trust: :trusted
     }}
  end
end
