defmodule CodingAgent.Session.ContextBudgetTest do
  use ExUnit.Case, async: true
  alias CodingAgent.{SessionManager, SettingsManager}
  alias CodingAgent.Session.{ContextBudget, Planning}
  alias LemonAi.Types.{AssistantMessage, Model, TextContent, Usage}

  test "budget uses latest request usage, configured reserve, and invalidates changed plan context" do
    settings = %{
      SettingsManager.load(System.tmp_dir!())
      | reserve_tokens: 512,
        compaction_enabled: true
    }

    manager = SessionManager.new(System.tmp_dir!())

    state = %{
      session_manager: manager,
      settings_manager: settings,
      model: %Model{context_window: 10_000}
    }

    first = %AssistantMessage{
      content: [%TextContent{text: "old"}],
      usage: %Usage{input: 8_000, output: 100},
      stop_reason: :stop,
      timestamp: 1
    }

    last = %AssistantMessage{
      content: [%TextContent{text: "latest"}],
      usage: %Usage{input: 1_000, output: 20, cache_read: 30},
      stop_reason: :stop,
      timestamp: 2
    }

    agent = %{messages: [first, last], system_prompt: "Current system prompt", tools: []}
    budget = ContextBudget.measure(state, agent)
    assert budget.tokens == 1_050
    assert budget.source == "usage"
    assert budget.window == 10_000
    assert budget.reserve_tokens == 512
    assert budget.threshold_tokens == 9_488
    assert budget.headroom_tokens == 8_438
    {:ok, _, manager} = Planning.transition(manager, :enter, [])
    estimate = ContextBudget.measure(%{state | session_manager: manager}, agent)
    assert estimate.source == "estimate"
    assert is_integer(estimate.usage_after)

    assert estimate.tokens ==
             CodingAgent.Compaction.estimate_request_context_tokens(
               agent.messages,
               agent.system_prompt,
               [],
               estimate.usage_after
             )
  end
end
