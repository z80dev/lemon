defmodule CodingAgent.Tools.ConflictsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{Read, Write}
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir
  @block "<<<<<<< ours\nleft\n||||||| base\nancestor\n=======\nright\n>>>>>>> theirs\n"

  setup %{tmp_dir: cwd} do
    owner = "conflicts-#{System.unique_integer([:positive])}"
    opts = [session_id: owner, session_pid: self(), filesystem_checkpoints: false]
    {:ok, cwd: cwd, opts: opts}
  end

  test "indexes numbered standard and diff3 regions with previews", %{cwd: cwd, opts: opts} do
    File.write!(
      Path.join(cwd, "file"),
      "header\n" <> @block <> "between\n<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n"
    )

    result = index(cwd, opts)
    assert result.details.conflict_count == 2
    assert text(result) =~ "#1 L2-L8 ours: \"left\" | theirs: \"right\""
    assert text(result) =~ "#2 L10-L14"
    assert text(index(cwd, opts)) == text(result)
  end

  test "each token expands its original side and preserves surrounding bytes", %{
    cwd: cwd,
    opts: opts
  } do
    for {token, expected} <- [
          {"@ours", "left\n"},
          {"@theirs", "right\n"},
          {"@base", "ancestor\n"},
          {"@both", "left\nright\n"}
        ] do
      File.write!(Path.join(cwd, "file"), "before\n" <> @block <> "after\n")
      id = id(index(cwd, opts))
      assert %AgentToolResult{is_error: false} = resolve(id, token, cwd, opts)
      assert File.read!(Path.join(cwd, "file")) == "before\n" <> expected <> "after\n"
    end
  end

  test "literal bodies and mixed token lines replace only the region", %{cwd: cwd, opts: opts} do
    File.write!(Path.join(cwd, "file"), "before\n" <> @block <> "after\n")
    id = id(index(cwd, opts))
    assert %AgentToolResult{} = resolve(id, "custom\n@ours\n@theirs\nend\n", cwd, opts)
    assert File.read!(Path.join(cwd, "file")) == "before\ncustom\nleft\nright\nend\nafter\n"
  end

  test "ordinary conflicts have an empty base and no final newline is required", %{
    cwd: cwd,
    opts: opts
  } do
    File.write!(Path.join(cwd, "file"), "<<<<<<< ours\nleft\n=======\nright\n>>>>>>> theirs")
    assert %AgentToolResult{} = resolve(id(index(cwd, opts)), "@base", cwd, opts)
    assert File.read!(Path.join(cwd, "file")) == ""
  end

  test "BOM and CRLF survive a first-line conflict", %{cwd: cwd, opts: opts} do
    File.write!(
      Path.join(cwd, "file"),
      <<0xEF, 0xBB, 0xBF>> <> String.replace(@block, "\n", "\r\n") <> "after\r\n"
    )

    assert %AgentToolResult{} = resolve(id(index(cwd, opts)), "@both", cwd, opts)

    assert File.read!(Path.join(cwd, "file")) ==
             <<0xEF, 0xBB, 0xBF>> <> "left\r\nright\r\nafter\r\n"
  end

  test "file changes invalidate all ids, including after one resolution", %{cwd: cwd, opts: opts} do
    path = Path.join(cwd, "file")
    File.write!(path, @block <> @block)
    index(cwd, opts)
    File.write!(path, "changed\n" <> @block <> @block)
    assert {:error, stale} = resolve(1, "@ours", cwd, opts)
    assert stale =~ "stale"
    assert {:error, _} = resolve(2, "@ours", cwd, opts)
    result = index(cwd, opts)
    assert id(result) > 2
    assert %AgentToolResult{} = resolve(id(result), "@ours", cwd, opts)
    assert {:error, _} = resolve(id(result) + 1, "@theirs", cwd, opts)
  end

  test "foreign, missing and malformed ids never write files", %{cwd: cwd, opts: opts} do
    File.write!(Path.join(cwd, "file"), @block)
    id = id(index(cwd, opts))
    assert {:error, _} = resolve(id, "@ours", cwd, Keyword.put(opts, :session_id, "foreign"))

    for bad <- ["../file", "0", "1/ours", "99", ""] do
      assert {:error, _} = resolve(bad, "@ours", cwd, opts)
    end

    assert File.read!(Path.join(cwd, "file")) == @block
  end

  test "literal colon paths win, clean files and malformed marker blocks are explicit", %{
    cwd: cwd,
    opts: opts
  } do
    File.write!(Path.join(cwd, "file"), "clean\n=======\n")
    assert text(index(cwd, opts)) == "(no unresolved conflicts)"
    File.write!(Path.join(cwd, "file:conflicts"), "literal\n")
    assert text(index(cwd, opts)) =~ "literal"
    File.rm!(Path.join(cwd, "file:conflicts"))
    File.write!(Path.join(cwd, "file"), "<<<<<<< ours\nunfinished\n")
    assert {:error, "Unterminated conflict markers"} = index(cwd, opts)
  end

  test "conflict writes retain normal filesystem checkpoints", %{cwd: cwd, opts: opts} do
    File.write!(Path.join(cwd, "file"), @block)
    on_exit(fn -> CodingAgent.Checkpoint.delete_all(opts[:session_id]) end)

    result =
      resolve(
        id(index(cwd, opts)),
        "@ours",
        cwd,
        Keyword.put(opts, :filesystem_checkpoints, true)
      )

    assert %AgentToolResult{details: %{checkpoint_id: checkpoint_id}} = result
    assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(checkpoint_id)
    assert File.read!(Path.join(cwd, "file")) == @block
  end

  defp index(cwd, opts),
    do: Read.execute("index", %{"path" => "file:conflicts"}, nil, nil, cwd, opts)

  defp resolve(id, body, cwd, opts),
    do:
      Write.execute(
        "resolve",
        %{"path" => "conflict://#{id}", "content" => body},
        nil,
        nil,
        cwd,
        opts
      )

  defp text(result), do: Enum.map_join(result.content, "\n", & &1.text)

  defp id(result) do
    [_, id] = Regex.run(~r/#(\d+) L/, text(result))
    String.to_integer(id)
  end
end
