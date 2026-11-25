defmodule LemonCore.Doctor.RuntimeCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Checks.Runtime

  # The packaged lemon_core declares an Elixir floor below the application's;
  # its own runtime check must not fail on any toolchain it admits (#730). The
  # application floor is LemonCli.Doctor.Toolchain's.
  test "the runtime check passes the build identity and judges no toolchain" do
    checks = Runtime.run([])

    assert %{status: :pass, message: "Lemon " <> _} =
             Enum.find(checks, &(&1.name == "runtime.build"))

    refute Enum.any?(checks, &(&1.name == "runtime.elixir"))
  end
end
