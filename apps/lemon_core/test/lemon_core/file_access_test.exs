defmodule LemonCore.FileAccessTest do
  use ExUnit.Case, async: true

  alias LemonCore.FileAccess

  @moduletag :tmp_dir

  describe "deny glob grammar" do
    test "matches the Path.wildcard grammar case-insensitively" do
      cases = [
        {"**/*.{pem,key}", ["a.pem", "d/e/b.KEY"], ["a.pemx", "a.txt"]},
        {"secret[0-9].txt", ["secret1.txt", "SECRET9.TXT"], ["secretx.txt", "secret10.txt"]},
        {"secret[9-0].txt", ["secret5.txt"], ["secreta.txt"]},
        {"x[-a].txt", ["x-.txt", "xa.txt"], ["xb.txt"]},
        {"x[a-].txt", ["x-.txt", "xa.txt"], ["xb.txt"]},
        {"x.{pem,}", ["x.pem", "x."], ["x.key"]},
        {"{[ab],c}.txt", ["a.txt", "c.txt"], ["d.txt"]},
        {"logs/?.log", ["logs/a.log"], ["logs/ab.log", "logs/a/b.log"]},
        {"*.txt", ["a.txt"], ["d/a.txt"]},
        {"build/**", ["build/a/b"], ["other/a"]},
        {"\\*.txt", ["*.txt"], ["a.txt"]}
      ]

      for {glob, denied, allowed} <- cases do
        for path <- denied,
            do:
              assert(FileAccess.denied?(Path.split(path), [glob]), "#{glob} should deny #{path}")

        for path <- allowed,
            do: refute(FileAccess.denied?(Path.split(path), [glob]), "#{glob} allowed #{path}")
      end
    end

    test "agrees with :filelib on what it matches" do
      dir = Path.join(System.tmp_dir!(), "lemon-glob-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)

      names = ~w(a b c x.pem x.key x.txt secret1.txt secretx.txt secret-.txt d/y.pem d/z.txt)

      for name <- names do
        File.mkdir_p!(Path.dirname(Path.join(dir, name)))
        File.write!(Path.join(dir, name), "")
      end

      for glob <- ~w(*.{pem,key} secret[0-9].txt secret[-x].txt [a-b] **/*.pem d/** {a,c} x.{pem}) do
        expected =
          File.cd!(dir, fn -> Path.wildcard(glob, match_dot: true) end)
          |> Enum.filter(&File.regular?(Path.join(dir, &1)))
          |> Enum.sort()

        actual = names |> Enum.filter(&FileAccess.denied?(Path.split(&1), [glob])) |> Enum.sort()
        assert actual == expected, "#{glob}: #{inspect(actual)} != #{inspect(expected)}"
      end
    end

    test "a malformed or unsupported pattern denies every path" do
      for glob <- [
            "{a,b",
            "a}",
            "[0-9",
            "]",
            "[]",
            "{a,{b,c}}",
            "{d/y,a}",
            "[a/b]",
            "x\\",
            "{**,a}"
          ] do
        assert FileAccess.denied?(["readme.md"], [glob]), "#{inspect(glob)} must fail closed"
      end

      assert FileAccess.denied?(["readme.md"], [:not_a_glob])
      assert FileAccess.denied?(["readme.md"], "**/*.pem")
      refute FileAccess.denied?(["readme.md"], nil)
      refute FileAccess.denied?(["readme.md"], ["", "  "])
    end

    test "built-in names are compared case-insensitively" do
      for name <- [".ENV", ".Git", ".SSH", ".Lemon", ".NETRC", ".EnvRC", ".ENV.local"] do
        assert FileAccess.denied?([name], []), name
        assert FileAccess.denied?(["sub", name, "x"], []), name
      end

      refute FileAccess.denied?(["env"], [])
      refute FileAccess.denied?([".environment"], [])
    end

    test "** spans directory names containing newlines", %{tmp_dir: tmp_dir} do
      assert FileAccess.denied?(["a\nb", "c\nd", "x.key"], ["**/*.key"])
      assert FileAccess.denied?(["build", "a\nb", "x.txt"], ["build/**"])
      assert FileAccess.denied?(["dir\nname", "secret.txt"], ["**/secret.txt"])

      {:ok, root} = FileAccess.real_root(tmp_dir)
      dir = Path.join(root, "a\nb")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.key"), "KEY")
      File.write!(Path.join(dir, "notes.txt"), "notes")
      cfg = %{deny_globs: ["**/*.key"]}

      assert {:error, "Access denied for that path."} =
               FileAccess.get(root, "a\nb/server.key", cfg, 1_000)

      assert {:error, "Access denied for that path."} =
               FileAccess.read_file(root, "a\nb/server.key", ["**/*.key"], 1_000)

      assert {:ok, _name, zip} = FileAccess.get(root, ".", cfg, 1_000)
      {:ok, entries} = :zip.unzip(zip, [:memory])
      assert Enum.map(entries, fn {name, _} -> to_string(name) end) == ["a\nb/notes.txt"]
    end
  end

  describe "read_file/4" do
    test "reads a regular file and refuses directories, symlinks and denied names", %{
      tmp_dir: tmp_dir
    } do
      {:ok, root} = FileAccess.real_root(tmp_dir)
      File.write!(Path.join(root, "ok.txt"), "OK")
      File.mkdir_p!(Path.join(root, "dir"))
      File.write!(Path.join(root, ".env"), "SECRET")
      File.ln_s!(Path.join(root, "ok.txt"), Path.join(root, "link.txt"))

      assert {:ok, "ok.txt", "OK"} = FileAccess.read_file(root, "ok.txt", [], 100)
      assert {:error, "Not a regular file."} = FileAccess.read_file(root, "dir", [], 100)

      assert {:error, "Symlinks are not allowed" <> _} =
               FileAccess.read_file(root, "link.txt", [], 100)

      assert {:error, "Access denied for that path."} =
               FileAccess.read_file(root, ".env", [], 100)

      assert {:error, "Access denied for that path."} =
               FileAccess.read_file(root, "ok.txt", ["*.txt"], 100)

      assert {:error, "File is too large."} = FileAccess.read_file(root, "ok.txt", [], 1)
      assert {:error, "Path escapes" <> _} = FileAccess.read_file(root, "dir/../ok.txt", [], 100)
      assert {:error, "Not found."} = FileAccess.read_file(root, "missing.txt", [], 100)
    end

    test "returns the actual entry name for another spelling", %{tmp_dir: tmp_dir} do
      {:ok, root} = FileAccess.real_root(tmp_dir)
      File.write!(Path.join(root, "Report.TXT"), "R")

      if File.exists?(Path.join(root, "report.txt")) do
        assert {:ok, "Report.TXT", "R"} = FileAccess.read_file(root, "report.txt", [], 100)
        assert {:ok, %{parts: ["Report.TXT"]}} = FileAccess.resolve(root, "REPORT.txt", :get)
      end
    end
  end

  describe "retain_copy/2" do
    test "writes a private copy and prunes expired copy directories without following links", %{
      tmp_dir: tmp_dir
    } do
      tmp = System.tmp_dir!()
      stale = Path.join(tmp, "lemon-outbound-stale-#{System.unique_integer([:positive])}")
      File.mkdir_p!(stale)
      File.write!(Path.join(stale, "old.bin"), "OLD")
      victim = Path.join(tmp_dir, "victim.txt")
      File.write!(victim, "KEEP")
      File.ln_s!(victim, Path.join(stale, "link"))
      old = System.os_time(:second) - 25 * 60 * 60
      File.touch!(stale, old)

      fresh = Path.join(tmp, "lemon-outbound-fresh-#{System.unique_integer([:positive])}")
      File.mkdir_p!(fresh)
      on_exit(fn -> File.rm_rf(fresh) end)

      link_dir = Path.join(tmp, "lemon-outbound-link-#{System.unique_integer([:positive])}")
      File.ln_s!(tmp_dir, link_dir)
      on_exit(fn -> File.rm(link_dir) end)

      assert {:ok, path} = FileAccess.retain_copy("../evil/name.png", "BYTES")
      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)

      assert Path.basename(path) == "name.png"
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.dirname(path))
      assert Bitwise.band(mode, 0o777) == 0o700

      assert File.read!(path) == "BYTES"
      assert String.starts_with?(Path.basename(Path.dirname(path)), "lemon-outbound-")
      refute File.exists?(stale)
      assert File.dir?(fresh)
      assert File.read!(victim) == "KEEP"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link_dir)
    end
  end
end
