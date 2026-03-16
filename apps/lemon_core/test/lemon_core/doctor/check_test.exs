defmodule LemonCore.Doctor.CheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Check

  describe "pass/2" do
    test "builds a passing check" do
      check = Check.pass("my.check")
      assert check.name == "my.check"
      assert check.status == :pass
      assert check.message == "OK"
    end

    test "accepts custom message" do
      check = Check.pass("my.check", "All good.")
      assert check.message == "All good."
    end
  end

  describe "warn/3" do
    test "builds a warning check" do
      check = Check.warn("my.check", "something is off")
      assert check.status == :warn
      assert check.message == "something is off"
      assert is_nil(check.remediation)
    end

    test "accepts remediation text" do
      check = Check.warn("my.check", "off", "fix it")
      assert check.remediation == "fix it"
    end
  end

  describe "fail/3" do
    test "builds a failing check" do
      check = Check.fail("my.check", "broken", "fix it")
      assert check.status == :fail
      assert check.remediation == "fix it"
    end
  end

  describe "skip/2" do
    test "builds a skipped check" do
      check = Check.skip("my.check", "not applicable")
      assert check.status == :skip
    end
  end

  describe "color/1 and label/1" do
    test "each status has a color and label" do
      for status <- [:pass, :warn, :fail, :skip] do
        assert is_atom(Check.color(status))
        assert is_binary(Check.label(status))
      end
    end
  end
end
