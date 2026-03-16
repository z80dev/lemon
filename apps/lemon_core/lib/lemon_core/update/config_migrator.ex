defmodule LemonCore.Update.ConfigMigrator do
  @moduledoc """
  Detects and migrates deprecated configuration sections.

  ## Deprecated sections

  | Old section | New location |
  |---|---|
  | `[agent]` fields | `[defaults]` (provider, model, thinking_level) or `[runtime]` |
  | `[agents.<id>]` | `[profiles.<id>]` |
  | `[agent.tools.*]` | `[runtime.tools.*]` |
  | `[tools.*]` | `[runtime.tools.*]` |

  ## Usage

      # Check what would be migrated (dry run):
      {:needs_migration, issues} = ConfigMigrator.check(path)

      # Apply migration:
      :ok = ConfigMigrator.migrate!(path)
  """

  alias LemonCore.Config.Modular

  @type issue :: String.t()

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

  Creates a backup at `<path>.pre-update-bak` before writing.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec migrate!(String.t()) :: :ok | {:error, term()}
  def migrate!(path) do
    expanded = Path.expand(path)

    with {:ok, content} <- File.read(expanded),
         {:ok, _settings} <- Toml.decode(content),
         :ok <- backup!(expanded, content) do
      migrated = apply_migrations(content)

      case File.write(expanded, migrated) do
        :ok -> :ok
        {:error, reason} -> {:error, {:write_failed, reason}}
      end
    end
  end

  @doc """
  Returns the backup path for a given config path.
  """
  @spec backup_path(String.t()) :: String.t()
  def backup_path(path), do: "#{Path.expand(path)}.pre-update-bak"

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp load_toml(path) do
    case File.read(Path.expand(path)) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, settings} -> {:ok, settings}
          {:error, reason} -> {:error, {:invalid_toml, reason}}
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp detect_deprecated(settings) do
    []
    |> maybe_add_issue(
      is_map(settings["agent"]),
      "[agent] is deprecated. Move fields to [defaults] (provider, model, thinking_level) and [runtime]."
    )
    |> maybe_add_issue(
      is_map(settings["agents"]),
      "[agents.<id>] is deprecated. Use [profiles.<id>] instead."
    )
    |> maybe_add_issue(
      is_map(settings["agent"]) and is_map(get_in(settings, ["agent", "tools"])),
      "[agent.tools.*] is deprecated. Use [runtime.tools.*] instead."
    )
    |> maybe_add_issue(
      is_map(settings["tools"]),
      "[tools.*] is deprecated. Use [runtime.tools.*] instead."
    )
    |> Enum.reverse()
  end

  defp maybe_add_issue(acc, false, _), do: acc
  defp maybe_add_issue(acc, true, issue), do: [issue | acc]

  defp backup!(path, content) do
    bak = backup_path(path)

    case File.write(bak, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:backup_failed, reason}}
    end
  end

  # Text-level TOML migration. Renames section headers to new names.
  # This preserves comments and formatting, only touching deprecated headers.
  defp apply_migrations(content) do
    content
    |> migrate_agents_section()
    |> migrate_tools_section()
    |> migrate_agent_tools_section()
  end

  # Renames [agents.x] → [profiles.x]
  defp migrate_agents_section(content) do
    String.replace(content, ~r/^\[agents\./m, "[profiles.")
  end

  # Renames [tools.x] → [runtime.tools.x] (standalone [tools] section)
  defp migrate_tools_section(content) do
    String.replace(content, ~r/^\[tools\b/m, "[runtime.tools")
  end

  # Renames [agent.tools.x] → [runtime.tools.x]
  defp migrate_agent_tools_section(content) do
    String.replace(content, ~r/^\[agent\.tools\b/m, "[runtime.tools")
  end
end
