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

  test "creates a restorable pre-migration backup outside the backup payload", %{target: target} do
    File.mkdir_p!(Path.join([target, "agent", "workspace"]))
    File.write!(Path.join([target, "agent", "workspace", "MEMORY.md"]), "existing memory\n")

    assert {:ok, archive} = HermesMigration.create_backup(target)
    assert File.exists?(archive)

    {:ok, files} = :zip.list_dir(String.to_charlist(archive))
    names = files |> Enum.map(&zip_entry_name/1) |> Enum.reject(&is_nil/1)

    assert "agent/workspace/MEMORY.md" in names
    refute Enum.any?(names, &String.starts_with?(&1, "backups/"))
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

      assert Enum.sort(unsupported) ==
               ~w(dialecticDepth pinUserPeer userPeerAliases writeFrequency)

      assert report["summary"]["unsupported"] == 4

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
               "ai_peer" => "hermes-assistant",
               "recall_mode" => "tools",
               "session_strategy" => "per-session",
               "context_tokens" => 1200,
               "context_cadence" => 3,
               "dialectic_cadence" => 5,
               "reasoning_level" => "medium",
               "dialectic_max_chars" => 900,
               "message_max_chars" => 16000,
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
      assert {:ok, "hk-fixture-not-a-real-key"} = LemonCore.Secrets.get("HONCHO_API_KEY")
      assert File.exists?(Path.join(report["output_dir"], "backups/config.toml"))
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

      assert report["summary"]["unsupported"] == 4
      refute File.exists?(ctx.target)
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

  defp zip_entry_name({:zip_file, name, _info, _comment, _offset, _comp_size}),
    do: to_string(name)

  defp zip_entry_name({:zip_comment, _comment}), do: nil
end
