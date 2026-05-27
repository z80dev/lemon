defmodule LemonCore.HermesMigrationTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias LemonCore.{HermesMigration, MemoryStore}

  setup do
    Application.ensure_all_started(:yaml_elixir)
    Application.ensure_all_started(:lemon_core)

    root =
      Path.join(System.tmp_dir!(), "hermes_migration_test_#{System.unique_integer([:positive])}")

    source = Path.join(root, "hermes")
    target = Path.join(root, "lemon")

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

    %{source: source, target: target}
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
        {MemoryStore,
         [
           name: :"hermes_migration_assert_#{System.unique_integer([:positive])}",
           path: Path.join(target, "store")
         ]}
      )

    assert eventually(fn ->
             MemoryStore.get_by_session(store, "hermes:s1", limit: 5)
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

  defp eventually(fun, attempts \\ 20)

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
