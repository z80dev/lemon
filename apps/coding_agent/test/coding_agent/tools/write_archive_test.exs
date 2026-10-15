defmodule CodingAgent.Tools.WriteArchiveTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Write
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  defp write(dir, path, content, opts \\ []),
    do: Write.execute("write", %{"path" => path, "content" => content}, nil, nil, dir, opts)

  defp members(path) do
    if Path.extname(path) == ".zip" do
      {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])
      Map.new(files)
    else
      options = if String.ends_with?(path, [".tgz", ".tar.gz"]), do: [:compressed], else: []
      {:ok, files} = :erl_tar.extract(String.to_charlist(path), [:memory | options])
      Map.new(files)
    end
  end

  for suffix <- ["zip", "tar", "tar.gz", "tgz"] do
    test "replaces and adds #{suffix} members without changing other content", %{tmp_dir: dir} do
      path = Path.join(dir, "bundle.#{unquote(suffix)}")
      assert %AgentToolResult{} = write(dir, path <> ":keep.bin", "unchanged")
      assert %AgentToolResult{} = write(dir, path <> ":inner/change.txt", "before")
      before = File.read!(path)

      assert %AgentToolResult{details: %{format: :archive_member, member: "inner/change.txt"}} =
               write(dir, path <> ":inner/change.txt", "after")

      assert %{~c"keep.bin" => "unchanged", ~c"inner/change.txt" => "after"} = members(path)
      assert %AgentToolResult{} = write(dir, path <> ":added.txt", "new")
      assert members(path)[~c"added.txt"] == "new"

      unless unquote(suffix) == "zip" do
        old = if unquote(suffix) in ["tgz", "tar.gz"], do: :zlib.gunzip(before), else: before
        current = File.read!(path)

        current =
          if unquote(suffix) in ["tgz", "tar.gz"], do: :zlib.gunzip(current), else: current

        assert binary_part(old, 0, 1024) == binary_part(current, 0, 1024)
      end
    end
  end

  test "rejects unsafe names and directory targets without mutation", %{tmp_dir: dir} do
    for suffix <- ["zip", "tar"] do
      path = Path.join(dir, "bundle." <> suffix)
      assert %AgentToolResult{} = write(dir, path <> ":folder/file", "keep")
      original = File.read!(path)

      for member <- ["../escape", "/absolute", "a/../b", "folder/", "folder", "", "a\\b"] do
        assert {:error, _} = write(dir, path <> ":" <> member, "no")
        assert File.read!(path) == original
      end
    end

    refute File.exists?(Path.join(dir, "escape"))
  end

  test "preserves unrelated TAR links and refuses to replace a link", %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    link = Path.join(dir, "link")
    File.write!(source, "target")
    File.ln_s!("source", link)
    path = Path.join(dir, "links.tar")

    :ok =
      :erl_tar.create(String.to_charlist(path), [
        {~c"source", String.to_charlist(source)},
        {~c"link", String.to_charlist(link)}
      ])

    original = File.read!(path)
    assert %AgentToolResult{} = write(dir, path <> ":new", "added")
    assert binary_part(File.read!(path), 0, 1536) == binary_part(original, 0, 1536)
    assert {:error, _} = write(dir, path <> ":link", "not followed")
    assert {:ok, table} = :erl_tar.table(String.to_charlist(path), [:verbose])

    assert Enum.any?(table, fn {name, type, _, _, _, _, _} ->
             name == ~c"link" and type == :symlink
           end)
  end

  test "normal mutation safety and checkpoint restoration apply to the archive", %{tmp_dir: dir} do
    path = Path.join(dir, "bundle.zip")
    assert %AgentToolResult{} = write(dir, path <> ":file", "before")
    session = "archive-write-#{System.unique_integer([:positive])}"
    on_exit(fn -> CodingAgent.Checkpoint.delete_all(session) end)

    assert %AgentToolResult{details: %{checkpoint_id: id}} =
             write(dir, path <> ":file", "after", session_id: session)

    assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(id)
    assert members(path)[~c"file"] == "before"
    File.ln_s!(path, Path.join(dir, "link.zip"))
    assert {:error, _} = write(dir, "link.zip:file", "blocked")

    assert {:error, _} =
             write(dir, path <> ":file", "[Showing lines 1-2 of 10. Use offset=3 to continue.]")

    assert members(path)[~c"file"] == "before"
  end

  test "ZIP binary members and archive permissions survive rewriting", %{tmp_dir: dir} do
    path = Path.join(dir, "binary.zip")
    {:ok, _} = :zip.create(String.to_charlist(path), [{~c"binary", <<0, 255, 1, 2>>}])
    File.chmod!(path, 0o600)
    assert %AgentToolResult{} = write(dir, path <> ":text", "new")
    assert members(path)[~c"binary"] == <<0, 255, 1, 2>>
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Path.wildcard(path <> ".tmp-*") == []
  end
end
