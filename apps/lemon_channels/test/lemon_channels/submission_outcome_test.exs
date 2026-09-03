defmodule LemonChannels.SubmissionOutcomeTest do
  use ExUnit.Case, async: true

  alias LemonChannels.SubmissionOutcome

  test "malformed mutation acknowledgements are uncertain and not retry-safe" do
    for answer <- [false, nil, {:ok, 123}, {:ok, ""}] do
      failure = {:error, {:unexpected_answer, answer}}

      assert SubmissionOutcome.uncertain?(failure)
      refute SubmissionOutcome.retry_safe?(failure)
      assert SubmissionOutcome.log_label(failure) == :unexpected_answer
    end
  end

  test "explicit rejection remains retry-safe while lost acknowledgement is uncertain" do
    assert SubmissionOutcome.retry_safe?({:error, :rejected})
    refute SubmissionOutcome.uncertain?({:error, :rejected})

    assert SubmissionOutcome.uncertain?({:error, :outcome_unknown})
    refute SubmissionOutcome.retry_safe?({:error, :outcome_unknown})
  end
end
