defmodule CodingAgent.ExecutionNode.CredentialIsolationTest do
  # Routed tool calls run on the node exactly as `ExecutionNode.Worker` runs
  # them (`ToolService.run/2`). The node's durable session/recovery tokens live
  # in its token store; Lemon secrets live in the node VM's environment. A tool
  # call (bash, eval, file tools) must reach neither. The test mutates the BEAM
  # OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.{TokenStore, ToolService}
  alias CodingAgent.Tools.FileValidation
  alias CodingAgent.Tools.Lsp.WorkspaceEdit
  alias CodingAgent.Tools.SemanticFind.Candidates
  alias LemonCore.{CredentialPaths, ExecutionContext}

  @moduletag :tmp_dir

  @controller "wss://controller.example/ws"

  @env_secrets %{
    "LEMON_OPERATOR_TOKEN" => "leak-operator-token",
    "LEMON_CONTROL_PLANE_OPERATOR_TOKEN" => "leak-control-plane-token",
    "LEMON_WS_TOKEN" => "leak-ws-token",
    "LEMON_WEB_ACCESS_TOKEN" => "leak-web-access",
    "LEMON_WEB_SECRET_KEY_BASE" => "leak-web-secret-key-base",
    "LEMON_TELEGRAM_BOT_TOKEN" => "leak-telegram-bot",
    "LEMON_BOT_ENCRYPTION_KEY" => "leak-bot-encryption",
    "LEMON_GATEWAY_COOKIE" => "leak-gateway-cookie",
    "LEMON_BROWSER_RELAY_TOKEN" => "leak-relay-token",
    "LEMON_NODE_TOKEN" => "leak-node-token",
    "LEMON_SECRETS_MASTER_KEY" => "leak-master-key",
    "RELEASE_COOKIE" => "leak-release-cookie"
  }

  setup %{tmp_dir: tmp_dir} do
    saved =
      Map.new(["HOME", "LEMON_BOT_DATA_DIR" | Map.keys(@env_secrets)], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    # A home without symlinked ancestors (macOS's /var is one), so mutation
    # tools judge the credential path itself rather than refusing its parents.
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)

    unique = System.unique_integer([:positive])
    node_id = "isolation-node-#{unique}"
    token = "node-session-secret-#{unique}"
    recovery = "node-recovery-secret-#{unique}"

    # The node's real credential location: `~/.lemon/nodes/execution` under the
    # (test-isolated) Lemon home. Saved explicitly there so this test never
    # writes outside the isolated home, whatever the store's default resolves to.
    root = LemonCore.Paths.home_path(["nodes", "execution"])

    assert :ok =
             TokenStore.save(
               "isolation",
               %{
                 "token" => token,
                 "recoveryToken" => recovery,
                 "nodeId" => node_id,
                 "controller" => @controller
               },
               root: root
             )

    {:ok, path} = TokenStore.node_path(node_id, root: root)
    on_exit(fn -> File.rm(path) end)

    cwd = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(cwd)

    {:ok, cwd: cwd, root: root, path: path, token: token, recovery: recovery}
  end

  test "the store's default location is the protected Lemon home, private on disk", ctx do
    assert {:ok, default_path} = TokenStore.node_path("isolation-default")
    assert Path.dirname(default_path) == ctx.root
    assert ctx.root in CredentialPaths.protected_paths()

    assert {:ok, %{mode: file_mode}} = File.stat(ctx.path)
    assert Bitwise.band(file_mode, 0o777) == 0o600
    assert {:ok, %{mode: dir_mode}} = File.stat(ctx.root)
    assert Bitwise.band(dir_mode, 0o777) == 0o700
  end

  test "bash on a node sees no Lemon secrets or distribution cookie in its environment", ctx do
    System.put_env(@env_secrets)

    for command <- ["env", "cat /proc/self/environ 2>/dev/null | tr '\\0' '\\n'; env"] do
      output = text!(run_tool("bash", %{"command" => command}, ctx.cwd))
      assert output =~ "PATH="

      for {name, value} <- @env_secrets do
        refute output =~ value, "bash environment exposes #{name}"
      end
    end
  end

  test "document and ast-grep helpers keep their overrides but no Lemon secrets", ctx do
    System.put_env(@env_secrets)
    env = System.find_executable("env")

    assert {:ok, {ast_env, 0}} =
             CodingAgent.Tools.AstGrep.Backend.run(env, [], ctx.cwd, nil, 5_000)

    assert {:ok, doc_env} = CodingAgent.Tools.ReadFormatCommand.run(env, [], nil)

    assert ast_env =~ "NO_COLOR=1"
    assert doc_env =~ "PYTHONIOENCODING=utf-8"

    for output <- [ast_env, doc_env], {name, value} <- @env_secrets do
      refute output =~ value, "helper environment exposes #{name}"
    end
  end

  test "file tools on a node cannot read the stored node credential", ctx do
    link = Path.join(ctx.cwd, "credential.json")
    File.ln_s!(ctx.path, link)
    dir_link = Path.join(ctx.cwd, "store")
    File.ln_s!(ctx.root, dir_link)
    name = Path.basename(ctx.path)

    reads = [
      {"read", %{"path" => ctx.path}},
      {"read", %{"path" => ctx.path <> ":raw"}},
      {"read", %{"path" => "credential.json"}},
      {"read", %{"path" => "store/" <> name}},
      # `..` after a symlink is resolved by the kernel, not lexically.
      {"read", %{"path" => "store/../execution/" <> name}},
      {"read", %{"path" => Path.join(Path.dirname(ctx.root), "./execution/" <> name)}},
      {"grep", %{"pattern" => "secret", "path" => ctx.path}},
      {"grep", %{"pattern" => "secret", "path" => ctx.root}},
      {"grep",
       %{"pattern" => "secret", "path" => LemonCore.Paths.home_state_dir(), "hidden" => true}},
      {"grep",
       %{
         "pattern" => "secret",
         "path" => LemonCore.Paths.home_state_dir(),
         "hidden" => true,
         "no_ignore" => true,
         "output_mode" => "content"
       }},
      {"ls", %{"path" => ctx.root}},
      {"find", %{"pattern" => "*", "path" => ctx.root, "hidden" => true}}
    ]

    for {tool, args} <- reads do
      result = run_tool(tool, args, ctx.cwd)
      output = text(result)

      refute output =~ ctx.token, "#{tool} #{inspect(args)} exposed the session token"
      refute output =~ ctx.recovery, "#{tool} #{inspect(args)} exposed the recovery token"

      if tool in ["read", "ls"] or args["path"] in [ctx.path, ctx.root] do
        assert result["isError"], "#{tool} #{inspect(args)} was not refused: #{output}"
        assert output =~ "credential", "#{tool} #{inspect(args)}: #{output}"
      end
    end
  end

  test "file tools on a node cannot rewrite or plant node credentials", ctx do
    original = File.read!(ctx.path)
    planted = Path.join(ctx.root, "node-planted.json")

    writes = [
      {"write", %{"path" => ctx.path, "content" => ~s({"token":"attacker"})}},
      {"write", %{"path" => planted, "content" => ~s({"token":"attacker"})}},
      {"edit", %{"path" => ctx.path, "old_text" => ctx.token, "new_text" => "attacker"}}
    ]

    for {tool, args} <- writes do
      result = run_tool(tool, args, ctx.cwd)
      assert result["isError"], "#{tool} #{inspect(args)} was not refused: #{text(result)}"
    end

    assert File.read!(ctx.path) == original
    refute File.exists?(planted)
  end

  test "bash on a node refuses commands that name the credential store", ctx do
    home = LemonCore.Paths.home_dir()
    relative = Path.relative_to(ctx.root, home)

    commands = [
      "cat #{ctx.path}",
      "cat #{ctx.root}/*.json",
      ~s(cat "$HOME/#{relative}/"*.json),
      "cat ~/#{relative}/*",
      "cd #{Path.dirname(ctx.root)} && cat execution/*",
      ~s(bash -c 'grep -r token #{ctx.root}')
    ]

    for command <- commands do
      result = run_tool("bash", %{"command" => command}, ctx.cwd)
      output = text(result)
      refute output =~ ctx.token, "bash #{inspect(command)} exposed the session token"
      assert result["isError"], "bash #{inspect(command)} was not refused: #{output}"
    end

    result = run_tool("bash", %{"command" => "cat *.json", "cwd" => ctx.root}, ctx.cwd)
    refute text(result) =~ ctx.token
    assert result["isError"]
  end

  test "eval on a node refuses cell code that names the credential store", ctx do
    code = "print(open(#{inspect(ctx.path)}).read())"
    result = run_tool("eval", %{"language" => "py", "code" => code}, ctx.cwd)
    refute text(result) =~ ctx.token
    assert result["isError"]
    assert text(result) =~ "credential"
  end

  describe "other Lemon credential files" do
    setup ctx do
      home = LemonCore.Paths.home_state_dir()
      unique = System.unique_integer([:positive])

      # A configured bot data directory is protected as well as the default.
      bot_data = Path.join(Path.dirname(ctx.cwd), "bot-data")
      System.put_env("LEMON_BOT_DATA_DIR", bot_data)

      # Secret content is unique per file so a leak names its source.
      files = %{
        master_key: {LemonCore.Secrets.KeyProvider.key_file([]), "master-key-secret-#{unique}"},
        cookie: {Path.join(home, "cookie"), "cookie-secret-#{unique}"},
        env: {Path.join(home, "env"), "LEMON_BOT_OPERATOR_TOKEN=env-secret-#{unique}"},
        dotenv: {Path.join(home, ".env"), "OPENAI_API_KEY=dotenv-secret-#{unique}"},
        web: {Path.join(home, "web_secret_key_base"), "web-secret-#{unique}"},
        cp_token: {Path.join(home, "run/control-plane-4040.token"), "cp-secret-#{unique}"},
        cp_temp: {Path.join(home, "run/.control-plane-4040.AbC123"), "cp-temp-secret-#{unique}"},
        bot_key: {Path.join(home, "lemon_bot/master.key"), "bot-key-secret-#{unique}"},
        bot_access: {Path.join(home, "lemon_bot/local-access.key"), "bot-access-#{unique}"},
        bot_access_tmp:
          {Path.join(home, "lemon_bot/.local-access.key.a1b2c3"), "bot-access-tmp-#{unique}"},
        cfg_bot_key: {Path.join(bot_data, "master.key"), "cfg-bot-key-#{unique}"},
        cfg_bot_access: {Path.join(bot_data, "local-access.key"), "cfg-bot-access-#{unique}"},
        cfg_bot_tmp: {Path.join(bot_data, ".local-access.key.ffee00"), "cfg-bot-tmp-#{unique}"},
        store: {Path.join(home, "store/store.sqlite3"), "store-secret-#{unique}"}
      }

      for {_name, {path, content}} <- files do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content <> "\n")
        File.chmod!(path, 0o600)
      end

      log = Path.join(home, "run/lemon-4040.log")
      File.write!(log, "runtime log line\n")

      Map.merge(ctx, %{home: home, files: files, log: log})
    end

    test "file tools cannot read the master key, cookie or other credential files", ctx do
      for {name, {path, content}} <- ctx.files do
        link = Path.join(ctx.cwd, "link-#{name}")
        File.ln_s!(path, link)
        upper = String.replace(path, "/.lemon/", "/.LEMON/")

        for args <- [%{"path" => path}, %{"path" => "link-#{name}"}, %{"path" => upper}] do
          result = run_tool("read", args, ctx.cwd)
          refute text(result) =~ secret(content), "read #{inspect(args)} exposed #{name}"
          assert result["isError"], "read #{inspect(args)} (#{name}) was not refused"
        end

        result = run_tool("write", %{"path" => path, "content" => "attacker"}, ctx.cwd)
        assert result["isError"], "write #{name} was not refused"
        assert File.read!(path) == content <> "\n"
      end

      for args <- [
            %{"pattern" => "secret", "path" => ctx.home, "hidden" => true, "no_ignore" => true},
            %{"pattern" => "secret", "path" => ctx.cwd, "hidden" => true}
          ] do
        output = text(run_tool("grep", args, ctx.cwd))

        for {name, {_path, content}} <- ctx.files do
          refute output =~ secret(content), "grep #{inspect(args)} exposed #{name}"
        end
      end

      # Non-credential runtime state stays readable.
      assert text!(run_tool("read", %{"path" => ctx.log}, ctx.cwd)) =~ "runtime log line"
    end

    test "bash and eval refuse text naming the master key or the cookie", ctx do
      {key_path, key} = ctx.files.master_key
      {cookie_path, cookie} = ctx.files.cookie

      commands = [
        "cat #{key_path}",
        "cat ~/.lemon/secrets_master_key",
        ~s(cat "$HOME/.lemon/cookie"),
        "cat #{cookie_path}",
        "cd ~/.lemon && cat secrets_master_key",
        "cat ~/.lemon/run/control-plane-4040.token",
        "cat ~/.lemon/web_secret_key_base"
      ]

      for command <- commands do
        result = run_tool("bash", %{"command" => command}, ctx.cwd)
        output = text(result)
        refute output =~ secret(key), "bash #{inspect(command)} exposed the master key"
        refute output =~ secret(cookie), "bash #{inspect(command)} exposed the cookie"
        assert result["isError"], "bash #{inspect(command)} was not refused: #{output}"
      end

      for path <- [key_path, cookie_path] do
        code = "print(open(#{inspect(path)}).read())"
        result = run_tool("eval", %{"language" => "py", "code" => code}, ctx.cwd)
        refute text(result) =~ secret(key)
        refute text(result) =~ secret(cookie)
        assert result["isError"]
      end

      assert text!(run_tool("bash", %{"command" => "cat #{ctx.log}"}, ctx.cwd)) =~
               "runtime log line"
    end
  end

  defp secret(content), do: content |> String.split("=") |> List.last()

  describe "every model-reachable reader" do
    setup ctx do
      home = LemonCore.Paths.home_state_dir()
      unique = System.unique_integer([:positive])
      store = Path.join(home, "store")
      File.mkdir_p!(store)

      db = Path.join(store, "secrets.sqlite3")
      {:ok, conn} = Exqlite.Sqlite3.open(db)
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE secrets (value TEXT)")

      :ok =
        Exqlite.Sqlite3.execute(conn, "INSERT INTO secrets VALUES ('sqlite-secret-#{unique}')")

      :ok = Exqlite.Sqlite3.close(conn)

      zip = Path.join(store, "backup.zip")

      {:ok, _} =
        :zip.create(String.to_charlist(zip), [{~c"secret.txt", "zip-secret-#{unique}\n"}])

      cookie = Path.join(home, "cookie")
      File.write!(cookie, "cookie-secret-#{unique}\n")

      Map.merge(ctx, %{home: home, db: db, zip: zip, cookie: cookie, unique: unique})
    end

    test "rich-read selectors check the backing file behind symlinks and hard links", ctx do
      File.ln_s!(ctx.path, Path.join(ctx.cwd, "alias.json"))
      File.ln!(ctx.path, Path.join(ctx.cwd, "hard.json"))
      File.ln_s!(ctx.db, Path.join(ctx.cwd, "alias.sqlite3"))
      File.ln!(ctx.db, Path.join(ctx.cwd, "hard.sqlite3"))
      File.ln_s!(ctx.zip, Path.join(ctx.cwd, "alias.zip"))
      File.ln!(ctx.zip, Path.join(ctx.cwd, "hard.zip"))

      for path <- [
            "alias.json?q=.token",
            "hard.json?q=.",
            ctx.path <> "?q=.recoveryToken",
            "alias.sqlite3:secrets",
            "hard.sqlite3:secrets",
            ctx.db <> ":secrets",
            "alias.zip:secret.txt",
            "hard.zip:secret.txt",
            ctx.zip <> ":secret.txt"
          ] do
        result = run_tool("read", %{"path" => path}, ctx.cwd)
        output = text(result)
        refute output =~ ctx.token, "read #{path} exposed the session token"
        refute output =~ ctx.recovery, "read #{path} exposed the recovery token"
        refute output =~ "sqlite-secret", "read #{path} exposed the store row"
        refute output =~ "zip-secret", "read #{path} exposed the archive member"
        assert result["isError"], "read #{path} was not refused: #{output}"
      end

      # Selectors on ordinary files still work.
      File.write!(Path.join(ctx.cwd, "plain.json"), ~s({"a": 1}))
      assert text!(run_tool("read", %{"path" => "plain.json?q=.a"}, ctx.cwd)) =~ "1"
    end

    test "semantic search never reads credential files from a parent root", ctx do
      File.ln!(ctx.cookie, Path.join(ctx.cwd, "cookie_secret_notes.txt"))
      File.write!(Path.join(ctx.home, "notes_secret.txt"), "ordinary secret note\n")
      keywords = Candidates.keywords("cookie secret token recovery")

      assert {:ok, candidates, _truncated?} =
               Candidates.collect([ctx.home, ctx.cwd], keywords, ctx.cwd, 200, nil)

      assert Enum.any?(candidates, &(&1.path =~ "notes_secret.txt"))
      found = inspect(candidates)
      refute found =~ ctx.token
      refute found =~ ctx.recovery
      refute found =~ "cookie-secret-#{ctx.unique}"
      refute found =~ "sqlite-secret"
    end

    test "directory mutations that would move or delete credentials are refused", ctx do
      dirs =
        Enum.map(
          ["run", "nodes", "nodes/execution", "lemon_bot", "store"],
          &Path.join(ctx.home, &1)
        )

      File.mkdir_p!(Path.join(ctx.home, "lemon_bot"))
      plain = Path.join(ctx.home, "plugins")
      File.mkdir_p!(plain)

      for dir <- [ctx.home | dirs] do
        assert {:error, message} =
                 FileValidation.check_mutation_target(dir, allow_directories: true)

        assert message =~ "credential", "#{dir}: #{message}"
      end

      assert :ok = FileValidation.check_mutation_target(plain, allow_directories: true)

      uri = &("file://" <> &1)
      stolen = Path.join(ctx.cwd, "stolen")

      for change <- [
            %{
              "kind" => "rename",
              "oldUri" => uri.(Path.join(ctx.home, "run")),
              "newUri" => uri.(stolen)
            },
            %{
              "kind" => "rename",
              "oldUri" => uri.(Path.join(ctx.home, "nodes")),
              "newUri" => uri.(stolen)
            },
            %{
              "kind" => "delete",
              "uri" => uri.(Path.join(ctx.home, "nodes")),
              "options" => %{"recursive" => true}
            }
          ] do
        assert {:ok, ops} = WorkspaceEdit.plan(%{"documentChanges" => [change]})

        assert {:error, message} =
                 WorkspaceEdit.apply(ops, ctx.cwd, [filesystem_checkpoints: false], nil, %{})

        assert message =~ "credential"
      end

      refute File.exists?(stolen)
      assert File.read!(ctx.path) =~ ctx.token

      # A checkpoint of a workspace holding a hard-linked credential never copies it.
      File.ln!(ctx.cookie, Path.join(ctx.cwd, "hard-cookie"))

      assert {:error, {:protected_credential, _path}} =
               LemonCore.Checkpoint.create_filesystem("isolation-session", [ctx.cwd],
                 cwd: ctx.cwd
               )
    end
  end

  test "hard links, case-folded spellings and loops do not alias around the store", ctx do
    hard = Path.join(ctx.cwd, "hard.json")
    File.ln!(ctx.path, hard)
    loop = Path.join(ctx.cwd, "loop")
    File.ln_s!(loop, loop)

    upper =
      String.replace(ctx.path, "/.lemon/nodes/execution/", "/.LEMON/Nodes/EXECUTION/")

    for path <- [hard, upper, Path.join(loop, "x")] do
      result = run_tool("read", %{"path" => path}, ctx.cwd)
      refute text(result) =~ ctx.token, "read #{path} exposed the session token"
      assert result["isError"], "read #{path} was not refused"
    end

    assert {:error, message} = CredentialPaths.check_read(hard)
    assert message =~ "credential store"
    assert {:error, _} = CredentialPaths.check_read(upper)
    assert :ok = CredentialPaths.check_read(Path.join(ctx.cwd, "other.json"))
  end

  test "the grep fallback and ast_grep never scan the credential store", ctx do
    File.write!(Path.join(ctx.cwd, "visible.txt"), "visible secret\n")
    File.ln_s!(ctx.root, Path.join(ctx.cwd, "store"))
    home_state = LemonCore.Paths.home_state_dir()

    grep = CodingAgent.Tools.Grep.tool(ctx.cwd, ripgrep_available?: false)
    File.write!(Path.join(home_state, "other.json"), ~s({"note":"home secret"}))

    for {path, visible} <- [{ctx.cwd, "visible secret"}, {home_state, "home secret"}] do
      result =
        grep.execute.(
          "grep",
          %{"pattern" => "secret", "path" => path, "hidden" => true},
          nil,
          nil
        )

      output = Enum.map_join(result.content, "\n", & &1.text)
      assert output =~ visible, "fallback grep over #{path} found nothing: #{output}"
      refute output =~ ctx.token, "fallback grep over #{path} exposed the session token"
      refute output =~ ctx.recovery
    end

    log = Path.join(ctx.cwd, "scanned.log")
    fake = Path.join(ctx.cwd, "fake-ast-grep")

    File.write!(fake, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo "ast-grep 0.30.0"; exit 0; fi
    for arg in "$@"; do last="$arg"; done
    echo "$last" >> #{log}
    exit 1
    """)

    File.chmod!(fake, 0o755)
    ast_grep = CodingAgent.Tools.AstGrep.tool(ctx.cwd, ast_grep_executable: fake)

    ast_grep.execute.(
      "ast",
      %{"action" => "search", "pattern" => "$X", "language" => "json", "paths" => [home_state]},
      nil,
      nil
    )

    scanned = if File.exists?(log), do: File.read!(log), else: ""
    assert scanned =~ "other.json", "ast_grep did not scan the Lemon home: #{scanned}"
    refute scanned =~ Path.basename(ctx.path), "ast_grep scanned the credential file"
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp run_tool(tool, arguments, cwd) do
    {:ok, context} = ExecutionContext.new(run_id: "run-1")
    {:ok, context} = ExecutionContext.for_remote(context, nil)
    {:ok, encoded} = ExecutionContext.encode(context)
    call_id = "call-#{System.unique_integer([:positive])}"

    request = %{
      "version" => 1,
      "tool" => tool,
      "arguments" => arguments,
      "toolCallId" => call_id,
      "toolIntent" => %{"recordedBy" => "controller", "toolCallId" => call_id},
      "sessionId" => "isolation-session",
      "runId" => "run-1",
      "executionContext" => encoded
    }

    assert {:ok, result} = ToolService.run(request, default_cwd: cwd, node_name: "isolation")
    result
  end

  defp text(result) do
    for(%{"type" => "text", "text" => t} <- result["content"] || [], do: t)
    |> Enum.join("\n")
  end

  defp text!(result) do
    refute result["isError"], text(result)
    text(result)
  end
end
