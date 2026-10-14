defmodule CodingAgent.ExecutionNode.HostIOTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.HostIO
  alias LemonCore.Secrets

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(home)
    File.mkdir_p!(outside)
    opts = [default_cwd: home, allowed_roots: [home]]
    {:ok, home} = HostIO.resolve(".", opts)
    opts = Keyword.put(opts, :default_cwd, home)
    {:ok, outside} = HostIO.resolve(outside, default_cwd: outside, allowed_roots: [outside])
    %{home: home, outside: outside, opts: opts}
  end

  test "home is the default root, not the worker cwd", %{outside: outside} do
    assert {:ok, _} = HostIO.resolve(System.user_home!(), [])
    assert {:error, :path_not_allowed} = HostIO.resolve(outside, default_cwd: outside)
  end

  test "rejects traversal, sibling prefix collisions and caller policy overrides", ctx do
    assert {:error, :path_not_allowed} = HostIO.resolve("../outside/private", ctx.opts)
    assert {:error, :path_not_allowed} = HostIO.resolve(ctx.home <> "-other/file", ctx.opts)
    assert {:error, :path_not_allowed} =
             HostIO.handle("node.fs.write", %{"path" => Path.join(ctx.outside, "private"),
               "dataBase64" => Base.encode64("blocked"), "allowed_roots" => [ctx.outside]}, ctx.opts)
    refute File.exists?(Path.join(ctx.outside, "private"))
    assert {:error, :invalid_path} = HostIO.resolve("bad" <> <<0>>, ctx.opts)
  end

  test "rejects symlink escapes for existing and nonexistent descendants", ctx do
    private = Path.join(ctx.outside, "private")
    File.write!(private, "outside-content")
    File.ln_s!(ctx.outside, Path.join(ctx.home, "escape"))
    File.ln_s!(private, Path.join(ctx.home, "file-link"))
    File.ln_s!(Path.join(ctx.outside, "missing"), Path.join(ctx.home, "dangling"))
    File.ln_s!("missing/../escape", Path.join(ctx.home, "missing-parent-link"))

    for path <- ["escape/private", "escape/new/leaf", "file-link", "dangling/new", "missing-parent-link/private"] do
      assert {:error, :path_not_allowed} = HostIO.resolve(path, ctx.opts)
      assert {:error, :path_not_allowed} =
               HostIO.handle("node.fs.write", %{"path" => path, "dataBase64" => "YQ==", "mkdirs" => true}, ctx.opts)
    end
    assert File.read!(private) == "outside-content"
    refute File.exists?(Path.join(ctx.outside, "new"))
    assert {:error, :path_not_allowed} =
             HostIO.handle("node.fs.move", %{"path" => "escape/private", "destination" => "stolen"}, ctx.opts)
  end

  test "resolves safe symlinks and limits link cycles", ctx do
    File.mkdir_p!(Path.join(ctx.home, "real"))
    File.ln_s!("real", Path.join(ctx.home, "alias"))
    assert {:ok, path} = HostIO.resolve("alias/new.txt", ctx.opts)
    assert path == Path.join(ctx.home, "real/new.txt")
    File.ln_s!("loop", Path.join(ctx.home, "loop"))
    assert {:error, :symlink_loop} = HostIO.resolve("loop/new", ctx.opts)
  end

  test "canonical paths returned under a symlinked configured root remain usable", ctx do
    root_alias = Path.join(Path.dirname(ctx.home), "home-alias")
    File.ln_s!(ctx.home, root_alias)
    opts = [default_cwd: root_alias, allowed_roots: [root_alias]]
    assert {:ok, written} = HostIO.handle("node.fs.write", %{"path" => "result.txt", "dataBase64" => Base.encode64("real")}, opts)
    assert {:ok, read} = HostIO.handle("node.fs.read", %{"path" => written["path"]}, opts)
    assert Base.decode64!(read["dataBase64"]) == "real"
  end

  test "worker opts can grant another existing root and invalid policies fail closed", ctx do
    opts = Keyword.put(ctx.opts, :allowed_roots, [ctx.home, ctx.outside])
    assert {:ok, _} = HostIO.resolve(Path.join(ctx.outside, "new"), opts)
    assert {:error, :invalid_allowed_roots} = HostIO.resolve("file", Keyword.put(ctx.opts, :allowed_roots, []))
    assert {:error, :invalid_allowed_roots} = HostIO.resolve("file", Keyword.put(ctx.opts, :allowed_roots, [Path.join(ctx.home, "missing")]))
  end

  test "chunked binary roundtrip, offset overwrite and truncation", ctx do
    first = :binary.copy(<<0, 255, 3, 128>>, 262_144)
    last = <<4, 0, 254, 5>>
    assert {:ok, %{"bytesWritten" => 1_048_576}} =
             HostIO.handle("node.fs.write", %{"path" => "nested/data.bin", "dataBase64" => Base.encode64(first), "mkdirs" => true, "truncate" => false}, ctx.opts)
    assert {:ok, %{"size" => 1_048_580}} =
             HostIO.handle("node.fs.write", %{"path" => "nested/data.bin", "dataBase64" => Base.encode64(last), "offset" => byte_size(first), "truncate" => true}, ctx.opts)
    assert {:ok, chunk} = HostIO.handle("node.fs.read", %{"path" => "nested/data.bin", "length" => byte_size(first)}, ctx.opts)
    assert Base.decode64!(chunk["dataBase64"]) == first
    assert chunk["size"] == byte_size(first) + byte_size(last)
    assert chunk["length"] == byte_size(first)
    refute chunk["eof"]
    assert is_binary(chunk["mime"])
    assert {:ok, chunk} = HostIO.handle("node.fs.read", %{"path" => "nested/data.bin", "offset" => byte_size(first), "length" => 10}, ctx.opts)
    assert Base.decode64!(chunk["dataBase64"]) == last
    assert chunk["eof"]
    assert {:ok, %{"dataBase64" => "", "eof" => true}} =
             HostIO.handle("node.fs.read", %{"path" => "nested/data.bin", "offset" => 2_000_000}, ctx.opts)

    assert {:ok, %{"size" => 1_048_580}} =
             HostIO.handle("node.fs.write", %{"path" => "nested/data.bin", "dataBase64" => Base.encode64("X"), "offset" => 1, "truncate" => false}, ctx.opts)
    assert {:ok, %{"size" => 2}} =
             HostIO.handle("node.fs.write", %{"path" => "nested/data.bin", "dataBase64" => Base.encode64("Y"), "offset" => 1}, ctx.opts)
    assert File.read!(Path.join(ctx.home, "nested/data.bin")) == <<0, ?Y>>
  end

  test "rejects oversized decoded data and invalid chunk options before writes", ctx do
    oversized = :binary.copy("a", 1_048_577) |> Base.encode64()
    assert {:error, :content_too_large} = HostIO.handle("node.fs.write", %{"path" => "large", "dataBase64" => oversized}, ctx.opts)
    assert {:error, :invalid_base64} = HostIO.handle("node.fs.write", %{"path" => "bad", "dataBase64" => "%%%"}, ctx.opts)
    assert {:error, :invalid_request} = HostIO.handle("node.fs.read", %{"path" => "bad", "length" => 1_048_577}, ctx.opts)
    assert {:error, :invalid_request} = HostIO.handle("node.fs.write", %{"path" => "bad", "dataBase64" => "", "offset" => -1}, ctx.opts)
    assert {:error, :invalid_request} = HostIO.handle("node.fs.write", %{"path" => "bad", "dataBase64" => "", "mkdirs" => "yes"}, ctx.opts)
    refute File.exists?(Path.join(ctx.home, "large"))
    refute File.exists?(Path.join(ctx.home, "bad"))
  end

  test "mkdir, stat, move and exact caller path confirmation", ctx do
    assert {:ok, %{"created" => true}} = HostIO.handle("node.fs.mkdir", %{"path" => "directory"}, ctx.opts)
    assert {:ok, %{"type" => "directory"}} = HostIO.handle("node.fs.stat", %{"path" => "directory"}, ctx.opts)
    File.write!(Path.join(ctx.home, "directory/source.txt"), "content")
    assert {:ok, %{"moved" => true}} = HostIO.handle("node.fs.move", %{"path" => "directory/source.txt", "destination" => "directory/destination.txt"}, ctx.opts)
    refute File.exists?(Path.join(ctx.home, "directory/source.txt"))
    assert {:error, :confirmation_required} = HostIO.handle("node.fs.delete", %{"path" => "directory/destination.txt"}, ctx.opts)
    assert {:error, :confirmation_required} = HostIO.handle("node.fs.delete", %{"path" => "directory/destination.txt", "confirm" => Path.join(ctx.home, "directory/destination.txt")}, ctx.opts)
    assert {:error, :directory_not_empty} = HostIO.handle("node.fs.delete", %{"path" => "directory", "confirm" => "directory"}, ctx.opts)
    assert {:error, :path_not_allowed} = HostIO.handle("node.fs.delete", %{"path" => ".", "confirm" => "."}, ctx.opts)
    assert {:ok, %{"deleted" => true}} = HostIO.handle("node.fs.delete", %{"path" => "directory/destination.txt", "confirm" => "directory/destination.txt"}, ctx.opts)
    assert {:ok, %{"deleted" => true}} = HostIO.handle("node.fs.delete", %{"path" => "directory", "confirm" => "directory"}, ctx.opts)
  end

  test "directory output is bounded and hidden entries are opt-in", ctx do
    for n <- 1..501, do: File.write!(Path.join(ctx.home, "file-#{n}"), "")
    File.write!(Path.join(ctx.home, ".hidden"), "hidden")
    assert {:ok, listed} = HostIO.handle("node.fs.list", %{"path" => "."}, ctx.opts)
    assert length(listed["entries"]) == 500
    assert listed["truncated"]
    refute Enum.any?(listed["entries"], &(&1["name"] == ".hidden"))
    assert {:ok, listed} = HostIO.handle("node.fs.list", %{"path" => ".", "showHidden" => true}, ctx.opts)
    assert Enum.any?(listed["entries"], &(&1["name"] == ".hidden"))
    refute inspect(listed) =~ "hidden-content"
  end

  test "encrypted secrets return names only and content-free audits", ctx do
    unless Process.whereis(LemonCore.Store), do: start_supervised!({LemonCore.Store, []})
    key_file = Path.join(ctx.home, "master-key")
    File.write!(key_file, Base.encode64(:crypto.strong_rand_bytes(32)))
    owner = "host-io-test-#{System.unique_integer([:positive])}"
    secret_opts = [owner: owner, key_providers: [:file], key_file: key_file]
    opts = Keyword.put(ctx.opts, :secret_opts, secret_opts)
    on_exit(fn -> Secrets.delete("integration/token", secret_opts) end)

    id = "host-io-audit-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(id, [:coding_agent, :execution_node, :host_io], fn event, measurements, metadata, pid ->
      send(pid, {:host_audit, event, measurements, metadata})
    end, self())
    on_exit(fn -> :telemetry.detach(id) end)

    value = "private-token-must-not-be-projected"
    assert {:ok, set} = HostIO.handle("node.secrets.set", %{"name" => "integration/token", "value" => value}, opts)
    assert set == %{"name" => "integration/token", "set" => true}
    assert {:ok, ^value} = Secrets.get("integration/token", secret_opts)
    assert {:ok, listed} = HostIO.handle("node.secrets.list", %{}, opts)
    assert listed == %{"names" => ["integration/token"], "limit" => 500, "truncated" => false}
    refute inspect(listed) =~ value
    refute Map.has_key?(listed, "values")
    assert_receive {:host_audit, _, %{count: 1}, %{method: "node.secrets.set", outcome: :ok} = metadata}
    assert map_size(metadata) == 2
    refute inspect(metadata) =~ value
    refute inspect(metadata) =~ "integration/token"
    assert {:ok, %{"name" => "integration/token", "deleted" => true}} = HostIO.handle("node.secrets.delete", %{"name" => "integration/token"}, opts)
    assert {:error, :not_found} = Secrets.get("integration/token", secret_opts)
    assert {:ok, %{"names" => []}} = HostIO.handle("node.secrets.list", %{}, opts)
  end

  test "host information describes this destination without fabricated metrics", ctx do
    assert {:ok, host} = HostIO.handle("node.host.info", %{}, ctx.opts)
    assert host["defaultCwd"] == ctx.home
    assert is_binary(host["hostname"])
    assert host["os"] == (:os.type() |> elem(1) |> Atom.to_string())
    for key <- ["cpuCount", "memTotalBytes", "diskTotalBytes"] do
      assert is_nil(host[key]) or (is_integer(host[key]) and host[key] > 0)
    end
    for key <- ["memFreeBytes", "diskFreeBytes", "uptimeSec"] do
      assert is_nil(host[key]) or (is_integer(host[key]) and host[key] >= 0)
    end
  end

  test "host metadata remains available when worker cwd is outside file roots", ctx do
    opts = Keyword.put(ctx.opts, :default_cwd, ctx.outside)
    assert {:error, :path_not_allowed} = HostIO.resolve(".", opts)
    assert {:ok, %{"defaultCwd" => cwd}} = HostIO.handle("node.host.info", %{}, opts)
    assert cwd == ctx.outside
  end
end
