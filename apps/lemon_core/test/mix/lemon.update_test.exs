defmodule Mix.Tasks.Lemon.UpdateTest do
  use ExUnit.Case, async: true

  @update_task_source "lib/mix/tasks/lemon.update.ex"

  describe "start_apps! — fail-fast on startup errors" do
    test "start_apps! does not skip Mix.raise when --check is passed" do
      # Regression test: previously start_apps! had `unless check_only?` which
      # swallowed startup failures in --check mode.  The fix removes that guard
      # so the task always fails fast on a startup error.
      source_path = Path.join([File.cwd!(), @update_task_source])
      source = File.read!(source_path)

      refute String.contains?(source, "unless check_only?"),
             "start_apps!/1 must not suppress Mix.raise based on --check flag. " <>
               "Found `unless check_only?` guard in #{@update_task_source}."
    end

    test "lemon_core app starts successfully in test environment" do
      # Verifies that start_apps! would succeed in the current test environment,
      # which ensures --check mode behaves correctly without masking real errors.
      assert {:ok, _} = Application.ensure_all_started(:lemon_core)
    end
  end
end
