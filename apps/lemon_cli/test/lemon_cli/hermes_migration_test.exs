defmodule LemonCli.HermesMigrationTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias LemonCli.HermesMigration
  alias LemonMemory.Store

  setup do
    Application.ensure_all_started(:yaml_elixir)
    Application.ensure_all_started(:lemon_core)

    root =
      Path.join(System.tmp_dir!(), "hermes_migration_test_#{System.unique_integer([:positive])}")

    source = Path.join(root, "hermes")
    target = Path.join(root, "lemon")

    home = Path.join(root, "home")
    File.mkdir_p!(home)
    saved_env = Map.new(~w(HOME LEMON_SECRETS_MASTER_KEY), &{&1, System.get_env(&1)})
    saved_secrets_config = Application.fetch_env(:lemon_core, LemonCore.Secrets)
    saved_secret_rows = honcho_secret_rows()
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env])
    System.put_env("HOME", home)
    System.delete_env("LEMON_SECRETS_MASTER_KEY")

    on_exit(fn ->
      Enum.each(saved_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case saved_secrets_config do
        {:ok, value} -> Application.put_env(:lemon_core, LemonCore.Secrets, value)
        :error -> Application.delete_env(:lemon_core, LemonCore.Secrets)
      end

      Enum.each(honcho_secret_rows(), fn {key, _} ->
        LemonCore.Store.delete(LemonCore.Secrets.table(), key)
      end)

      Enum.each(saved_secret_rows, fn {key, value} ->
        LemonCore.Store.put(LemonCore.Secrets.table(), key, value)
      end)
    end)

    File.mkdir_p!(Path.join(source, "memories"))
    File.mkdir_p!(Path.join([source, "skills", "demo-skill"]))
    File.write!(Path.join(source, "SOUL.md"), "Hermes persona\n")

    File.write!(
      Path.join([source, "memories", "MEMORY.md"]),
      "- prefers focused plans\n- runs tests\n"
    )

    File.write!(Path.join([source, "memories", "USER.md"]), "- likes concise updates\n")

    File.write!(Path.join([source, "skills", "demo-skill", "SKILL.md"]), """
    ---
    name: demo-skill
    description: Demo skill
    ---

    Do the demo thing.
    """)

    File.write!(Path.join(source, "config.yaml"), """
    model: anthropic:claude-test
    providers:
      openai:
        base_url: https://api.openai.test/v1
    """)

    create_state_db(Path.join(source, "state.db"))

    on_exit(fn -> File.rm_rf(root) end)

    %{source: source, target: target, home: home}
  end

  test "dry run reports planned compatible imports", %{source: source, target: target} do
    report = HermesMigration.preview(source: source, target: target)

    assert report["summary"]["planned"] >= 5
    assert Enum.any?(report["items"], &(&1["kind"] == "memory" and &1["status"] == "planned"))
    assert Enum.any?(report["items"], &(&1["kind"] == "sessions" and &1["status"] == "planned"))
  end

  test "applies memory, skills, config, and session memory documents", %{
    source: source,
    target: target
  } do
    report = HermesMigration.apply(source: source, target: target, skill_conflict: "rename")

    assert report["summary"]["migrated"] >= 5

    assert File.read!(Path.join([target, "agent", "workspace", "MEMORY.md"])) =~
             "prefers focused plans"

    assert File.exists?(Path.join([target, "agent", "skill", "demo-skill", "SKILL.md"]))

    config = File.read!(Path.join(target, "config.toml"))
    assert config =~ ~s(provider = "anthropic")
    assert config =~ ~s(model = "anthropic:claude-test")
    assert config =~ ~s(base_url = "https://api.openai.test/v1")

    {:ok, store} =
      start_supervised(
        {Store,
         [
           name: :"hermes_migration_assert_#{System.unique_integer([:positive])}",
           path: Path.join(target, "store")
         ]}
      )

    assert eventually(fn ->
             Store.get_by_session(store, "hermes:s1", limit: 5)
             |> Enum.any?(&String.contains?(&1.prompt_summary, "Please fix auth"))
           end)
  end

  test "detects conflicts without overwrite", %{source: source, target: target} do
    File.mkdir_p!(Path.join([target, "agent", "workspace"]))
    File.write!(Path.join([target, "agent", "workspace", "SOUL.md"]), "existing\n")

    report = HermesMigration.preview(source: source, target: target)

    assert HermesMigration.has_conflicts?(report)
    assert Enum.any?(report["items"], &(&1["kind"] == "soul" and &1["status"] == "conflict"))
  end

  test "provider config conflicts require overwrite, including custom config paths", ctx do
    File.mkdir_p!(ctx.target)
    path = Path.join(ctx.target, "custom.toml")

    before = """
    [defaults]
    provider = "openai"
    model = "openai:existing"
    [providers.openai]
    base_url = "http://localhost:1234/v1"
    """

    File.write!(path, before)
    opts = [source: ctx.source, target: ctx.target, config_path: path]

    preview = HermesMigration.preview(opts)
    assert Enum.any?(preview["items"], &(&1["kind"] == "config" and &1["status"] == "conflict"))
    HermesMigration.apply(opts)
    assert File.read!(path) == before

    report = HermesMigration.apply(Keyword.put(opts, :overwrite, true))
    assert Toml.decode_file!(path)["defaults"]["model"] == "anthropic:claude-test"
    assert File.exists?(Path.join(report["output_dir"], "backups/custom.toml"))
    refute File.exists?(Path.join(ctx.target, "config.toml"))

    refute Enum.any?(
             HermesMigration.preview(opts)["items"],
             &(&1["kind"] == "config" and &1["status"] == "conflict")
           )
  end

  test "user-data apply gates auth.json and never writes its token outside secrets", %{
    source: source,
    target: target
  } do
    token = "hermes-oauth-token-not-real-42"
    File.write!(Path.join(source, "auth.json"), ~s({"telegram":{"token":"#{token}"}}))

    report = HermesMigration.apply(source: source, target: target, preset: "user-data")

    archive = Path.join(report["output_dir"], "archive")
    refute File.exists?(Path.join(archive, "auth.json"))

    assert [auth] =
             Enum.filter(report["items"], &(&1["source"] == Path.join(source, "auth.json")))

    assert auth["status"] == "gated"
    assert auth["reason"] =~ "--preset full --migrate-secrets"

    for file <- Path.wildcard(Path.join(target, "**/*"), match_dot: true),
        File.regular?(file) do
      refute File.read!(file) =~ token, "token leaked into #{file}"
    end
  end

  test "archived config.yaml keeps only supported non-secret fields", %{
    source: source,
    target: target
  } do
    File.write!(Path.join(source, "config.yaml"), """
    model: anthropic:claude-test
    api_key: sk-config-not-real-42
    providers:
      openai:
        base_url: https://api.openai.test/v1
        apiKey: sk-provider-not-real-42
      custom:
        base_url: https://user:pw-url-not-real-42@api.custom.test/v1?key=qk-not-real-42
    telegram:
      bot_token: tg-not-real-42
    mcp_servers:
      github:
        command: npx
        args: ["--token", "sk-args-not-real-42"]
        env: ["OPENAI_API_KEY=sk-envlist-not-real-42"]
        headers:
          - name: Authorization
            value: Bearer sk-header-not-real-42
        url: https://api.mcp.test/sse?access=sk-query-not-real-42
    """)

    report = HermesMigration.apply(source: source, target: target)
    archive = Path.join(report["output_dir"], "archive")

    archived = File.read!(Path.join(archive, "config.yaml"))
    assert {:ok, parsed} = YamlElixir.read_from_string(archived)
    assert parsed["model"] == "anthropic:claude-test"
    assert parsed["providers"]["openai"]["base_url"] == "https://api.openai.test/v1"
    refute Map.has_key?(parsed, "mcp_servers")

    config = File.read!(Path.join(target, "config.toml"))
    assert config =~ "https://api.openai.test/v1"

    leaked =
      ~w(sk-config-not-real-42 sk-provider-not-real-42 pw-url-not-real-42 qk-not-real-42
         tg-not-real-42 sk-args-not-real-42 sk-envlist-not-real-42 sk-header-not-real-42
         sk-query-not-real-42)

    for file <- Path.wildcard(Path.join(target, "**/*"), match_dot: true),
        File.regular?(file),
        value <- leaked do
      refute File.read!(file) =~ value, "#{value} leaked into #{file}"
    end

    assert Enum.any?(
             report["items"],
             &(&1["status"] == "gated" and &1["details"]["key"] == "providers.custom.base_url")
           )

    assert Enum.any?(
             report["items"],
             &(&1["status"] == "gated" and "mcp_servers" in (&1["details"]["keys"] || []))
           )
  end

  test "cron archive keeps only schedules and skills never import credential files", %{
    source: source,
    target: target
  } do
    File.mkdir_p!(Path.join(source, "cron"))

    File.write!(
      Path.join([source, "cron", "jobs.json"]),
      Jason.encode!([
        %{
          "name" => "daily",
          "schedule" => "0 9 * * *",
          "command" => "curl -H 'Authorization: Bearer cron-not-real-42' https://x.test",
          "env" => %{"TOKEN" => "cron-env-not-real-42"}
        }
      ])
    )

    skill = Path.join([source, "skills", "demo-skill"])

    credential_like = %{
      ".env" => "skill-env-not-real-42",
      ".envrc" => "skill-envrc-not-real-42",
      "id_ed25519" => "skill-key-not-real-42",
      "service-account.json" => "skill-sa-not-real-42",
      "authentication.json" => "skill-authn-not-real-42",
      "kubeconfig" => "skill-kube-not-real-42",
      "helper.py" => "skill-root-not-real-42",
      "config/auth.json" => "skill-auth-not-real-42",
      "scripts/settings.json" => "skill-json-not-real-42",
      "scripts/.secret.py" => "skill-dot-not-real-42"
    }

    for {name, value} <- credential_like do
      File.mkdir_p!(Path.dirname(Path.join(skill, name)))
      File.write!(Path.join(skill, name), value)
    end

    File.mkdir_p!(Path.join(skill, "scripts"))
    File.write!(Path.join([skill, "scripts", "run.py"]), "print('ok')\n")
    File.mkdir_p!(Path.join(skill, "references"))
    File.write!(Path.join([skill, "references", "guide.md"]), "# Guide\n")

    report = HermesMigration.apply(source: source, target: target)
    archive = Path.join(report["output_dir"], "archive")

    refute File.exists?(Path.join(archive, "cron"))
    assert File.read!(Path.join(archive, "cron.json")) =~ "0 9 * * *"

    skill_target = Path.join([target, "agent", "skill", "demo-skill"])
    assert File.exists?(Path.join(skill_target, "SKILL.md"))
    assert File.exists?(Path.join([skill_target, "scripts", "run.py"]))
    assert File.exists?(Path.join([skill_target, "references", "guide.md"]))

    leaked = ~w(cron-not-real-42 cron-env-not-real-42) ++ Map.values(credential_like)

    for file <- Path.wildcard(Path.join(target, "**/*"), match_dot: true),
        File.regular?(file),
        value <- leaked do
      refute File.read!(file) =~ value, "#{value} leaked into #{file}"
    end

    gated =
      for %{"status" => "gated", "kind" => "skill_file", "source" => path} <- report["items"],
          do: Path.relative_to(path, skill)

    assert Enum.sort(gated) == Enum.sort(Map.keys(credential_like))
    assert Enum.any?(report["items"], &(&1["status"] == "warning" and &1["kind"] == "content"))

    File.rm_rf!(skill_target)
    report = HermesMigration.apply(source: source, target: target, include_skill_assets: true)
    assert File.read!(Path.join(skill_target, "kubeconfig")) == "skill-kube-not-real-42"

    approved =
      for %{"status" => "migrated", "kind" => "skill_file"} = i <- report["items"], do: i

    assert length(approved) == map_size(credential_like)
  end

  describe "durable secret store coverage" do
    setup ctx do
      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<7>>, 32)))
      File.write!(Path.join(ctx.source, ".env"), "DEEPGRAM_API_KEY=dg-hermes\n")
      original = Application.fetch_env!(:lemon_core, LemonCore.Store)
      original_override = Application.fetch_env(:lemon_core, :store_runtime_override)

      on_exit(fn ->
        Application.put_env(:lemon_core, LemonCore.Store, original)

        case original_override do
          {:ok, value} -> Application.put_env(:lemon_core, :store_runtime_override, value)
          :error -> Application.delete_env(:lemon_core, :store_runtime_override)
        end

        :ok = Supervisor.terminate_child(LemonCore.Supervisor, LemonCore.Store)
        {:ok, _} = Supervisor.restart_child(LemonCore.Supervisor, LemonCore.Store)
      end)

      File.mkdir_p!(ctx.target)
      %{opts: [source: ctx.source, target: ctx.target, preset: "full", migrate_secrets: true]}
    end

    test "a store outside the target, behind a symlink, or in an excluded dir is refused",
         ctx do
      external = Path.join(ctx.home, "elsewhere")
      File.mkdir_p!(external)
      File.ln_s!(external, Path.join(ctx.target, "linked"))

      for db <- [
            Path.join(external, "store.sqlite3"),
            Path.join([ctx.target, "linked", "store.sqlite3"]),
            Path.join([ctx.target, "logs", "store.sqlite3"])
          ] do
        use_sqlite_store!(db)
        report = HermesMigration.apply(ctx.opts ++ [backup: true])

        assert [secret] = Enum.filter(report["items"], &(&1["kind"] == "secret")), db
        assert secret["status"] == "gated", db
        assert {:error, _} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")
      end
    end

    test "an in-target store needs the pre-migration backup to cover it", ctx do
      use_sqlite_store!(Path.join([ctx.target, "store", "store.sqlite3"]))

      report = HermesMigration.apply(ctx.opts)
      assert [%{"status" => "gated", "reason" => reason}] = secret_items(report)
      assert reason =~ "backup"
      assert {:error, _} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")

      report = HermesMigration.apply(ctx.opts ++ [backup: true])
      assert [%{"status" => "migrated"}] = secret_items(report)
      assert {:ok, "dg-hermes"} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")

      rollback = HermesMigration.rollback(report["output_dir"])

      assert Enum.any?(
               rollback["items"],
               &(&1["status"] == "reverted" and &1["source"] == "DEEPGRAM_API_KEY")
             )

      assert {:error, _} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")
    end

    test "rollback never deletes a rotated secret or one in another store", ctx do
      store = Path.join([ctx.target, "store", "store.sqlite3"])
      use_sqlite_store!(store)
      report = HermesMigration.apply(ctx.opts ++ [backup: true])
      assert [%{"status" => "migrated"}] = secret_items(report)

      assert {:ok, _} = LemonCore.Secrets.set("DEEPGRAM_API_KEY", "dg-rotated")
      rollback = HermesMigration.rollback(report["output_dir"])

      assert Enum.any?(
               rollback["items"],
               &(&1["status"] == "manual" and &1["source"] == "DEEPGRAM_API_KEY")
             )

      assert {:ok, "dg-rotated"} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")

      use_sqlite_store!(Path.join([ctx.target, "other", "store.sqlite3"]))
      assert {:ok, _} = LemonCore.Secrets.set("DEEPGRAM_API_KEY", "dg-other-store")
      rollback = HermesMigration.rollback(report["output_dir"])

      assert Enum.any?(
               rollback["items"],
               &(&1["status"] == "error" and &1["reason"] =~ "not the one the migration wrote")
             )

      assert {:ok, "dg-other-store"} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")
    end
  end

  defp use_sqlite_store!(db) do
    Application.put_env(:lemon_core, LemonCore.Store,
      backend: LemonCore.Store.SqliteBackend,
      backend_opts: [path: db]
    )

    Application.delete_env(:lemon_core, :store_runtime_override)
    :ok = Supervisor.terminate_child(LemonCore.Supervisor, LemonCore.Store)
    {:ok, _} = Supervisor.restart_child(LemonCore.Supervisor, LemonCore.Store)
  end

  defp secret_items(report), do: Enum.filter(report["items"], &(&1["kind"] == "secret"))

  test ".env-only secret import checks the providers table reference", ctx do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<7>>, 32)))
    File.rm!(Path.join(ctx.source, "config.yaml"))
    File.write!(Path.join(ctx.source, ".env"), "OPENAI_API_KEY=sk-stale-hermes\n")
    _ = LemonCore.Secrets.delete("OPENAI_API_KEY")
    on_exit(fn -> LemonCore.Secrets.delete("OPENAI_API_KEY") end)

    File.mkdir_p!(ctx.target)
    config = Path.join(ctx.target, "config.toml")
    File.write!(config, "[providers.openai]\napi_key_secret = \"MY_OPENAI\"\n")
    opts = [source: ctx.source, target: ctx.target, preset: "full", migrate_secrets: true]

    report = HermesMigration.apply(opts)
    assert Enum.any?(report["items"], &(&1["kind"] == "secret" and &1["status"] == "conflict"))
    assert {:error, _} = LemonCore.Secrets.get("OPENAI_API_KEY")
    assert File.read!(config) == "[providers.openai]\napi_key_secret = \"MY_OPENAI\"\n"

    File.write!(config, "")
    report = HermesMigration.apply(opts)
    assert Enum.any?(report["items"], &(&1["kind"] == "secret" and &1["status"] == "migrated"))
    decoded = Toml.decode_file!(config)
    assert decoded["providers"]["openai"]["api_key_secret"] == "OPENAI_API_KEY"
    refute Map.has_key?(decoded, "openai")
  end

  test "a failed config update removes the secret the migration created", ctx do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<7>>, 32)))
    File.write!(Path.join(ctx.source, ".env"), "DEEPGRAM_API_KEY=dg-stale-hermes\n")
    _ = LemonCore.Secrets.delete("DEEPGRAM_API_KEY")
    on_exit(fn -> LemonCore.Secrets.delete("DEEPGRAM_API_KEY") end)

    # The config is readable as absent but its directory is read-only, so only
    # the write after the secret was created fails.
    readonly = Path.join(ctx.target, "readonly")
    File.mkdir_p!(readonly)
    File.chmod!(readonly, 0o500)
    on_exit(fn -> File.chmod(readonly, 0o700) end)

    report =
      HermesMigration.apply(
        source: ctx.source,
        target: ctx.target,
        config_path: Path.join(readonly, "config.toml"),
        preset: "full",
        migrate_secrets: true
      )

    assert [secret] = Enum.filter(report["items"], &(&1["kind"] == "secret"))
    assert secret["status"] == "error"
    assert {:error, _} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")
  end

  test "rollback removes created artifacts and restores modified files", ctx do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<7>>, 32)))
    File.write!(Path.join(ctx.source, ".env"), "DEEPGRAM_API_KEY=dg-hermes\n")
    _ = LemonCore.Secrets.delete("DEEPGRAM_API_KEY")
    on_exit(fn -> LemonCore.Secrets.delete("DEEPGRAM_API_KEY") end)

    soul = Path.join([ctx.target, "agent", "workspace", "SOUL.md"])
    File.mkdir_p!(Path.dirname(soul))
    File.write!(soul, "existing soul\n")
    config = Path.join(ctx.target, "config.toml")
    File.write!(config, "[defaults]\nthinking = \"low\"\n")

    report =
      HermesMigration.apply(
        source: ctx.source,
        target: ctx.target,
        overwrite: true,
        preset: "full",
        migrate_secrets: true
      )

    assert File.read!(soul) == "Hermes persona\n"
    assert File.exists?(Path.join([ctx.target, "agent", "skill", "demo-skill"]))
    assert {:ok, "dg-hermes"} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")

    rollback = HermesMigration.rollback(report["output_dir"])
    refute Enum.any?(rollback["items"], &(&1["status"] == "error"))

    assert File.read!(soul) == "existing soul\n"
    assert File.read!(config) == "[defaults]\nthinking = \"low\"\n"
    refute File.exists?(Path.join([ctx.target, "agent", "skill", "demo-skill"]))
    refute File.exists?(Path.join([ctx.target, "agent", "workspace", "MEMORY.md"]))
    assert {:error, _} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")

    # The migration created memory.sqlite3, so offline rollback removes it.
    refute File.exists?(Path.join([ctx.target, "store", "memory.sqlite3"]))
    assert rollback["complete"] == true
    refute File.read!(Path.join(report["output_dir"], "journal.jsonl")) =~ "-wal"
  end

  test "config rewrites stage content only inside a private sibling directory", ctx do
    File.mkdir_p!(ctx.target)
    config = Path.join(ctx.target, "config.toml")
    File.write!(config, "")
    File.chmod!(config, 0o644)
    parent = self()

    hook = fn dir ->
      {:ok, stat} = File.lstat(dir)
      send(parent, {:staging, dir, stat.type, Bitwise.band(stat.mode, 0o777), File.ls!(dir)})
    end

    HermesMigration.apply(source: ctx.source, target: ctx.target, before_config_write: hook)

    assert_received {:staging, dir, :directory, 0o700, []}
    assert Path.dirname(dir) == ctx.target
    refute File.exists?(dir)
    assert File.read!(config) =~ "anthropic:claude-test"
    assert {:ok, %{mode: mode}} = File.stat(config)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "rollback into a pre-existing memory database is incomplete until the bundle restore",
       ctx do
    first = HermesMigration.apply(source: ctx.source, target: ctx.target, timestamp: "first")
    assert File.exists?(Path.join([ctx.target, "store", "memory.sqlite3"]))
    File.write!(Path.join(ctx.target, "config.toml"), "")
    File.chmod!(Path.join(ctx.target, "config.toml"), 0o644)

    second =
      HermesMigration.apply(
        source: ctx.source,
        target: ctx.target,
        overwrite: true,
        timestamp: "second"
      )

    assert {:ok, %{mode: mode}} = File.stat(Path.join(ctx.target, "config.toml"))
    assert Bitwise.band(mode, 0o777) == 0o600

    rollback = HermesMigration.rollback(second["output_dir"])
    assert rollback["complete"] == false

    assert Enum.any?(
             rollback["items"],
             &(&1["status"] == "manual" and &1["reason"] =~ "backup bundle")
           )

    assert File.exists?(Path.join([ctx.target, "store", "memory.sqlite3"]))
    assert first["output_dir"] != second["output_dir"]
  end

  test "apply and rollback refuse while a runtime uses the target and hold the lock", ctx do
    run = Path.join(ctx.target, "run")
    File.mkdir_p!(run)
    File.write!(Path.join(run, "lemon-4999.pid"), "")
    probe = fn _port -> true end

    report = HermesMigration.apply(source: ctx.source, target: ctx.target, runtime_probe: probe)
    assert report["error"] =~ "runtime"
    assert report["output_dir"] == nil
    refute File.exists?(Path.join([ctx.target, "agent", "workspace", "SOUL.md"]))

    File.rm!(Path.join(run, "lemon-4999.pid"))
    parent = self()

    report =
      HermesMigration.apply(
        source: ctx.source,
        target: ctx.target,
        after_runtime_check: fn ->
          send(parent, {:locks, Path.wildcard(Path.join(run, "restore-*.lock"))})
        end
      )

    assert_received {:locks, [_lock]}
    assert File.exists?(Path.join([ctx.target, "agent", "workspace", "SOUL.md"]))
    assert Path.wildcard(Path.join(run, "restore-*.lock")) == []

    File.write!(Path.join(run, "lemon-4999.pid"), "")
    rollback = HermesMigration.rollback(report["output_dir"], runtime_probe: probe)
    assert [%{"status" => "error", "reason" => reason}] = rollback["items"]
    assert reason =~ "daemon_running"
    assert File.exists?(Path.join([ctx.target, "agent", "workspace", "SOUL.md"]))
  end

  test "legacy plaintext archives and zips produce value-free warnings and stay on disk", ctx do
    legacy = Path.join([ctx.target, "migration", "hermes", "20250101-000000", "archive"])
    File.mkdir_p!(legacy)
    File.write!(Path.join(legacy, "auth.json"), ~s({"token":"legacy-not-real-42"}))
    File.write!(Path.join(legacy, "config.yaml"), "api_key: legacy-config-not-real-42\n")
    zip = Path.join([ctx.target, "backups", "pre-hermes-migration-20250101-000000.zip"])
    File.mkdir_p!(Path.dirname(zip))
    File.write!(zip, "legacy-zip-not-real-42")

    report = HermesMigration.preview(source: ctx.source, target: ctx.target)
    warnings = Enum.filter(report["items"], &(&1["kind"] == "legacy_archive"))
    paths = Enum.map(warnings, & &1["source"])

    assert Path.join(legacy, "auth.json") in paths
    assert Path.join(legacy, "config.yaml") in paths
    assert zip in paths
    assert Enum.all?(warnings, &(&1["status"] == "warning" and &1["reason"] =~ "rotate"))

    encoded = Jason.encode!(report)
    refute encoded =~ "not-real-42"
    assert File.exists?(Path.join(legacy, "auth.json"))
    assert File.exists?(zip)

    audit = HermesMigration.audit(source: ctx.source, target: ctx.target)
    assert Enum.any?(audit["items"], &(&1["kind"] == "legacy_archive"))
  end

  test "secret import reports existing secrets as conflicts and preserves them", ctx do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<7>>, 32)))
    File.write!(Path.join(ctx.source, ".env"), "OPENAI_API_KEY=sk-stale-hermes\n")
    saved = LemonCore.Secrets.get("OPENAI_API_KEY")

    on_exit(fn ->
      case saved do
        {:ok, value} -> LemonCore.Secrets.set("OPENAI_API_KEY", value)
        _ -> LemonCore.Secrets.delete("OPENAI_API_KEY")
      end
    end)

    assert {:ok, _} = LemonCore.Secrets.set("OPENAI_API_KEY", "sk-live-lemon")
    opts = [source: ctx.source, target: ctx.target, preset: "full", migrate_secrets: true]

    preview = HermesMigration.preview(opts)
    assert HermesMigration.has_conflicts?(preview)
    assert Enum.any?(preview["items"], &(&1["kind"] == "secret" and &1["status"] == "conflict"))

    report = HermesMigration.apply(opts)
    assert Enum.any?(report["items"], &(&1["kind"] == "secret" and &1["status"] == "conflict"))
    assert {:ok, "sk-live-lemon"} = LemonCore.Secrets.get("OPENAI_API_KEY")

    report = HermesMigration.apply(Keyword.put(opts, :overwrite, true))
    assert Enum.any?(report["items"], &(&1["kind"] == "secret" and &1["status"] == "conflict"))
    assert {:ok, "sk-live-lemon"} = LemonCore.Secrets.get("OPENAI_API_KEY")
  end

  test "secret import conflicts with a different credential reference in config", ctx do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<7>>, 32)))
    File.write!(Path.join(ctx.source, ".env"), "DEEPGRAM_API_KEY=dg-stale-hermes\n")
    _ = LemonCore.Secrets.delete("DEEPGRAM_API_KEY")
    on_exit(fn -> LemonCore.Secrets.delete("DEEPGRAM_API_KEY") end)

    File.mkdir_p!(ctx.target)
    config = Path.join(ctx.target, "config.toml")
    File.write!(config, "[gateway.voice]\ndeepgram_api_key_secret = \"MY_DEEPGRAM\"\n")
    opts = [source: ctx.source, target: ctx.target, preset: "full", migrate_secrets: true]

    report = HermesMigration.apply(opts)
    assert Enum.any?(report["items"], &(&1["kind"] == "secret" and &1["status"] == "conflict"))
    assert {:error, _} = LemonCore.Secrets.get("DEEPGRAM_API_KEY")
    assert File.read!(config) =~ ~s(deepgram_api_key_secret = "MY_DEEPGRAM")
  end

  test "audits compatible and future v2 surfaces without writing target files", %{
    source: source,
    target: target
  } do
    File.write!(Path.join(source, ".env"), "OPENAI_API_KEY=sk-test\nUNKNOWN_SECRET=value\n")
    File.mkdir_p!(Path.join(source, "cron"))
    File.write!(Path.join([source, "cron", "daily.json"]), "{}")
    File.mkdir_p!(Path.join(source, "plugins"))

    File.write!(Path.join(source, "config.yaml"), """
    model: anthropic:claude-test
    providers:
      openai:
        base_url: https://api.openai.test/v1
    mcp_servers:
      demo:
        command: demo-mcp
    provider_routing:
      fallback_providers: [openai]
    """)

    report = HermesMigration.audit(source: source, target: target)

    assert report["mode"] == "audit"
    assert report["summary"]["compatible"] >= 6
    assert report["summary"]["gated"] == 1
    assert Enum.any?(report["items"], &(&1["kind"] == "mcp" and &1["status"] == "partial"))
    assert Enum.any?(report["items"], &(&1["kind"] == "cron" and &1["status"] == "partial"))

    secrets = Enum.find(report["items"], &(&1["kind"] == "secrets"))
    assert secrets["destination"] == "[redacted]"
    refute File.exists?(target)
  end

  test "audits malformed Hermes session database as an error", %{source: source, target: target} do
    db_path = Path.join(source, "state.db")
    File.rm!(db_path)
    File.write!(db_path, "not sqlite")

    report = HermesMigration.audit(source: source, target: target)

    sessions = Enum.find(report["items"], &(&1["kind"] == "sessions"))
    assert sessions["status"] == "error"
    assert report["summary"]["error"] == 1
  end

  test "ignores blank model and malformed provider config", %{source: source, target: target} do
    File.write!(Path.join(source, "config.yaml"), """
    model: "   "
    providers:
      openai:
    """)

    report = HermesMigration.preview(source: source, target: target)

    assert Enum.any?(
             report["items"],
             &(&1["kind"] == "config" and &1["status"] == "skipped")
           )
  end

  describe "Honcho configuration import" do
    test "global fixture previews supported settings and unsupported keys without writes", ctx do
      global = Path.join([ctx.home, ".honcho", "config.json"])
      File.mkdir_p!(Path.dirname(global))
      File.cp!(honcho_fixture(), global)
      before = honcho_secret_rows()

      report =
        HermesMigration.preview(
          source: ctx.source,
          target: ctx.target,
          honcho_global_path: global
        )

      entries = Enum.filter(report["items"], &(&1["kind"] == "honcho"))
      assert Enum.any?(entries, &(&1["source"] == global and &1["status"] == "planned"))

      unsupported =
        entries
        |> Enum.filter(&(&1["status"] == "unsupported"))
        |> Enum.map(& &1["details"]["key"])

      assert Enum.sort(unsupported) == ~w(dialecticDepth writeFrequency)
      assert report["summary"]["unsupported"] == 2

      assert Enum.any?(
               report["items"],
               &(&1["kind"] == "honcho_secret" and &1["status"] == "gated")
             )

      assert honcho_secret_rows() == before
      refute Jason.encode!(report) =~ "hk-fixture"
      refute File.exists?(ctx.target)
    end

    test "profile-local config replaces global config instead of merging profiles", ctx do
      global = Path.join([ctx.home, ".honcho", "config.json"])
      File.mkdir_p!(Path.dirname(global))
      File.cp!(honcho_fixture(), global)
      local = Path.join(ctx.source, "honcho.json")
      File.write!(local, Jason.encode!(%{"workspace" => "profile-only", "saveMessages" => false}))

      report =
        HermesMigration.apply(source: ctx.source, target: ctx.target, honcho_global_path: global)

      config = Toml.decode_file!(Path.join(ctx.target, "config.toml"))["honcho"]
      assert config["workspace"] == "profile-only"
      assert config["save_messages"] == false
      refute Map.has_key?(config, "base_url")
      refute Map.has_key?(config, "recall_mode")
      refute Enum.any?(report["items"], &(&1["kind"] == "honcho_secret"))
    end

    test "maps fixture values and imports the API key only through encrypted secrets", ctx do
      File.cp!(honcho_fixture(), Path.join(ctx.source, "honcho.json"))
      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<7>>, 32)))

      opts = [source: ctx.source, target: ctx.target, preset: "full", migrate_secrets: true]
      before = honcho_secret_rows()
      preview = HermesMigration.preview(opts)

      assert Enum.any?(
               preview["items"],
               &(&1["kind"] == "honcho_secret" and &1["status"] == "planned")
             )

      assert honcho_secret_rows() == before
      refute File.exists?(ctx.target)

      report = HermesMigration.apply(opts)

      assert Enum.any?(
               report["items"],
               &(&1["kind"] == "honcho_secret" and &1["status"] == "migrated")
             )

      assert {:ok, "hk-fixture-not-a-real-key"} = LemonCore.Secrets.get("HONCHO_API_KEY")

      raw = File.read!(Path.join(ctx.target, "config.toml"))
      config = Toml.decode!(raw)["honcho"]

      assert config == %{
               "api_key_secret" => "HONCHO_API_KEY",
               "base_url" => "http://honcho.test:8000",
               "environment" => "local",
               "workspace" => "hermes-workspace",
               "user_peer" => "alice",
               "pin_user_peer" => true,
               "user_peer_aliases" => %{"123" => "alice"},
               "ai_peer" => "hermes-assistant",
               "recall_mode" => "tools",
               "session_strategy" => "per-session",
               "context_tokens" => 1200,
               "context_cadence" => 3,
               "dialectic_cadence" => 5,
               "reasoning_level" => "medium",
               "dialectic_max_chars" => 900,
               "message_max_chars" => 16_000,
               "save_messages" => false,
               "observation_mode" => "unified",
               "timeout_ms" => 1500
             }

      refute raw =~ "hk-fixture"
      refute inspect(honcho_secret_rows()) =~ "hk-fixture"
      refute Jason.encode!(report) =~ "hk-fixture"
      refute File.read!(Path.join(report["output_dir"], "report.json")) =~ "hk-fixture"
      refute File.exists?(Path.join(report["output_dir"], "archive/honcho.json"))
    end

    test "missing secrets master key reports an error without a plaintext fallback", ctx do
      File.cp!(honcho_fixture(), Path.join(ctx.source, "honcho.json"))

      report =
        HermesMigration.apply(
          source: ctx.source,
          target: ctx.target,
          preset: "full",
          migrate_secrets: true
        )

      assert Enum.any?(
               report["items"],
               &(&1["kind"] == "honcho_secret" and &1["status"] == "error")
             )

      raw = File.read!(Path.join(ctx.target, "config.toml"))
      refute Map.has_key?(Toml.decode!(raw)["honcho"], "api_key_secret")
      refute Map.has_key?(Toml.decode!(raw)["honcho"], "api_key")
      refute raw =~ "hk-fixture"
      assert Toml.decode!(raw)["honcho"]["workspace"] == "hermes-workspace"
    end

    test "selected host overrides root values and never imports other hosts", ctx do
      File.write!(
        Path.join(ctx.source, "honcho.json"),
        Jason.encode!(%{
          "apiKey" => "root-key",
          "workspace" => "root-workspace",
          "defaultHost" => "hermes_work",
          "hosts" => %{
            "hermes_work" => %{
              "apiKey" => "host-key",
              "workspace" => "host-workspace",
              "saveMessages" => false
            },
            "hermes_other" => %{"apiKey" => "other-key", "workspace" => "other-workspace"}
          }
        })
      )

      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<8>>, 32)))

      report =
        HermesMigration.apply(
          source: ctx.source,
          target: ctx.target,
          preset: "full",
          migrate_secrets: true
        )

      config = Toml.decode_file!(Path.join(ctx.target, "config.toml"))["honcho"]
      assert config["workspace"] == "host-workspace"
      assert config["ai_peer"] == "hermes_work"
      assert config["save_messages"] == false
      assert {:ok, "host-key"} = LemonCore.Secrets.get("HONCHO_API_KEY")

      assert Enum.any?(
               report["items"],
               &(&1["status"] == "unsupported" and
                   &1["details"]["key"] == "hosts.hermes_other")
             )

      refute Jason.encode!(report) =~ "other-key"
    end

    test "pending Honcho secret is written even when config bytes are unchanged", ctx do
      File.cp!(honcho_fixture(), Path.join(ctx.source, "honcho.json"))
      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<9>>, 32)))
      _ = LemonCore.Secrets.delete("HONCHO_API_KEY")

      HermesMigration.apply(source: ctx.source, target: ctx.target, timestamp: "settings")
      config_path = Path.join(ctx.target, "config.toml")

      File.write!(
        config_path,
        LemonCore.Config.TomlPatch.upsert_string(
          File.read!(config_path),
          "honcho",
          "api_key_secret",
          "HONCHO_API_KEY"
        )
      )

      before = File.read!(config_path)

      report =
        HermesMigration.apply(
          source: ctx.source,
          target: ctx.target,
          preset: "full",
          migrate_secrets: true,
          overwrite: true,
          timestamp: "secret"
        )

      assert File.read!(config_path) == before

      assert [%{"status" => "migrated"}] =
               Enum.filter(report["items"], &(&1["kind"] == "honcho_secret"))

      assert {:ok, "hk-fixture-not-a-real-key"} = LemonCore.Secrets.get("HONCHO_API_KEY")
    end

    test "config and secret conflicts require overwrite and preserve target values", ctx do
      File.cp!(honcho_fixture(), Path.join(ctx.source, "honcho.json"))
      File.mkdir_p!(ctx.target)
      config_path = Path.join(ctx.target, "config.toml")
      File.write!(config_path, "[honcho]\nworkspace = \"existing\"\n")
      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<9>>, 32)))
      assert {:ok, _} = LemonCore.Secrets.set("HONCHO_API_KEY", "existing-key")
      opts = [source: ctx.source, target: ctx.target, preset: "full", migrate_secrets: true]

      report = HermesMigration.preview(opts)
      assert HermesMigration.has_conflicts?(report)

      assert Enum.any?(
               report["items"],
               &(&1["kind"] == "honcho_secret" and &1["status"] == "conflict")
             )

      HermesMigration.apply(opts)
      assert Toml.decode_file!(config_path)["honcho"]["workspace"] == "existing"
      assert {:ok, "existing-key"} = LemonCore.Secrets.get("HONCHO_API_KEY")

      report = HermesMigration.apply(Keyword.merge(opts, overwrite: true))
      assert Toml.decode_file!(config_path)["honcho"]["workspace"] == "hermes-workspace"
      assert File.exists?(Path.join(report["output_dir"], "backups/config.toml"))

      # Existing secrets are never replaced, even with --overwrite.
      assert Enum.any?(
               report["items"],
               &(&1["kind"] == "honcho_secret" and &1["status"] == "conflict")
             )

      assert {:ok, "existing-key"} = LemonCore.Secrets.get("HONCHO_API_KEY")
    end

    test "malformed profile config is reported without falling back to the global profile", ctx do
      global = Path.join([ctx.home, ".honcho", "config.json"])
      File.mkdir_p!(Path.dirname(global))
      File.cp!(honcho_fixture(), global)
      File.write!(Path.join(ctx.source, "honcho.json"), ~s({"apiKey":"do-not-print"))

      report =
        HermesMigration.preview(
          source: ctx.source,
          target: ctx.target,
          honcho_global_path: global
        )

      assert Enum.any?(report["items"], &(&1["kind"] == "honcho" and &1["status"] == "error"))
      refute Jason.encode!(report) =~ "do-not-print"
      refute File.exists?(ctx.target)
    end

    test "audit includes supported, gated and unsupported Honcho settings", ctx do
      File.cp!(honcho_fixture(), Path.join(ctx.source, "honcho.json"))
      report = HermesMigration.audit(source: ctx.source, target: ctx.target)

      assert Enum.any?(
               report["items"],
               &(&1["kind"] == "honcho" and &1["status"] == "compatible")
             )

      assert Enum.any?(
               report["items"],
               &(&1["kind"] == "honcho_secret" and &1["status"] == "gated")
             )

      assert report["summary"]["unsupported"] == 2
      refute File.exists?(ctx.target)
    end

    test "imports gateway identities with quoted runtime IDs without exposing alias values",
         ctx do
      aliases = %{"telegram:123" => "alice", "discord.\"456\n" => "bob"}

      File.write!(
        Path.join(ctx.source, "honcho.json"),
        Jason.encode!(%{
          "pinUserPeer" => false,
          "userPeerAliases" => aliases,
          "runtimePeerPrefix" => "telegram_\"line\nprefix"
        })
      )

      preview = HermesMigration.preview(source: ctx.source, target: ctx.target)
      assert preview["summary"]["unsupported"] == 0
      refute File.exists?(ctx.target)
      refute Jason.encode!(preview) =~ "telegram:123"

      HermesMigration.apply(source: ctx.source, target: ctx.target)
      config = Toml.decode_file!(Path.join(ctx.target, "config.toml"))["honcho"]
      assert config["pin_user_peer"] == false
      assert config["user_peer_aliases"] == aliases
      assert config["runtime_peer_prefix"] == "telegram_\"line\nprefix"
    end

    test "canonical pin key wins within a scope and host legacy pin overrides the root", ctx do
      source = Path.join(ctx.source, "honcho.json")

      File.write!(
        source,
        Jason.encode!(%{
          "pinUserPeer" => true,
          "pinPeerName" => false,
          "hosts" => %{"hermes" => %{"pinPeerName" => false}}
        })
      )

      HermesMigration.apply(source: ctx.source, target: ctx.target)
      path = Path.join(ctx.target, "config.toml")
      assert Toml.decode_file!(path)["honcho"]["pin_user_peer"] == false

      File.write!(source, Jason.encode!(%{"pinUserPeer" => true, "pinPeerName" => false}))
      HermesMigration.apply(source: ctx.source, target: ctx.target, overwrite: true)
      assert Toml.decode_file!(path)["honcho"]["pin_user_peer"] == true
      refute File.read!(path) =~ "pinPeerName"
    end

    test "gateway setting conflicts preserve target aliases until overwrite", ctx do
      File.write!(
        Path.join(ctx.source, "honcho.json"),
        Jason.encode!(%{
          "pinUserPeer" => true,
          "userPeerAliases" => %{"new-runtime-id" => "alice"},
          "runtimePeerPrefix" => "telegram_"
        })
      )

      File.mkdir_p!(ctx.target)
      path = Path.join(ctx.target, "config.toml")

      File.write!(path, """
      [honcho]
      pin_user_peer = false
      runtime_peer_prefix = "old_"
      [honcho.user_peer_aliases]
      old_runtime_id = "bob"
      """)

      opts = [source: ctx.source, target: ctx.target]
      preview = HermesMigration.preview(opts)
      assert HermesMigration.has_conflicts?(preview)
      HermesMigration.apply(opts)
      existing = Toml.decode_file!(path)["honcho"]
      assert existing["user_peer_aliases"] == %{"old_runtime_id" => "bob"}
      assert existing["pin_user_peer"] == false

      HermesMigration.apply(Keyword.put(opts, :overwrite, true))
      config = Toml.decode_file!(path)["honcho"]
      assert config["user_peer_aliases"] == %{"new-runtime-id" => "alice"}
      assert config["pin_user_peer"] == true
      assert config["runtime_peer_prefix"] == "telegram_"
    end

    test "invalid aliases are unsupported and empty maps can explicitly clear aliases", ctx do
      source = Path.join(ctx.source, "honcho.json")
      File.write!(source, Jason.encode!(%{"userPeerAliases" => %{"123" => "not a peer"}}))
      preview = HermesMigration.preview(source: ctx.source, target: ctx.target)

      assert Enum.any?(
               preview["items"],
               &(&1["status"] == "unsupported" and
                   &1["details"]["key"] == "userPeerAliases")
             )

      File.write!(source, Jason.encode!(%{"userPeerAliases" => %{}, "runtimePeerPrefix" => ""}))
      HermesMigration.apply(source: ctx.source, target: ctx.target)
      config = Toml.decode_file!(Path.join(ctx.target, "config.toml"))["honcho"]
      assert config["user_peer_aliases"] == %{}
      assert config["runtime_peer_prefix"] == ""
    end

    test "source home and explicit host selection preserve profile identity and aliases", ctx do
      original = System.get_env("HERMES_HOME")
      System.put_env("HERMES_HOME", ctx.source)

      on_exit(fn ->
        if original,
          do: System.put_env("HERMES_HOME", original),
          else: System.delete_env("HERMES_HOME")
      end)

      File.write!(Path.join(ctx.source, ".env"), "HERMES_HONCHO_HOST=hermes_work\n")

      File.write!(
        Path.join(ctx.source, "honcho.json"),
        Jason.encode!(%{
          "baseUrl" => "http://root.test",
          "timeout" => 20,
          "defaultHost" => "hermes",
          "contextTokens" => nil,
          "contextCadence" => -2,
          "hosts" => %{
            "hermes_work" => %{"base_url" => "http://profile.test", "requestTimeout" => 0.25}
          }
        })
      )

      report = HermesMigration.apply(target: ctx.target)
      assert report["source"] == ctx.source
      config = Toml.decode_file!(Path.join(ctx.target, "config.toml"))["honcho"]
      assert config["base_url"] == "http://profile.test"
      assert config["timeout_ms"] == 250
      assert config["workspace"] == "hermes_work"
      assert config["ai_peer"] == "hermes_work"
      refute Map.has_key?(config, "context_tokens")
      refute Map.has_key?(config, "context_cadence")

      assert Enum.any?(
               report["items"],
               &(&1["status"] == "unsupported" and
                   &1["details"]["key"] == "contextCadence")
             )
    end
  end

  defp honcho_fixture, do: Path.expand("../fixtures/hermes/honcho.json", __DIR__)

  defp honcho_secret_rows do
    LemonCore.Store.list(LemonCore.Secrets.table())
    |> Enum.filter(fn {{_owner, name}, _value} -> name == "HONCHO_API_KEY" end)
  end

  defp create_state_db(path) do
    {:ok, conn} = Sqlite3.open(path)

    try do
      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT,
          user_id TEXT,
          model TEXT,
          started_at REAL,
          title TEXT
        );
        """)

      :ok =
        Sqlite3.execute(conn, """
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT,
          role TEXT,
          content TEXT,
          timestamp REAL,
          tool_name TEXT
        );
        """)

      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO sessions (id, source, user_id, model, started_at, title) VALUES ('s1', 'cli', 'user1', 'anthropic:claude-test', 1000.0, 'Auth fix')"
        )

      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO messages (session_id, role, content, timestamp, tool_name) VALUES ('s1', 'user', 'Please fix auth', 1000.0, NULL)"
        )

      :ok =
        Sqlite3.execute(
          conn,
          "INSERT INTO messages (session_id, role, content, timestamp, tool_name) VALUES ('s1', 'assistant', 'Fixed auth', 1001.0, 'terminal')"
        )
    after
      Sqlite3.close(conn)
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
