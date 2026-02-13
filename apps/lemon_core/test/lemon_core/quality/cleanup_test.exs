defmodule LemonCore.Quality.CleanupTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.Cleanup

  @repo_root Path.expand("../../../../..", __DIR__)

  test "cleanup scan returns structured report" do
    report = Cleanup.scan(root: @repo_root, retention_days: 7)

    assert is_integer(report.retention_days)
    assert is_list(report.old_run_files)
    assert is_list(report.stale_docs)
    assert report.deleted_files == []
  end
end
