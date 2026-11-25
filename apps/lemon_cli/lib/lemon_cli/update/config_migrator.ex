defmodule LemonCli.Update.ConfigMigrator do
  @moduledoc """
  Detects and migrates deprecated configuration sections.

  ## Deprecated sections

  | Old section | New location |
  |---|---|
  | `[agent]` and `[agent.<sub>]` | `[defaults]`, `[runtime]` and `[tui]` (see `LemonCore.Config.LegacyAgentMigration`) |
  | `[agents.<id>]` | `[profiles.<id>]` |
  | `[tools.*]` | `[runtime.tools.*]` |

  Engine selection, custom engine configuration, and `[runtime.cli]` are not
  migrated automatically. The preflight reports their exact paths because all
  subagent tasks now run natively.

  ## Usage

      # Check what would be migrated (dry run):
      {:needs_migration, issues} = ConfigMigrator.check(path)

      # Apply migration:
      {:ok, %{backup: backup, changes: changes}} = ConfigMigrator.migrate!(path)
  """

  alias LemonCore.Config.LegacyAgentMigration

  @type issue :: String.t()

  @removed_engine_keys MapSet.new([
                         "engine",
                         "default_engine",
                         "engine_preference",
                         "preferred_engine",
                         "preferred_engines",
                         "preferred-engine",
                         "preferred-engines",
                         "preferredEngine",
                         "preferredEngines",
                         "known_engines",
                         "known_engine",
                         "custom_engines",
                         "custom_engine",
                         "engine_registry",
                         "engine_module",
                         "engine_modules",
                         "engines",
                         "gateway_engines"
                       ])

  @doc """
  Checks the config at `path` for deprecated sections.

  Returns:
  - `:ok` — config is clean, no migration needed.
  - `{:needs_migration, issues}` — deprecated sections found; `issues` describes each one.
  - `{:error, reason}` — could not read or parse the file.
  """
  @spec check(String.t()) :: :ok | {:needs_migration, [issue()]} | {:error, term()}
  def check(path) do
    with {:ok, settings} <- load_toml(path) do
      case detect_deprecated(settings) do
        [] -> :ok
        issues -> {:needs_migration, issues}
      end
    end
  end

  @doc """
  Applies automated config migration to `path` in-place.

  Before the file is replaced, its original bytes are copied to a new
  `<path>.bak-<UTC timestamp>` with the same permissions; an existing backup is
  never overwritten. The new content replaces the file atomically, and only
  when the migrated settings pass removed-setting validation.

  Returns `{:ok, %{backup: path | nil, changes: [String.t()]}}` (`backup` is
  `nil` when there was nothing to rewrite) or `{:error, reason}`.
  """
  @spec migrate!(String.t()) ::
          {:ok, %{backup: String.t() | nil, changes: [String.t()]}} | {:error, term()}
  def migrate!(path) do
    expanded = Path.expand(path)

    with {:ok, content} <- read(expanded),
         {:ok, _settings} <- decode(content),
         {:ok, migrated, changes} <- apply_migrations(content),
         {:ok, settings} <- decode(migrated),
         :ok <- validate_migrated(settings) do
      if migrated == content do
        {:ok, %{backup: nil, changes: []}}
      else
        with {:ok, backup} <- backup(expanded, content),
             :ok <- atomic_write(expanded, migrated) do
          {:ok, %{backup: backup, changes: changes}}
        end
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp load_toml(path) do
    with {:ok, content} <- read(Path.expand(path)), do: decode(content)
  end

  defp detect_deprecated(settings) do
    deprecated_section_issues =
      []
      |> maybe_add_issue(
        is_map(settings["agent"]),
        "[agent] is deprecated. Its fields move to [defaults] (provider, model, thinking_level), [tui] (theme) and [runtime] (everything else)."
      )
      |> maybe_add_issue(
        is_map(settings["agents"]),
        "[agents.<id>] is deprecated. Use [profiles.<id>] instead."
      )
      |> maybe_add_issue(
        is_map(settings["tools"]),
        "[tools.*] is deprecated. Use [runtime.tools.*] instead."
      )
      |> maybe_add_issue(
        runtime_cli_present?(settings),
        "The [runtime.cli] section has been removed; all subagent tasks run natively."
      )
      |> Enum.reverse()

    deprecated_section_issues ++ deprecated_engine_issues(settings)
  end

  defp deprecated_engine_issues(settings) do
    settings
    |> find_engine_issues([], [])
    |> Enum.sort_by(&issue_path/1)
    |> Enum.map(&engine_issue/1)
  end

  defp find_engine_issues(value, path, issues) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce(issues, fn {key, child}, acc ->
      key = to_string(key)
      child_path = path ++ [key]

      acc =
        if MapSet.member?(@removed_engine_keys, key) do
          [child_path | acc]
        else
          acc
        end

      find_engine_issues(child, child_path, acc)
    end)
  end

  defp find_engine_issues(value, path, issues) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce(issues, fn {child, index}, acc ->
      find_engine_issues(child, path ++ [index], acc)
    end)
  end

  defp find_engine_issues(_value, _path, issues), do: issues

  defp issue_path(path), do: format_config_path(path)

  defp engine_issue(path) do
    key = List.last(path)
    path = format_config_path(path)

    if key in [
         "engines",
         "gateway_engines",
         "known_engines",
         "known_engine",
         "custom_engines",
         "custom_engine",
         "engine_registry",
         "engine_module",
         "engine_modules"
       ] do
      "#{path} config is no longer supported: custom LemonGateway.Engine support and external top-level engines have been removed. " <>
        "Top-level execution now uses native Lemon."
    else
      "#{path} is no longer supported: external top-level engine selection has been removed. " <>
        "Top-level execution now uses native Lemon."
    end
  end

  defp runtime_cli_present?(%{"runtime" => runtime}) when is_map(runtime),
    do: Map.has_key?(runtime, "cli")

  defp runtime_cli_present?(_settings), do: false

  defp format_config_path(path) do
    Enum.reduce(path, "", fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      key, "" -> key
      key, acc -> "#{acc}.#{key}"
    end)
  end

  defp maybe_add_issue(acc, false, _), do: acc
  defp maybe_add_issue(acc, true, issue), do: [issue | acc]

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp decode(content) do
    case Toml.decode(content) do
      {:ok, settings} -> {:ok, settings}
      {:error, reason} -> {:error, {:invalid_toml, reason}}
    end
  end

  defp validate_migrated(settings) do
    case LemonCore.Config.Validator.validate_deprecated_sections(settings) do
      :ok -> :ok
      {:error, errors} -> {:error, {:manual_steps_required, errors}}
    end
  end

  # Text-level TOML migration. Renames section headers to new names and moves
  # `[agent]` through `LegacyAgentMigration`, preserving comments and order.
  defp apply_migrations(content) do
    content = String.replace(content, "\r\n", "\n")

    {renamed, renames} =
      {content, []}
      |> rename(&migrate_agents_section/1, "[agents.*] → [profiles.*]")
      |> rename(&migrate_tools_section/1, "[tools.*] → [runtime.tools.*]")

    case LegacyAgentMigration.migrate_content(renamed) do
      {:ok, migrated, changes} ->
        {:ok, migrated, Enum.reverse(renames) ++ changes}

      :unchanged ->
        {:ok, renamed, Enum.reverse(renames)}

      {:error, reason} ->
        {:error, {:manual_steps_required, [LegacyAgentMigration.format_error(reason)]}}
    end
  end

  defp rename({content, changes}, fun, description) do
    case fun.(content) do
      ^content -> {content, changes}
      renamed -> {renamed, [description | changes]}
    end
  end

  # Renames [agents.x] → [profiles.x]
  defp migrate_agents_section(content) do
    String.replace(content, ~r/^\[agents\./m, "[profiles.")
  end

  # Renames [tools.x] → [runtime.tools.x] (standalone [tools] section)
  defp migrate_tools_section(content) do
    if Regex.match?(~r/^\[runtime\.tools/m, content) do
      content
    else
      String.replace(content, ~r/^\[tools\b/m, "[runtime.tools")
    end
  end

  defp backup(path, content) do
    stamp =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601(:basic)

    backup = unique_path("#{path}.bak-#{stamp}")

    case write_with_mode(backup, content, existing_mode(path)) do
      :ok -> {:ok, backup}
      {:error, reason} -> {:error, {:backup_failed, reason}}
    end
  end

  defp unique_path(candidate) do
    if File.exists?(candidate),
      do: unique_path("#{candidate}-#{System.unique_integer([:positive])}"),
      else: candidate
  end

  defp atomic_write(path, content) do
    temp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}"
      )

    with :ok <- write_with_mode(temp, content, existing_mode(path)),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp)
        {:error, {:write_failed, reason}}
    end
  end

  # The file is created empty and restricted before any content lands in it, so
  # a private config is never briefly readable under the default umask.
  defp write_with_mode(path, content, mode) do
    with :ok <- File.write(path, "", [:binary, :exclusive]),
         :ok <- File.chmod(path, mode) do
      File.write(path, content, [:binary])
    end
  end

  defp existing_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o777)
      _ -> 0o600
    end
  end
end
