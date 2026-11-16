defmodule LemonAi.Providers.VendorCustomTool603Test do
  use ExUnit.Case, async: true

  alias LemonAi.EventStream
  alias LemonAi.Providers.OpenAIResponsesShared, as: Shared

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Cost,
    Model,
    ModelCost,
    TextContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    Usage
  }

  defp model do
    %Model{
      id: "gpt-5.3-codex",
      name: "Codex",
      api: :openai_codex_responses,
      provider: :openai_codex,
      cost: %ModelCost{}
    }
  end

  defp tool do
    %Tool{
      name: "apply_patch",
      description: "Patch",
      parameters: %{
        "type" => "object",
        "properties" => %{"input" => %{"type" => "string"}},
        "required" => ["input"],
        "x-lemon-tool-format" => %{
          "type" => "grammar",
          "syntax" => "lark",
          "definition" => "start: /.+/"
        }
      }
    }
  end

  test "custom schema emits upstream grammar without function-only fields" do
    assert [
             %{"type" => "custom", "name" => "apply_patch", "format" => %{"syntax" => "lark"}} =
               wire
           ] = Shared.convert_tools([tool()], %{strict: true})

    refute Map.has_key?(wire, "parameters")
    refute Map.has_key?(wire, "strict")

    assert [%{"type" => "function", "strict" => false}] =
             Shared.convert_tools([%Tool{name: "native", parameters: %{"type" => "object"}}])
  end

  test "freeform streamed input becomes validated object arguments and replays as custom input/output" do
    {:ok, stream} = EventStream.start_link()
    on_exit(fn -> if Process.alive?(stream), do: EventStream.cancel(stream, :test_cleanup) end)
    patch = "*** Begin Patch\n*** Add File: hello\n+hi\n*** End Patch\n"

    item = %{
      "type" => "custom_tool_call",
      "id" => "ctc_603",
      "call_id" => "call_603",
      "name" => "apply_patch"
    }

    events = [
      %{"type" => "response.output_item.added", "item" => Map.put(item, "input", "")},
      %{"type" => "response.custom_tool_call_input.delta", "delta" => patch},
      %{"type" => "response.custom_tool_call_input.done", "input" => patch},
      %{"type" => "response.output_item.done", "item" => Map.put(item, "input", patch)},
      %{"type" => "response.completed", "response" => %{"status" => "completed"}}
    ]

    output = %AssistantMessage{
      api: :openai_codex_responses,
      provider: :openai_codex,
      model: model().id,
      usage: %Usage{cost: %Cost{}}
    }

    assert {:ok, final} = Shared.process_stream(events, output, stream, model())

    assert [%ToolCall{name: "apply_patch", arguments: %{"input" => ^patch}} = call] =
             final.content

    assert call.id == "call_603|ctc_603"

    result = %ToolResultMessage{
      tool_call_id: call.id,
      tool_name: call.name,
      content: [%TextContent{text: "done"}]
    }

    context = %Context{tools: [tool()], messages: [final, result]}
    wire = Shared.convert_messages(model(), context, MapSet.new([:openai_codex]))
    assert Enum.any?(wire, &match?(%{"type" => "custom_tool_call", "input" => ^patch}, &1))

    assert Enum.any?(
             wire,
             &match?(%{"type" => "custom_tool_call_output", "output" => "done"}, &1)
           )

    refute Enum.any?(wire, &(&1["type"] in ["function_call", "function_call_output"]))

    # Historical custom protocol items remain custom after disabling the
    # experiment or selecting another model; only their execution exposure changes.
    for next_model <- [model(), %{model() | id: "gpt-5.4-codex"}] do
      replay =
        Shared.convert_messages(next_model, %{context | tools: []}, MapSet.new([:openai_codex]))

      assert Enum.any?(replay, &match?(%{"type" => "custom_tool_call", "input" => ^patch}, &1))

      assert Enum.any?(
               replay,
               &match?(%{"type" => "custom_tool_call_output", "output" => "done"}, &1)
             )
    end
  end

  test "prebuilt custom output uses the same byte cap as function output" do
    params = %{
      "input" => [
        %{
          "type" => "custom_tool_call_output",
          "call_id" => "call_603",
          "output" => String.duplicate("x", 80_000)
        }
      ]
    }

    assert %{"input" => [%{"output" => output}]} = Shared.clamp_function_call_outputs(params)
    assert byte_size(output) == 65_536
  end
end
