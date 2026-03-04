defmodule LemonSim.Deciders.ToolLoopDeciderTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.{AssistantMessage, Context, Model, TextContent, ToolCall}
  alias LemonSim.Deciders.ToolLoopDecider

  test "loops through memory tools and returns first non-memory tool decision" do
    tmp_dir = System.tmp_dir!()
    namespace = "sim_decider_mem_#{System.unique_integer([:positive])}"

    {:ok, seq} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _ctx, _stream_opts ->
      turn = Agent.get_and_update(seq, fn n -> {n, n + 1} end)

      message =
        case turn do
          0 ->
            assistant_tool_call("tc-memory", "memory_write_file", %{
              "path" => "notes/faction.md",
              "content" => "alliance pending"
            })

          _ ->
            assistant_tool_call("tc-action", "attack", %{"target" => "goblin"})
        end

      {:ok, message}
    end

    tools = [
      %AgentCore.Types.AgentTool{
        name: "attack",
        description: "Attack a visible enemy",
        parameters: %{
          "type" => "object",
          "properties" => %{"target" => %{"type" => "string"}},
          "required" => ["target"]
        },
        label: "Attack",
        execute: fn _id, _params, _signal, _on_update ->
          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content("attack committed")],
             details: %{ok: true},
             trust: :trusted
           }}
        end
      }
    ]

    context =
      Context.new(system_prompt: "Pick actions via tools only")
      |> Context.add_user_message("enemy spotted")

    assert {:ok, decision} =
             ToolLoopDecider.decide(
               context,
               tools,
               model: fake_model(),
               complete_fn: complete_fn,
               memory_root: tmp_dir,
               memory_namespace: namespace
             )

    assert decision["type"] == "tool_call"
    assert decision["tool_name"] == "attack"
    assert decision["arguments"] == %{"target" => "goblin"}

    memory_file = Path.join([tmp_dir, namespace, "notes", "faction.md"])
    assert File.read!(memory_file) == "alliance pending"
  end

  test "returns assistant text decision when no tool call is produced" do
    complete_fn = fn _model, _ctx, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [%TextContent{type: :text, text: "hold position"}],
         stop_reason: :stop,
         timestamp: System.system_time(:millisecond)
       }}
    end

    context = Context.new(system_prompt: "Return a direct instruction")

    assert {:ok, decision} =
             ToolLoopDecider.decide(
               context,
               [],
               model: fake_model(),
               include_memory_tools: false,
               complete_fn: complete_fn
             )

    assert decision["type"] == "assistant_text"
    assert decision["text"] == "hold position"
  end

  test "returns error when model is missing" do
    assert {:error, :missing_model} =
             ToolLoopDecider.decide(Context.new(), [], include_memory_tools: false)
  end

  defp assistant_tool_call(id, name, args) do
    %AssistantMessage{
      role: :assistant,
      content: [%ToolCall{type: :tool_call, id: id, name: name, arguments: args}],
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp fake_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end
end
