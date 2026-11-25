defmodule LemonEvals.HarnessTest do
  use ExUnit.Case, async: false

  alias LemonEvals.Harness

  test "eval harness passes all baseline checks" do
    report = Harness.run(cwd: File.cwd!(), iterations: 10)

    failed = for result <- report.results, result.status == :fail, do: result.name
    assert report.summary.failed == 0, "failed eval checks: #{Enum.join(failed, ", ")}"
  end
end
