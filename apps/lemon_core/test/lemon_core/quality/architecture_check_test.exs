defmodule LemonCore.Quality.ArchitectureCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.ArchitectureCheck

  @repo_root Path.expand("../../../../..", __DIR__)

  test "architecture dependency check passes for umbrella apps" do
    assert {:ok, report} = ArchitectureCheck.run(root: @repo_root)
    assert report.issue_count == 0
    assert report.apps_checked >= 1
  end
end
