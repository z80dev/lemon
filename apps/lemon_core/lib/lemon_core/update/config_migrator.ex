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

  Engine selection and custom engine configuration are not migrated automatically.
  The preflight reports their exact paths because top-level execution now uses native
  Lemon. CLI vendors under `[runtime.cli.<vendor>]` remain available through task
  delegation.

  ## Usage

      # Check what would be migrated (dry run):
      {:needs_migration, issues} = ConfigMigrator.check(path)

      # Apply migration:
      :ok = ConfigMigrator.migrate!(path)
  """

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
    deprecated_section_issues =
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

    deprecated_section_issues ++ deprecated_engine_issues(settings)
  end

  defp deprecated_engine_issues(settings) do
    settings
    |> find_engine_issues([], [])
    |> Enum.sort_by(&issue_path/1)
    |> Enum.map(&engine_issue/1)
  end

  defp find_engine_issues(_value, ["runtime", "cli" | _rest], issues), do: issues

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
        "Top-level execution now uses native Lemon; CLI vendors configured under [runtime.cli.<vendor>] remain available through task delegation."
    else
      "#{path} is no longer supported: external top-level engine selection has been removed. " <>
        "Top-level execution now uses native Lemon; CLI vendors configured under [runtime.cli.<vendor>] remain available through task delegation."
    end
  end

  defp format_config_path(path) do
    Enum.reduce(path, "", fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      key, "" -> key
      key, acc -> "#{acc}.#{key}"
    end)
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
    |> migrate_agent_section()
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

  # Rewrites the standalone [agent] section:
  #   - Fields provider/model/thinking_level move to [defaults]
  #   - All other fields move to [runtime]
  #   - The [agent] header itself is removed
  #
  # We do a line-by-line scan so we can route each key to the right section
  # without relying on a full TOML parser (preserving comments and order).
  defp migrate_agent_section(content) do
    lines = String.split(content, "\n")

    {result, pending_defaults, pending_runtime, _in_agent} =
      Enum.reduce(lines, {[], [], [], false}, fn line, {acc, defaults, runtime, in_agent} ->
        trimmed = String.trim(line)

        cond do
          # Start of [agent] section (not [agent.something])
          Regex.match?(~r/^\[agent\]/, trimmed) ->
            {acc, defaults, runtime, true}

          # Start of another top-level section — flush buffered agent keys
          in_agent and Regex.match?(~r/^\[/, trimmed) ->
            flushed = flush_agent_keys(acc, defaults, runtime)
            {flushed ++ [line], [], [], false}

          # Inside [agent]: route keys to their new homes
          in_agent ->
            cond do
              Regex.match?(~r/^(provider|model|thinking_level)\s*=/, trimmed) ->
                {acc, defaults ++ [line], runtime, true}

              # Comment or blank line inside [agent] — keep with runtime keys
              trimmed == "" or String.starts_with?(trimmed, "#") ->
                {acc, defaults, runtime ++ [line], true}

              true ->
                {acc, defaults, runtime ++ [line], true}
            end

          true ->
            {acc ++ [line], defaults, runtime, false}
        end
      end)

    # Flush any remaining buffered agent keys at EOF
    final = flush_agent_keys(result, pending_defaults, pending_runtime)
    Enum.join(final, "\n")
  end

  defp flush_agent_keys(acc, [], []), do: acc

  defp flush_agent_keys(acc, defaults, runtime) do
    defaults_block =
      if defaults != [] do
        ["", "[defaults]"] ++ defaults
      else
        []
      end

    runtime_block =
      if runtime != [] do
        # Filter out blank-only lines to avoid empty [runtime] sections
        non_blank = Enum.reject(runtime, &(String.trim(&1) == ""))

        if non_blank != [] do
          ["", "[runtime]"] ++ runtime
        else
          []
        end
      else
        []
      end

    acc ++ defaults_block ++ runtime_block
  end
end
