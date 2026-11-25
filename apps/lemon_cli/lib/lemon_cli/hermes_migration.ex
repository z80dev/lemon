defmodule LemonCli.HermesMigration do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Secrets
  alias LemonMemory.Document
  alias LemonMemory.Store

  @entry_delimiter "\n§\n"
  @memory_limit 2_200
  @user_limit 1_375
  @journal_file "journal.jsonl"
  @config_archive_header "# Hermes config.yaml reduced to supported non-secret fields"
  # Destination TOML table and key for each allowlisted secret's reference.
  @secret_names %{
    "ANTHROPIC_API_KEY" => {"providers.anthropic", "api_key_secret"},
    "OPENAI_API_KEY" => {"providers.openai", "api_key_secret"},
    "OPENAI_CODEX_API_KEY" => {"providers.openai-codex", "api_key_secret"},
    "OPENCODE_API_KEY" => {"providers.opencode", "api_key_secret"},
    "ZAI_API_KEY" => {"providers.zai", "api_key_secret"},
    "MINIMAX_API_KEY" => {"providers.minimax", "api_key_secret"},
    "TELEGRAM_BOT_TOKEN" => {"gateway.telegram", "bot_token_secret"},
    "DISCORD_BOT_TOKEN" => {"gateway.discord", "bot_token_secret"},
    "ELEVENLABS_API_KEY" => {"gateway.voice", "elevenlabs_api_key_secret"},
    "DEEPGRAM_API_KEY" => {"gateway.voice", "deepgram_api_key_secret"}
  }

  # Persist the satellite's public config schema without depending on its app.
  @honcho_fields %{
    "enabled" => {"enabled", :boolean},
    "baseUrl" => {"base_url", :string},
    "environment" => {"environment", :string},
    "workspace" => {"workspace", :string},
    "peerName" => {"user_peer", :string},
    "pinUserPeer" => {"pin_user_peer", :boolean},
    "userPeerAliases" => {"user_peer_aliases", :peer_aliases},
    "runtimePeerPrefix" => {"runtime_peer_prefix", :optional_string},
    "aiPeer" => {"ai_peer", :string},
    "recallMode" => {"recall_mode", ~w(hybrid context tools)},
    "sessionStrategy" => {"session_strategy", ~w(per-session per-directory per-repo global)},
    "contextTokens" => {"context_tokens", :positive_integer},
    "contextCadence" => {"context_cadence", :positive_integer},
    "dialecticCadence" => {"dialectic_cadence", :positive_integer},
    "dialecticReasoningLevel" => {"reasoning_level", ~w(minimal low medium high max)},
    "dialecticMaxChars" => {"dialectic_max_chars", :positive_integer},
    "messageMaxChars" => {"message_max_chars", :positive_integer},
    "saveMessages" => {"save_messages", :boolean},
    "observationMode" => {"observation_mode", ~w(directional unified)},
    "timeout" => {"timeout_ms", :seconds}
  }

  @user_data_sections MapSet.new([
                        :soul,
                        :memory,
                        :user_profile,
                        :skills,
                        :config,
                        :honcho,
                        :sessions,
                        :archive
                      ])

  @full_sections MapSet.union(@user_data_sections, MapSet.new([:secrets]))

  def preview(opts \\ []) do
    run(Keyword.put(opts, :execute, false))
  end

  @doc """
  Applies the migration offline.

  Refuses while a Lemon runtime uses the target and holds the restore
  lifecycle locks for the whole run, so no runtime, restore or other migration
  can write the target meanwhile. With `backup: true` an existing target is
  first snapshotted with `LemonCli.Backup.create/1`; the bundle path is
  reported as `"backup"`. A refusal returns a report with `"error"` set and
  nothing written.
  """
  def apply(opts \\ []) do
    target = target_root(opts)

    result =
      LemonCli.Backup.with_offline_target(target, offline_opts(opts), fn ->
        with {:ok, bundle} <- pre_migration_backup(target, opts) do
          {:ok, run(opts |> Keyword.put(:execute, true) |> Keyword.put(:backup_bundle, bundle))}
        end
      end)

    case result do
      {:ok, report} -> report
      {:error, reason} -> refused_report(opts, target, reason)
    end
  end

  defp target_root(opts), do: path(opts[:target] || Path.join(System.user_home!(), ".lemon"))

  defp offline_opts(opts), do: Keyword.take(opts, [:runtime_probe, :after_runtime_check])

  defp pre_migration_backup(target, opts) do
    if Keyword.get(opts, :backup, false) and File.dir?(target) do
      case LemonCli.Backup.create(paths_opts: [home_state_dir: target]) do
        {:ok, %{path: bundle}} -> {:ok, bundle}
        {:error, reason} -> {:error, {:backup_failed, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp refused_report(opts, target, reason) do
    message = refusal_reason(reason)
    items = [item("migration", nil, target, "error", message)]

    %{
      "source" => source_root(opts),
      "target" => target,
      "execute" => true,
      "error" => message,
      "backup" => nil,
      "output_dir" => nil,
      "summary" => summarize(items),
      "items" => items
    }
  end

  defp refusal_reason(:daemon_running),
    do: "A Lemon runtime is using the target; stop it first (migration runs offline)"

  defp refusal_reason(:backup_restore_locked),
    do: "Another migration, backup restore or runtime start holds the target lock"

  defp refusal_reason({:backup_failed, reason}),
    do: "Could not create pre-migration backup: #{inspect(reason)}"

  defp refusal_reason(reason), do: "Migration refused: #{inspect(reason)}"

  defp source_root(opts) do
    path(
      opts[:source] || System.get_env("HERMES_HOME") || Path.join(System.user_home!(), ".hermes")
    )
  end

  def audit(opts \\ []) do
    source_root = source_root(opts)
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
      audit_honcho(opts, source_root, target_root),
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

    items = List.flatten(items) ++ legacy_archive_items(target_root)

    %{
      "source" => source_root,
      "target" => target_root,
      "execute" => false,
      "mode" => "audit",
      "summary" => audit_summary(items),
      "items" => Enum.map(items, &redact_item/1)
    }
  end

  defp run(opts) do
    source_root = source_root(opts)
    target_root = target_root(opts)
    execute? = Keyword.get(opts, :execute, false)
    overwrite? = Keyword.get(opts, :overwrite, false)
    migrate_secrets? = Keyword.get(opts, :migrate_secrets, false)
    skill_conflict = Keyword.get(opts, :skill_conflict, "skip")
    sections = sections(Keyword.get(opts, :preset, "user-data"), migrate_secrets?)
    timestamp = Keyword.get(opts, :timestamp, timestamp())
    report_dir = Path.join([target_root, "migration", "hermes", timestamp])

    ctx = %{
      source_root: source_root,
      config_path: path(opts[:config_path] || Path.join(target_root, "config.toml")),
      target_root: target_root,
      honcho_global_path:
        opts[:honcho_global_path] || Path.join([System.user_home!(), ".honcho", "config.json"]),
      workspace_dir:
        Keyword.get(opts, :workspace_dir) || Path.join([target_root, "agent", "workspace"]),
      skill_dir: Path.join([target_root, "agent", "skill"]),
      store_dir: Path.join(target_root, "store"),
      report_dir: report_dir,
      backup_dir: Path.join(report_dir, "backups"),
      archive_dir: Path.join(report_dir, "archive"),
      backup_bundle: opts[:backup_bundle],
      execute?: execute?,
      overwrite?: overwrite?,
      migrate_secrets?: migrate_secrets?,
      include_skill_assets?: Keyword.get(opts, :include_skill_assets, false),
      before_config_write: opts[:before_config_write],
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
      |> maybe_add(ctx, :honcho, &migrate_honcho/1)
      |> maybe_add(ctx, :sessions, &migrate_sessions/1)
      |> maybe_add(ctx, :archive, &archive_unmapped/1)
      |> List.flatten()

    items = items ++ content_warning(items) ++ legacy_archive_items(target_root)

    report = %{
      "source" => source_root,
      "target" => target_root,
      "execute" => execute?,
      "preset" => Keyword.get(opts, :preset, "user-data"),
      "migrate_secrets" => migrate_secrets?,
      "skill_conflict" => skill_conflict,
      "backup" => opts[:backup_bundle],
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

  @doc """
  Reverts an applied migration from the journal in its report directory.

  Runs offline under the same exclusion as `apply/1`. Paths the migration
  created are removed and plain files it modified are restored from the copies
  taken before their first change. A secret the migration created is deleted
  only from the same store and only while it is still that exact value.
  Imported session memory is never rolled back here: restore the pre-migration
  backup bundle for the store. Empty parent directories and the report
  directory itself are left in place.
  """
  def rollback(report_dir, opts \\ []) do
    report_dir = path(report_dir)

    with {:ok, body} <- File.read(Path.join(report_dir, "report.json")),
         {:ok, %{"target" => target}} when is_binary(target) <- Jason.decode(body),
         {:ok, report} <-
           LemonCli.Backup.with_offline_target(target, offline_opts(opts), fn ->
             {:ok, do_rollback(report_dir)}
           end) do
      report
    else
      {:error, reason} -> rollback_report(report_dir, [rollback_error(report_dir, reason)])
      _ -> rollback_report(report_dir, [rollback_error(report_dir, :invalid_report)])
    end
  end

  defp do_rollback(report_dir) do
    journal = Path.join(report_dir, @journal_file)

    items =
      case File.read(journal) do
        {:ok, body} ->
          body
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)
          |> Enum.reverse()
          |> Enum.map(&undo_entry(report_dir, &1))

        {:error, reason} ->
          [rollback_error(journal, reason)]
      end

    report = rollback_report(report_dir, items)
    File.write!(Path.join(report_dir, "rollback.json"), Jason.encode!(report, pretty: true))
    report
  end

  # Rollback is complete only when nothing is left for the operator to recover.
  defp rollback_report(report_dir, items) do
    %{
      "report_dir" => report_dir,
      "complete" => not Enum.any?(items, &(&1["status"] in ["error", "manual"])),
      "summary" => Enum.frequencies_by(items, & &1["status"]),
      "items" => Enum.map(items, &redact_item/1)
    }
  end

  defp undo_entry(_report_dir, %{"op" => "created", "path" => path}) do
    case File.rm_rf(path) do
      {:ok, _} -> item("rollback", path, nil, "reverted", "Removed path created by the migration")
      {:error, reason, _} -> rollback_error(path, reason)
    end
  end

  defp undo_entry(report_dir, %{"op" => "modified", "path" => path, "backup" => backup}) do
    if inside?(path(backup), report_dir) and File.exists?(backup) do
      _ = File.rm_rf!(path)
      copy_path!(backup, path, overwrite: true)
      item("rollback", path, nil, "restored", "Restored the pre-migration copy")
    else
      rollback_error(path, :missing_backup)
    end
  rescue
    e in File.Error -> rollback_error(path, e.reason)
  end

  defp undo_entry(_report_dir, %{
         "op" => "secret_created",
         "name" => name,
         "store" => store,
         "incarnation" => incarnation
       }) do
    entry = &item("rollback", name, nil, &1, &2, %{"name" => name}, true)

    case store_identity() do
      {:ok, ^store} ->
        case Secrets.delete_if_incarnation(name, incarnation) do
          :ok ->
            entry.("reverted", "Deleted the secret created by the migration")

          {:error, :stale_revision} ->
            entry.(
              "manual",
              "Secret changed or was removed after the migration created it; left untouched"
            )

          {:error, reason} ->
            entry.("error", "Could not delete the secret: #{inspect(reason)}")
        end

      _other ->
        entry.(
          "error",
          "The active secret store is not the one the migration wrote (#{store}); secret not deleted"
        )
    end
  end

  defp undo_entry(_report_dir, %{"op" => "database", "path" => path, "existed" => false}) do
    results = Enum.map(["", "-wal", "-shm", "-journal"], &File.rm_rf(path <> &1))

    case Enum.find(results, &match?({:error, _, _}, &1)) do
      nil ->
        item(
          "rollback",
          path,
          nil,
          "reverted",
          "Removed session memory database the migration created"
        )

      {:error, reason, _} ->
        rollback_error(path, reason)
    end
  end

  defp undo_entry(_report_dir, %{"op" => "database", "path" => path}) do
    item(
      "rollback",
      path,
      nil,
      "manual",
      "Imported session memory was added to an existing database and is not rolled back; restore the pre-migration backup bundle (lemon backup restore) to revert it"
    )
  end

  defp undo_entry(_report_dir, entry),
    do: item("rollback", inspect(entry["op"]), nil, "error", "Unknown journal entry")

  defp rollback_error(path, reason),
    do: item("rollback", path, nil, "error", "Rollback failed: #{inspect(reason)}")

  # Records a destination before its first mutation in this run: new paths as
  # `created`, existing ones as `modified` with a copy under `backups/`.
  defp journal!(ctx, path) do
    if ctx.execute? and not journaled?(ctx, path) do
      entry =
        case File.lstat(path) do
          {:ok, _} ->
            %{"op" => "modified", "path" => path, "backup" => backup_existing(ctx, path)}

          {:error, _} ->
            %{"op" => "created", "path" => path}
        end

      append_journal!(ctx, entry)
    end

    :ok
  end

  defp journaled?(ctx, path) do
    case File.read(Path.join(ctx.report_dir, @journal_file)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.any?(&(Jason.decode!(&1)["path"] == path))

      {:error, _} ->
        false
    end
  end

  defp append_journal!(ctx, entry) do
    journal = Path.join(ctx.report_dir, @journal_file)
    File.mkdir_p!(ctx.report_dir)
    File.write!(journal, Jason.encode!(entry) <> "\n", [:append])
    File.chmod!(journal, 0o600)
  end

  @legacy_reason "May hold plaintext Hermes credentials copied by an earlier migration. " <>
                   "Lemon no longer creates it and never backs it up. Review it, delete it " <>
                   "once you no longer need it, and rotate any credentials it contained."

  # Value-free warnings for plaintext copies made by earlier migration versions.
  defp legacy_archive_items(target_root) do
    archived =
      [target_root, "migration", "hermes", "*", "archive"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.flat_map(fn dir ->
        config = Path.join(dir, "config.yaml")

        Enum.filter([Path.join(dir, "auth.json"), Path.join(dir, "cron")], &File.exists?/1) ++
          if(File.regular?(config) and not reduced_config_archive?(config),
            do: [config],
            else: []
          )
      end)

    zips = Path.wildcard(Path.join([target_root, "backups", "pre-hermes-migration-*.zip"]))

    Enum.map(archived ++ zips, &item("legacy_archive", &1, nil, "warning", @legacy_reason))
  end

  defp reduced_config_archive?(path) do
    case File.open(path, [:read], &IO.read(&1, :line)) do
      {:ok, line} when is_binary(line) -> String.trim_trailing(line) == @config_archive_header
      _ -> false
    end
  end

  @content_kinds ~w(soul memory user_profile skill sessions)

  defp content_warning(items) do
    if Enum.any?(items, &(&1["kind"] in @content_kinds and &1["status"] in ~w(planned migrated))) do
      [
        item(
          "content",
          nil,
          nil,
          "warning",
          "Persona, memory, skill and session text is imported as written and is not scanned for embedded secrets; review it and move any credentials into Lemon secrets"
        )
      ]
    else
      []
    end
  end

  def has_conflicts?(%{"summary" => %{"conflict" => count}}), do: count > 0

  def has_conflicts?(_), do: false

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
      |> Enum.sort()
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.map(&Path.join(source, &1))
      |> Enum.filter(
        &match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(&1, "SKILL.md")))
      )
      |> Enum.map(fn dir ->
        case File.lstat(dir) do
          {:ok, %File.Stat{type: :directory}} ->
            copy_skill(ctx, dir)

          _ ->
            item("skill", dir, nil, "gated", "Symlinked skill directory not imported")
        end
      end)
    else
      [item("skills", source, nil, "skipped", "Hermes skills directory not found")]
    end
  end

  defp migrate_config(ctx) do
    source = Path.join(ctx.source_root, "config.yaml")

    if File.exists?(source) do
      case YamlElixir.read_from_file(source) do
        {:ok, config} ->
          target = ctx.config_path
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

    env_path
    |> parse_env()
    |> Enum.filter(fn {name, value} ->
      Map.has_key?(@secret_names, name) and String.trim(value) != ""
    end)
    |> Enum.map(fn {name, value} -> import_secret(ctx, name, value) end)
    |> case do
      [] -> [item("secrets", env_path, nil, "skipped", "No allowlisted Hermes secrets found")]
      items -> items
    end
  end

  defp audit_honcho(opts, source, target) do
    migrate_honcho(%{
      source_root: source,
      config_path: path(opts[:config_path] || Path.join(target, "config.toml")),
      target_root: target,
      honcho_global_path:
        opts[:honcho_global_path] || Path.join([System.user_home!(), ".honcho", "config.json"]),
      sections: @user_data_sections,
      execute?: false,
      overwrite?: true
    })
    |> Enum.map(fn entry ->
      status =
        case entry["status"] do
          "planned" -> "compatible"
          "skipped" -> "missing"
          other -> other
        end

      Map.put(entry, "status", status)
    end)
  end

  defp migrate_honcho(ctx) do
    local = Path.join(ctx.source_root, "honcho.json")
    source = if File.exists?(local), do: local, else: ctx.honcho_global_path
    target = ctx.config_path

    with {:ok, bytes} <- File.read(source),
         {:ok, raw} when is_map(raw) <- Jason.decode(bytes),
         {:ok, config, unsupported} <- honcho_host_config(raw, ctx.source_root),
         {:ok, existing} <- read_target_config(target) do
      content = if File.exists?(target), do: File.read!(target), else: ""

      {patched, entries} =
        config
        |> Enum.sort()
        |> Enum.reduce({content, []}, fn {key, value}, {content, entries} ->
          case Map.fetch(@honcho_fields, key) do
            {:ok, {dest_key, type}} ->
              case honcho_value(value, type) do
                {:ok, converted} when dest_key == "base_url" and not is_nil(converted) ->
                  if safe_url?(converted) do
                    {next, entry} =
                      honcho_config_item(
                        ctx,
                        source,
                        target,
                        existing,
                        content,
                        dest_key,
                        converted
                      )

                    {next, [entry | entries]}
                  else
                    {content, [credential_url_item(source, target, "honcho.base_url") | entries]}
                  end

                {:ok, converted} ->
                  {next, entry} =
                    honcho_config_item(
                      ctx,
                      source,
                      target,
                      existing,
                      content,
                      dest_key,
                      converted
                    )

                  {next, [entry | entries]}

                :error ->
                  {content,
                   [honcho_unsupported(source, target, key, "Unsupported Honcho value") | entries]}

                :unset ->
                  {content, entries}
              end

            :error ->
              {content, entries}
          end
        end)

      {with_secret, secret_items, pending} =
        honcho_secret(ctx, source, existing, patched, config)

      secret_items =
        if ctx.execute? and (with_secret != content or pending != nil) do
          write_honcho(ctx, target, content, patched, with_secret, pending, secret_items)
        else
          secret_items
        end

      unsupported_items =
        Enum.map(unsupported, &honcho_unsupported(source, target, &1, "Unsupported Honcho key"))

      Enum.reverse(entries) ++ secret_items ++ unsupported_items
    else
      {:error, :enoent} ->
        [item("honcho", source, target, "skipped", "Hermes Honcho config not found")]

      _ ->
        [item("honcho", source, target, "error", "Could not read Hermes or Lemon Honcho config")]
    end
  end

  defp honcho_host_config(raw, source_root) do
    source_env = parse_env(Path.join(source_root, ".env"))

    profile_host =
      if Path.basename(Path.dirname(source_root)) == "profiles" do
        "hermes_" <> String.replace(Path.basename(source_root), ~r/[^A-Za-z0-9_-]/, "_")
      else
        normalize_string(raw["defaultHost"]) || "hermes"
      end

    host = normalize_string(source_env["HERMES_HONCHO_HOST"]) || profile_host
    hosts = Map.get(raw, "hosts", %{})

    if is_map(hosts) and is_map(Map.get(hosts, host, %{})) do
      host_config =
        hosts
        |> Map.get(host, %{})
        |> honcho_alias("base_url", "baseUrl")
        |> honcho_alias("requestTimeout", "timeout")
        |> honcho_alias("pinPeerName", "pinUserPeer")

      config =
        raw
        |> Map.drop(["hosts", "defaultHost"])
        |> honcho_alias("base_url", "baseUrl")
        |> honcho_alias("requestTimeout", "timeout")
        |> honcho_alias("pinPeerName", "pinUserPeer")
        |> Map.merge(host_config)
        |> Map.put_new("workspace", host)
        |> Map.put_new("aiPeer", host)

      unsupported =
        Enum.reject(Map.keys(config), &(&1 == "apiKey" or Map.has_key?(@honcho_fields, &1))) ++
          Enum.map(Enum.reject(Map.keys(hosts), &(&1 == host)), &("hosts." <> &1))

      {:ok, config, Enum.sort(unsupported)}
    else
      :error
    end
  end

  defp honcho_alias(config, alias_key, key) do
    case Map.pop(config, alias_key) do
      {nil, config} -> config
      {value, config} -> Map.put_new(config, key, value)
    end
  end

  defp read_target_config(target) do
    case File.read(target) do
      {:ok, content} -> Toml.decode(content)
      {:error, :enoent} -> {:ok, %{}}
      error -> error
    end
  end

  defp honcho_value(nil, _type), do: :unset

  defp honcho_value(value, :string) do
    case normalize_string(value) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp honcho_value(value, :optional_string) when is_binary(value),
    do: {:ok, String.trim(value)}

  defp honcho_value(value, :peer_aliases) when is_map(value) do
    if Enum.all?(value, fn {id, peer} ->
         is_binary(id) and id != "" and is_binary(peer) and
           Regex.match?(~r/^[A-Za-z0-9_-]{1,512}$/, peer)
       end),
       do: {:ok, value},
       else: :error
  end

  defp honcho_value(value, :boolean) when is_boolean(value), do: {:ok, value}

  defp honcho_value(value, :positive_integer) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp honcho_value(value, :seconds) when is_number(value) and value > 0,
    do: {:ok, max(1, round(value * 1_000))}

  defp honcho_value(value, allowed) when is_list(allowed) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp honcho_value(_value, _type), do: :error

  defp honcho_config_item(ctx, source, target, existing, content, key, value) do
    current = get_in(existing, ["honcho", key])
    details = %{"key" => key}

    cond do
      current == value ->
        {content, item("honcho", source, target, "skipped", "Target already matches", details)}

      not is_nil(current) and not ctx.overwrite? ->
        {content,
         item("honcho", source, target, "conflict", "Target Honcho setting exists", details)}

      true ->
        patched =
          cond do
            is_binary(value) ->
              TomlPatch.upsert_raw_line(
                content,
                "honcho",
                key,
                "#{key} = #{Jason.encode!(value)}"
              )

            is_map(value) ->
              aliases =
                value
                |> Enum.sort()
                |> Enum.map_join("\n", fn {id, peer} ->
                  "#{Jason.encode!(id)} = #{Jason.encode!(peer)}"
                end)

              # Explicit tables also preserve an empty alias map with the TOML
              # decoder, whose empty inline-table path loses the parent scope.
              content
              |> TomlPatch.delete_key("honcho", key)
              |> TomlPatch.delete_table_tree("honcho.#{key}")
              |> then(&(&1 <> "\n[honcho.#{key}]\n" <> aliases <> "\n"))

            true ->
              TomlPatch.upsert_raw_line(content, "honcho", key, "#{key} = #{value}")
          end

        {patched,
         item(
           "honcho",
           source,
           target,
           if(ctx.execute?, do: "migrated", else: "planned"),
           "Mapped Honcho setting",
           details
         )}
    end
  end

  # Returns the config with the secret reference, the secret items, and the
  # secret still to be written (only when executing) by `write_honcho/7`.
  defp honcho_secret(ctx, source, existing, content, config) do
    case normalize_string(config["apiKey"]) do
      nil ->
        {content, [], nil}

      value ->
        name = "HONCHO_API_KEY"

        entry = fn status, reason ->
          item("honcho_secret", source, name, status, reason, %{"name" => name}, true)
        end

        cond do
          not MapSet.member?(ctx.sections, :secrets) ->
            {content,
             [entry.("gated", "Honcho API key requires --preset full --migrate-secrets")], nil}

          match?({:outside, _}, secret_store_scope(ctx)) ->
            {:outside, reason} = secret_store_scope(ctx)
            {content, [entry.("gated", outside_store_reason(reason))], nil}

          not ctx.overwrite? and
              (not is_nil(get_in(existing, ["honcho", "api_key_secret"])) or
                 not is_nil(get_in(existing, ["honcho", "api_key"]))) ->
            {content, [entry.("conflict", "Target Honcho credential setting exists")], nil}

          true ->
            case Secrets.list() do
              {:ok, secrets} ->
                cond do
                  Enum.any?(secrets, &(&1.name == name)) ->
                    {content, [entry.("conflict", existing_secret_reason(name))], nil}

                  ctx.execute? ->
                    patched =
                      content
                      |> TomlPatch.delete_key("honcho", "api_key")
                      |> TomlPatch.upsert_string("honcho", "api_key_secret", name)

                    {patched,
                     [entry.("migrated", "Imported Honcho API key into encrypted secrets")],
                     {name, value}}

                  true ->
                    {content,
                     [
                       entry.(
                         "planned",
                         "Honcho API key would be imported into encrypted secrets"
                       )
                     ], nil}
                end

              {:error, _} ->
                {content, [entry.("error", "Could not inspect Lemon secrets")], nil}
            end
        end
    end
  end

  # Writes the Honcho config only if it is unchanged since it was read. With a
  # pending secret, the secret is written first and undone if the config write
  # fails; on a secret failure the non-secret settings are still written.
  defp write_honcho(ctx, target, content, patched, with_secret, pending, secret_items) do
    write = fn new ->
      fn ->
        update_config_file(ctx, target, fn current ->
          if current == content, do: {:ok, new}, else: {:error, :config_changed}
        end)
      end
    end

    {secret_items, config_result} =
      case pending do
        nil ->
          {secret_items, write.(patched).()}

        {name, value} ->
          result =
            case secret_store_scope(ctx) do
              {:ok, store} ->
                write_secret_then_config(ctx, store, name, value, write.(with_secret))

              {:outside, reason} ->
                {:error, {:outside, reason}}
            end

          case result do
            :ok ->
              {secret_items, :ok}

            {:error, reason} ->
              failed =
                Enum.map(
                  secret_items,
                  &Map.merge(&1, %{
                    "status" => secret_failure_status(reason),
                    "reason" => "Honcho " <> secret_failure_reason(reason)
                  })
                )

              {failed, write.(patched).()}
          end
      end

    case config_result do
      :ok ->
        secret_items

      {:error, reason} ->
        secret_items ++
          [
            item(
              "honcho",
              target,
              target,
              "error",
              "Honcho settings not written: #{config_failure_reason(reason)}"
            )
          ]
    end
  end

  defp honcho_unsupported(source, target, key, reason) do
    item("honcho", source, target, "unsupported", reason, %{"key" => key})
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

  # auth.json is never copied: it holds tokens and is reported as gated instead.
  # config.yaml is archived reduced to the supported non-secret fields and cron
  # jobs only by name and schedule; everything else is reported, never copied.
  defp archive_unmapped(ctx) do
    auth = Path.join(ctx.source_root, "auth.json")

    auth_items =
      if File.exists?(auth) do
        [
          item(
            "archive",
            auth,
            nil,
            "gated",
            "Hermes auth.json holds credentials and is never archived; import supported credentials with --preset full --migrate-secrets",
            %{},
            true
          )
        ]
      else
        []
      end

    archive_items =
      archive_config_yaml(ctx, Path.join(ctx.source_root, "config.yaml")) ++
        archive_cron(ctx, Path.join(ctx.source_root, "cron"))

    case auth_items ++ archive_items do
      [] -> [item("archive", ctx.source_root, nil, "skipped", "No unmapped Hermes files found")]
      items -> items
    end
  end

  defp archive_config_yaml(ctx, source) do
    with true <- File.exists?(source),
         {:ok, config} <- YamlElixir.read_from_file(source) do
      {kept, unsupported} = supported_config(config)
      dest = Path.join(ctx.archive_dir, "config.yaml")

      # JSON is valid YAML, so the reduced copy stays readable as config.yaml.
      _ =
        if ctx.execute? do
          write_private!(
            dest,
            @config_archive_header <> "\n" <> Jason.encode!(kept, pretty: true) <> "\n"
          )
        end

      [archive_item(ctx, source, dest, "Archived supported non-secret config fields")] ++
        if unsupported == [] do
          []
        else
          [
            item(
              "archive",
              source,
              nil,
              "gated",
              "Unsupported config.yaml sections were neither imported nor archived; review them in the Hermes home",
              %{"keys" => unsupported}
            )
          ]
        end
    else
      false ->
        []

      {:error, _} ->
        [item("archive", source, nil, "skipped", "Unparseable Hermes config.yaml not archived")]
    end
  end

  defp supported_config(config) when is_map(config) do
    kept =
      [
        {"model", normalize_string(config["model"])},
        {"providers", supported_providers(config["providers"])}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, %{}] end)
      |> Map.new()

    unsupported =
      config
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in ["model", "providers"]))
      |> Enum.sort()

    {kept, unsupported}
  end

  defp supported_config(_config), do: {%{}, []}

  defp supported_providers(providers) when is_map(providers) do
    providers
    |> Enum.flat_map(fn {name, provider} ->
      url = if is_map(provider), do: provider_base_url(provider)

      if is_binary(url) and safe_url?(url),
        do: [{to_string(name), %{"base_url" => url}}],
        else: []
    end)
    |> Map.new()
  end

  defp supported_providers(_providers), do: nil

  defp provider_base_url(provider),
    do: normalize_string(provider["base_url"] || provider["baseUrl"])

  # A mapped URL must not carry credentials: no userinfo, query or fragment.
  defp safe_url?(url) do
    case URI.new(url) do
      {:ok, %URI{userinfo: nil, query: nil, fragment: nil, host: host}} when is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp credential_url_item(source, target, key) do
    item(
      "config",
      source,
      target,
      "gated",
      "URL with userinfo, query or fragment not imported; it may embed credentials. Set it manually without them and keep credentials in Lemon secrets",
      %{"key" => key}
    )
  end

  @cron_fields ~w(id name schedule cron enabled timezone)

  defp archive_cron(ctx, source) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :directory}} ->
        files = private_regular_files(source)
        dest = Path.join(ctx.archive_dir, "cron.json")

        _ =
          if ctx.execute? do
            summary = %{
              "jobs" => Enum.flat_map(files, &cron_jobs/1),
              "files" => Enum.map(files, &Path.relative_to(&1, source))
            }

            write_private!(dest, Jason.encode!(summary, pretty: true) <> "\n")
          end

        [
          archive_item(
            ctx,
            source,
            dest,
            "Archived cron job names and schedules only; commands, prompts and environment were not copied, so recreate the jobs manually"
          )
        ]

      {:ok, _} ->
        [
          item(
            "archive",
            source,
            nil,
            "gated",
            "Hermes cron path is not a directory; not archived"
          )
        ]

      {:error, _} ->
        []
    end
  end

  defp private_regular_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&match?({:ok, %File.Stat{type: :regular}}, File.lstat(&1)))
    |> Enum.sort()
  end

  defp cron_jobs(file) do
    parsed =
      case Path.extname(file) do
        ".json" -> with {:ok, body} <- File.read(file), do: Jason.decode(body)
        ext when ext in [".yaml", ".yml"] -> YamlElixir.read_from_file(file)
        _ -> :skip
      end

    jobs =
      case parsed do
        {:ok, list} when is_list(list) -> list
        {:ok, %{"jobs" => list}} when is_list(list) -> list
        {:ok, map} when is_map(map) -> [map]
        _ -> []
      end

    jobs
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn job ->
      for {k, v} <- job, k in @cron_fields, scalar?(v), into: %{}, do: {k, v}
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp write_private!(dest, content) do
    _ = File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, content)
    File.chmod!(dest, 0o600)
  end

  defp archive_item(ctx, source, dest, reason) do
    item("archive", source, dest, if(ctx.execute?, do: "archived", else: "planned"), reason)
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
          journal!(ctx, dest)
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
        journal!(ctx, target)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, Enum.join(merged, @entry_delimiter))

        if overflow != [] do
          overflow_path = overflow_path(ctx, kind)
          journal!(ctx, overflow_path)
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

        import_skill(ctx, source, renamed, false, "Imported under renamed folder", %{
          "renamed_from" => target
        })

      true ->
        import_skill(ctx, source, target, true, "Imported skill", %{})
    end
  end

  @skill_layout_dirs ~w(references templates scripts assets)
  @skill_text_dirs ~w(references scripts templates)
  @skill_text_exts ~w(.md .markdown .txt .rst .py .sh .bash .js .mjs .ts .rb .lua .sql .html .css .csv)

  # Stages the selected files in a private temp dir outside every skill root,
  # then hands the staged bundle to `LemonSkills.Installer.import_bundle/2`:
  # it audits that exact file set, refuses a blocked bundle, activates only the
  # audited files and records the skill as `community` / `pending`, so the
  # runtime audit and approval pipeline still judges it before it is trusted.
  defp import_skill(ctx, source, target, force, reason, details) do
    {files, asset_items, gated} = select_skill_files(ctx, source, target)

    if ctx.execute? do
      journal!(ctx, target)
      journal!(ctx, Path.join(Path.dirname(ctx.skill_dir), "skills.lock.json"))

      case stage_and_import(ctx, files, target, force) do
        {:ok, {verdict, findings}} ->
          [
            item(
              "skill",
              source,
              target,
              "migrated",
              reason <> "; audited and recorded as pending",
              audit_details(details, "pending", verdict, findings)
            )
            | asset_items ++ gated
          ]

        {:error, {:blocked, findings}} ->
          [
            item(
              "skill",
              source,
              nil,
              "blocked",
              "Skill blocked by the security audit; not imported",
              audit_details(details, "block", :block, findings)
            )
            | gated
          ]

        {:error, error} ->
          [
            item(
              "skill",
              source,
              nil,
              "error",
              "Skill import failed: #{inspect(error)}",
              Map.put(details, "audit_status", nil)
            )
            | gated
          ]
      end
    else
      [
        item(
          "skill",
          source,
          target,
          "planned",
          reason <> "; will be audited on import and recorded as pending",
          Map.put(details, "audit_status", "pending")
        )
        | asset_items ++ gated
      ]
    end
  end

  defp audit_details(details, status, verdict, findings) do
    Map.merge(details, %{
      "audit_status" => status,
      "audit_verdict" => Atom.to_string(verdict),
      "audit_findings" => findings
    })
  end

  defp stage_and_import(ctx, files, target, force) do
    staging =
      Path.join(System.tmp_dir!(), "lemon-hermes-skill-#{System.unique_integer([:positive])}")

    try do
      bundle = Path.join(staging, "bundle")

      with :ok <- File.mkdir(staging),
           :ok <- File.chmod(staging, 0o700),
           :ok <- write_staged_files(bundle, files) do
        case LemonSkills.Installer.import_bundle(bundle,
               agent_dir: Path.dirname(ctx.skill_dir),
               key: Path.basename(target),
               source_kind: :hermes,
               force: force
             ) do
          {:ok, _entry, audit} -> {:ok, audit}
          {:error, _} = error -> error
        end
      end
    after
      File.rm_rf(staging)
    end
  end

  defp write_staged_files(bundle, files) do
    Enum.reduce_while(files, :ok, fn {rel, bytes, mode}, :ok ->
      dest = Path.join(bundle, rel)

      with :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.write(dest, bytes, [:exclusive]),
           :ok <- File.chmod(dest, Bitwise.band(mode, 0o755)) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:stage_failed, rel, reason}}}
      end
    end)
  end

  # Selects recognised skill content: SKILL.md plus UTF-8 text files with a
  # known extension under references/, scripts/ or templates/. With
  # --include-skill-assets any other regular file inside the skill bundle
  # layout is selected too. Everything else is gated: files outside the
  # layout, hidden names, symlinks and special files are never staged, and a
  # file is read only while lstat shows the same regular file.
  defp select_skill_files(ctx, root, target) do
    {files, assets, gated} = select_skill_files(ctx, root, root, target, {[], [], []})
    {Enum.reverse(files), Enum.reverse(assets), Enum.reverse(gated)}
  end

  defp select_skill_files(ctx, root, dir, target, acc) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(acc, fn name, {files, assets, gated} = acc ->
      from = Path.join(dir, name)

      case File.lstat!(from) do
        %File.Stat{type: :directory} ->
          select_skill_files(ctx, root, from, target, acc)

        %File.Stat{type: :regular} ->
          rel = Path.relative_to(from, root)

          case read_regular(from) do
            {:ok, bytes, mode} ->
              case classify_skill_file(ctx, rel, bytes) do
                :recognised ->
                  {[{rel, bytes, mode} | files], assets, gated}

                :asset ->
                  asset =
                    item(
                      "skill_file",
                      from,
                      Path.join(target, rel),
                      if(ctx.execute?, do: "migrated", else: "planned"),
                      "Unrecognised skill asset imported because --include-skill-assets was given; review it for credentials"
                    )

                  {[{rel, bytes, mode} | files], [asset | assets], gated}

                {:gated, reason} ->
                  {files, assets, [gated_skill_file(from, reason) | gated]}
              end

            {:error, reason} ->
              {files, assets, [gated_skill_file(from, reason) | gated]}
          end

        _other ->
          {files, assets,
           [gated_skill_file(from, "Symlink or special file not imported") | gated]}
      end
    end)
  end

  defp classify_skill_file(ctx, rel, bytes) do
    cond do
      recognised_skill_file?(rel, bytes) ->
        :recognised

      ctx.include_skill_assets? and in_skill_layout?(rel) ->
        :asset

      ctx.include_skill_assets? ->
        {:gated,
         "Outside the skill bundle layout (SKILL.md plus references/, templates/, scripts/, assets/); not imported"}

      true ->
        {:gated,
         "Unrecognised skill asset not imported; review it, then rerun with --include-skill-assets to import assets inside the skill layout"}
    end
  end

  # Reads a file only while lstat shows the same single-link regular file: a
  # hard link (nlink > 1) is refused before any byte is read, since staging its
  # bytes as an ordinary copy would launder a host file into the bundle. The
  # opened handle must be that same inode with one link, and at most the
  # bundle byte cap plus one byte is read.
  defp read_regular(path) do
    max = LemonSkills.Bundle.max_file_bytes()

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: links}} when links > 1 ->
        {:error, "Hard-linked file not imported"}

      {:ok, %File.Stat{type: :regular, size: size}} when size > max ->
        {:error, "Larger than #{max} bytes; not imported"}

      {:ok, %File.Stat{type: :regular} = stat} ->
        case bounded_read(path, stat, max) do
          {:ok, bytes} -> {:ok, bytes, stat.mode}
          {:error, reason} when is_binary(reason) -> {:error, reason}
          _ -> {:error, "File changed while reading; not imported"}
        end

      _ ->
        {:error, "File changed while reading; not imported"}
    end
  end

  # file_info record: {:file_info, size, type, access, atime, mtime, ctime,
  #                    mode, links, major_device, minor_device, inode, uid, gid}
  defp bounded_read(path, %File.Stat{} = stat, max) do
    with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(fd),
             true <- elem(info, 2) == :regular,
             true <- {elem(info, 9), elem(info, 11)} == {stat.major_device, stat.inode},
             true <- elem(info, 8) == 1 || {:error, "Hard-linked file not imported"} do
          case :file.read(fd, max + 1) do
            {:ok, bytes} when byte_size(bytes) > max ->
              {:error, "Larger than #{max} bytes; not imported"}

            {:ok, bytes} ->
              {:ok, bytes}

            :eof ->
              {:ok, ""}

            error ->
              error
          end
        else
          {:error, _} = error -> error
          _ -> {:error, :changed}
        end
      after
        :file.close(fd)
      end
    end
  end

  defp recognised_skill_file?("SKILL.md", _bytes), do: true

  defp recognised_skill_file?(relative, bytes) do
    case Path.split(relative) do
      [dir | [_ | _] = rest] ->
        dir in @skill_text_dirs and not Enum.any?(rest, &String.starts_with?(&1, ".")) and
          Path.extname(relative) in @skill_text_exts and String.valid?(bytes)

      _ ->
        false
    end
  end

  defp in_skill_layout?(relative) do
    case Path.split(relative) do
      [dir | [_ | _] = rest] ->
        dir in @skill_layout_dirs and not Enum.any?(rest, &String.starts_with?(&1, "."))

      _ ->
        false
    end
  end

  defp gated_skill_file(path, reason), do: item("skill_file", path, nil, "gated", reason)

  defp patch_config_item(ctx, source, target, config) do
    content = if File.exists?(target), do: File.read!(target), else: ""
    providers = if is_map(config["providers"]), do: config["providers"], else: %{}

    url_items =
      Enum.flat_map(providers, fn {name, provider} ->
        url = if is_map(provider), do: provider_base_url(provider)

        if is_binary(url) and not safe_url?(url),
          do: [credential_url_item(source, target, "providers.#{name}.base_url")],
          else: []
      end)

    patched =
      case normalize_string(config["model"]) do
        nil -> content
        model -> patch_model(content, model)
      end

    patched = patch_providers(providers, patched)

    config_item =
      cond do
        patched == content ->
          item("config", source, target, "skipped", "No compatible Hermes config values found")

        not ctx.overwrite? and
            config_values_changed?(Toml.decode!(content), Toml.decode!(patched)) ->
          item(
            "config",
            source,
            target,
            "conflict",
            "Target config values exist and overwrite is disabled"
          )

        not ctx.execute? ->
          item("config", source, target, "planned", "Mapped compatible config.yaml values")

        true ->
          result =
            update_config_file(ctx, target, fn current ->
              if current == content, do: {:ok, patched}, else: {:error, :config_changed}
            end)

          case result do
            :ok ->
              item(
                "config",
                source,
                target,
                "migrated",
                "Mapped compatible config.yaml values into Lemon TOML"
              )

            {:error, reason} ->
              item("config", source, target, "error", config_failure_reason(reason))
          end
      end

    [config_item | url_items]
  end

  defp config_values_changed?(existing, patched) do
    Enum.any?(existing, fn {key, value} ->
      replacement = Map.get(patched, key)

      if is_map(value) and is_map(replacement),
        do: config_values_changed?(value, replacement),
        else: value != replacement
    end)
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
        url = provider_base_url(provider)

        acc
        |> maybe_upsert(table, "base_url", if(url && safe_url?(url), do: url))
        |> maybe_upsert(table, "api_key_secret", secret_name_for_provider(name))
      else
        acc
      end
    end)
  end

  defp patch_providers(_, content), do: content

  defp import_secret(ctx, name, value) do
    {table, key} = Map.fetch!(@secret_names, name)
    reference_path = String.split(table, ".") ++ [key]
    source = Path.join(ctx.source_root, ".env")

    entry = fn status, reason ->
      item("secret", source, name, status, reason, %{"name" => name}, true)
    end

    conflicting_reference? = fn config ->
      not ctx.overwrite? and get_in(config, reference_path) not in [nil, name]
    end

    with {:ok, store} <- secret_store_scope(ctx),
         {:ok, existing} <- read_target_config(ctx.config_path),
         {:ok, secrets} <- Secrets.list() do
      cond do
        conflicting_reference?.(existing) ->
          entry.("conflict", "Target #{table}.#{key} references a different credential")

        Enum.any?(secrets, &(&1.name == name)) ->
          entry.("conflict", existing_secret_reason(name))

        not ctx.execute? ->
          entry.("planned", "Allowlisted secret would be imported")

        true ->
          update_config = fn ->
            update_config_file(ctx, ctx.config_path, fn current ->
              with {:ok, config} <- Toml.decode(current) do
                if conflicting_reference?.(config),
                  do: {:error, :conflict},
                  else: {:ok, TomlPatch.upsert_string(current, table, key, name)}
              end
            end)
          end

          case write_secret_then_config(ctx, store, name, value, update_config) do
            :ok ->
              entry.("migrated", "Imported allowlisted secret")

            {:error, reason} ->
              entry.(secret_failure_status(reason), secret_failure_reason(reason))
          end
      end
    else
      {:outside, reason} -> entry.("gated", outside_store_reason(reason))
      {:error, _} -> entry.("error", "Could not inspect target config or Lemon secrets")
    end
  end

  defp existing_secret_reason(name) do
    "Target secret exists and is never replaced by migration (even with --overwrite); delete it first with `lemon secrets delete #{name}` to import"
  end

  # Secret migration writes the running store, so it is only allowed when that
  # store's physical database lies inside the target, is reached without
  # symlinks, and (when applying) is present in the pre-migration backup.
  # Returns the store identity recorded in the journal.
  defp secret_store_scope(ctx) do
    case LemonCore.Store.location() do
      {_backend, nil} ->
        store_identity()

      {_backend, db} ->
        physical = LemonCli.Backup.physical_path(db)
        target = LemonCli.Backup.physical_path(ctx.target_root)
        relative = Path.relative_to(physical, target)

        cond do
          not inside?(physical, target) ->
            {:outside, "the active secret store #{physical} is outside --target #{target}"}

          Path.relative_to(path(db), ctx.target_root) != relative ->
            {:outside, "the active secret store #{db} is reached through a symlink"}

          ctx.execute? and not covered_by_backup?(ctx[:backup_bundle], relative) ->
            {:outside,
             "the pre-migration backup does not include the active secret store (#{relative}); apply without --no-backup"}

          true ->
            {:ok, "sqlite:" <> physical}
        end
    end
  end

  defp covered_by_backup?(nil, _relative), do: false

  defp covered_by_backup?(bundle, relative),
    do:
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join([bundle, "data", relative])))

  # In-memory stores have no file; their identity is the running process.
  defp store_identity do
    case LemonCore.Store.location() do
      {_backend, nil} -> {:ok, "memory:" <> inspect(Process.whereis(LemonCore.Store))}
      {_backend, db} -> {:ok, "sqlite:" <> LemonCli.Backup.physical_path(db)}
    end
  end

  defp outside_store_reason(reason) do
    "Secret migration refused: #{reason}. Neither the pre-migration backup nor rollback would cover it"
  end

  # Creates the secret only if absent, then runs the conditional config update.
  # If the update fails, exactly the created value is deleted again; a failed
  # compensation is reported. Success is journaled with the store identity and
  # the value's incarnation so rollback can delete only that value.
  defp write_secret_then_config(ctx, store, name, value, update_config) do
    case Secrets.create(name, value, provider: "hermes_migration") do
      {:ok, %{incarnation: incarnation}} when is_binary(incarnation) ->
        case update_config.() do
          :ok ->
            append_journal!(ctx, %{
              "op" => "secret_created",
              "name" => name,
              "store" => store,
              "incarnation" => incarnation
            })

            :ok

          {:error, reason} ->
            case Secrets.delete_if_incarnation(name, incarnation) do
              :ok -> {:error, reason}
              {:error, undo} -> {:error, {:compensation_failed, reason, undo}}
            end
        end

      {:ok, _metadata} ->
        {:error, :missing_incarnation}

      {:error, _reason} = error ->
        error
    end
  end

  defp secret_failure_status(reason) when reason in [:already_exists, :conflict, :config_changed],
    do: "conflict"

  defp secret_failure_status(_reason), do: "error"

  defp secret_failure_reason(:already_exists),
    do: "secret appeared in the target during migration; it was not replaced"

  defp secret_failure_reason(reason) when reason in [:conflict, :config_changed],
    do: "secret not imported: #{config_failure_reason(reason)}"

  defp secret_failure_reason({:compensation_failed, reason, undo}) do
    "secret was created but #{config_failure_reason(reason)}, and removing the created secret failed (#{inspect(undo)}); it is still stored without a config reference, delete or reference it manually"
  end

  defp secret_failure_reason(reason),
    do: "secret not imported: #{config_failure_reason(reason)}"

  defp config_failure_reason(:conflict),
    do: "the target config gained a different credential reference during migration"

  defp config_failure_reason(:config_changed),
    do: "the target config changed during migration"

  defp config_failure_reason(reason),
    do: "config update or secret write failed (#{inspect(reason)})"

  # Re-reads the config, lets `fun` decide on the current content, and replaces
  # the file atomically. Journals the file before its first change.
  defp update_config_file(ctx, path, fun) do
    current =
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:ok, ""}
        error -> error
      end

    with {:ok, current} <- current,
         {:ok, patched} <- fun.(current) do
      if patched == current do
        :ok
      else
        journal!(ctx, path)
        atomic_write(ctx, path, patched)
      end
    end
  rescue
    e in [File.Error, Jason.DecodeError] -> {:error, Exception.message(e)}
  end

  # The new content is written into a freshly created private (0700) sibling
  # directory, so the temp file is unreachable by others whatever the umask.
  # The file is narrowed to 0600 (or the stricter existing mode), synced and
  # renamed into place on the same filesystem, then the directory is removed.
  defp atomic_write(ctx, path, content) do
    dir = Path.join(Path.dirname(path), ".lemon-migrate-#{System.unique_integer([:positive])}")
    tmp = Path.join(dir, Path.basename(path))

    mode =
      case File.stat(path) do
        {:ok, %File.Stat{mode: existing}} -> Bitwise.band(existing, 0o600)
        {:error, _} -> 0o600
      end

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.mkdir(dir),
           :ok <- File.chmod(dir, 0o700),
           {:ok, %File.Stat{type: :directory, mode: dir_mode}} <- File.lstat(dir),
           true <- Bitwise.band(dir_mode, 0o077) == 0,
           _ <- before_config_write(ctx, dir),
           {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]) do
        result =
          try do
            with :ok <- File.chmod(tmp, mode),
                 :ok <- IO.binwrite(io, content),
                 :ok <- :file.sync(io),
                 do: :ok
          after
            File.close(io)
          end

        with :ok <- result, do: File.rename(tmp, path)
      else
        {:ok, %File.Stat{}} -> {:error, :temp_dir_not_private}
        false -> {:error, :temp_dir_not_private}
        error -> error
      end
    after
      File.rm_rf(dir)
    end
  end

  # Test seam: observes the private directory before any content is written.
  defp before_config_write(ctx, dir) do
    case ctx[:before_config_write] do
      hook when is_function(hook, 1) -> hook.(dir)
      _ -> :ok
    end
  end

  defp import_session_documents(ctx, db_path) do
    # SQLite files are never journaled or raw-copied. Rollback removes the
    # database only if this migration created it; otherwise it points at the
    # pre-migration backup bundle, which holds a consistent snapshot.
    db = Path.join(ctx.store_dir, "memory.sqlite3")
    append_journal!(ctx, %{"op" => "database", "path" => db, "existed" => File.exists?(db)})

    # Migration runs offline (`LemonCli.Backup.with_offline_target/3` refuses
    # while a runtime uses the target), so this is the only memory writer. Each
    # document is confirmed; a timed-out write may still land, so it is
    # reported as outcome_unknown rather than migrated or failed.
    {:ok, store} =
      Store.start_link(
        name: :"hermes_migration_memory_#{System.unique_integer([:positive])}",
        path: ctx.store_dir
      )

    try do
      docs = session_docs(db_path)
      results = Enum.map(docs, &Store.put_sync(store, &1))
      [session_import_item(ctx, db_path, length(docs), results)]
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

  defp session_import_item(ctx, db_path, total, results) do
    destination = Path.join(ctx.store_dir, "memory.sqlite3")
    unknown = Enum.count(results, &match?({:error, {:timeout_or_down, _}}, &1))
    failed = Enum.count(results, &(&1 != :ok)) - unknown

    details = %{
      "count" => total - failed - unknown,
      "failed" => failed,
      "outcome_unknown" => unknown
    }

    cond do
      unknown > 0 ->
        item(
          "sessions",
          db_path,
          destination,
          "error",
          "outcome_unknown: #{unknown} of #{total} Hermes session imports may or may not " <>
            "have been written; inspect memory before re-running the migration",
          details
        )

      failed > 0 ->
        item(
          "sessions",
          db_path,
          destination,
          "error",
          "Could not import #{failed} of #{total} Hermes sessions",
          details
        )

      true ->
        item(
          "sessions",
          db_path,
          destination,
          "migrated",
          "Imported #{total} Hermes sessions as Lemon memory documents",
          %{"count" => total}
        )
    end
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

      {:error, reason} ->
        raise "could not open Hermes state.db: #{inspect(reason)}"
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

    %Document{
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
      "error" => Map.get(statuses, "error", 0),
      "unsupported" => Map.get(statuses, "unsupported", 0),
      "gated" => Map.get(statuses, "gated", 0),
      "blocked" => Map.get(statuses, "blocked", 0),
      "warning" => Map.get(statuses, "warning", 0)
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
      "error" => Map.get(statuses, "error", 0),
      "warning" => Map.get(statuses, "warning", 0)
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
    - unsupported: #{summary["unsupported"]}
    - gated: #{summary["gated"]}
    - blocked: #{summary["blocked"]}
    - warnings: #{summary["warning"]}
    #{skill_audit_markdown(report["items"])}
    Undo this migration with `lemon migrate hermes rollback #{report["output_dir"]}`.
    """
  end

  defp skill_audit_markdown(items) do
    rows =
      for %{"kind" => "skill", "details" => %{"audit_status" => status} = details} = item <-
            items do
        verdict =
          if details["audit_verdict"], do: " (audit verdict: #{details["audit_verdict"]})"

        "- #{Path.basename(item["source"])}: #{item["status"]}, audit status #{status || "none"}#{verdict}"
      end

    if rows == [], do: "", else: "\n## Skills\n\n" <> Enum.join(rows, "\n") <> "\n"
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
      _ = copy_path!(path, dest, overwrite: true)
      dest
    end
  end

  defp copy_path!(source, dest, opts) do
    _ = if File.exists?(dest) and Keyword.get(opts, :overwrite, false), do: File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))

    _ = if File.dir?(source), do: File.cp_r!(source, dest), else: File.cp!(source, dest)

    copy_mode!(source, dest)
  end

  # Copies keep the source permission bits so a 0600 file never lands 0644.
  defp copy_mode!(source, dest) do
    if File.dir?(source) do
      source
      |> File.ls!()
      |> Enum.each(&copy_mode!(Path.join(source, &1), Path.join(dest, &1)))
    end

    File.chmod!(dest, Bitwise.band(File.stat!(source).mode, 0o7777))
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
    table = "providers.#{name}"

    Enum.find_value(@secret_names, fn
      {secret, {^table, "api_key_secret"}} -> secret
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

  defp path(value), do: value |> Path.expand()

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp timestamp do
    DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
