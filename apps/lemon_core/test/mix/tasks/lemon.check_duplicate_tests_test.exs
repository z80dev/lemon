defmodule Mix.Tasks.Lemon.CheckDuplicateTestsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.CheckDuplicateTests

  @moduletag :tmp_dir

  test "local helper names collide only when their enclosing module is the same", %{tmp_dir: root} do
    write_test(root, "first", "defmodule FirstTest do\n  defmodule FakeCron do\n  end\nend")
    write_test(root, "second", "defmodule SecondTest do\n  defmodule FakeCron do\n  end\nend")

    capture_io(fn -> CheckDuplicateTests.run(["--root", root]) end)

    write_test(root, "collision", "defmodule SecondTest.FakeCron do\nend")

    assert_raise Mix.Error, ~r/SecondTest\.FakeCron/, fn ->
      CheckDuplicateTests.run(["--root", root])
    end
  end

  test "absolute Elixir names do not inherit their enclosing module", %{tmp_dir: root} do
    write_test(
      root,
      "nested",
      "defmodule ParentTest do\n  defmodule Elixir.SharedWorker do\n  end\nend"
    )

    write_test(root, "absolute", "defmodule SharedWorker do\nend")

    assert_raise Mix.Error, ~r/SharedWorker/, fn ->
      CheckDuplicateTests.run(["--root", root])
    end
  end

  test "an edge-cases file beside its canonical test fails", %{tmp_dir: root} do
    write_test(root, "circuit_breaker", "defmodule Sample.CircuitBreakerTest do\nend")

    write_test(
      root,
      "circuit_breaker_concurrency",
      "defmodule Sample.CircuitBreakerConcurrencyTest do\nend"
    )

    write_test(root, "bash_edge_cases", "defmodule Sample.BashEdgeCasesTest do\nend")

    assert capture_io(fn -> CheckDuplicateTests.run(["--root", root]) end) =~ "[ok]"

    write_test(
      root,
      "circuit_breaker_edge_cases",
      "defmodule Sample.CircuitBreakerEdgeCasesTest do\nend"
    )

    error =
      assert_raise Mix.Error, fn ->
        CheckDuplicateTests.run(["--root", root])
      end

    assert error.message =~
             "apps/sample/test/circuit_breaker_edge_cases_test.exs " <>
               "(canonical: apps/sample/test/circuit_breaker_test.exs)"

    refute error.message =~ "bash_edge_cases"
    refute error.message =~ "concurrency"
  end

  test "a layered module elsewhere fails when its canonical module exists", %{tmp_dir: root} do
    write_test(root, "session", "defmodule Sample.SessionTest do\nend")

    write_test(
      root,
      "legacy/session_comprehensive",
      "defmodule Sample.SessionComprehensiveTest do\nend"
    )

    assert_raise Mix.Error,
                 ~r"legacy/session_comprehensive_test\.exs \(canonical: apps/sample/test/session_test\.exs\)",
                 fn -> CheckDuplicateTests.run(["--root", root]) end
  end

  defp write_test(root, name, source) do
    path = Path.join([root, "apps", "sample", "test", name <> "_test.exs"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end
end
