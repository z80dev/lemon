defmodule LemonCore.Doctor.ReportTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.{Check, Report}

  defp sample_checks do
    [
      Check.pass("a.b", "all fine"),
      Check.warn("a.c", "watch out", "do this"),
      Check.fail("a.d", "broken", "fix it"),
      Check.skip("a.e", "n/a")
    ]
  end

  describe "from_checks/1" do
    test "counts statuses correctly" do
      report = Report.from_checks(sample_checks())
      assert report.pass == 1
      assert report.warn == 1
      assert report.fail == 1
      assert report.skip == 1
    end
  end

  describe "ok?/1" do
    test "returns true when no failures" do
      report = Report.from_checks([Check.pass("x"), Check.warn("y", "w")])
      assert Report.ok?(report)
    end

    test "returns false when there are failures" do
      report = Report.from_checks([Check.fail("x", "bad")])
      refute Report.ok?(report)
    end
  end

  describe "overall/1" do
    test "returns :fail when any check fails" do
      report = Report.from_checks(sample_checks())
      assert Report.overall(report) == :fail
    end

    test "returns :warn when no failures but warnings" do
      report = Report.from_checks([Check.pass("a"), Check.warn("b", "w")])
      assert Report.overall(report) == :warn
    end

    test "returns :pass when all pass or skip" do
      report = Report.from_checks([Check.pass("a"), Check.skip("b")])
      assert Report.overall(report) == :pass
    end
  end

  describe "to_json/1" do
    test "returns a valid JSON string" do
      report = Report.from_checks(sample_checks())
      json = Report.to_json(report)
      decoded = Jason.decode!(json)

      assert decoded["overall"] == "fail"
      assert decoded["summary"]["fail"] == 1
      assert decoded["summary"]["pass"] == 1
      assert is_list(decoded["checks"])
      assert length(decoded["checks"]) == 4
    end

    test "each check has name, status, message, remediation fields" do
      report = Report.from_checks([Check.fail("my.check", "bad", "fix")])
      json = Report.to_json(report)
      [check | _] = Jason.decode!(json)["checks"]

      assert check["name"] == "my.check"
      assert check["status"] == "fail"
      assert check["message"] == "bad"
      assert check["remediation"] == "fix"
    end
  end
end
