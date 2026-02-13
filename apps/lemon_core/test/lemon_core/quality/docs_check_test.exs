defmodule LemonCore.Quality.DocsCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.DocsCheck

  @repo_root Path.expand("../../../../..", __DIR__)

  test "docs check passes for the repository catalog" do
    assert {:ok, report} = DocsCheck.run(root: @repo_root)
    assert report.issue_count == 0
    assert report.checked_files > 0
  end
end
