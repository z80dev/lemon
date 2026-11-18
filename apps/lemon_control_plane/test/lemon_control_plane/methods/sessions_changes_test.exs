defmodule LemonControlPlane.Methods.SessionsChangesTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{Registry, SessionsChanges}

  @key "agent:default:web:local:dm:changes"
  @operator_ctx %{auth: %{role: :operator, scopes: [:read, :content]}}

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-changes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.email=t@example.com",
          "-c",
          "user.name=T",
          "-c",
          "init.defaultBranch=main" | args
        ],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}]
      )

    out
  end

  defp repo!(root) do
    git!(root, ["init", "-q"])
    File.write!(Path.join(root, "README.md"), "one\ntwo\nthree\n")
    File.write!(Path.join(root, "gone.txt"), "bye\n")

    File.write!(
      Path.join(root, "old_name.txt"),
      Enum.map_join(1..20, "\n", &"line #{&1}") <> "\n"
    )

    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "sub/inner.ex"), "defmodule Inner do\nend\n")
    git!(root, ["add", "-A"])
    git!(root, ["commit", "-q", "-m", "init"])
    root
  end

  defp call(params),
    do: SessionsChanges.handle(Map.put_new(params, "sessionKey", @key), @operator_ctx)

  test "lists bounded status with codes, counts and branch", %{root: root} do
    repo!(root)
    File.write!(Path.join(root, "README.md"), "one\nTWO\nthree\nfour\n")
    File.rm!(Path.join(root, "gone.txt"))
    git!(root, ["mv", "old_name.txt", "new_name.txt"])
    File.write!(Path.join(root, "staged.txt"), "a\nb\n")
    git!(root, ["add", "staged.txt"])
    File.write!(Path.join(root, "fresh.txt"), "x\ny\nz")
    File.write!(Path.join(root, "blob.bin"), <<0, 1, 2, 3, 0>>)

    assert {:ok, result} = call(%{"cwd" => root})
    assert result["repository"] == true
    assert result["state"] == "ok"
    assert result["branch"] == "main"
    assert result["truncated"] == false

    files = Map.new(result["files"], &{&1["path"], &1})

    assert files["README.md"]["status"] == "modified"
    assert files["README.md"]["additions"] == 2
    assert files["README.md"]["deletions"] == 1
    assert files["gone.txt"]["status"] == "deleted"
    assert files["gone.txt"]["deletions"] == 1
    assert files["new_name.txt"]["status"] == "renamed"
    assert files["new_name.txt"]["origPath"] == "old_name.txt"
    assert files["staged.txt"]["status"] == "added"
    assert files["staged.txt"]["staged"] == true
    assert files["fresh.txt"]["status"] == "untracked"
    assert files["fresh.txt"]["additions"] == 3
    assert files["blob.bin"]["binary"] == true
    assert result["totals"]["files"] == length(result["files"])
    assert result["totals"]["additions"] >= 7

    refute inspect(result) =~ root
  end

  test "restricts listing and diffs to the cwd subtree", %{root: root} do
    repo!(root)
    File.write!(Path.join(root, "README.md"), "changed\n")
    File.write!(Path.join(root, "sub/inner.ex"), "defmodule Inner do\n  def hi, do: :hi\nend\n")
    sub = Path.join(root, "sub")

    assert {:ok, result} = call(%{"cwd" => sub})
    assert Enum.map(result["files"], & &1["path"]) == ["inner.ex"]

    assert {:ok, %{"diff" => diff}} = call(%{"cwd" => sub, "path" => "inner.ex"})
    assert diff["patch"] =~ "+  def hi, do: :hi"
    assert diff["additions"] == 1

    # A changed file outside cwd is not served, even though it is in the repo.
    assert {:error, {:invalid_params, _, _}} = call(%{"cwd" => sub, "path" => "../README.md"})
    assert {:error, {:not_found, _, _}} = call(%{"cwd" => sub, "path" => "README.md"})
  end

  test "serves one bounded unified diff without headers", %{root: root} do
    repo!(root)
    File.write!(Path.join(root, "README.md"), "one\nTWO\nthree\n")

    assert {:ok, %{"diff" => diff}} = call(%{"cwd" => root, "path" => "README.md"})
    assert diff["status"] == "modified"
    assert diff["binary"] == false
    assert diff["truncated"] == false
    assert String.starts_with?(diff["patch"], "@@ ")
    refute diff["patch"] =~ "diff --git"
    assert diff["patch"] =~ "-two"
    assert diff["patch"] =~ "+TWO"
    assert {diff["additions"], diff["deletions"]} == {1, 1}
  end

  test "untracked, binary and directory diffs", %{root: root} do
    repo!(root)
    File.write!(Path.join(root, "fresh.txt"), "hello\nworld\n")
    File.write!(Path.join(root, "blob.bin"), <<0, 159, 146, 150, 0, 1>>)
    File.mkdir_p!(Path.join(root, "newdir"))
    File.write!(Path.join(root, "newdir/a.txt"), "a\n")

    assert {:ok, %{"diff" => fresh}} = call(%{"cwd" => root, "path" => "fresh.txt"})
    assert fresh["status"] == "untracked"
    assert fresh["patch"] =~ "+hello"
    assert fresh["additions"] == 2

    assert {:ok, %{"diff" => blob}} = call(%{"cwd" => root, "path" => "blob.bin"})
    assert blob["binary"] == true
    assert blob["patch"] == ""

    # Files inside new directories are listed (and diffable) individually.
    assert {:ok, %{"files" => files}} = call(%{"cwd" => root})
    assert "newdir/a.txt" in Enum.map(files, & &1["path"])
    assert {:ok, %{"diff" => nested}} = call(%{"cwd" => root, "path" => "newdir/a.txt"})
    assert nested["patch"] =~ "+a"
    assert {:error, {:not_found, _, _}} = call(%{"cwd" => root, "path" => "newdir/"})
  end

  test "caps large diffs by lines and bytes", %{root: root} do
    repo!(root)

    File.write!(
      Path.join(root, "big.txt"),
      Enum.map_join(1..20_000, "\n", &"row #{&1} #{String.duplicate("x", 40)}")
    )

    assert {:ok, %{"diff" => diff}} = call(%{"cwd" => root, "path" => "big.txt"})
    assert diff["truncated"] == true
    assert byte_size(diff["patch"]) <= 256_000
    assert diff["lineCount"] <= 3_000
    assert String.valid?(diff["patch"])
  end

  test "refuses unsafe or unchanged paths", %{root: root} do
    repo!(root)
    File.write!(Path.join(root, "README.md"), "changed\n")
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "secret\n")
    on_exit(fn -> File.rm(outside) end)

    for bad <- [
          outside,
          "../#{Path.basename(outside)}",
          "sub/../../x",
          "./README.md",
          "-p",
          "a\\b",
          <<"a", 0>>
        ] do
      assert {:error, {:invalid_params, message, _}} = call(%{"cwd" => root, "path" => bad})
      refute message =~ root
    end

    # Unchanged tracked file: not a workspace change, so no diff.
    assert {:error, {:not_found, _, _}} = call(%{"cwd" => root, "path" => "gone.txt"})
    # Pathspec magic is literal, so it cannot widen the match.
    assert {:error, {:not_found, _, _}} = call(%{"cwd" => root, "path" => ":(glob)*"})
  end

  test "non-git cwd answers an explicit state; missing cwd is not found", %{root: root} do
    assert {:ok, result} = call(%{"cwd" => root})
    assert result["repository"] == false
    assert result["state"] == "not_git_repository"
    assert result["files"] == []

    assert {:ok, %{"repository" => false, "diff" => nil}} =
             call(%{"cwd" => root, "path" => "a.txt"})

    assert {:error, {:not_found, message, _}} = call(%{"cwd" => Path.join(root, "missing")})
    refute message =~ root
    assert {:error, {:not_found, _, _}} = call(%{"cwd" => "relative/dir"})
  end

  test "repository without commits lists staged additions", %{root: root} do
    git!(root, ["init", "-q"])
    File.write!(Path.join(root, "first.txt"), "1\n2\n")
    git!(root, ["add", "first.txt"])

    assert {:ok, result} = call(%{"cwd" => root})
    assert [%{"path" => "first.txt", "status" => "added", "additions" => 2}] = result["files"]
    assert {:ok, %{"diff" => %{"patch" => patch}}} = call(%{"cwd" => root, "path" => "first.txt"})
    assert patch =~ "+1"
  end

  test "is a registered async read method with bounded params", %{root: root} do
    assert SessionsChanges.scopes() == [:read]
    assert "sessions.changes" in Registry.list_methods()
    assert Registry.dispatch_mode("sessions.changes") == :async

    assert {:ok, %{"state" => "not_git_repository"}} =
             Registry.dispatch("sessions.changes", %{"sessionKey" => @key, "cwd" => root}, %{
               auth: %{role: :operator, scopes: [:read]}
             })

    assert {:error, _} =
             Registry.dispatch("sessions.changes", %{"sessionKey" => @key, "cwd" => root}, %{
               auth: %{role: :node, scopes: [:node]}
             })

    assert {:error, {:invalid_params, _, _}} = SessionsChanges.handle(%{"cwd" => root}, %{})

    assert {:error, {:invalid_params, _, _}} =
             call(%{"cwd" => root, "path" => String.duplicate("a", 4097)})
  end

  test "parsers tolerate malformed git output" do
    assert %{entries: [], branch: nil} = SessionsChanges.parse_status("garbage\0", "", false)

    assert SessionsChanges.parse_numstat(
             "3\t1\ta.txt\0-\t-\tb.bin\0" <> "2\t0\t\0old.txt\0new.txt\0"
           ) ==
             %{"a.txt" => {3, 1, false}, "b.bin" => {nil, nil, true}, "new.txt" => {2, 0, false}}

    parsed = SessionsChanges.parse_diff("diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+\xff\n", false)
    assert String.valid?(parsed.patch)
    assert {parsed.additions, parsed.deletions} == {1, 1}
  end
end
