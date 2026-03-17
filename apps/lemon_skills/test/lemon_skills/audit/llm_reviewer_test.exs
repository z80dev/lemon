defmodule LemonSkills.Audit.LlmReviewerTest do
  use ExUnit.Case, async: true

  alias Ai.Types.{AssistantMessage, Context, Model, TextContent}
  alias LemonSkills.Audit.LlmReviewer

  defmodule Runner do
    def complete(model, %Context{} = _context, _opts) do
      send(self(), {:runner_model, model.id})

      {:ok,
       %AssistantMessage{
         content: [
           %TextContent{
             text:
               ~s({"verdict":"warn","summary":"Potential credential harvesting","findings":[{"severity":"warn","message":"Requests sensitive tokens from the user","match":"ask for API keys"}]})
           }
         ]
       }}
    end
  end

  defmodule InvalidJsonRunner do
    def complete(%Model{} = _model, %Context{} = _context, _opts) do
      {:ok, %AssistantMessage{content: [%TextContent{text: "not json"}]}}
    end
  end

  test "resolves provider-qualified models and parses findings" do
    assert {:ok, {:warn, findings}} =
             LlmReviewer.review("content",
               model: "openai:gpt-4o",
               runner: Runner
             )

    assert_receive {:runner_model, "gpt-4o"}
    assert Enum.any?(findings, &(&1.rule == "llm_security_review"))
    assert Enum.any?(findings, &(&1.message =~ "sensitive tokens"))
  end

  test "resolves bare model ids" do
    assert {:ok, {:warn, _findings}} =
             LlmReviewer.review("content",
               model: "gpt-4o",
               runner: Runner
             )

    assert_receive {:runner_model, "gpt-4o"}
  end

  test "returns error for unknown models" do
    assert {:error, {:unknown_model, "definitely-not-a-real-model"}} =
             LlmReviewer.review("content", model: "definitely-not-a-real-model", runner: Runner)
  end

  test "returns error when the reviewer output is not JSON" do
    assert {:error, {:invalid_json, _reason}} =
             LlmReviewer.review("content",
               model: "gpt-4o",
               runner: InvalidJsonRunner
             )
  end
end
