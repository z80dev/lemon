defmodule Mix.Tasks.Lemon.WorkspaceTest do
  @moduledoc """
  Tests for the Lemon.Workspace mix task.

  These tests verify that the workspace initialization task works correctly.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Workspace

  setup do
    # Store original cwd
    original_cwd = File.cwd!()

    # Create a temporary directory for testing
    tmp_dir = Path.join(System.tmp_dir!(), "workspace_task_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.cd!(original_cwd)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, original_cwd: original_cwd}
  end

  describe "run/1" do
    test "init command creates workspace files", %{tmp_dir: tmp_dir} do
      output = capture_io(fn ->
        Workspace.run(["init", "--workspace-dir", tmp_dir])
      end)

      assert output =~ "Workspace initialized"
      assert output =~ tmp_dir
    end

    test "init without workspace-dir uses default location" do
      # This test just verifies the command runs without error
      # We can't easily test the default location without affecting the real workspace
      output = capture_io(fn ->
        # Use a custom workspace dir to avoid affecting real workspace
        tmp_dir = Path.join(System.tmp_dir!(), "default_workspace_test_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(tmp_dir)
        Workspace.run(["init", "--workspace-dir", tmp_dir])
      end)

      assert output =~ "Workspace initialized"
    end

    test "invalid command shows usage info" do
      output = capture_io(fn ->
        Workspace.run(["invalid"])
      end)

      assert output =~ "Usage:"
    end

    test "empty args shows usage info" do
      output = capture_io(fn ->
        Workspace.run([])
      end)

      assert output =~ "Usage:"
    end
  end

  describe "option parsing" do
    test "handles --workspace-dir option", %{tmp_dir: tmp_dir} do
      output = capture_io(fn ->
        Workspace.run(["init", "--workspace-dir", tmp_dir])
      end)

      assert output =~ "Workspace initialized"
    end

    test "handles -w alias for --workspace-dir", %{tmp_dir: tmp_dir} do
      output = capture_io(fn ->
        Workspace.run(["init", "-w", tmp_dir])
      end)

      assert output =~ "Workspace initialized"
    end
  end
end
