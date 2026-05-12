defmodule LemonCore.DoctorTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor
  alias LemonCore.Doctor.{Check, Report}

  test "collects structured checks" do
    checks = Doctor.checks()

    assert is_list(checks)
    assert Enum.all?(checks, &match?(%Check{}, &1))
  end

  test "builds a report" do
    assert %Report{} = report = Doctor.report()
    assert is_integer(report.pass)
    assert is_integer(report.warn)
    assert is_integer(report.fail)
    assert is_integer(report.skip)
  end
end
