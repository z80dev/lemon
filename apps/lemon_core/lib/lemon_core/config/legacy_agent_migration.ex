defmodule LemonCore.Config.LegacyAgentMigration do
  @moduledoc """
  Moves the legacy `[agent]` table onto the canonical config sections.

  Earlier terminal clients persisted their default model and theme by
  rewriting `config.toml` with an `[agent]` table. Lemon reads such a file as
  a legacy alias, so it never stops the runtime from booting, and
  `LemonCore.Update.ConfigMigrator` rewrites the file when setup,
  `lemon config migrate` or an update runs.

  The mapping, shared by the in-memory alias and the file rewrite:

  | Legacy                          | Canonical                                   |
  |---------------------------------|---------------------------------------------|
  | `agent.default_provider`        | `defaults.provider`                         |
  | `agent.default_model`           | `defaults.model`                            |
  | `agent.default_thinking_level`  | `defaults.thinking_level`                   |
  | `agent.theme`                   | `tui.theme` (the terminal client's theme)   |
  | any other `agent.<key>`         | `runtime.<key>`, including `[agent.<sub>]`  |

  An existing `[defaults]` or `[runtime]` value wins over its legacy
  counterpart, matching how the runtime always resolved the two. The legacy
  theme wins over `[tui] theme` because the terminal client only ever read the
  legacy key.

  Content rewrites are textual (see `LemonCore.Config.TomlPatch`): comments and
  unrelated tables are kept. A rewrite is accepted only if the new text decodes
  to exactly the mapped settings; otherwise it is refused.
  """

  alias LemonCore.Config.TomlPatch
  alias LemonCore.MapHelpers

  @default_keys %{
    "default_provider" => "provider",
    "default_model" => "model",
    "default_thinking_level" => "thinking_level"
  }

  @typedoc "One-line human-readable description of a single move."
  @type change :: String.t()

  @doc "Returns true when decoded settings still contain an `[agent]` table."
  @spec legacy?(map()) :: boolean()
  def legacy?(settings) when is_map(settings), do: is_map(settings["agent"])

  @doc """
  Maps decoded settings with an `[agent]` table onto the canonical sections.
  Settings without one are returned unchanged.
  """
  @spec migrate_settings(map()) :: map()
  def migrate_settings(%{"agent" => agent} = settings) when is_map(agent) do
    {default_values, rest} = Map.split(agent, Map.keys(@default_keys))
    {theme, runtime_values} = Map.pop(rest, "theme")

    defaults =
      Enum.reduce(default_values, map_or_empty(settings["defaults"]), fn {legacy, value}, acc ->
        Map.put_new(acc, Map.fetch!(@default_keys, legacy), value)
      end)

    runtime = MapHelpers.deep_merge(runtime_values, map_or_empty(settings["runtime"]))
    tui = if is_nil(theme), do: nil, else: Map.put(map_or_empty(settings["tui"]), "theme", theme)

    settings
    |> Map.delete("agent")
    |> put_section("defaults", defaults)
    |> put_section("runtime", runtime)
    |> put_section("tui", tui)
  end

  def migrate_settings(settings) when is_map(settings), do: settings

  @doc """
  Rewrites TOML text so it no longer uses `[agent]`.

  Returns `:unchanged` when there is nothing to migrate and
  `{:error, reason}` when the file cannot be decoded or rewritten safely.
  """
  @spec migrate_content(String.t()) ::
          {:ok, String.t(), [change()]} | :unchanged | {:error, term()}
  def migrate_content(content) when is_binary(content) do
    content = String.replace(content, "\r\n", "\n")

    with {:ok, settings} <- decode(content) do
      if legacy?(settings), do: rewrite(content, settings), else: :unchanged
    end
  end

  @doc "Human-readable explanation of a `migrate_content/1` error."
  @spec format_error(term()) :: String.t()
  def format_error({:invalid_toml, _reason}), do: "the file is not valid TOML"

  def format_error(:unsupported_layout),
    do: "the [agent] table uses multi-line values or arrays of tables; move it by hand"

  def format_error(:verification_failed),
    do: "the rewritten file would not match the original settings; move [agent] by hand"

  def format_error(reason), do: inspect(reason)

  # ── rewrite ────────────────────────────────────────────────────────────────

  defp rewrite(content, settings) do
    expected = migrate_settings(settings)

    with {:ok, lines, entries, renamed} <- split_agent_tables(content) do
      {migrated, changes} =
        Enum.reduce(entries, {Enum.join(lines, "\n"), renamed}, fn entry, {acc, changes} ->
          place_entry(acc, entry, settings, changes)
        end)

      case decode(migrated) do
        {:ok, ^expected} -> {:ok, migrated, Enum.reverse(changes)}
        _ -> {:error, :verification_failed}
      end
    end
  end

  # Removes the `[agent]` header and its key lines (keeping its comments),
  # renames `[agent.<sub>]` headers to `[runtime.<sub>]`, and returns the
  # removed key/value entries for placement into their canonical tables.
  defp split_agent_tables(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.reduce_while({[], [], [], :outside}, fn line, {kept, entries, changes, state} ->
      case classify(line, state) do
        {:header, ["agent"]} ->
          {:cont, {kept, entries, changes, :agent_root}}

        {:header, ["agent" | sub]} ->
          header = "[" <> render_key(["runtime" | sub]) <> "]"
          change = "[#{render_key(["agent" | sub])}] → #{header}"
          {:cont, {[header | kept], entries, [change | changes], :outside}}

        {:header, _other} ->
          {:cont, {[line | kept], entries, changes, :outside}}

        :agent_array_header ->
          {:halt, {:error, :unsupported_layout}}

        {:entry, key, value} ->
          {:cont, {kept, [{key, value} | entries], changes, state}}

        :blank_in_agent ->
          {:cont, {kept, entries, changes, state}}

        :unsupported ->
          {:halt, {:error, :unsupported_layout}}

        :keep ->
          {:cont, {[line | kept], entries, changes, state}}
      end
    end)
    |> case do
      {:error, _reason} = error ->
        error

      {kept, entries, changes, _state} ->
        {:ok, Enum.reverse(kept), Enum.reverse(entries), changes}
    end
  end

  defp classify(line, state) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "[[") ->
        if array_header_under_agent?(trimmed), do: :agent_array_header, else: header_or_keep(line)

      String.starts_with?(trimmed, "[") ->
        header_or_keep(line)

      state != :agent_root ->
        :keep

      trimmed == "" ->
        :blank_in_agent

      String.starts_with?(trimmed, "#") ->
        :keep

      true ->
        entry(trimmed)
    end
  end

  defp header_or_keep(line) do
    case TomlPatch.header_path(line) do
      {:ok, path} -> {:header, path}
      :error -> :keep
    end
  end

  defp array_header_under_agent?(trimmed) do
    case Regex.run(~r/^\[\[(.+)\]\]\s*(?:#.*)?$/, trimmed, capture: :all_but_first) do
      [body] -> match?({:ok, ["agent" | _]}, TomlPatch.parse_dotted_key(body))
      _ -> false
    end
  end

  # A single-line `key = value`; anything else inside `[agent]` (multi-line
  # strings or arrays) is left for the user to move.
  defp entry(trimmed) do
    with [key_text, value] <- split_key_value(trimmed),
         {:ok, key} <- TomlPatch.parse_dotted_key(key_text),
         true <- single_line_value?(value) do
      {:entry, key, value}
    else
      _ -> :unsupported
    end
  end

  defp split_key_value(line) do
    case Regex.run(~r/^((?:"(?:[^"\\]|\\.)*+"|'[^']*+'|[^='"])++)\s*=\s*(.+)$/, line,
           capture: :all_but_first
         ) do
      [key, value] -> [key, value]
      _ -> :error
    end
  end

  defp single_line_value?(value) do
    not String.starts_with?(value, ~s(""")) and not String.starts_with?(value, "'''") and
      balanced_brackets?(value)
  end

  defp balanced_brackets?(value) do
    value
    |> String.replace(~r/"(?:[^"\\]|\\.)*"|'[^']*'/, "")
    |> String.replace(~r/#.*$/, "")
    |> String.graphemes()
    |> Enum.reduce(0, fn
      char, depth when char in ["[", "{"] -> depth + 1
      char, depth when char in ["]", "}"] -> depth - 1
      _char, depth -> depth
    end)
    |> Kernel.==(0)
  end

  defp place_entry(content, {[legacy], value}, settings, changes)
       when is_map_key(@default_keys, legacy) do
    key = Map.fetch!(@default_keys, legacy)

    if Map.has_key?(map_or_empty(settings["defaults"]), key) do
      {content, ["agent.#{legacy} dropped: defaults.#{key} is already set" | changes]}
    else
      {TomlPatch.upsert_raw_line(content, "defaults", key, "#{key} = #{value}"),
       ["agent.#{legacy} → defaults.#{key}" | changes]}
    end
  end

  defp place_entry(content, {["theme"], value}, _settings, changes) do
    {TomlPatch.upsert_raw_line(content, "tui", "theme", "theme = #{value}"),
     ["agent.theme → tui.theme" | changes]}
  end

  defp place_entry(content, {[first | _] = key, value}, settings, changes) do
    name = render_key(key)
    existing = Map.get(map_or_empty(settings["runtime"]), first)

    if not is_nil(existing) and not is_map(existing) do
      {content, ["agent.#{name} dropped: runtime.#{first} is already set" | changes]}
    else
      {TomlPatch.upsert_raw_line(content, "runtime", name, "#{name} = #{value}"),
       ["agent.#{name} → runtime.#{name}" | changes]}
    end
  end

  defp render_key(segments) do
    Enum.map_join(segments, ".", fn segment ->
      if Regex.match?(~r/^[A-Za-z0-9_-]+$/, segment), do: segment, else: inspect(segment)
    end)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp decode(content) do
    case Toml.decode(content) do
      {:ok, settings} -> {:ok, settings}
      {:error, reason} -> {:error, {:invalid_toml, reason}}
    end
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp put_section(settings, _name, nil), do: settings

  defp put_section(settings, _name, section) when section == %{}, do: settings

  defp put_section(settings, name, section), do: Map.put(settings, name, section)
end
