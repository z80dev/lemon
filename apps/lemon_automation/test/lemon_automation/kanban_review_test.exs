defmodule LemonAutomation.KanbanReviewTest do
  use ExUnit.Case, async: true
  alias LemonAutomation.KanbanReview

  test "reviewer defaults route automatically while requested review models stay explicit" do
    task = %{
      assignee: "reviewer",
      board_id: "board",
      id: "task",
      title: "Review",
      description: ""
    }

    checkpoint = %{"cwd" => "/repo", "codingRunId" => "coding"}
    snapshot = %{"tree" => "tree"}

    for {persona_model, review_model, expected_model, explicit} <- [
          {"@review", nil, "@review", false},
          {"@review", "openai:gpt-4o", "openai:gpt-4o", false},
          {nil, nil, "openai:gpt-4o-mini", true}
        ] do
      assert {:ok, params} =
               KanbanReview.params(
                 task,
                 checkpoint,
                 snapshot,
                 %{review_model: review_model},
                 "review",
                 model: "openai:gpt-4o-mini",
                 reviewer_resolver: fn _, _ ->
                   {:ok, %{prompt: "Review", model: persona_model, tool_policy: %{}}}
                 end
               )

      assert params.model == expected_model
      assert params.model_explicit == explicit
    end
  end

  test "accepts only an explicit bounded JSON verdict" do
    assert {:ok, %{"approved" => true}} =
             KanbanReview.parse(~s({"approved":true,"findings":"No blockers"}))

    assert {:ok, %{"approved" => false}} =
             KanbanReview.parse("```json\n{\"approved\":false,\"findings\":\"Fix the bug\"}\n```")

    for output <- [
          "Looks good",
          ~s({"approved":"true","findings":"ok"}),
          ~s({"approved":true}),
          ~s({"approved":true,"findings":"ok","skip":true}),
          Jason.encode!(%{approved: true, findings: String.duplicate("x", 8193)}),
          nil
        ] do
      assert {:error, :invalid_review_result} = KanbanReview.parse(output)
    end
  end

  test "missing reviewer cannot waive independent review" do
    assert {:error, :reviewer_unavailable} =
             KanbanReview.params(%{}, %{"cwd" => "/repo"}, %{}, %{}, "run",
               reviewer_resolver: fn _, _ -> {:error, :missing} end
             )
  end
end
