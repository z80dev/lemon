defmodule LemonAutomation.GoalJudgeSourceTest do
  @moduledoc """
  Verdict provenance is server-side: whatever `source` the judge model writes
  into its JSON answer is discarded.
  """
  use ExUnit.Case, async: true

  alias LemonAutomation.GoalJudge

  @secret "PROMPT_SECRET_7Q2X9 merger closes Friday"

  defmodule ModelSourceRunner do
    @moduledoc false
    def judge(_goal, _context),
      do:
        {:ok,
         %{
           "action" => "done",
           "reason" => "finished",
           "source" => "PROMPT_SECRET_7Q2X9 merger closes Friday",
           run_id: "judge-run"
         }}
  end

  test "a model-supplied source is replaced by the server-side judge provenance" do
    assert {:ok, verdict} =
             GoalJudge.judge(%{}, judge_runner: ModelSourceRunner, judge_model: "judge-model")

    assert verdict.action == :done
    assert verdict.source == "judge:judge-model"
    assert verdict.run_id == "judge-run"
    refute inspect(verdict) =~ @secret
  end
end
