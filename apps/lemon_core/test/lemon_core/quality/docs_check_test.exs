defmodule LemonCore.Quality.DocsCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.DocsCheck

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "docs_check_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "docs/guide"))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, root: tmp_dir}
  end

  test "passes when every local link resolves, ignoring external, anchor and mailto links",
       %{root: root} do
    write(root, "docs/target.md", "# Target\n")

    write(root, "docs/guide/page.md", """
    [relative](../target.md) [anchor into file](../target.md#section) [self](#top)
    [absolute](/docs/target.md) [angle](<../target.md>)
    [external](https://example.com) [plain](http://example.com) [mail](mailto:a@b.c)
    """)

    assert {:ok, report} = DocsCheck.run(root: root)
    assert report.checked_files == 2
    assert report.issues == []
  end

  test "reports each broken local link once, with the source doc path", %{root: root} do
    write(root, "docs/page.md", "[a](missing.md) [again](missing.md) [b](gone/file.md#x)")

    assert {:error, report} = DocsCheck.run(root: root)
    assert report.issue_count == 2
    assert Enum.all?(report.issues, &(&1.code == :broken_link and &1.path == "docs/page.md"))

    assert Enum.map(report.issues, & &1.message) == [
             "Broken local markdown link in docs/page.md: missing.md",
             "Broken local markdown link in docs/page.md: gone/file.md#x"
           ]
  end

  test "parses an optional link title separately from the destination", %{root: root} do
    write(root, "docs/target.md", "# Target\n")

    write(root, "docs/guide/page.md", """
    [double](../target.md "Title") [single](../target.md 'Title') [paren](../target.md (Title))
    [angle](<../target.md> "Title") [anchor](../target.md#x "Title with ) paren")
    """)

    assert {:ok, %{issues: []}} = DocsCheck.run(root: root)

    write(root, "docs/guide/broken.md", ~s|[x](../missing.md "Title")|)

    assert {:error, report} = DocsCheck.run(root: root)

    assert Enum.map(report.issues, & &1.message) == [
             "Broken local markdown link in docs/guide/broken.md: ../missing.md"
           ]
  end

  test "in a Git checkout only tracked docs are checked", %{root: root} do
    write(root, "docs/tracked.md", "# Tracked\n")
    write(root, "docs/untracked.md", "[broken](nowhere.md)")

    assert {_, 0} = System.cmd("git", ["init", "--quiet", root])
    assert {_, 0} = System.cmd("git", ["-C", root, "add", "docs/tracked.md"])

    assert {:ok, %{checked_files: 1}} = DocsCheck.run(root: root)
  end

  defp write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
