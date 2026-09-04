defmodule LemonCore.Quality.RatchetCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.RatchetCheck

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    lib = Path.join(root, "apps/demo/lib/demo")
    tests = Path.join(root, "apps/demo/test")
    File.mkdir_p!(lib)
    File.mkdir_p!(tests)

    File.write!(Path.join(lib, "thing.ex"), """
    defmodule Demo.Thing do
      @runtime :"Elixir.Demo.Runtime"

      def run do
        if Code.ensure_loaded?(@runtime) and function_exported?(@runtime, :run, 0),
          do: @runtime.run()
      rescue
        ArgumentError -> :error
      catch
        :exit, _reason -> :error
      end
    end
    """)

    File.write!(Path.join(lib, "demo_store.ex"), "defmodule Demo.Store do\nend\n")

    File.write!(Path.join(tests, "thing_test.exs"), """
    defmodule Demo.ThingTest do
      use ExUnit.Case, async: true
      test "waits", do: Process.sleep(1)
      test "waits again", do: :timer.sleep(1)
    end
    """)

    {:ok, root: root}
  end

  test "measures only the declared AST and file-shape debts", %{root: root} do
    assert RatchetCheck.measure(root) == %{
             large_lib_files: 0,
             dynamic_module_atoms: 1,
             reflection_calls: 2,
             rescue_clauses: 1,
             catch_clauses: 1,
             store_wrapper_modules: 1,
             test_sleep_calls: 2
           }
  end

  test "comments and documentation examples do not affect AST counts", %{root: root} do
    File.write!(Path.join(root, "apps/demo/lib/demo/comments.ex"), """
    defmodule Demo.Comments do
      @moduledoc \"Code.ensure_loaded?(:ignored) and Process.sleep(10)\"
      # function_exported?(:ignored, :run, 0)
      def ok, do: :ok
    end
    """)

    measurements = RatchetCheck.measure(root)
    assert measurements.reflection_calls == 2
    assert measurements.test_sleep_calls == 2
  end

  test "excludes only the checker itself, not sibling quality modules", %{root: root} do
    quality_dir = Path.join(root, "apps/lemon_core/lib/lemon_core/quality")
    File.mkdir_p!(quality_dir)

    File.write!(
      Path.join(quality_dir, "ratchet_check.ex"),
      "defmodule LemonCore.Quality.RatchetCheck do\n  def self, do: Code.ensure_loaded?(:self)\nend\n"
    )

    File.write!(
      Path.join(quality_dir, "other_check.ex"),
      "defmodule LemonCore.Quality.OtherCheck do\n  def sibling, do: Code.ensure_loaded?(:sibling)\nend\n"
    )

    measurements = RatchetCheck.measure(root)
    assert measurements.reflection_calls == 3
  end

  test "fails without a baseline and passes after recording one", %{root: root} do
    assert {:error, %{issues: [%{code: :missing_ratchet_baseline}]}} =
             RatchetCheck.run(root: root)

    assert {:ok, %{baselines: baselines}} = RatchetCheck.update_baselines(root)
    assert baselines == RatchetCheck.measure(root)
    assert {:ok, %{issue_count: 0}} = RatchetCheck.run(root: root)
  end

  test "reports regressions and update never raises a ratchet", %{root: root} do
    {:ok, _report} = RatchetCheck.update_baselines(root)
    path = Path.join(root, RatchetCheck.baseline_file())

    File.write!(
      path,
      String.replace(File.read!(path), "test_sleep_calls: 2", "test_sleep_calls: 1")
    )

    assert {:error, %{issues: issues}} = RatchetCheck.run(root: root)
    assert Enum.any?(issues, &(&1.code == :ratchet_regression))

    assert {:ok, %{baselines: %{test_sleep_calls: 1}}} =
             RatchetCheck.update_baselines(root)
  end

  test "rejects executable or malformed baseline content", %{root: root} do
    path = Path.join(root, RatchetCheck.baseline_file())
    File.write!(path, "System.cmd(\"true\", [])\n")

    assert {:error, %{issues: [%{code: :missing_ratchet_baseline}]}} =
             RatchetCheck.run(root: root)

    File.write!(path, "%{test_sleep_calls: -1}\n")

    assert {:error, %{issues: [%{code: :missing_ratchet_baseline}]}} =
             RatchetCheck.run(root: root)
  end
end
