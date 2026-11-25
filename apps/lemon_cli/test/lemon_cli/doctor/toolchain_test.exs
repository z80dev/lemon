defmodule LemonCli.Doctor.ToolchainTest do
  use ExUnit.Case, async: true

  alias LemonCli.Doctor.Toolchain

  test "doctor fails unsupported Elixir versions with upgrade guidance" do
    for version <- ["1.20.4", "1.19.5", "1.20.5-rc.1", "invalid"] do
      [check] = Toolchain.run(elixir_version: version)
      assert check.name == "runtime.elixir"
      assert check.status == :fail
      assert check.message =~ version
      assert check.message =~ "requires Elixir 1.20.5 or newer"
      assert check.remediation =~ "Upgrade Elixir"
    end
  end

  test "doctor accepts the minimum and newer Elixir versions" do
    for version <- ["1.20.5", "1.20.6", "1.21.0"] do
      [check] = Toolchain.run(elixir_version: version)
      assert check.status == :pass
      assert check.message =~ version
    end
  end

  test "is registered with lemon doctor" do
    assert Toolchain in LemonCore.Doctor.registered_checks()
  end
end
