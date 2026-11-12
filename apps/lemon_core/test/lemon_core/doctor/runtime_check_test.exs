defmodule LemonCore.Doctor.RuntimeCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Checks.Runtime

  test "doctor fails unsupported Elixir versions with upgrade guidance" do
    for version <- ["1.20.4", "1.19.5", "1.20.5-rc.1", "invalid"] do
      check = elixir_check(version)
      assert check.status == :fail
      assert check.message =~ version
      assert check.message =~ "requires Elixir 1.20.5 or newer"
      assert check.remediation =~ "Upgrade Elixir"
    end
  end

  test "doctor accepts the minimum and newer Elixir versions" do
    for version <- ["1.20.5", "1.20.6", "1.21.0"] do
      check = elixir_check(version)
      assert check.status == :pass
      assert check.message =~ version
    end
  end

  defp elixir_check(version) do
    Runtime.run(elixir_version: version)
    |> Enum.find(&(&1.name == "runtime.elixir"))
  end
end
