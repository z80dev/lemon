defmodule AgentCoreTest do
  use ExUnit.Case
  doctest AgentCore

  alias AgentCore.Test.Mocks

  describe "AgentCore module" do
    test "module exists" do
      assert Code.ensure_loaded?(AgentCore)
    end

    test "exposes Types submodule" do
      assert Code.ensure_loaded?(AgentCore.Types)
    end

    test "exposes EventStream submodule" do
      assert Code.ensure_loaded?(AgentCore.EventStream)
    end

    test "exposes Loop submodule" do
      assert Code.ensure_loaded?(AgentCore.Loop)
    end

    test "exposes Agent submodule" do
      assert Code.ensure_loaded?(AgentCore.Agent)
    end
  end

  describe "new_agent/1" do
    test "accepts top-level initial state options" do
      model = Mocks.mock_model(id: "agentcore-top-level")

      {:ok, agent} =
        AgentCore.new_agent(
          model: model,
          system_prompt: "Top-level prompt",
          tools: [Mocks.echo_tool()]
        )

      state = AgentCore.get_state(agent)

      assert state.model.id == "agentcore-top-level"
      assert state.system_prompt == "Top-level prompt"
      assert length(state.tools) == 1
    end
  end

  describe "wait_for_idle/2" do
    test "accepts numeric timeout" do
      response = Mocks.assistant_message("Hello")

      {:ok, agent} =
        AgentCore.new_agent(
          model: Mocks.mock_model(),
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      :ok = AgentCore.prompt(agent, "Hi")

      assert :ok = AgentCore.wait_for_idle(agent, 1000)
    end
  end
end
