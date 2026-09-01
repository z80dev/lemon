defmodule LemonCore.Quality.RatchetCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.RatchetCheck

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    lib = Path.join(root, "apps/demo/lib/demo")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "thing.ex"), """
    defmodule Demo.Thing do
      @mod :"Elixir.Demo.Other"
      @table :attr_table

      def go do
        if Code.ensure_loaded?(@mod) and function_exported?(@mod, :run, 0), do: @mod.run()
      rescue
        _ -> :ok
      end

      def read, do: LemonCore.Store.get(:demo_table, :k)
      def write, do: Store.put(:demo_table, :k, 1)
      def other, do: Store.list(:other_table)
      def attr, do: Store.get(@table, :k)
    end
    """)

    File.write!(Path.join(lib, "demo_store.ex"), "defmodule Demo.DemoStore do\nend\n")

    tests = Path.join(root, "apps/demo/test")
    File.mkdir_p!(tests)

    File.write!(
      Path.join(tests, "sync_test.exs"),
      "defmodule SyncTest do\n  use ExUnit.Case\n  test \"x\", do: Process.sleep(10)\nend\n"
    )

    File.write!(
      Path.join(tests, "async_test.exs"),
      "defmodule AsyncTest do\n  use ExUnit.Case, async: true\n  test \"x\", do: :timer.sleep(1)\nend\n"
    )

    File.write!(Path.join(root, "apps/demo/AGENTS.md"), "# Demo\n")
    {:ok, root: root}
  end

  test "measures every metric from the tree", %{root: root} do
    measurements = RatchetCheck.measure(root)

    assert measurements == %{
             lib_lines: 17,
             large_lib_files: 0,
             dynamic_module_atoms: 1,
             reflection_sites: 2,
             rescue_clauses: 1,
             silent_rescues: 1,
             catch_clauses: 0,
             generic_store_tables: 3,
             store_wrapper_modules: 1,
             architecture_rules: 0,
             test_sleeps: 2,
             sync_test_files: 1,
             agents_md_bytes: 7
           }
  end

  test "fails without a ratchet file and passes once one is recorded", %{root: root} do
    assert {:error, %{issue_count: 1, issues: [%{code: :missing_ratchet_baseline}]}} =
             RatchetCheck.run(root: root)

    assert {:ok, %{baselines: baselines}} = RatchetCheck.update_baselines(root)
    assert baselines == RatchetCheck.measure(root)
    assert {:ok, %{issue_count: 0}} = RatchetCheck.run(root: root)
  end

  test "a measurement above its ratchet is a regression", %{root: root} do
    {:ok, _} = RatchetCheck.update_baselines(root)
    lower_ratchet(root, "test_sleeps: 2", "test_sleeps: 1")

    assert {:error, %{issues: [%{code: :ratchet_regression, message: message}]}} =
             RatchetCheck.run(root: root)

    assert message =~ "test_sleeps is 2, above the ratchet of 1"
  end

  test "metrics missing from the file are reported", %{root: root} do
    File.write!(Path.join(root, RatchetCheck.baseline_file()), "%{lib_lines: 17}\n")

    missing = length(RatchetCheck.metrics()) - 1
    assert {:error, %{issue_count: ^missing, issues: issues}} = RatchetCheck.run(root: root)
    assert Enum.all?(issues, &(&1.code == :missing_ratchet))
    assert Enum.any?(issues, &(&1.message =~ "test_sleeps has no ratchet"))
  end

  test "update never raises a ratchet", %{root: root} do
    {:ok, _} = RatchetCheck.update_baselines(root)
    lower_ratchet(root, "test_sleeps: 2", "test_sleeps: 1")

    assert {:ok, %{baselines: %{test_sleeps: 1}}} = RatchetCheck.update_baselines(root)
  end

  test "rejects a ratchet file that is not a map of counts", %{root: root} do
    File.write!(Path.join(root, RatchetCheck.baseline_file()), "[1, 2]\n")

    assert {:error, %{issues: [%{code: :missing_ratchet_baseline, message: message}]}} =
             RatchetCheck.run(root: root)

    assert message =~ "expected a map literal"

    File.write!(Path.join(root, RatchetCheck.baseline_file()), "%{test_sleeps: -1}\n")

    assert {:error, %{issues: [%{code: :missing_ratchet_baseline}]}} =
             RatchetCheck.run(root: root)
  end

  defp lower_ratchet(root, from, to) do
    path = Path.join(root, RatchetCheck.baseline_file())
    File.write!(path, String.replace(File.read!(path), from, to))
  end
end
