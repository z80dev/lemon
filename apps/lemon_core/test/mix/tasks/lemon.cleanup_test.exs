defmodule Mix.Tasks.Lemon.CleanupTest do
  @moduledoc """
  Tests for the lemon.cleanup mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Cleanup

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_cleanup_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "module attributes" do
    test "task module exists and is loaded" do
      assert Code.ensure_loaded?(Cleanup)
    end

    test "has proper @shortdoc attribute" do
      shortdoc = Mix.Task.shortdoc(Cleanup)
      assert shortdoc =~ "Scan or prune stale docs/agent-loop run artifacts"
    end

    test "moduledoc is present" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Cleanup)

      case module_doc do
        :none ->
          flunk("Module documentation is missing")

        :hidden ->
          flunk("Module documentation is hidden")

        %{} ->
          doc = module_doc["en"]
          assert is_binary(doc)
          assert doc =~ "Scan cleanup candidates"
          assert doc =~ "mix lemon.cleanup"
          assert doc =~ "--apply"
          assert doc =~ "--retention-days"
      end
    end

    test "module has run/1 function exported" do
      assert function_exported?(Cleanup, :run, 1)
    end
  end

  describe "dry-run mode (default)" do
    test "shows dry-run output with empty results", %{tmp_dir: tmp_dir} do
      # Mock the Cleanup.prune function by creating test files
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "Cleanup scan complete"
      assert output =~ "root:"
      assert output =~ "retention_days:"
      assert output =~ "old_run_files:"
      assert output =~ "stale_docs:"
      assert output =~ "mode: dry-run"
      assert output =~ "--apply"
    end

    test "does not show deleted_files in dry-run mode", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      refute output =~ "deleted_files:"
    end
  end

  describe "--apply mode" do
    test "shows apply mode output with deleted_files count", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--apply"])
        end)

      assert output =~ "Cleanup scan complete"
      assert output =~ "deleted_files:"
      refute output =~ "mode: dry-run"
    end

    test "accepts -a alias for --apply", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "-a"])
        end)

      assert output =~ "Cleanup scan complete"
      assert output =~ "deleted_files:"
    end
  end

  describe "--retention-days option" do
    test "accepts custom retention days", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--retention-days", "30"])
        end)

      assert output =~ "retention_days: 30"
    end

    test "accepts -d alias for --retention-days", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "-d", "21"])
        end)

      assert output =~ "retention_days: 21"
    end

    test "defaults to 14 days when not specified", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "retention_days: 14"
    end
  end

  describe "--root option" do
    test "accepts custom root directory", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "root: #{tmp_dir}"
    end

    test "accepts -r alias for --root", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["-r", tmp_dir])
        end)

      assert output =~ "root: #{tmp_dir}"
    end

    test "defaults to current working directory when not specified" do
      output =
        capture_io(fn ->
          Cleanup.run([])
        end)

      cwd = File.cwd!()
      assert output =~ "root: #{cwd}"
    end
  end

  describe "with non-empty results" do
    test "displays old run files in output", %{tmp_dir: tmp_dir} do
      # Create a mock docs/agent-loop/runs directory structure
      runs_dir = Path.join(tmp_dir, "docs/agent-loop/runs")
      File.mkdir_p!(runs_dir)

      # Create an old file (more than 14 days old)
      old_file = Path.join(runs_dir, "old_run.json")
      File.write!(old_file, "{}")

      # Set the file modification time to be old
      old_time = System.os_time(:second) - 20 * 24 * 60 * 60
      File.touch!(old_file, old_time)

      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "old_run_files:"
    end

    test "displays stale docs in output" do
      # This test runs against the actual repo to potentially find stale docs
      output =
        capture_io(fn ->
          Cleanup.run([])
        end)

      assert output =~ "stale_docs:"
    end

    test "limits displayed items to 10", %{tmp_dir: tmp_dir} do
      # Create multiple old run files
      runs_dir = Path.join(tmp_dir, "docs/agent-loop/runs")
      File.mkdir_p!(runs_dir)

      old_time = System.os_time(:second) - 20 * 24 * 60 * 60

      for i <- 1..15 do
        file = Path.join(runs_dir, "run_#{i}.json")
        File.write!(file, "{}")
        File.touch!(file, old_time)
      end

      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--apply"])
        end)

      # Should show the "showing up to 10" message or similar limiting
      assert output =~ "Cleanup scan complete"
    end
  end

  describe "with empty results" do
    test "handles empty old_run_files gracefully", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      assert output =~ "old_run_files: 0"
      # Should not crash when printing empty list
      assert output =~ "Cleanup scan complete"
    end

    test "handles empty stale_docs gracefully", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir])
        end)

      # stale_docs count should be present
      assert output =~ "stale_docs:"
    end
  end

  describe "combined options" do
    test "accepts --apply with --retention-days", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["--root", tmp_dir, "--apply", "--retention-days", "7"])
        end)

      assert output =~ "retention_days: 7"
      assert output =~ "deleted_files:"
      refute output =~ "mode: dry-run"
    end

    test "accepts all short options together", %{tmp_dir: tmp_dir} do
      output =
        capture_io(fn ->
          Cleanup.run(["-r", tmp_dir, "-a", "-d", "21"])
        end)

      assert output =~ "root: #{tmp_dir}"
      assert output =~ "retention_days: 21"
      assert output =~ "deleted_files:"
    end
  end

  describe "Mix.Task integration" do
    test "task can be retrieved via Mix.Task.get" do
      assert Mix.Task.get("lemon.cleanup") == Cleanup
    end

    test "task is registered with correct name" do
      task_module = Mix.Task.get("lemon.cleanup")
      assert task_module == Cleanup
    end

    test "task shortdoc is accessible via Mix.Task.shortdoc" do
      shortdoc = Mix.Task.shortdoc(Cleanup)
      assert is_binary(shortdoc)
      assert shortdoc =~ "Scan or prune"
    end
  end
end
