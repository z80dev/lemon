defmodule CodingAgent.Tools.WriteSqliteSwapTest do
  @moduledoc """
  Deterministic check-then-use race against `write` with a SQLite selector.

  `FileServerTap` swaps `root/sub/inner` for a symlink to a directory outside
  the workspace right after validation's last check, the way a concurrent
  local writer could. The database must then be read and replaced only
  through descriptor-bound I/O (or refused), never opened by SQLite by name.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Write
  alias Exqlite.Sqlite3
  alias LemonCore.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "root")
    inner = Path.join(root, "sub/inner")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(inner)
    File.mkdir_p!(outside)

    for dir <- [inner, outside] do
      {:ok, conn} = Sqlite3.open(Path.join(dir, "app.db"))

      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO users VALUES (1, 'original');
        """)

      :ok = Sqlite3.close(conn)
    end

    File.write!(Path.join(outside, "sentinel.txt"), "sentinel\n")
    %{root: root, inner: inner, outside: outside}
  end

  for {action, path, content} <- [
        {"insert", "sub/inner/app.db:users", ~s({"name":"planted"})},
        {"update", "sub/inner/app.db:users:1", ~s({"name":"planted"})},
        {"delete", "sub/inner/app.db:users:1", ""}
      ] do
    test "a row #{action} swapped after validation stays inside the workspace", ctx do
      db = Path.join(ctx.inner, "app.db")
      original = File.read!(db)
      before = tree(ctx.outside)
      test = self()

      # The target's access stat is validation's last check.
      hook = fn request ->
        if {elem(request, 0), FileServerTap.path(request)} == {:read_file_info, db} and
             Process.get(:swapped) != true do
          Process.put(:swapped, true)
          FileServerTap.swap_for_symlink(ctx.inner, ctx.outside)
          send(test, :swapped)
        end
      end

      result =
        FileServerTap.with_tap(hook, fn ->
          Write.execute(
            "write",
            %{"path" => unquote(path), "content" => unquote(content)},
            nil,
            nil,
            ctx.root,
            filesystem_checkpoints: false
          )
        end)

      assert_received :swapped
      assert tree(ctx.outside) == before
      assert {:error, message} = result
      assert message =~ "symlink"
      assert File.read!(Path.join(ctx.inner <> ".moved", "app.db")) == original
    end
  end

  defp tree(dir), do: dir |> File.ls!() |> Map.new(&{&1, File.read!(Path.join(dir, &1))})
end
