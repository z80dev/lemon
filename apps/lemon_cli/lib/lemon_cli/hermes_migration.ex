defmodule LemonCli.HermesMigration do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias LemonCore.Config.TomlPatch
  alias LemonCore.{MemoryDocument, MemoryStore, Secrets}

  @entry_delimiter "\n§\n"
  @memory_limit 2_200
  @user_limit 1_375
  @secret_names %{
    "ANTHROPIC_API_KEY" => {"anthropic", "api_key_secret"},
    "OPENAI_API_KEY" => {"openai", "api_key_secret"},
    "OPENAI_CODEX_API_KEY" => {"openai-codex", "api_key_secret"},
    "OPENCODE_API_KEY" => {"opencode", "api_key_secret"},
    "ZAI_API_KEY" => {"zai", "api_key_secret"},
    "MINIMAX_API_KEY" => {"minimax", "api_key_secret"},
    "TELEGRAM_BOT_TOKEN" => {"gateway.telegram", "bot_token_secret"},
    "DISCORD_BOT_TOKEN" => {"gateway.discord", "bot_token_secret"},
    "ELEVENLABS_API_KEY" => {"gateway.voice", "elevenlabs_api_key_secret"},
    "DEEPGRAM_API_KEY" => {"gateway.voice", "deepgram_api_key_secret"}
  }

  @user_data_sections MapSet.new([
                        :soul,
                        :memory,
                        :user_profile,
                        :skills,
                        :config,
                        :sessions,
                        :archive
                      ])

  @full_sections MapSet.union(@user_data_sections, MapSet.new([:secrets]))

  def preview(opts \\ []) do
    run(Keyword.put(opts, :execute, false))
  end

  def apply(opts \\ []) do
    run(Keyword.put(opts, :execute, true))
  end

  def audit(opts \\ []) do
    source_root = path(opts[:source] || Path.join(System.user_home!(), ".hermes"))
    target_root = path(opts[:target] || Path.join(System.user_home!(), ".lemon"))
    config_path = Path.join(source_root, "config.yaml")
    config = read_config(config_path)

    items = [
      audit_file(
        "soul",
        Path.join(source_root, "SOUL.md"),
        "Imports into Lemon assistant workspace"
      ),
      audit_file(
        "memory",
        Path.join([source_root, "memories", "MEMORY.md"]),
        "Imports into compact MEMORY.md with overflow topic file"
      ),
      audit_file(
        "user_profile",
        Path.join([source_root, "memories", "USER.md"]),
        "Imports into compact USER.md with overflow topic file"
      ),
      audit_skills(source_root),
      audit_config(config_path, config),
      audit_secrets(source_root),
      audit_sessions(Path.join(source_root, "state.db")),
      audit_config_surface(
        "mcp",
        config_path,
        config,
        ["mcp", "mcp_servers", "mcpServers"],
        "Hermes MCP config detected; v2 mapper should translate compatible sources"
      ),
      audit_path_or_config_surface(
        "cron",
        Path.join(source_root, "cron"),
        config_path,
        config,
        ["cron", "jobs", "scheduled_jobs", "scheduledJobs"],
        "Hermes cron data detected; v2 mapper should import disabled drafts"
      ),
      audit_config_surface(
        "provider_routing",
        config_path,
        config,
        ["provider_routing", "providerRouting", "fallback_providers", "credential_pools"],
        "Provider routing or credential pool config detected; v2 mapper should translate compatible routing"
      ),
      audit_path_or_config_surface(
        "channel_bindings",
        Path.join(source_root, "auth.json"),
        config_path,
        config,
        ["telegram", "discord", "gateway", "bindings"],
        "Messaging auth or binding data detected; manual review required before import"
      ),
      audit_path_surface(
        "plugins",
        [Path.join(source_root, "plugins"), Path.join(source_root, "extensions")],
        "Hermes plugin or extension state detected; plugin/provider migration is not implemented yet"
      ),
      audit_path_surface(
        "checkpoints",
        [Path.join(source_root, "checkpoints")],
        "Hermes checkpoint state detected; exact rollback replay is not implemented yet"
      ),
      audit_path_surface(
        "browser_state",
        [Path.join(source_root, "browser"), Path.join(source_root, "browser_state")],
        "Hermes browser state detected; browser-session replay is not implemented yet"
      )
    ]

    %{
      "source" => source_root,
      "target" => target_root,
      "execute" => false,
      "mode" => "audit",
      "summary" => audit_summary(items),
      "items" => Enum.map(items, &redact_item/1)
    }
  end

  def run(opts) do
    source_root = path(opts[:source] || Path.join(System.user_home!(), ".hermes"))
    target_root = path(opts[:target] || Path.join(System.user_home!(), ".lemon"))
    execute? = Keyword.get(opts, :execute, false)
    overwrite? = Keyword.get(opts, :overwrite, false)
    migrate_secrets? = Keyword.get(opts, :migrate_secrets, false)
    skill_conflict = Keyword.get(opts, :skill_conflict, "skip")
    sections = sections(Keyword.get(opts, :preset, "user-data"), migrate_secrets?)
    timestamp = Keyword.get(opts, :timestamp, timestamp())
    report_dir = Path.join([target_root, "migration", "hermes", timestamp])

    ctx = %{
      source_root: source_root,
      target_root: target_root,
      workspace_dir:
        Keyword.get(opts, :workspace_dir) || Path.join([target_root, "agent", "workspace"]),
      skill_dir: Path.join([target_root, "agent", "skill"]),
      store_dir: Path.join(target_root, "store"),
      report_dir: report_dir,
      backup_dir: Path.join(report_dir, "backups"),
      archive_dir: Path.join(report_dir, "archive"),
      execute?: execute?,
      overwrite?: overwrite?,
      migrate_secrets?: migrate_secrets?,
      skill_conflict: skill_conflict,
      sections: sections
    }

    items =
      []
      |> maybe_add(ctx, :soul, &migrate_soul/1)
      |> maybe_add(ctx, :memory, &migrate_memory/1)
      |> maybe_add(ctx, :user_profile, &migrate_user_profile/1)
      |> maybe_add(ctx, :skills, &migrate_skills/1)
      |> maybe_add(ctx, :config, &migrate_config/1)
      |> maybe_add(ctx, :secrets, &migrate_secrets/1)
      |> maybe_add(ctx, :sessions, &migrate_sessions/1)
      |> maybe_add(ctx, :archive, &archive_unmapped/1)
      |> List.flatten()

    report = %{
      "source" => source_root,
      "target" => target_root,
      "execute" => execute?,
      "preset" => Keyword.get(opts, :preset, "user-data"),
      "migrate_secrets" => migrate_secrets?,
      "skill_conflict" => skill_conflict,
      "output_dir" => if(execute?, do: report_dir, else: nil),
      "summary" => summarize(items),
      "items" => Enum.map(items, &redact_item/1)
    }

    if execute? do
      File.mkdir_p!(report_dir)
      File.write!(Path.join(report_dir, "report.json"), Jason.encode!(report, pretty: true))
      File.write!(Path.join(report_dir, "summary.md"), summary_markdown(report))
    end

    report
  end

  def has_conflicts?(%{"summary" => %{"conflict" => count}}), do: count > 0

  def has_conflicts?(_), do: false

  def create_backup(target_root) do
    target_root = path(target_root)

    if File.dir?(target_root) do
      backup_dir = Path.join(target_root, "backups")
      File.mkdir_p!(backup_dir)
      archive = Path.join(backup_dir, "pre-hermes-migration-#{timestamp()}.zip")

      entries =
        target_root
        |> recursive_files()
        |> Enum.reject(&String.starts_with?(&1, backup_dir <> "/"))
        |> Enum.map(fn file -> file |> Path.relative_to(target_root) |> String.to_charlist() end)

      case :zip.create(String.to_charlist(archive), entries, cwd: String.to_charlist(target_root)) do
        {:ok, _} -> {:ok, archive}
        {:error, reason} -> {:error, reason}
      end
    else
      :none
    end
  end

  defp maybe_add(items, ctx, section, fun) do
    if MapSet.member?(ctx.sections, section), do: [fun.(ctx) | items], else: items
  end

  defp sections("full", true), do: @full_sections
  defp sections("full", false), do: @user_data_sections
  defp sections("user-data", _), do: @user_data_sections
  defp sections(_, _), do: @user_data_sections

  defp migrate_soul(ctx) do
    copy_file_item(
      ctx,
      "soul",
      Path.join(ctx.source_root, "SOUL.md"),
      Path.join(ctx.workspace_dir, "SOUL.md")
    )
  end

  defp migrate_memory(ctx) do
    merge_memory_file(
      ctx,
      "memory",
      Path.join([ctx.source_root, "memories", "MEMORY.md"]),
      "MEMORY.md",
      @memory_limit
    )
  end

  defp migrate_user_profile(ctx) do
    merge_memory_file(
      ctx,
      "user_profile",
      Path.join([ctx.source_root, "memories", "USER.md"]),
      "USER.md",
      @user_limit
    )
  end

  defp migrate_skills(ctx) do
    source = Path.join(ctx.source_root, "skills")

    if File.dir?(source) do
      source
      |> File.ls!()
      |> Enum.map(&Path.join(source, &1))
      |> Enum.filter(&(File.dir?(&1) and File.exists?(Path.join(&1, "SKILL.md"))))
      |> Enum.map(&copy_skill(ctx, &1))
    else
      [item("skills", source, nil, "skipped", "Hermes skills directory not found")]
    end
  end

  defp migrate_config(ctx) do
    source = Path.join(ctx.source_root, "config.yaml")

    if File.exists?(source) do
      case YamlElixir.read_from_file(source) do
        {:ok, config} ->
          target = Path.join(ctx.target_root, "config.toml")
          patch_config_item(ctx, source, target, config || %{})
        {:error, reason} ->
          item(
            "config",
            source,
            nil,
            "skipped",
            "Could not parse Hermes config.yaml: #{inspect(reason)}"
          )
      end
    else
      item("config", source, nil, "skipped", "Hermes config.yaml not found")
    end
  end

  defp migrate_secrets(ctx) do
    env_path = Path.join(ctx.source_root, ".env")
    env = parse_env(env_path)

    if env == %{} do
      [item("secrets", env_path, nil, "skipped", "No allowlisted Hermes secrets found")]
    else
      env
      |> Enum.filter(fn {name, value} ->
        Map.has_key?(@secret_names, name) and String.trim(value) != ""
      end)
      |> Enum.map(fn {name, value} -> import_secret(ctx, name, value) end)
      |> case do
        [] -> [item("secrets", env_path, nil, "skipped", "No allowlisted Hermes secrets found")]
        items -> items
      end
    end
  end

  defp migrate_sessions(ctx) do
    db_path = Path.join(ctx.source_root, "state.db")

    cond do
      not File.exists?(db_path) ->
        [item("sessions", db_path, nil, "skipped", "Hermes state.db not found")]

      not ctx.execute? ->
        case count_sessions(db_path) do
          {:ok, count} ->
            [
              item(
                "sessions",
                db_path,
                Path.join(ctx.store_dir, "memory.sqlite3"),
                "planned",
                "#{count} Hermes sessions would be imported as Lemon memory documents"
              )
            ]

          {:error, reason} ->
            [
              item(
                "sessions",
                db_path,
                Path.join(ctx.store_dir, "memory.sqlite3"),
                "error",
                "Could not inspect Hermes state.db: #{inspect(reason)}"
              )
            ]
        end

      true ->
        import_session_documents(ctx, db_path)
    end
  end

  defp archive_unmapped(ctx) do
    candidates = [
      {"config.yaml", Path.join(ctx.source_root, "config.yaml")},
      {"auth.json", Path.join(ctx.source_root, "auth.json")},
      {"cron", Path.join(ctx.source_root, "cron")}
    ]

    candidates
    |> Enum.filter(fn {_name, path} -> File.exists?(path) end)
    |> Enum.map(fn {name, source} ->
      dest = Path.join(ctx.archive_dir, name)

      if ctx.execute? do
        copy_path!(source, dest, overwrite: true)
      end

      item(
        "archive",
        source,
        dest,
        if(ctx.execute?, do: "archived", else: "planned"),
        "Archived for manual review"
      )
    end)
    |> case do
      [] -> [item("archive", ctx.source_root, nil, "skipped", "No unmapped Hermes files found")]
      items -> items
    end
  end

  defp audit_file(kind, source, reason) do
    if File.exists?(source) do
      item(kind, source, nil, "compatible", reason, %{"exists" => true})
    else
      item(kind, source, nil, "missing", "Hermes #{kind} source not found")
    end
  end

  defp audit_skills(source_root) do
    source = Path.join(source_root, "skills")

    cond do
      not File.dir?(source) ->
        item("skills", source, nil, "missing", "Hermes skills directory not found")

      true ->
        count =
          source
          |> File.ls!()
          |> Enum.count(fn name -> File.exists?(Path.join([source, name, "SKILL.md"])) end)

        item("skills", source, nil, "compatible", "Imports direct-child Hermes skills", %{
          "skill_count" => count
        })
    end
  end

  defp audit_config(config_path, {:ok, config}) when is_map(config) do
    providers = Map.get(config, "providers", %{})

    compatible =
      []
      |> maybe_list("model", normalize_string(config["model"]))
      |> maybe_list("providers", is_map(providers) and map_size(providers) > 0)

    status = if compatible == [], do: "partial", else: "compatible"

    reason =
      if compatible == [],
        do: "No known compatible config keys found",
        else: "Compatible config keys can be mapped into Lemon TOML"

    item("config", config_path, nil, status, reason, %{"compatible_keys" => compatible})
  end

  defp audit_config(config_path, {:error, reason}) do
    item(
      "config",
      config_path,
      nil,
      "error",
      "Could not parse Hermes config.yaml: #{inspect(reason)}"
    )
  end

  defp audit_config(config_path, :missing) do
    item("config", config_path, nil, "missing", "Hermes config.yaml not found")
  end

  defp audit_secrets(source_root) do
    env_path = Path.join(source_root, ".env")
    env = parse_env(env_path)

    allowlisted_count =
      Enum.count(env, fn {name, value} ->
        Map.has_key?(@secret_names, name) and String.trim(value) != ""
      end)

    cond do
      env == %{} ->
        item("secrets", env_path, nil, "missing", "No Hermes .env secrets found", %{}, true)

      allowlisted_count > 0 ->
        item(
          "secrets",
          env_path,
          nil,
          "gated",
          "Allowlisted secrets can be imported only with --migrate-secrets",
          %{"allowlisted_count" => allowlisted_count, "total_env_keys" => map_size(env)},
          true
        )

      true ->
        item(
          "secrets",
          env_path,
          nil,
          "unsupported",
          "Hermes .env exists, but no allowlisted Lemon secret names were found",
          %{"total_env_keys" => map_size(env)},
          true
        )
    end
  end

  defp audit_sessions(db_path) do
    cond do
      not File.exists?(db_path) ->
        item("sessions", db_path, nil, "missing", "Hermes state.db not found")

      true ->
        case count_sessions(db_path) do
          {:ok, count} ->
            item(
              "sessions",
              db_path,
              nil,
              "compatible",
              "Imports Hermes sessions as Lemon memory documents",
              %{"session_count" => count}
            )

          {:error, reason} ->
            item(
              "sessions",
              db_path,
              nil,
              "error",
              "Could not inspect Hermes state.db: #{inspect(reason)}"
            )
        end
    end
  end

  defp audit_config_surface(kind, config_path, {:ok, config}, keys, reason) when is_map(config) do
    if has_any_key?(config, keys) do
      item(kind, config_path, nil, "partial", reason, %{
        "detected_keys" => present_keys(config, keys)
      })
    else
      item(kind, config_path, nil, "missing", "No Hermes #{kind} config detected")
    end
  end

  defp audit_config_surface(kind, config_path, :missing, _keys, _reason) do
    item(kind, config_path, nil, "missing", "No Hermes #{kind} config detected")
  end

  defp audit_config_surface(kind, config_path, {:error, reason}, _keys, _surface_reason) do
    item(
      kind,
      config_path,
      nil,
      "error",
      "Could not audit Hermes #{kind} config: #{inspect(reason)}"
    )
  end

  defp audit_path_or_config_surface(kind, path, config_path, config, keys, reason) do
    cond do
      File.exists?(path) ->
        item(kind, path, nil, "partial", reason, %{"detected_path" => Path.basename(path)})

      true ->
        audit_config_surface(kind, config_path, config, keys, reason)
    end
  end

  defp audit_path_surface(kind, paths, reason) do
    case Enum.find(paths, &File.exists?/1) do
      nil ->
        item(kind, List.first(paths), nil, "missing", "No Hermes #{kind} data detected")

      path ->
        item(kind, path, nil, "unsupported", reason, %{"detected_path" => Path.basename(path)})
    end
  end

  defp copy_file_item(ctx, kind, source, dest) do
    cond do
      not File.exists?(source) ->
        item(kind, source, dest, "skipped", "Source file not found")

      File.exists?(dest) and not ctx.overwrite? and same_file?(source, dest) ->
        item(kind, source, dest, "skipped", "Target already matches source")

      File.exists?(dest) and not ctx.overwrite? ->
        item(kind, source, dest, "conflict", "Target exists and overwrite is disabled")

      true ->
        if ctx.execute? do
          backup_existing(ctx, dest)
          File.mkdir_p!(Path.dirname(dest))
          File.cp!(source, dest)
        end

        item(kind, source, dest, if(ctx.execute?, do: "migrated", else: "planned"), "Direct copy")
    end
  end

  defp merge_memory_file(ctx, kind, source, filename, limit) do
    target = Path.join(ctx.workspace_dir, filename)

    if File.exists?(source) do
      incoming = source |> File.read!() |> parse_entries()
      existing = if File.exists?(target), do: target |> File.read!() |> parse_entries(), else: []
      {merged, details, overflow} = merge_entries(existing, incoming, limit)

      if ctx.execute? do
        backup_existing(ctx, target)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, Enum.join(merged, @entry_delimiter))

        if overflow != [] do
          overflow_path = overflow_path(ctx, kind)
          File.mkdir_p!(Path.dirname(overflow_path))
          File.write!(overflow_path, Enum.join(overflow, "\n\n"))
        end
      end

      item(
        kind,
        source,
        target,
        if(ctx.execute?, do: "migrated", else: "planned"),
        "Merged compact memory entries",
        Map.put(
          details,
          "overflow_file",
          if(overflow == [], do: nil, else: overflow_path(ctx, kind))
        )
      )
    else
      item(kind, source, target, "skipped", "Source file not found")
    end
  end

  defp copy_skill(ctx, source) do
    base = Path.basename(source)
    target = Path.join(ctx.skill_dir, base)

    cond do
      File.exists?(target) and ctx.skill_conflict == "skip" ->
        item(
          "skill",
          source,
          target,
          "conflict",
          "Skill target exists and skill conflict mode is skip"
        )

      File.exists?(target) and ctx.skill_conflict == "rename" ->
        renamed = unique_path(Path.join(ctx.skill_dir, "#{base}-hermes-import"))

        if ctx.execute? do
          copy_path!(source, renamed, overwrite: false)
        end

        item(
          "skill",
          source,
          renamed,
          if(ctx.execute?, do: "migrated", else: "planned"),
          "Imported under renamed folder",
          %{"renamed_from" => target}
        )

      true ->
        if ctx.execute? do
          backup_existing(ctx, target)
          copy_path!(source, target, overwrite: true)
        end

        item(
          "skill",
          source,
          target,
          if(ctx.execute?, do: "migrated", else: "planned"),
          "Copied skill directory"
        )
    end
  end

  defp patch_config_item(ctx, source, target, config) do
    content = if File.exists?(target), do: File.read!(target), else: ""
    patched = content

    patched =
      case normalize_string(config["model"]) do
        nil -> patched
        model -> patch_model(patched, model)
      end

    patched =
      config
      |> Map.get("providers", %{})
      |> patch_providers(patched)

    if patched == content do
      item("config", source, target, "skipped", "No compatible Hermes config values found")
    else
      if ctx.execute? do
        backup_existing(ctx, target)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, patched)
      end

      item(
        "config",
        source,
        target,
        if(ctx.execute?, do: "migrated", else: "planned"),
        "Mapped compatible config.yaml values into Lemon TOML"
      )
    end
  end

  defp patch_model(content, model) do
    provider =
      case String.split(model, ":", parts: 2) do
        [prefix, _] when prefix != "" -> prefix
        _ -> nil
      end

    content
    |> maybe_upsert("defaults", "provider", provider)
    |> TomlPatch.upsert_string("defaults", "model", model)
  end

  defp patch_providers(providers, content) when is_map(providers) do
    Enum.reduce(providers, content, fn {name, provider}, acc ->
      if is_map(provider) do
        table = "providers.#{name}"

        acc
        |> maybe_upsert(
          table,
          "base_url",
          normalize_string(provider["base_url"] || provider["baseUrl"])
        )
        |> maybe_upsert(table, "api_key_secret", secret_name_for_provider(name))
      else
        acc
      end
    end)
  end

  defp patch_providers(_, content), do: content

  defp import_secret(ctx, name, value) do
    {table, key} = Map.fetch!(@secret_names, name)
    config_path = Path.join(ctx.target_root, "config.toml")

    if ctx.execute? do
      case Secrets.set(name, value, provider: "hermes_migration") do
        {:ok, _} ->
          patch_secret_config(config_path, table, key, name)

          item(
            "secret",
            Path.join(ctx.source_root, ".env"),
            name,
            "migrated",
            "Imported allowlisted secret",
            %{"name" => name},
            true
          )

        {:error, reason} ->
          item(
            "secret",
            Path.join(ctx.source_root, ".env"),
            name,
            "error",
            "Secret import failed: #{inspect(reason)}",
            %{"name" => name},
            true
          )
      end
    else
      item(
        "secret",
        Path.join(ctx.source_root, ".env"),
        name,
        "planned",
        "Allowlisted secret would be imported",
        %{"name" => name},
        true
      )
    end
  end

  defp patch_secret_config(config_path, table, key, secret_name) do
    content = if File.exists?(config_path), do: File.read!(config_path), else: ""
    patched = TomlPatch.upsert_string(content, table, key, secret_name)
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, patched)
  end

  defp import_session_documents(ctx, db_path) do
    {:ok, store} =
      MemoryStore.start_link(
        name: :"hermes_migration_memory_#{System.unique_integer([:positive])}",
        path: ctx.store_dir
      )

    try do
      docs = session_docs(db_path)
      Enum.each(docs, &MemoryStore.put(store, &1))
      Process.sleep(100)

      [
        item(
          "sessions",
          db_path,
          Path.join(ctx.store_dir, "memory.sqlite3"),
          "migrated",
          "Imported #{length(docs)} Hermes sessions as Lemon memory documents",
          %{"count" => length(docs)}
        )
      ]
    after
      GenServer.stop(store)
    end
  rescue
    e ->
      [
        item(
          "sessions",
          db_path,
          Path.join(ctx.store_dir, "memory.sqlite3"),
          "error",
          Exception.message(e)
        )
      ]
  end

  defp session_docs(db_path) do
    case Sqlite3.open(db_path) do
      {:ok, conn} ->
        try do
          conn
          |> fetch_rows!(
            "SELECT id, source, user_id, model, started_at, title FROM sessions ORDER BY started_at DESC LIMIT 100000"
          )
          |> Enum.map(&session_doc(conn, &1))
        after
          Sqlite3.close(conn)
        end
      {:error, reason} -> raise "could not open Hermes state.db: #{inspect(reason)}"
    end
  end

  defp session_doc(conn, [id, source, user_id, model, started_at, title]) do
    messages =
      fetch_rows!(
        conn,
        "SELECT role, content, timestamp, tool_name FROM messages WHERE session_id = ?1 ORDER BY id ASC",
        [id]
      )

    prompt = first_role(messages, "user") || title || "Hermes session #{id}"
    answer = last_role(messages, "assistant") || ""
    tools = messages |> Enum.map(&Enum.at(&1, 3)) |> Enum.filter(&is_binary/1) |> Enum.uniq()
    started_ms = seconds_to_ms(started_at)

    %MemoryDocument{
      doc_id: "mem_hermes_#{stable_id(id)}",
      run_id: "hermes:#{id}",
      session_key: "hermes:#{id}",
      agent_id: normalize_string(user_id) || "hermes",
      workspace_key: nil,
      scope: :session,
      started_at_ms: started_ms,
      ingested_at_ms: System.system_time(:millisecond),
      prompt_summary: truncate_text(prompt, 2_000),
      answer_summary: truncate_text(answer, 2_000),
      tools_used: tools,
      provider: normalize_provider(model),
      model: normalize_string(model),
      outcome: :unknown,
      meta: %{
        "source" => "hermes",
        "hermes_source" => source,
        "hermes_session_id" => id,
        "title" => title
      }
    }
  end

  defp count_sessions(db_path) do
    case Sqlite3.open(db_path) do
      {:ok, conn} ->
        try do
          {:ok,
           case fetch_rows!(conn, "SELECT COUNT(*) FROM sessions") do
             [[count]] -> count
             _ -> 0
           end}
        after
          Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_rows!(conn, sql, params \\ []) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- bind_all(stmt, params),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
      rows
    else
      {:error, reason} -> raise inspect(reason)
      error -> raise inspect(error)
    end
  end

  defp bind_all(_stmt, []), do: :ok
  defp bind_all(stmt, params), do: Sqlite3.bind(stmt, params)

  defp first_role(messages, role) do
    messages
    |> Enum.find(fn row -> Enum.at(row, 0) == role end)
    |> then(fn row -> row && normalize_content(Enum.at(row, 1)) end)
  end

  defp last_role(messages, role) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn row -> Enum.at(row, 0) == role end)
    |> then(fn row -> row && normalize_content(Enum.at(row, 1)) end)
  end

  defp normalize_content(nil), do: nil
  defp normalize_content(text) when is_binary(text), do: String.trim(text)
  defp normalize_content(value), do: inspect(value)

  defp parse_entries(raw) do
    cond do
      String.trim(raw) == "" ->
        []

      String.contains?(raw, @entry_delimiter) ->
        raw
        |> String.split(@entry_delimiter)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      true ->
        raw
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.map(&String.replace(&1, ~r/^\s*(?:[-*]|\d+\.)\s+/, ""))
    end
  end

  defp merge_entries(existing, incoming, limit) do
    {merged, seen, size} =
      Enum.reduce(existing, {[], MapSet.new(), 0}, fn entry, {acc, seen, size} ->
        norm = normalize_entry(entry)
        {[entry | acc], MapSet.put(seen, norm), size + String.length(entry)}
      end)

    {merged, _seen, _size, added, duplicates, overflow} =
      Enum.reduce(incoming, {merged, seen, size, 0, 0, []}, fn entry,
                                                               {acc, seen, size, added,
                                                                duplicates, overflow} ->
        norm = normalize_entry(entry)
        delimiter_size = if acc == [], do: 0, else: String.length(@entry_delimiter)
        candidate_size = size + delimiter_size + String.length(entry)

        cond do
          norm == "" ->
            {acc, seen, size, added, duplicates, overflow}

          MapSet.member?(seen, norm) ->
            {acc, seen, size, added, duplicates + 1, overflow}

          candidate_size > limit ->
            {acc, seen, size, added, duplicates, [entry | overflow]}

          true ->
            {[entry | acc], MapSet.put(seen, norm), candidate_size, added + 1, duplicates,
             overflow}
        end
      end)

    {Enum.reverse(merged),
     %{
       "existing" => length(existing),
       "incoming" => length(incoming),
       "added" => added,
       "duplicates" => duplicates,
       "overflowed" => length(overflow)
     }, Enum.reverse(overflow)}
  end

  defp item(kind, source, destination, status, reason, details \\ %{}, sensitive \\ false) do
    %{
      "kind" => kind,
      "source" => source,
      "destination" => destination,
      "status" => status,
      "reason" => reason,
      "details" => details,
      "sensitive" => sensitive
    }
  end

  defp summarize(items) do
    statuses = Enum.frequencies_by(items, & &1["status"])

    %{
      "total" => length(items),
      "planned" => Map.get(statuses, "planned", 0),
      "migrated" => Map.get(statuses, "migrated", 0),
      "archived" => Map.get(statuses, "archived", 0),
      "skipped" => Map.get(statuses, "skipped", 0),
      "conflict" => Map.get(statuses, "conflict", 0),
      "error" => Map.get(statuses, "error", 0)
    }
  end

  defp audit_summary(items) do
    statuses = Enum.frequencies_by(items, & &1["status"])

    %{
      "total" => length(items),
      "compatible" => Map.get(statuses, "compatible", 0),
      "partial" => Map.get(statuses, "partial", 0),
      "gated" => Map.get(statuses, "gated", 0),
      "unsupported" => Map.get(statuses, "unsupported", 0),
      "missing" => Map.get(statuses, "missing", 0),
      "error" => Map.get(statuses, "error", 0)
    }
  end

  defp redact_item(%{"sensitive" => true} = item) do
    item
    |> put_in(["destination"], "[redacted]")
    |> put_in(["details"], Map.put(item["details"] || %{}, "value", "[redacted]"))
  end

  defp redact_item(item), do: item

  defp summary_markdown(report) do
    summary = report["summary"]

    """
    # Hermes Migration Report

    Source: #{report["source"]}
    Target: #{report["target"]}

    - planned: #{summary["planned"]}
    - migrated: #{summary["migrated"]}
    - archived: #{summary["archived"]}
    - skipped: #{summary["skipped"]}
    - conflicts: #{summary["conflict"]}
    - errors: #{summary["error"]}
    """
  end

  defp parse_env(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        line = String.trim(line)

        if line == "" or String.starts_with?(line, "#") or not String.contains?(line, "=") do
          acc
        else
          [key, value] = String.split(line, "=", parts: 2)
          Map.put(acc, String.trim(key), String.trim(value))
        end
      end)
    else
      %{}
    end
  end

  defp read_config(path) do
    if File.exists?(path), do: YamlElixir.read_from_file(path), else: :missing
  end

  defp backup_existing(ctx, path) do
    if File.exists?(path) do
      rel = Path.relative_to(path, ctx.target_root)
      dest = Path.join(ctx.backup_dir, rel)
      copy_path!(path, dest, overwrite: true)
      dest
    end
  end

  defp copy_path!(source, dest, opts) do
    if File.exists?(dest) and Keyword.get(opts, :overwrite, false), do: File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))

    if File.dir?(source) do
      File.cp_r!(source, dest)
    else
      File.cp!(source, dest)
    end
  end

  defp same_file?(source, dest) do
    File.exists?(source) and File.exists?(dest) and
      :crypto.hash(:sha256, File.read!(source)) == :crypto.hash(:sha256, File.read!(dest))
  end

  defp unique_path(path), do: unique_path(path, 1)

  defp unique_path(path, n) do
    candidate = if n == 1, do: path, else: "#{path}-#{n}"
    if File.exists?(candidate), do: unique_path(path, n + 1), else: candidate
  end

  defp maybe_upsert(content, _table, _key, nil), do: content

  defp maybe_upsert(content, table, key, value),
    do: TomlPatch.upsert_string(content, table, key, value)

  defp maybe_list(list, _value, nil), do: list
  defp maybe_list(list, _value, false), do: list
  defp maybe_list(list, value, _present), do: [value | list]

  defp has_any_key?(map, keys), do: Enum.any?(keys, &Map.has_key?(map, &1))

  defp present_keys(map, keys) do
    Enum.filter(keys, &Map.has_key?(map, &1))
  end

  defp secret_name_for_provider(name) do
    @secret_names
    |> Enum.find_value(fn
      {secret, {provider, "api_key_secret"}} when provider == name -> secret
      _ -> nil
    end)
  end

  defp normalize_provider(nil), do: nil

  defp normalize_provider(model) when is_binary(model),
    do: model |> String.split(":", parts: 2) |> List.first()

  defp normalize_provider(_), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(""), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp normalize_entry(entry) do
    entry |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")
  end

  defp stable_id(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 24)
  end

  defp truncate_text(text, limit) when is_binary(text) and byte_size(text) > limit do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      next = acc <> grapheme

      if byte_size(next) > limit do
        {:halt, acc}
      else
        {:cont, next}
      end
    end)
  end

  defp truncate_text(text, _limit) when is_binary(text), do: text
  defp truncate_text(_, _limit), do: ""

  defp seconds_to_ms(seconds) when is_float(seconds), do: trunc(seconds * 1000)
  defp seconds_to_ms(seconds) when is_integer(seconds), do: seconds * 1000
  defp seconds_to_ms(_), do: System.system_time(:millisecond)

  defp overflow_path(ctx, kind) do
    Path.join([ctx.workspace_dir, "memory", "topics", "hermes-imported-#{kind}.md"])
  end

  defp recursive_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp path(value), do: value |> Path.expand()

  defp timestamp do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
