defmodule LemonCore.DurableTest do
  use ExUnit.Case, async: true

  alias LemonCore.Durable

  @moduletag :tmp_dir

  test "a directory flush is claimed only where it is synchronous", %{tmp_dir: dir} do
    dir = Path.join(dir, "literal 'quoted' 雪")
    File.mkdir!(dir)
    result = Durable.sync_directory(dir)

    cond do
      match?({:unix, :darwin}, :os.type()) ->
        # The owning helper fsyncs this exact descriptor and issues F_FULLFSYNC.
        assert result == :ok

      gnu_sync?() ->
        assert result == :ok

      true ->
        assert result == {:error, :directory_sync_unsupported}
    end
  end

  test "a file flush syncs an existing file", %{tmp_dir: dir} do
    path = Path.join(dir, "data 'literal' 雪")
    File.write!(path, "contents")
    assert Durable.sync_file(path) == :ok
    assert {:error, :enoent} = Durable.sync_file(Path.join(dir, "missing"))
  end

  test "Darwin rejects wrong descriptor kinds instead of claiming a weaker barrier", %{
    tmp_dir: dir
  } do
    if match?({:unix, :darwin}, :os.type()) do
      path = Path.join(dir, "regular")
      File.write!(path, "contents")
      assert {:error, {:full_sync_failed, _}} = Durable.sync_directory(path)
      assert {:error, {:full_sync_failed, _}} = Durable.sync_file(dir)
      link = Path.join(dir, "link")
      File.ln_s!(path, link)
      assert {:error, {:full_sync_failed, _}} = Durable.sync_file(link)
    end
  end

  defp gnu_sync? do
    case System.find_executable("sync") do
      nil -> false
      sync -> match?({"sync (GNU coreutils)" <> _, 0}, System.cmd(sync, ["--version"]))
    end
  end
end
