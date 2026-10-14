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

  test "home is the default root, not the worker cwd", %{home: home, outside: outside} do
    assert {:ok, ^home} = HostIO.resolve(home, home: home)
    assert {:error, :path_not_allowed} = HostIO.resolve(outside, home: home, default_cwd: outside)
  end

  test "rejects traversal, sibling prefix collisions and caller policy overrides", ctx do
    assert {:error, :path_not_allowed} = HostIO.resolve("../outside/private", ctx.opts)
    assert {:error, :path_not_allowed} = HostIO.resolve(ctx.home <> "-other/file", ctx.opts)

    assert {:error, :path_not_allowed} =
             HostIO.handle(
               "node.fs.write",
               %{
                 "path" => Path.join(ctx.outside, "private"),
                 "dataBase64" => Base.encode64("blocked"),
                 "allowed_roots" => [ctx.outside]
               },
               ctx.opts
             )

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

    for path <- [
          "escape/private",
          "escape/new/leaf",
          "file-link",
          "dangling/new",
          "missing-parent-link/private"
        ] do
      assert {:error, :path_not_allowed} = HostIO.resolve(path, ctx.opts)

      assert {:error, :path_not_allowed} =
               HostIO.handle(
                 "node.fs.write",
                 %{"path" => path, "dataBase64" => "YQ==", "mkdirs" => true},
                 ctx.opts
               )
    end

    assert File.read!(private) == "outside-content"
    refute File.exists?(Path.join(ctx.outside, "new"))

    assert {:error, :path_not_allowed} =
             HostIO.handle(
               "node.fs.move",
               %{
                 "path" => "escape/private",
                 "destination" => "stolen",
                 "expectedModifiedAtMs" => 0
               },
               ctx.opts
             )
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

    assert {:ok, written} =
             HostIO.handle(
               "node.fs.write",
               %{"path" => "result.txt", "dataBase64" => Base.encode64("real")},
               opts
             )

    assert {:ok, read} = HostIO.handle("node.fs.read", %{"path" => written["path"]}, opts)
    assert Base.decode64!(read["dataBase64"]) == "real"
  end

  test "worker opts can grant another existing root and invalid policies fail closed", ctx do
    opts = Keyword.put(ctx.opts, :allowed_roots, [ctx.home, ctx.outside])
    assert {:ok, _} = HostIO.resolve(Path.join(ctx.outside, "new"), opts)

    assert {:error, :invalid_allowed_roots} =
             HostIO.resolve("file", Keyword.put(ctx.opts, :allowed_roots, []))

    assert {:error, :invalid_allowed_roots} =
             HostIO.resolve(
               "file",
               Keyword.put(ctx.opts, :allowed_roots, [Path.join(ctx.home, "missing")])
             )
  end

  test "chunked binary roundtrip, offset overwrite and truncation", ctx do
    first = :binary.copy(<<0, 255, 3, 128>>, 262_144)
    last = <<4, 0, 254, 5>>

    assert {:ok, %{"bytesWritten" => 1_048_576}} =
             HostIO.handle(
               "node.fs.write",
               %{
                 "path" => "nested/data.bin",
                 "dataBase64" => Base.encode64(first),
                 "mkdirs" => true,
                 "truncate" => false
               },
               ctx.opts
             )

    revision = modified_at("nested/data.bin", ctx.opts)

    assert {:ok, %{"size" => 1_048_580}} =
             HostIO.handle(
               "node.fs.write",
               %{
                 "path" => "nested/data.bin",
                 "dataBase64" => Base.encode64(last),
                 "offset" => byte_size(first),
                 "truncate" => true,
                 "expectedModifiedAtMs" => revision
               },
               ctx.opts
             )

    assert {:ok, chunk} =
             HostIO.handle(
               "node.fs.read",
               %{"path" => "nested/data.bin", "length" => byte_size(first)},
               ctx.opts
             )

    assert Base.decode64!(chunk["dataBase64"]) == first
    assert chunk["size"] == byte_size(first) + byte_size(last)
    assert chunk["length"] == byte_size(first)
    refute chunk["eof"]
    assert is_binary(chunk["mime"])

    assert {:ok, chunk} =
             HostIO.handle(
               "node.fs.read",
               %{"path" => "nested/data.bin", "offset" => byte_size(first), "length" => 10},
               ctx.opts
             )

    assert Base.decode64!(chunk["dataBase64"]) == last
    assert chunk["eof"]

    assert {:ok, %{"dataBase64" => "", "eof" => true}} =
             HostIO.handle(
               "node.fs.read",
               %{"path" => "nested/data.bin", "offset" => 2_000_000},
               ctx.opts
             )

    revision = modified_at("nested/data.bin", ctx.opts)

    assert {:ok, %{"size" => 1_048_580}} =
             HostIO.handle(
               "node.fs.write",
               %{
                 "path" => "nested/data.bin",
                 "dataBase64" => Base.encode64("X"),
                 "offset" => 1,
                 "truncate" => false,
                 "expectedModifiedAtMs" => revision
               },
               ctx.opts
             )

    revision = modified_at("nested/data.bin", ctx.opts)

    assert {:ok, %{"size" => 2}} =
             HostIO.handle(
               "node.fs.write",
               %{
                 "path" => "nested/data.bin",
                 "dataBase64" => Base.encode64("Y"),
                 "offset" => 1,
                 "expectedModifiedAtMs" => revision
               },
               ctx.opts
             )

    assert File.read!(Path.join(ctx.home, "nested/data.bin")) == <<0, ?Y>>
  end

  test "rejects oversized decoded data and invalid chunk options before writes", ctx do
    oversized = :binary.copy("a", 1_048_577) |> Base.encode64()

    assert {:error, :content_too_large} =
             HostIO.handle(
               "node.fs.write",
               %{"path" => "large", "dataBase64" => oversized},
               ctx.opts
             )

    assert {:error, :invalid_base64} =
             HostIO.handle("node.fs.write", %{"path" => "bad", "dataBase64" => "%%%"}, ctx.opts)

    assert {:error, :invalid_request} =
             HostIO.handle("node.fs.read", %{"path" => "bad", "length" => 1_048_577}, ctx.opts)

    assert {:error, :invalid_request} =
             HostIO.handle(
               "node.fs.write",
               %{"path" => "bad", "dataBase64" => "", "offset" => -1},
               ctx.opts
             )

    assert {:error, :invalid_request} =
             HostIO.handle(
               "node.fs.write",
               %{"path" => "bad", "dataBase64" => "", "mkdirs" => "yes"},
               ctx.opts
             )

    refute File.exists?(Path.join(ctx.home, "large"))
    refute File.exists?(Path.join(ctx.home, "bad"))
  end

  test "mkdir, stat, move and exact caller path confirmation", ctx do
    assert {:ok, %{"created" => true}} =
             HostIO.handle("node.fs.mkdir", %{"path" => "directory"}, ctx.opts)

    assert {:ok, %{"type" => "directory"}} =
             HostIO.handle("node.fs.stat", %{"path" => "directory"}, ctx.opts)

    File.write!(Path.join(ctx.home, "directory/source.txt"), "content")
    revision = modified_at("directory/source.txt", ctx.opts)

    assert {:ok, %{"moved" => true}} =
             HostIO.handle(
               "node.fs.move",
               %{
                 "path" => "directory/source.txt",
                 "destination" => "directory/destination.txt",
                 "expectedModifiedAtMs" => revision
               },
               ctx.opts
             )

    refute File.exists?(Path.join(ctx.home, "directory/source.txt"))

    assert {:error, :confirmation_required} =
             HostIO.handle("node.fs.delete", %{"path" => "directory/destination.txt"}, ctx.opts)

    assert {:error, :confirmation_required} =
             HostIO.handle(
               "node.fs.delete",
               %{
                 "path" => "directory/destination.txt",
                 "confirm" => Path.join(ctx.home, "directory/destination.txt")
               },
               ctx.opts
             )

    assert {:ok, preview} =
             HostIO.handle("node.fs.delete.preview", %{"path" => "directory"}, ctx.opts)

    assert {:error, :directory_not_empty} = delete("directory", preview, ctx.opts)

    assert {:error, :path_not_allowed} =
             HostIO.handle("node.fs.delete.preview", %{"path" => "."}, ctx.opts)

    assert {:ok, preview} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => "directory/destination.txt"},
               ctx.opts
             )

    assert {:ok, %{"deleted" => true}} = delete("directory/destination.txt", preview, ctx.opts)

    assert {:ok, preview} =
             HostIO.handle("node.fs.delete.preview", %{"path" => "directory"}, ctx.opts)

    assert {:ok, %{"deleted" => true}} = delete("directory", preview, ctx.opts)
  end

  test "directory output is bounded and hidden entries are opt-in", ctx do
    for n <- 1..501, do: File.write!(Path.join(ctx.home, "file-#{n}"), "")
    File.write!(Path.join(ctx.home, ".hidden"), "hidden")
    assert {:ok, listed} = HostIO.handle("node.fs.list", %{"path" => "."}, ctx.opts)
    assert length(listed["entries"]) == 500
    assert listed["truncated"]
    refute Enum.any?(listed["entries"], &(&1["name"] == ".hidden"))

    assert {:ok, listed} =
             HostIO.handle("node.fs.list", %{"path" => ".", "showHidden" => true}, ctx.opts)

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

    :ok =
      :telemetry.attach(
        id,
        [:coding_agent, :execution_node, :host_io],
        fn event, measurements, metadata, pid ->
          send(pid, {:host_audit, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    value = "private-token-must-not-be-projected"

    assert {:ok, set} =
             HostIO.handle(
               "node.secrets.set",
               %{"name" => "integration/token", "value" => value},
               opts
             )

    assert set == %{"name" => "integration/token", "set" => true}
    assert {:ok, ^value} = Secrets.get("integration/token", secret_opts)
    assert {:ok, listed} = HostIO.handle("node.secrets.list", %{}, opts)
    assert listed == %{"names" => ["integration/token"], "limit" => 500, "truncated" => false}
    refute inspect(listed) =~ value
    refute Map.has_key?(listed, "values")

    assert_receive {:host_audit, _, %{count: 1},
                    %{method: "node.secrets.set", outcome: :ok} = metadata}

    assert map_size(metadata) == 2
    refute inspect(metadata) =~ value
    refute inspect(metadata) =~ "integration/token"

    assert {:ok, %{"name" => "integration/token", "deleted" => true}} =
             HostIO.handle("node.secrets.delete", %{"name" => "integration/token"}, opts)

    assert {:error, :not_found} = Secrets.get("integration/token", secret_opts)
    assert {:ok, %{"names" => []}} = HostIO.handle("node.secrets.list", %{}, opts)
  end

  test "fixed-ID secret receipts are read-only and use only worker node identity", ctx do
    unless Process.whereis(LemonCore.Store), do: start_supervised!({LemonCore.Store, []})
    key_file = Path.join(ctx.home, "receipt-master-key")
    File.write!(key_file, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_file, 0o600)
    owner = "host-receipt-#{System.unique_integer([:positive])}"
    secret_opts = [owner: owner, key_providers: [:file], key_file: key_file]

    opts =
      ctx.opts
      |> Keyword.put(:secret_opts, secret_opts)
      |> Keyword.put(:node_id, "authenticated-node")

    on_exit(fn -> LemonCore.Store.delete(Secrets.table(), {owner, "token"}) end)

    args = %{
      "name" => "token",
      "value" => "private-value",
      "operationId" => "install:token",
      "nodeId" => "caller-controlled-node"
    }

    assert {:ok, result} = HostIO.handle("node.secrets.set", args, opts)

    assert result == %{
             "name" => "token",
             "set" => true,
             "operationId" => "install:token",
             "status" => "applied",
             "currentBindingMatches" => true
           }

    before = LemonCore.Store.get(Secrets.table(), {owner, "token"})
    assert {:ok, ^result} = HostIO.handle("node.secrets.set", args, opts)
    assert LemonCore.Store.get(Secrets.table(), {owner, "token"}) == before
    query = %{"operationId" => "install:token", "nodeId" => "caller-controlled-node"}
    assert {:ok, proof} = HostIO.handle("node.secrets.receipt", query, opts)

    assert proof == %{
             "nodeId" => "authenticated-node",
             "operationId" => "install:token",
             "status" => "applied",
             "name" => "token",
             "currentBindingMatches" => true
           }

    assert LemonCore.Store.get(Secrets.table(), {owner, "token"}) == before

    assert {:error, :secret_operation_conflict} =
             HostIO.handle("node.secrets.set", Map.put(args, "value", "changed"), opts)

    assert {:error, :invalid_node_id} =
             HostIO.handle("node.secrets.set", args, Keyword.delete(opts, :node_id))

    assert {:error, :invalid_node_id} =
             HostIO.handle("node.secrets.receipt", query, Keyword.delete(opts, :node_id))

    assert {:ok, %{"status" => "not_found", "name" => nil, "currentBindingMatches" => false}} =
             HostIO.handle("node.secrets.receipt", %{"operationId" => "missing"}, opts)

    assert {:ok, _} = HostIO.handle("node.secrets.delete", %{"name" => "token"}, opts)

    assert {:ok, %{"status" => "applied", "currentBindingMatches" => false}} =
             HostIO.handle("node.secrets.receipt", query, opts)

    assert {:error, :secret_operation_conflict} = HostIO.handle("node.secrets.set", args, opts)
  end

  test "secret receipt audits never carry names, values or private proof", ctx do
    id = "host-receipt-audit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        id,
        [:coding_agent, :execution_node, :host_io],
        fn _, measurements, metadata, pid ->
          send(pid, {:receipt_audit, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    assert {:error, :invalid_operation_id} =
             HostIO.handle(
               "node.secrets.receipt",
               %{"operationId" => "private-invalid/value", "name" => "private-name"},
               ctx.opts
             )

    assert_receive {:receipt_audit, %{count: 1}, metadata}
    assert metadata == %{method: "node.secrets.receipt", outcome: :invalid_operation_id}
    refute inspect(metadata) =~ "private-name"
    refute inspect(metadata) =~ "private-invalid/value"
  end

  test "host information describes this destination without fabricated metrics", ctx do
    assert {:ok, host} = HostIO.handle("node.host.info", %{}, ctx.opts)
    assert host["defaultCwd"] == ctx.home
    assert is_binary(host["hostname"])
    assert host["os"] == :os.type() |> elem(1) |> Atom.to_string()

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

  test "existing writes require the observed revision and stale writes preserve bytes", ctx do
    File.write!(Path.join(ctx.home, "cas"), "original")
    revision = modified_at("cas", ctx.opts)
    args = %{"path" => "cas", "dataBase64" => Base.encode64("replacement")}
    assert {:error, :revision_conflict} = HostIO.handle("node.fs.write", args, ctx.opts)

    assert {:error, :revision_conflict} =
             HostIO.handle("node.fs.write", Map.put(args, "expectedModifiedAtMs", 0), ctx.opts)

    assert {:ok, _} =
             HostIO.handle(
               "node.fs.write",
               Map.put(args, "expectedModifiedAtMs", revision),
               ctx.opts
             )

    assert modified_at("cas", ctx.opts) > revision

    assert {:error, :revision_conflict} =
             HostIO.handle(
               "node.fs.write",
               Map.put(args, "expectedModifiedAtMs", revision),
               ctx.opts
             )

    assert File.read!(Path.join(ctx.home, "cas")) == "replacement"

    assert {:error, :revision_conflict} =
             HostIO.handle(
               "node.fs.write",
               %{"path" => "missing", "dataBase64" => "", "expectedModifiedAtMs" => revision},
               ctx.opts
             )

    refute File.exists?(Path.join(ctx.home, "missing"))
  end

  test "concurrent alias CAS writes have exactly one winner", ctx do
    File.write!(Path.join(ctx.home, "cas"), "initial")
    File.ln_s!("cas", Path.join(ctx.home, "alias-cas"))
    revision = modified_at("cas", ctx.opts)

    results =
      1..16
      |> Task.async_stream(
        fn index ->
          HostIO.handle(
            "node.fs.write",
            %{
              "path" => if(rem(index, 2) == 0, do: "cas", else: "alias-cas"),
              "dataBase64" => Base.encode64("winner-#{index}"),
              "expectedModifiedAtMs" => revision
            },
            ctx.opts
          )
        end, max_concurrency: 16, ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :revision_conflict})) == 15
  end

  test "stat and listing return actual subsecond filesystem milliseconds", ctx do
    path = Path.join(ctx.home, "precise")
    File.write!(path, "content")
    python = System.find_executable("python3")
    ns = 1_770_000_000_123_456_789

    {_, 0} =
      System.cmd(python, [
        "-c",
        "import os,sys; n=int(sys.argv[2]); os.utime(sys.argv[1],ns=(n,n))",
        path,
        Integer.to_string(ns)
      ])

    assert modified_at("precise", ctx.opts) == div(ns, 1_000_000)
    assert {:ok, listed} = HostIO.handle("node.fs.list", %{"path" => "."}, ctx.opts)

    assert Enum.find(listed["entries"], &(&1["name"] == "precise"))["mtimeMs"] ==
             div(ns, 1_000_000)

    assert {:ok, _} =
             HostIO.handle(
               "node.fs.write",
               %{
                 "path" => "precise",
                 "dataBase64" => "YQ==",
                 "expectedModifiedAtMs" => div(ns, 1_000_000)
               },
               ctx.opts
             )
  end

  test "move defaults to no overwrite and compares the source revision", ctx do
    File.write!(Path.join(ctx.home, "source"), "source")
    File.write!(Path.join(ctx.home, "destination"), "destination")
    revision = modified_at("source", ctx.opts)

    args = %{
      "path" => "source",
      "destination" => "destination",
      "expectedModifiedAtMs" => revision
    }

    assert {:error, :already_exists} = HostIO.handle("node.fs.move", args, ctx.opts)
    assert File.read!(Path.join(ctx.home, "source")) == "source"
    assert File.read!(Path.join(ctx.home, "destination")) == "destination"

    assert {:error, :revision_conflict} =
             HostIO.handle(
               "node.fs.move",
               Map.put(args, "expectedModifiedAtMs", revision + 1),
               ctx.opts
             )

    assert {:ok, %{"moved" => true}} =
             HostIO.handle("node.fs.move", Map.put(args, "overwrite", true), ctx.opts)

    assert File.read!(Path.join(ctx.home, "destination")) == "source"
  end

  test "concurrent no-overwrite moves never replace the winning destination", ctx do
    for name <- ["first", "second"], do: File.write!(Path.join(ctx.home, name), name)

    requests =
      Enum.map(["first", "second"], fn name ->
        %{
          "path" => name,
          "destination" => "winner",
          "expectedModifiedAtMs" => modified_at(name, ctx.opts),
          "overwrite" => false
        }
      end)

    results =
      requests
      |> Task.async_stream(&HostIO.handle("node.fs.move", &1, ctx.opts), max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_exists})) == 1
    winner = File.read!(Path.join(ctx.home, "winner"))
    loser = if winner == "first", do: "second", else: "first"
    assert File.read!(Path.join(ctx.home, loser)) == loser
  end

  test "delete binds exact caller, revision, candidates and one-use worker token", ctx do
    File.mkdir_p!(Path.join(ctx.home, "tree/nested"))
    File.write!(Path.join(ctx.home, "tree/nested/file"), "original")

    assert {:ok, preview} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => "tree", "recursive" => true},
               ctx.opts
             )

    assert preview["childCount"] == 1
    assert preview["candidateCount"] == 3
    assert byte_size(preview["childrenDigest"]) == 64
    assert preview["expiresAtMs"] > System.system_time(:millisecond)
    File.write!(Path.join(ctx.home, "tree/nested/file"), "changed")
    assert {:error, :stale_preview} = delete("tree", preview, ctx.opts)
    assert File.read!(Path.join(ctx.home, "tree/nested/file")) == "changed"

    assert {:ok, preview} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => "tree", "recursive" => true},
               ctx.opts
             )

    File.write!(Path.join(ctx.home, "tree/new-child"), "")
    assert {:error, :stale_preview} = delete("tree", preview, ctx.opts)

    assert {:error, :invalid_confirmation_token} =
             HostIO.handle("node.fs.delete", %{"path" => "tree", "confirm" => "tree"}, ctx.opts)

    assert {:ok, preview} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => "tree", "recursive" => true},
               ctx.opts
             )

    assert {:error, :invalid_confirmation_token} =
             delete(Path.join(ctx.home, "tree"), preview, ctx.opts)

    assert {:ok, preview} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => "tree", "recursive" => true},
               ctx.opts
             )

    assert {:ok, %{"deleted" => true}} = delete("tree", preview, ctx.opts)
    refute File.exists?(Path.join(ctx.home, "tree"))
  end

  test "delete rejects replaced target even when size and mtime are preserved", ctx do
    path = Path.join(ctx.home, "target")
    File.write!(path, "same")

    assert {:ok, preview} =
             HostIO.handle("node.fs.delete.preview", %{"path" => "target"}, ctx.opts)

    python = System.find_executable("python3")

    {_, 0} =
      System.cmd(python, [
        "-c",
        "import os,sys; p=sys.argv[1]; s=os.stat(p); os.rename(p,p+'.old'); open(p,'w').write('same'); os.utime(p,ns=(s.st_atime_ns,s.st_mtime_ns))",
        path
      ])

    assert {:error, :stale_preview} = delete("target", preview, ctx.opts)
    assert File.read!(path) == "same"

    assert {:ok, preview} =
             HostIO.handle("node.fs.delete.preview", %{"path" => "target"}, ctx.opts)

    assert {:ok, _} = delete("target", preview, ctx.opts)
    File.write!(path, "new")
    assert {:error, :invalid_confirmation_token} = delete("target", preview, ctx.opts)
    assert File.read!(path) == "new"
  end

  test "recursive deletion unlinks child symlinks without following outside targets", ctx do
    File.mkdir_p!(Path.join(ctx.home, "tree"))
    File.write!(Path.join(ctx.outside, "keep"), "outside")
    File.ln_s!(ctx.outside, Path.join(ctx.home, "tree/escape"))

    assert {:ok, preview} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => "tree", "recursive" => true},
               ctx.opts
             )

    assert {:ok, _} = delete("tree", preview, ctx.opts)
    assert File.read!(Path.join(ctx.outside, "keep")) == "outside"
  end

  test "pinned roots do not follow a root swapped for an outside symlink", ctx do
    assert {:ok, _} = HostIO.handle("node.fs.stat", %{"path" => "."}, ctx.opts)
    original = ctx.home <> "-original"
    File.rename!(ctx.home, original)
    File.ln_s!(ctx.outside, ctx.home)

    assert {:ok, _} =
             HostIO.handle("node.fs.write", %{"path" => "safe", "dataBase64" => "YQ=="}, ctx.opts)

    refute File.exists?(Path.join(ctx.outside, "safe"))
    assert File.read!(Path.join(original, "safe")) == "a"
    File.rm!(ctx.home)
    File.rename!(original, ctx.home)
  end

  test "parent symlink replacement races never write outside the root", ctx do
    File.mkdir_p!(Path.join(ctx.home, "parent"))
    File.write!(Path.join(ctx.outside, "sentinel"), "untouched")
    parent = Path.join(ctx.home, "parent")
    saved = Path.join(ctx.home, "saved")

    racer =
      Task.async(fn ->
        for _ <- 1..100 do
          File.rename!(parent, saved)
          File.ln_s!(ctx.outside, parent)
          File.rm!(parent)
          File.rename!(saved, parent)
        end
      end)

    for _ <- 1..100 do
      result =
        HostIO.handle(
          "node.fs.write",
          %{"path" => "parent/sentinel", "dataBase64" => "YQ==", "expectedModifiedAtMs" => 0},
          ctx.opts
        )

      assert match?({:ok, _}, result) or
               result in [
                 {:error, :revision_conflict},
                 {:error, :path_not_allowed},
                 {:error, :not_directory},
                 {:error, :not_found}
               ]
    end

    Task.await(racer)
    assert File.read!(Path.join(ctx.outside, "sentinel")) == "untouched"
  end

  test "write receipt carries the actual next CAS revision and access flags are OS derived",
       ctx do
    assert {:ok, first} =
             HostIO.handle(
               "node.fs.write",
               %{"path" => "receipt", "dataBase64" => "YQ=="},
               ctx.opts
             )

    assert first["mtimeMs"] == modified_at("receipt", ctx.opts)

    assert {:ok, second} =
             HostIO.handle(
               "node.fs.write",
               %{
                 "path" => "receipt",
                 "dataBase64" => "Yg==",
                 "expectedModifiedAtMs" => first["mtimeMs"]
               },
               ctx.opts
             )

    assert second["mtimeMs"] > first["mtimeMs"]
    assert {:ok, stat} = HostIO.handle("node.fs.stat", %{"path" => "receipt"}, ctx.opts)

    {flags, 0} =
      System.cmd(System.find_executable("python3"), [
        "-c",
        "import os,sys,json; kw={'effective_ids':True} if os.access in os.supports_effective_ids else {}; print(json.dumps([os.access(sys.argv[1],os.R_OK,**kw),os.access(sys.argv[1],os.W_OK,**kw)]))",
        Path.join(ctx.home, "receipt")
      ])

    assert [stat["readable"], stat["writable"]] == Jason.decode!(flags)
  end

  test "expired queued requests do not execute and preview storage is bounded", ctx do
    assert {:ok, _} = HostIO.handle("node.fs.stat", %{"path" => "."}, ctx.opts)
    policy = %{"cwd" => ctx.home, "roots" => [ctx.home]}
    deadline = System.monotonic_time(:millisecond) - 1

    assert {:error, :host_io_unavailable} =
             GenServer.call(
               CodingAgent.ExecutionNode.FileService,
               {:request, "node.fs.write", %{"path" => "expired", "dataBase64" => "YQ=="}, policy,
                deadline}
             )

    refute File.exists?(Path.join(ctx.home, "expired"))
    File.write!(Path.join(ctx.home, "preview-cap"), "content")

    results =
      for _ <- 1..129,
          do: HostIO.handle("node.fs.delete.preview", %{"path" => "preview-cap"}, ctx.opts)

    assert Enum.any?(results, &(&1 == {:error, :preview_too_large}))

    for {:ok, preview} <- results do
      assert {:error, :invalid_confirmation_token} = delete("different-caller", preview, ctx.opts)
    end

    assert File.read!(Path.join(ctx.home, "preview-cap")) == "content"
  end

  test "deep recursive previews fail without producing truncated candidates", ctx do
    nested =
      Enum.reduce(1..65, Path.join(ctx.home, "deep"), fn _, path -> Path.join(path, "d") end)

    File.mkdir_p!(nested)

    assert {:error, :preview_too_large} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => "deep", "recursive" => true},
               ctx.opts
             )

    assert File.dir?(nested)
  end

  test "missing empty and nonregular targets fail explicitly", ctx do
    fifo = Path.join(ctx.home, "fifo")

    {_, 0} =
      System.cmd(System.find_executable("python3"), [
        "-c",
        "import os,sys; os.mkfifo(sys.argv[1])",
        fifo
      ])

    assert {:error, :not_regular_file} =
             HostIO.handle("node.fs.read", %{"path" => "fifo"}, ctx.opts)

    assert {:error, :not_regular_file} =
             HostIO.handle("node.fs.write", %{"path" => "fifo", "dataBase64" => ""}, ctx.opts)

    assert {:error, :invalid_path} = HostIO.handle("node.fs.stat", %{"path" => ""}, ctx.opts)

    assert {:error, :not_found} =
             HostIO.handle("node.fs.delete.preview", %{"path" => "missing"}, ctx.opts)

    assert {:error, :not_regular_file} = HostIO.handle("node.fs.read", %{"path" => "."}, ctx.opts)

    assert {:error, :not_regular_file} =
             HostIO.handle("node.fs.write", %{"path" => ".", "dataBase64" => ""}, ctx.opts)

    assert {:error, :invalid_request} =
             HostIO.handle(
               "node.fs.delete.preview",
               %{"path" => ".", "recursive" => "true"},
               ctx.opts
             )
  end

  defp modified_at(path, opts) do
    {:ok, stat} = HostIO.handle("node.fs.stat", %{"path" => path}, opts)
    stat["mtimeMs"]
  end

  defp delete(path, preview, opts) do
    HostIO.handle(
      "node.fs.delete",
      %{"path" => path, "confirm" => path, "confirmationToken" => preview["confirmationToken"]},
      opts
    )
  end
end
