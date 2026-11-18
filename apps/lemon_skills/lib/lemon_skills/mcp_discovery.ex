defmodule LemonSkills.McpDiscovery do
  @moduledoc """
  ## Profile HTTP inventories

  Destination-local, temporary discovery of a profile HTTP MCP server.

  Uses the profile definition validator and owner-bound MCP session services.
  Header secret references resolve only on this host through the encrypted store.
  The invoking process owns the random session; all clients are released on
  completion, failure or owner death. Results contain no connection definitions.
  `name` is the exact raw remote selector; `executionName` is the stable native
  policy/runtime alias for this public server endpoint and raw name. Aliases
  include URL path/query identity but never headers, credentials or DNS pins.
  `readOnly` is advisory metadata, true only for explicit boolean `readOnlyHint:
  true`; it cannot grant execution or weaken native tool-policy requirements.

  Inventories are limited to 256 tools, 128-byte names, 4096-byte descriptions,
  32-KiB complete input schemas, and a 1-MiB encoded response. Schemas have at
  most 24 JSON nesting levels; aggregate JSON items are bounded to 131,072 with
  room reserved for transport envelopes. Invalid or oversized schemas/tools are
  skipped with `truncated: true`, never truncated or modified. Credential-bearing
  raw names/schemas are skipped; credential-bearing server labels fail closed.
  Descriptions are scrubbed before truncation or projection.

  ## External server configuration

  Imports MCP server definitions from other coding tools' configuration files.

  Each discovered server is translated into Lemon's JSON entry shape (the same
  shape `.lemon/mcp.json` uses) and handed to `LemonSkills.Config`, which parses,
  merges and validates it like any other configured server. Discovery never
  writes to another tool's files.

  ## Providers

  Providers are read in omp's priority order. Within a provider, project entries
  (relative to the requesting project directory) precede user entries:

  | Provider | Project | User |
  | --- | --- | --- |
  | `omp` | `.omp/mcp.json`, `.omp/.mcp.json` | `~/.omp/agent/mcp.json`, `~/.omp/agent/.mcp.json` |
  | `claude` | `.claude/.mcp.json` or `.claude/mcp.json` | `~/.claude.json` (`projects[<cwd>]`, then top level) or `~/.claude/mcp.json` |
  | `codex` | `.codex/config.toml` | `~/.codex/config.toml` |
  | `gemini` | `.gemini/settings.json` | `~/.gemini/settings.json` |
  | `opencode` | `opencode.json[c]`, `.opencode/opencode.json[c]` | `~/.config/opencode/opencode.json[c]` |
  | `cursor` | `.cursor/mcp.json` | `~/.cursor/mcp.json` |
  | `windsurf` | `.windsurf/mcp_config.json` | `~/.codeium/windsurf/mcp_config.json` |
  | `vscode` | `.vscode/mcp.json` | — |
  | `mcp-json` | `mcp.json`, `.mcp.json` | — |

  The first name wins; a disabled entry still claims its name.

  ## Project trust

  Project files come from the requested directory, which may be an untrusted
  clone, so nothing from them is imported until the operator trusts that
  project (`lemon mcp trust`): neither other tools' servers nor the project's
  own `.lemon/mcp.json` (`project_config/2`). The trust record lives in the
  operator's agent directory (`LemonSkills.McpConfig.trust_project/2`), never in
  the project, and binds the project path to a digest of `.lemon/mcp.json` and
  every project file in the table above, including absent ones. Editing, adding
  or removing any of them revokes trust until it is granted again for the new
  digest. Until then nothing is spawned or connected; `project_status/2` reports
  the pending files, a bounded redacted preview of each server's command or URL,
  and its findings. Trusted servers carry `%{project:, digest:}` provenance that
  `LemonSkills.McpSource` re-checks with `project_trusted?/1` before every spawn
  or reconnect.

  Project files are read once per call (regular files up to 1 MiB) and the same
  bytes are both digested and parsed. A project `.lemon/mcp.json` entry naming
  OAuth `client_secret_secret` or `token_secret` is rejected, trusted or not.

  ## Switches

  Discovery is on unless `config :lemon_skills, :mcp_external_discovery, false`
  or `LEMON_MCP_EXTERNAL_DISCOVERY` is `0`/`false`/`no`; either switch disables
  trusted project servers too. User-level files of other tools (`claude`,
  `codex`, `gemini`, `opencode`, `cursor`, `windsurf`) additionally require
  `config :lemon_skills, :mcp_external_user_discovery, true` or
  `LEMON_MCP_EXTERNAL_USER_DISCOVERY=1`; a set `CLAUDE_CONFIG_DIR` opts in the
  Claude Code user files. The omp user file is read by default.

  User-level files are read from `config :lemon_skills, :mcp_discovery_home`
  when set, otherwise from the user's home directory unless an agent-directory
  override isolates the runtime (see `LemonSkills.Config.mcp_discovery_home/0`).

  ## Values

  Only user-level files read host values. There, `${VAR}` and `${VAR:-default}`
  are expanded in the JSON-based provider files (not Codex or OpenCode);
  unresolved placeholders stay literal. OpenCode files use OpenCode's own
  `{env:VAR}` / `{file:path}` substitution and accept JSONC. Substitution runs
  once on decoded string values: environment bytes stay exact, file contents are
  trimmed, and inserted text is never expanded again. Codex `env_vars`,
  `env_http_headers` and `bearer_token_env_var` read the current environment.

  Project files never read host environment variables or files, trusted or
  not: a project server whose values contain `${...}`, `{env:...}` or
  `{file:...}`, or a Codex project server with `env_vars`, `env_http_headers` or
  `bearer_token_env_var`, is rejected with a `host_value_reference` finding.
  VS Code's `${workspaceFolder}` is the project directory and is still replaced.

  Imported entries carry command, arguments, environment, working directory,
  URL, headers, timeouts and tool filters; tool-specific OAuth/auth blocks are
  not imported.
  """

  alias LemonCore.{JSONPayload, ProfileStore, Redact}
  alias LemonSkills.{Config, McpConfig, McpSession, McpSource}

  @max_tools 256
  @max_schema 32_768
  @max_result 1_048_576
  @max_items 131_072
  @max_schema_depth 24

  @type scope :: :project | :global
  @type source :: %{provider: String.t(), scope: scope()}
  @type server :: %{name: String.t(), entry: map(), enabled: boolean(), source: source()}

  @providers [:omp, :claude, :codex, :gemini, :opencode, :cursor, :windsurf, :vscode, :mcp_json]
  @falsy ["0", "false", "FALSE", "False", "no", "NO", "No"]
  @truthy ["1", "true", "TRUE", "True", "yes", "YES", "Yes"]
  @env_placeholder ~r/\$\{([^}:]+)(:-([^}]*))?\}/
  @foreign_user_configs [
    ".claude/mcp.json",
    ".claude/.mcp.json",
    ".codex/config.toml",
    ".gemini/settings.json",
    ".cursor/mcp.json",
    ".config/opencode/opencode.json",
    ".config/opencode/opencode.jsonc",
    ".codeium/windsurf/mcp_config.json"
  ]

  # Every project-relative file read for a project, Lemon's own included; the
  # trust digest covers all of them, present or absent, in this order.
  @project_configs [
    ".lemon/mcp.json",
    ".omp/mcp.json",
    ".omp/.mcp.json",
    ".claude/.mcp.json",
    ".claude/mcp.json",
    ".codex/config.toml",
    ".gemini/settings.json",
    "opencode.json",
    "opencode.jsonc",
    ".opencode/opencode.json",
    ".opencode/opencode.jsonc",
    ".cursor/mcp.json",
    ".windsurf/mcp_config.json",
    ".vscode/mcp.json",
    "mcp.json",
    ".mcp.json"
  ]
  @max_config_bytes 1_048_576
  @host_placeholder ~r/\$\{[^}]*\}/
  @opencode_directive ~r/\{(env|file):([^}]+)\}/
  @codex_host_keys ["env_vars", "env_http_headers", "bearer_token_env_var"]
  @max_preview_servers 64
  @max_finding_keys 8
  @preview_bytes 200
  @label_bytes 512
  @unsafe_text ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  # Lemon OAuth keys that resolve host secrets (encrypted store/env fallback, or
  # a persisted token cache); a project file may never name them.
  @lemon_oauth_host_keys [
    "client_secret_secret",
    "client-secret-secret",
    "token_secret",
    "token-secret"
  ]

  @doc """
  Pure, validated projection of raw tool names to profile-native execution names.

  Accepts only the public server `name` and `url`, plus at most 256 unique raw
  names. Uses the same canonical validation and alias identity as actual profile
  attachment, but never starts clients, resolves DNS or reads secret references.
  This projection is not discovery or authorization: callers must still retain
  their closed native tool-policy floor and explicit execution approval gates.
  """
  @spec execution_names(map(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def execution_names(server, raw_names) do
    with true <- public_server?(server),
         {:ok, [server]} <- ProfileStore.normalize_mcp_servers([server]),
         true <- Redact.text(server["name"], drop_keys: true) == server["name"] do
      if valid_projection_names?(raw_names) do
        tools =
          Enum.map(raw_names, fn raw_name ->
            %{
              "name" => raw_name,
              "executionName" => McpSource.execution_name(server["name"], server["url"], raw_name)
            }
          end)

        {:ok,
         %{"server" => %{"name" => server["name"]}, "tools" => tools, "count" => length(tools)}}
      else
        {:error, :invalid_tool_names}
      end
    else
      _ -> {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :invalid_config}
  catch
    _, _ -> {:error, :invalid_config}
  end

  defp public_server?(server) when is_map(server) and map_size(server) == 2 do
    Enum.all?(server, fn {key, value} ->
      key in ["name", "url", :name, :url] and is_binary(value) and String.valid?(value) and
        not String.contains?(value, "${LEMON_SECRET:")
    end)
  end

  defp public_server?(_), do: false

  defp valid_projection_names?(names) when is_list(names) and length(names) <= @max_tools do
    Enum.all?(names, fn name ->
      McpSource.valid_remote_name?(name) and Redact.text(name, drop_keys: true) == name
    end) and MapSet.size(MapSet.new(names)) == length(names)
  end

  defp valid_projection_names?(_), do: false

  @doc """
  Discover a profile HTTP tool inventory from a server definition and cwd, or
  import external server configurations from a cwd and keyword options.

  External discovery accepts `nil` to read only user-level files. Options:
  `:home` (defaults to `LemonSkills.Config.mcp_discovery_home/0`),
  `:user_sources` (defaults to `user_sources_enabled?/0`) and
  `:claude_config_dir` (defaults to `CLAUDE_CONFIG_DIR`). Imported servers are
  returned in precedence order; duplicate names are retained for the caller's
  first-name-wins merge. Project servers are returned only while the operator's
  trust record matches the current project digest (see `project_status/2`).
  Configuration import never opens MCP sessions.
  """
  @spec discover(String.t() | nil, keyword()) :: [server()]
  @spec discover(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def discover(server_or_cwd, cwd_or_opts \\ [])

  def discover(server, cwd) when is_map(server) or not is_list(cwd) do
    case ProfileStore.normalize_mcp_servers([server]) do
      {:ok, [server]} ->
        id = "mcp-discovery-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        try do
          # Discovery reads the raw inventory but never installs executable tools.
          with :ok <- McpSession.open_http(id, cwd, [Map.put(server, "enabledTools", [])], self()),
               {:ok, tools} <- McpSession.remote_tools(id) do
            {:ok, project(server, tools)}
          end
        after
          McpSession.close(id)
        end

      _ ->
        {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :discovery_failed}
  catch
    _, _ -> {:error, :discovery_failed}
  end

  def discover(cwd, opts) when (is_binary(cwd) or is_nil(cwd)) and is_list(opts) do
    ctx = context(cwd, opts)
    trusted? = project_trust(ctx) == :trusted

    for %{source: %{scope: scope}} = server <- imports(ctx),
        scope != :project or trusted?,
        do: server
  end

  @doc """
  Everything the project in `cwd` may contribute to `LemonSkills.Config`, read
  from one snapshot of the project files.

  `lemon` is the project `.lemon/mcp.json` document (servers, overrides and the
  `enabled` flag), or `%{}` unless the project is trusted; entries carrying
  host-secret references are removed. `servers` are the imported servers of
  `discover/2`, empty while external discovery is disabled. `provenance` is
  `%{project:, digest:}` for a trusted project and `nil` otherwise; consumers
  attach it to project-origin servers so connection setup can re-check trust
  with `project_trusted?/1`. `trust` is the state from `project_status/2`.
  """
  @spec project_config(String.t() | nil, keyword()) :: %{
          lemon: map(),
          servers: [server()],
          provenance: %{project: String.t(), digest: String.t()} | nil,
          trust: :none | :untrusted | :changed | :trusted
        }
  def project_config(cwd, opts \\ []) when is_binary(cwd) or is_nil(cwd) do
    ctx = context(cwd, opts)
    trust = project_trust(ctx)
    trusted? = trust == :trusted

    servers =
      if enabled?(),
        do:
          for(
            %{source: %{scope: s}} = server <- imports(ctx),
            s != :project or trusted?,
            do: server
          ),
        else: []

    %{
      lemon: if(trusted?, do: elem(lemon_document(ctx), 0), else: %{}),
      servers: servers,
      provenance: if(trusted?, do: %{project: ctx.cwd, digest: ctx.digest}),
      trust: trust
    }
  end

  @doc """
  Whether a project-origin server's provenance is still valid: the project's
  files still hash to `digest`, the operator's record still trusts exactly that
  digest and, for other tools' files (`external: true`), external discovery is
  still enabled. Connection setup calls this before every spawn or reconnect.
  """
  @spec project_trusted?(%{project: String.t(), digest: String.t(), external: boolean()}) ::
          boolean()
  def project_trusted?(%{project: project, digest: digest, external: external})
      when is_binary(project) and is_binary(digest) do
    ctx = context(project, [])
    (external != true or enabled?()) and ctx.digest == digest and project_trust(ctx) == :trusted
  end

  def project_trusted?(_provenance), do: false

  @doc false
  # Before an operator writes the project `.lemon/mcp.json` (lemon mcp add,
  # remove, enable, disable): when the project is trusted, or has no project
  # files yet, return `fn original, written -> digest | nil end` giving the
  # digest after replacing `original` (the bytes the writer loaded under its
  # lock, `nil` when absent) with `written`. It returns `nil` when `original` is
  # not what this snapshot saw. Otherwise `nil`: an operator edit never trusts
  # repository content it did not review.
  @spec operator_lemon_write(String.t()) :: (binary() | nil, binary() -> String.t() | nil) | nil
  def operator_lemon_write(cwd) when is_binary(cwd) do
    ctx = context(cwd, [])

    if project_trust(ctx) in [:trusted, :none] do
      target = lemon_path(ctx)
      seen = Map.get(ctx.files_read, target)

      fn original, written ->
        if seen == if(original, do: {:ok, original}, else: :absent) do
          ctx.entries
          |> Enum.map(fn
            {relative, ^target, _state} -> {relative, target, {:ok, written}}
            entry -> entry
          end)
          |> digest()
        end
      end
    end
  end

  @doc """
  Trust state of the project MCP files in `cwd` (`.lemon/mcp.json` and other
  tools' project files), without importing them.

  Returns the expanded `project` path, its terminal-safe bounded `label`, a
  shell-quoted `cwd_arg` for command suggestions (`nil` when the path cannot be
  shown safely, e.g. it contains control characters), the project-relative
  `files` present, the `digest` that `LemonSkills.McpConfig.trust_project/2`
  must be given (`nil` when no project file exists) and `trust`: `:none` (no
  project files), `:untrusted`, `:changed` (a record exists for a different
  digest) or `:trusted`.

  `servers` previews at most #{@max_preview_servers} project servers with a
  bounded, redacted, single-line command or URL (URLs without credentials,
  query or fragment). `findings` contains `untrusted_project_config` while trust
  is pending and one `host_value_reference` per rejected server. Accepts the
  same options as `discover/2`. Never spawns, connects or reads host values.
  """
  @spec project_status(String.t(), keyword()) :: %{
          project: String.t(),
          label: String.t(),
          cwd_arg: String.t() | nil,
          digest: String.t() | nil,
          files: [String.t()],
          trust: :none | :untrusted | :changed | :trusted,
          servers: [map()],
          findings: [map()]
        }
  def project_status(cwd, opts \\ []) when is_binary(cwd) and is_list(opts) do
    ctx = context(cwd, opts)
    trust = project_trust(ctx)
    imports = if ctx.digest, do: imports(ctx), else: []
    {lemon, lemon_rejected} = lemon_document(ctx)

    pending =
      if trust in [:untrusted, :changed],
        do: [%{"reason" => "untrusted_project_config", "files" => ctx.files}],
        else: []

    lemon_servers =
      for %{"type" => type} = entry <- List.wrap(lemon["servers"]),
          type in ["stdio", "http", "sse"],
          do:
            preview(%{
              name: entry["name"],
              entry: entry,
              enabled: true,
              source: %{provider: "lemon"}
            })

    %{
      project: ctx.cwd,
      label: display(ctx.cwd, @label_bytes),
      cwd_arg: shell_arg(ctx.cwd),
      digest: ctx.digest,
      files: ctx.files,
      trust: trust,
      servers:
        (lemon_servers ++
           for(%{source: %{scope: :project}} = server <- imports, do: preview(server)))
        |> Enum.take(@max_preview_servers),
      findings: pending ++ lemon_rejected ++ for({:rejected, finding} <- imports, do: finding)
    }
  end

  defp context(cwd, opts) do
    home = Keyword.get_lazy(opts, :home, &Config.mcp_discovery_home/0)
    user_sources = Keyword.get_lazy(opts, :user_sources, &user_sources_enabled?/0)
    boundary_home = home || System.user_home()

    user_config_paths =
      if not user_sources and boundary_home,
        do: MapSet.new(@foreign_user_configs, &Path.expand(&1, boundary_home)),
        else: MapSet.new()

    ctx = %{
      cwd: if(is_binary(cwd), do: Path.expand(cwd)),
      home: home,
      user_sources: user_sources,
      user_config_paths: user_config_paths,
      claude_config_dir:
        Keyword.get_lazy(opts, :claude_config_dir, fn -> System.get_env("CLAUDE_CONFIG_DIR") end)
    }

    Map.merge(ctx, snapshot(ctx))
  end

  defp imports(ctx), do: Enum.flat_map(@providers, &provider(&1, ctx))

  # Read each project file once; the digested bytes are the parsed bytes.
  defp snapshot(%{cwd: nil}), do: %{entries: [], files_read: %{}, files: [], digest: nil}

  defp snapshot(ctx) do
    entries =
      for relative <- @project_configs,
          path <- project_path(ctx, Path.split(relative)),
          do: {relative, path, read_project_file(path)}

    %{
      entries: entries,
      files_read: Map.new(entries, fn {_relative, path, state} -> {path, state} end),
      files: for({relative, _path, state} <- entries, state != :absent, do: relative),
      digest: digest(entries)
    }
  end

  defp digest(entries) do
    if Enum.all?(entries, &match?({_, _, :absent}, &1)) do
      nil
    else
      entries
      |> Enum.map(fn {relative, _path, state} -> [relative, 0, digest_part(state), 0] end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defp read_project_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_config_bytes ->
        case File.read(path) do
          {:ok, bytes} when byte_size(bytes) <= @max_config_bytes -> {:ok, bytes}
          {:error, reason} when reason in [:enoent, :enotdir] -> :absent
          _ -> :invalid
        end

      {:error, reason} when reason in [:enoent, :enotdir] ->
        :absent

      _ ->
        :invalid
    end
  end

  defp digest_part({:ok, bytes}), do: ["file:", :crypto.hash(:sha256, bytes)]
  defp digest_part(state), do: Atom.to_string(state)

  defp project_trust(%{digest: nil}), do: :none

  defp project_trust(%{cwd: cwd, digest: digest}) do
    case McpConfig.project_trust(cwd) do
      ^digest -> :trusted
      nil -> :untrusted
      _other -> :changed
    end
  end

  defp lemon_path(%{cwd: nil}), do: nil
  defp lemon_path(%{cwd: cwd}), do: Config.project_mcp_config_file(cwd)

  # The project `.lemon/mcp.json` from the snapshot, minus servers that would
  # resolve host secrets (encrypted-store/env OAuth client secrets, token caches).
  defp lemon_document(%{cwd: nil}), do: {%{}, []}

  defp lemon_document(ctx) do
    case read_json(ctx, lemon_path(ctx)) do
      %{"servers" => servers} = document when is_list(servers) ->
        {kept, rejected} =
          Enum.reduce(servers, {[], []}, fn entry, {kept, rejected} ->
            case lemon_host_keys(entry) do
              [] -> {[entry | kept], rejected}
              keys -> {kept, rejected ++ rejected(entry["name"], "lemon", keys)}
            end
          end)

        {Map.put(document, "servers", Enum.reverse(kept)),
         for({:rejected, finding} <- rejected, do: finding)}

      %{} = document ->
        {document, []}

      nil ->
        {%{}, []}
    end
  end

  defp lemon_host_keys(%{"oauth" => %{} = oauth}) do
    for key <- @lemon_oauth_host_keys, Map.has_key?(oauth, key), do: "oauth." <> key
  end

  defp lemon_host_keys(_entry), do: []

  defp preview(%{name: name, entry: entry, enabled: enabled, source: source}) do
    target =
      case entry do
        %{"command" => command} when is_binary(command) ->
          Enum.join([command | Enum.filter(List.wrap(entry["args"]), &is_binary/1)], " ")

        %{"url" => url} when is_binary(url) ->
          public_url(url)

        _ ->
          "(invalid)"
      end

    %{
      "name" => if(is_binary(name), do: display(name), else: "(unnamed)"),
      "provider" => source.provider,
      "transport" => entry["type"],
      "enabled" => enabled,
      "preview" => display(Redact.text(target)),
      "env_count" => count(entry["env"]),
      "header_count" => count(entry["headers"])
    }
  end

  defp count(value) when is_map(value), do: map_size(value)
  defp count(_value), do: 0

  defp public_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      _ ->
        "(invalid URL)"
    end
  rescue
    _ -> "(invalid URL)"
  end

  # Project text is untrusted terminal output: one bounded line, no controls.
  defp display(text, max \\ @preview_bytes) do
    text
    |> String.replace_invalid("?")
    |> String.replace(@unsafe_text, "?")
    |> bounded_text(max)
  end

  # A POSIX single-quoted argument, only for paths shown exactly as they are.
  defp shell_arg(path) do
    if String.valid?(path) and byte_size(path) <= @label_bytes and
         not Regex.match?(@unsafe_text, path),
       do: "'" <> String.replace(path, "'", ~S('\'')) <> "'"
  end

  @doc "Whether external MCP config discovery is enabled (default: true)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:lemon_skills, :mcp_external_discovery, true) not in [false, "false"] and
      System.get_env("LEMON_MCP_EXTERNAL_DISCOVERY") not in @falsy
  end

  @doc "Whether other tools' user-level (`~/`) MCP files are read (default: false)."
  @spec user_sources_enabled?() :: boolean()
  def user_sources_enabled? do
    Application.get_env(:lemon_skills, :mcp_external_user_discovery, false) in [true, "true"] or
      System.get_env("LEMON_MCP_EXTERNAL_USER_DISCOVERY") in @truthy
  end

  defp project(server, inventory) do
    base = %{
      "connected" => true,
      "server" => %{
        "name" => Redact.text(server["name"], drop_keys: true),
        "status" => "connected"
      },
      "tools" => [],
      "count" => 0,
      "truncated" => false
    }

    # Reserve conservative envelope/count overhead. Descriptor statistics include
    # executionName, schema contents and every other field sent over the wire.
    {:ok, base_stats} = JSONPayload.validate(base, max_bytes: @max_result, max_items: @max_items)
    budget = @max_result - base_stats.bytes - 32
    item_budget = @max_items - base_stats.item_count - 32

    {tools, _bytes, _items, _names, truncated} =
      Enum.reduce(inventory, {[], 0, 0, MapSet.new(), false}, fn raw,
                                                                 {tools, bytes, items, names,
                                                                  truncated} = acc ->
        case project_tool(raw) do
          {:ok, tool, shortened} ->
            tool =
              Map.put(
                tool,
                "executionName",
                McpSource.execution_name(server["name"], server["url"], tool["name"])
              )

            case JSONPayload.validate(tool,
                   max_bytes: budget,
                   max_items: item_budget,
                   max_depth: @max_schema_depth + 1
                 ) do
              {:ok, stats} ->
                size = stats.bytes + 1

                if length(tools) < @max_tools and bytes + size <= budget and
                     items + stats.item_count <= item_budget and
                     not MapSet.member?(names, tool["name"]) do
                  {[tool | tools], bytes + size, items + stats.item_count,
                   MapSet.put(names, tool["name"]), truncated or shortened}
                else
                  put_elem(acc, 4, true)
                end

              {:error, _} ->
                put_elem(acc, 4, true)
            end

          :skip ->
            put_elem(acc, 4, true)
        end
      end)

    tools = Enum.reverse(tools)
    %{base | "tools" => tools, "count" => length(tools), "truncated" => truncated}
  end

  defp project_tool(
         %{"name" => name, "description" => description, "inputSchema" => schema} = tool
       ) do
    with true <- McpSource.valid_remote_name?(name),
         true <- valid_text?(description),
         true <- valid_schema?(schema),
         {:ok, json} <- Jason.encode(schema),
         true <- byte_size(json) <= @max_schema do
      shortened = byte_size(description) > 4096
      description = bounded_text(description, 4096)

      {:ok,
       %{
         "name" => name,
         "description" => description,
         "inputSchema" => schema,
         "readOnly" => get_in(tool, ["annotations", "readOnlyHint"]) === true
       }, shortened}
    else
      _ -> :skip
    end
  end

  defp project_tool(_), do: :skip

  defp valid_text?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  # MCP requires an object input schema; validate its JSON shape without inventing
  # a partial schema repair or evaluating untrusted external schema references.
  defp valid_schema?(%{"type" => "object"} = schema),
    do: json_value?(schema, 0) and schema_shape?(schema)

  defp valid_schema?(_), do: false

  defp schema_shape?(value) when is_boolean(value), do: true

  defp schema_shape?(value) when is_map(value) do
    Enum.all?(value, fn
      {"type", type} when is_binary(type) ->
        type in ["null", "boolean", "object", "array", "number", "integer", "string"]

      {"type", types} when is_list(types) ->
        types != [] and Enum.uniq(types) == types and
          Enum.all?(types, &(is_binary(&1) and schema_shape?(%{"type" => &1})))

      {"type", _} ->
        false

      {key, schemas}
      when key in ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"] ->
        is_map(schemas) and Enum.all?(schemas, fn {_name, schema} -> schema_shape?(schema) end)

      {key, schemas} when key in ["allOf", "anyOf", "oneOf", "prefixItems"] ->
        is_list(schemas) and schemas != [] and Enum.all?(schemas, &schema_shape?/1)

      {key, schema}
      when key in [
             "additionalProperties",
             "unevaluatedProperties",
             "propertyNames",
             "contains",
             "additionalItems",
             "unevaluatedItems",
             "not",
             "if",
             "then",
             "else"
           ] ->
        schema_shape?(schema)

      {"items", schemas} when is_list(schemas) ->
        Enum.all?(schemas, &schema_shape?/1)

      {"items", schema} ->
        schema_shape?(schema)

      {"required", names} ->
        is_list(names) and Enum.all?(names, &valid_text?/1) and Enum.uniq(names) == names

      {"enum", values} ->
        is_list(values) and values != [] and Enum.uniq(values) == values

      {key, number} when key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] ->
        is_number(number)

      {"multipleOf", number} ->
        is_number(number) and number > 0

      {key, count}
      when key in [
             "minLength",
             "maxLength",
             "minItems",
             "maxItems",
             "minProperties",
             "maxProperties",
             "minContains",
             "maxContains"
           ] ->
        is_integer(count) and count >= 0

      {"uniqueItems", value} ->
        is_boolean(value)

      {key, text}
      when key in [
             "$ref",
             "$id",
             "$schema",
             "$anchor",
             "$dynamicRef",
             "$dynamicAnchor",
             "pattern",
             "format",
             "title",
             "description"
           ] ->
        valid_text?(text)

      _ ->
        true
    end)
  end

  defp schema_shape?(_), do: false

  defp json_value?(_value, depth) when depth > @max_schema_depth, do: false
  defp json_value?(value, _depth) when is_binary(value), do: valid_text?(value)

  defp json_value?(value, _depth) when is_number(value) or is_boolean(value) or is_nil(value),
    do: true

  defp json_value?(value, depth) when is_list(value),
    do: Enum.all?(value, &json_value?(&1, depth + 1))

  defp json_value?(value, depth) when is_map(value),
    do:
      Enum.all?(value, fn {key, nested} -> valid_text?(key) and json_value?(nested, depth + 1) end)

  defp json_value?(_, _), do: false

  defp bounded_text(value, max) when byte_size(value) <= max, do: value

  defp bounded_text(value, max) do
    prefix = binary_part(value, 0, max)
    if String.valid?(prefix), do: prefix, else: bounded_text(prefix, max - 1)
  end

  # ── providers ────────────────────────────────────────────────────────────────

  defp provider(:omp, ctx) do
    project =
      for file <- ["mcp.json", ".mcp.json"], path <- project_path(ctx, [".omp", file]) do
        {path, :project}
      end

    user =
      for file <- ["mcp.json", ".mcp.json"], ctx.home do
        {Path.join([ctx.home, ".omp", "agent", file]), :global}
      end

    Enum.flat_map(project ++ user, fn {path, scope} ->
      ctx |> read_json(path) |> mcp_servers_map() |> json_servers("omp", scope)
    end)
  end

  defp provider(:claude, ctx) do
    {user_dir, user_file} = claude_user_paths(ctx)
    user_document = if user_file, do: read_json(ctx, user_file)

    local =
      case {ctx.cwd, user_document} do
        {cwd, %{"projects" => %{} = projects}} when is_binary(cwd) ->
          projects |> Map.get(cwd) |> mcp_servers_map() |> json_servers("claude", :global)

        _ ->
          []
      end

    project =
      [[".claude", ".mcp.json"], [".claude", "mcp.json"]]
      |> Enum.flat_map(&project_path(ctx, &1))
      |> Enum.map(fn path -> fn -> ctx |> read_json(path) |> mcp_servers_map() end end)
      |> first_with_servers()
      |> json_servers("claude", :project)

    user_mcp_json =
      for dir <- List.wrap(user_dir),
          do: fn -> ctx |> read_json(Path.join(dir, "mcp.json")) |> mcp_servers_map() end

    user =
      [fn -> mcp_servers_map(user_document) end | user_mcp_json]
      |> first_with_servers()
      |> json_servers("claude", :global)

    local ++ project ++ user
  end

  defp provider(:codex, ctx) do
    project = for path <- project_path(ctx, [".codex", "config.toml"]), do: {path, :project}
    user = for path <- foreign_user_path(ctx, [".codex", "config.toml"]), do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} -> codex_servers(ctx, path, scope) end)
  end

  defp provider(:gemini, ctx) do
    project = for path <- project_path(ctx, [".gemini", "settings.json"]), do: {path, :project}
    user = for path <- foreign_user_path(ctx, [".gemini", "settings.json"]), do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} ->
      ctx
      |> read_json(path)
      |> mcp_servers_map()
      |> imported("gemini", scope, &gemini_fields/1)
    end)
  end

  defp provider(:opencode, ctx), do: opencode_servers(ctx)

  defp provider(:cursor, ctx) do
    project = for path <- project_path(ctx, [".cursor", "mcp.json"]), do: {path, :project}
    user = for path <- foreign_user_path(ctx, [".cursor", "mcp.json"]), do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} ->
      ctx |> read_json(path) |> mcp_servers_map() |> json_servers("cursor", scope)
    end)
  end

  defp provider(:windsurf, ctx) do
    project =
      for path <- project_path(ctx, [".windsurf", "mcp_config.json"]), do: {path, :project}

    user =
      for path <- foreign_user_path(ctx, [".codeium", "windsurf", "mcp_config.json"]),
          do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} ->
      ctx
      |> read_json(path)
      |> mcp_servers_map()
      |> imported("windsurf", scope, fn raw ->
        if is_map(raw),
          do: json_fields(Map.put(raw, "url", raw["serverUrl"] || raw["url"])),
          else: json_fields(raw)
      end)
    end)
  end

  defp provider(:vscode, ctx) do
    Enum.flat_map(project_path(ctx, [".vscode", "mcp.json"]), fn path ->
      servers =
        case read_json(ctx, path) do
          %{"servers" => %{} = servers} -> servers
          %{"mcp" => %{"servers" => %{} = servers}} -> servers
          _ -> %{}
        end

      servers
      |> replace_workspace_folder(ctx.cwd)
      |> imported("vscode", :project, fn raw ->
        if is_map(raw),
          do: json_fields(Map.put_new(raw, "type", raw["transport"])),
          else: json_fields(raw)
      end)
    end)
  end

  defp provider(:mcp_json, ctx) do
    for file <- ["mcp.json", ".mcp.json"],
        path <- project_path(ctx, [file]),
        server <-
          ctx |> read_json(path) |> mcp_servers_map() |> json_servers("mcp-json", :project),
        do: server
  end

  # ── paths ────────────────────────────────────────────────────────────────────

  defp project_path(%{cwd: nil}, _segments), do: []

  defp project_path(ctx, segments) do
    path = Path.join([ctx.cwd | segments])

    if not ctx.user_sources and foreign_user_config?(path, ctx),
      do: [],
      else: [path]
  end

  # A cwd at home (or inside a foreign config directory) must not reclassify a
  # user-level server as a project server and bypass the user-source opt-in.
  defp foreign_user_config?(path, ctx) do
    explicit_claude =
      is_binary(ctx.claude_config_dir) and String.trim(ctx.claude_config_dir) != "" and
        Path.dirname(path) == Path.expand(ctx.claude_config_dir) and
        Path.basename(path) in ["mcp.json", ".mcp.json"]

    MapSet.member?(ctx.user_config_paths, Path.expand(path)) and not explicit_claude
  end

  defp foreign_user_path(%{home: home, user_sources: true}, segments) when is_binary(home),
    do: [Path.join([home | segments])]

  defp foreign_user_path(_ctx, _segments), do: []

  defp claude_user_paths(%{home: nil}), do: {nil, nil}

  defp claude_user_paths(ctx) do
    case ctx.claude_config_dir && String.trim(ctx.claude_config_dir) do
      dir when is_binary(dir) and dir != "" ->
        dir = Path.expand(dir)
        {dir, Path.join(dir, ".claude.json")}

      _ when ctx.user_sources == true ->
        {Path.join(ctx.home, ".claude"), Path.join(ctx.home, ".claude.json")}

      _ ->
        {nil, nil}
    end
  end

  # Like omp, only the first file that declares servers is used.
  defp first_with_servers(loaders) do
    Enum.find_value(loaders, %{}, fn load ->
      servers = load.()
      if map_size(servers) > 0, do: servers
    end)
  end

  # ── JSON providers ───────────────────────────────────────────────────────────

  defp read_json(ctx, path) do
    with {:ok, bytes} <- read_file(ctx, path),
         {:ok, %{} = document} <- Jason.decode(bytes) do
      document
    else
      _ -> nil
    end
  end

  # Project files come from the call's snapshot; user files are read directly.
  defp read_file(ctx, path) do
    case Map.fetch(ctx.files_read, path) do
      {:ok, {:ok, bytes}} -> {:ok, bytes}
      {:ok, _absent_or_invalid} -> :error
      :error -> File.read(path)
    end
  end

  defp mcp_servers_map(%{"mcpServers" => %{} = servers}), do: servers
  defp mcp_servers_map(_document), do: %{}

  defp json_servers(servers, provider, scope),
    do: imported(servers, provider, scope, &json_fields/1)

  defp imported(servers, provider, scope, fields) do
    servers
    |> sorted()
    |> Enum.flat_map(fn {name, raw} ->
      case host_values(raw, scope) do
        {:ok, raw} -> server(name, fields.(raw), provider, scope)
        {:error, keys} -> rejected(name, provider, keys)
      end
    end)
  end

  # User files expand `${VAR}`; project files never read host values.
  defp host_values(raw, :project) do
    case references(raw, @host_placeholder) do
      [] -> {:ok, raw}
      keys -> {:error, keys}
    end
  end

  defp host_values(raw, _scope), do: {:ok, expand_env(raw)}

  defp json_fields(raw) when is_map(raw) do
    %{
      "enabled" => enabled_flag(raw),
      "transport" => transport(raw["type"]),
      "command" => raw["command"],
      "args" => raw["args"],
      "env" => raw["env"],
      "cwd" => raw["cwd"],
      "url" => raw["url"],
      "headers" => raw["headers"],
      "timeout_ms" => timeout_ms(raw["timeout"])
    }
  end

  defp json_fields(_raw), do: nil

  # Gemini CLI: `httpUrl` is Streamable HTTP, `url` is SSE.
  defp gemini_fields(raw) when is_map(raw) do
    {transport, url} =
      case {transport(raw["type"]), raw["httpUrl"], raw["url"]} do
        {type, http, url} when is_binary(type) -> {type, http || url}
        {nil, http, _url} when is_binary(http) -> {"http", http}
        {nil, nil, url} when is_binary(url) -> {"sse", url}
        _ -> {nil, nil}
      end

    raw
    |> json_fields()
    |> Map.merge(%{
      "transport" => transport,
      "url" => url,
      "allow_tools" => raw["includeTools"],
      "block_tools" => raw["excludeTools"]
    })
  end

  defp gemini_fields(_raw), do: nil

  defp replace_workspace_folder(value, nil), do: value

  defp replace_workspace_folder(value, cwd) when is_binary(value),
    do: String.replace(value, "${workspaceFolder}", cwd)

  defp replace_workspace_folder(value, cwd) when is_list(value),
    do: Enum.map(value, &replace_workspace_folder(&1, cwd))

  defp replace_workspace_folder(value, cwd) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, replace_workspace_folder(item, cwd)} end)

  defp replace_workspace_folder(value, _cwd), do: value

  # ── Codex ────────────────────────────────────────────────────────────────────

  defp codex_servers(ctx, path, scope) do
    with {:ok, bytes} <- read_file(ctx, path),
         {:ok, %{"mcp_servers" => %{} = servers}} <- Toml.decode(bytes) do
      config_dir = Path.dirname(path)

      servers
      |> sorted()
      |> Enum.flat_map(fn {name, raw} ->
        case codex_host_keys(raw, scope) do
          [] -> server(name, codex_fields(raw, config_dir), "codex", scope)
          keys -> rejected(name, "codex", keys)
        end
      end)
    else
      _ -> []
    end
  end

  defp codex_host_keys(raw, :project) when is_map(raw),
    do: Enum.filter(@codex_host_keys, &Map.has_key?(raw, &1))

  defp codex_host_keys(_raw, _scope), do: []

  defp codex_fields(raw, config_dir) when is_map(raw) do
    cwd =
      case raw["cwd"] do
        cwd when is_binary(cwd) -> rooted(cwd, config_dir)
        _ -> nil
      end

    command =
      case raw["command"] do
        command when is_binary(command) ->
          if Regex.match?(~r/\A\.\.?[\/\\]/, command),
            do: Path.expand(Path.join(cwd || config_dir, command)),
            else: command

        other ->
          other
      end

    env =
      raw["env"]
      |> string_map()
      |> Map.merge(raw["env_vars"] |> string_list() |> Enum.map(&{&1, &1}) |> env_values())

    headers =
      raw["http_headers"]
      |> string_map()
      |> Map.merge(raw["env_http_headers"] |> string_map() |> env_values())

    headers =
      case raw["bearer_token_env_var"] do
        var when is_binary(var) ->
          case System.get_env(var) do
            token when is_binary(token) and token != "" ->
              Map.put(headers, "Authorization", "Bearer " <> token)

            _ ->
              headers
          end

        _ ->
          headers
      end

    %{
      "enabled" => raw["enabled"] != false,
      "transport" =>
        cond do
          is_binary(raw["url"]) -> "http"
          is_binary(raw["command"]) -> "stdio"
          true -> nil
        end,
      "command" => command,
      "args" => raw["args"],
      "env" => env,
      "cwd" => cwd,
      "url" => raw["url"],
      "headers" => headers,
      "timeout_ms" => seconds_ms(raw["tool_timeout_sec"]),
      "ready_timeout_ms" => seconds_ms(raw["startup_timeout_sec"]),
      "allow_tools" => raw["enabled_tools"],
      "block_tools" => raw["disabled_tools"]
    }
  end

  defp codex_fields(_raw, _config_dir), do: nil

  defp env_values(pairs) do
    pairs
    |> Enum.flat_map(fn {key, var} ->
      case System.get_env(var) do
        nil -> []
        value -> [{key, value}]
      end
    end)
    |> Map.new()
  end

  defp rooted(path, base) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(Path.join(base, path))
  end

  defp seconds_ms(value) when is_number(value) and value > 0, do: round(value * 1000)
  defp seconds_ms(_value), do: nil

  # ── OpenCode ─────────────────────────────────────────────────────────────────

  # Layers in ascending precedence; each server deep-merges across layers like
  # OpenCode itself, and is attributed to the highest layer that defines it.
  # Substitution runs after the merge and only for user-attributed servers (all
  # user layers share one directory); a project-attributed server carrying any
  # `{env:}`/`{file:}` directive, from any layer, is rejected instead.
  defp opencode_servers(ctx) do
    user =
      for file <- ["opencode.json", "opencode.jsonc"],
          path <- foreign_user_path(ctx, [".config", "opencode", file]),
          do: {path, :global}

    project =
      for dir <- [[], [".opencode"]],
          file <- ["opencode.json", "opencode.jsonc"],
          path <- project_path(ctx, dir ++ [file]),
          do: {path, :project}

    (user ++ project)
    |> Enum.reduce(%{}, fn {path, scope}, merged ->
      case read_opencode(ctx, path) do
        %{"mcp" => %{} = servers} ->
          Enum.reduce(servers, merged, fn
            {name, %{} = raw}, acc ->
              keys = references(raw, @opencode_directive)
              layer = {raw, scope, Path.dirname(path), keys}

              Map.update(acc, name, layer, fn {previous, _scope, _dir, previous_keys} ->
                {deep_merge(previous, raw), scope, Path.dirname(path),
                 Enum.uniq(previous_keys ++ keys)}
              end)

            _, acc ->
              acc
          end)

        _ ->
          merged
      end
    end)
    |> sorted()
    |> Enum.flat_map(fn
      {name, {_raw, :project, _dir, [_ | _] = keys}} ->
        rejected(name, "opencode", keys)

      {name, {raw, :project, _dir, []}} ->
        server(name, opencode_fields(raw), "opencode", :project)

      {name, {raw, scope, dir, _keys}} ->
        server(name, opencode_fields(substitute_opencode(raw, dir, ctx.home)), "opencode", scope)
    end)
  end

  defp read_opencode(ctx, path) do
    with {:ok, bytes} <- read_file(ctx, path),
         {:ok, %{} = document} <- bytes |> strip_jsonc() |> Jason.decode() do
      document
    else
      _ -> nil
    end
  end

  # Match both directives in one pass so inserted values cannot become imports
  # or interpolation directives, regardless of which source supplied them.
  defp substitute_opencode(value, config_dir, home) when is_binary(value) do
    Regex.replace(@opencode_directive, value, fn
      _, "env", name -> System.get_env(name) || ""
      _, "file", path -> opencode_file(path, config_dir, home)
    end)
  end

  defp substitute_opencode(value, config_dir, home) when is_list(value),
    do: Enum.map(value, &substitute_opencode(&1, config_dir, home))

  defp substitute_opencode(value, config_dir, home) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, substitute_opencode(item, config_dir, home)} end)

  defp substitute_opencode(value, _config_dir, _home), do: value

  # Only user layers are substituted, and those exist only with a home.
  defp opencode_file(path, config_dir, home) do
    path =
      if String.starts_with?(path, "~/"),
        do: Path.join(home, String.slice(path, 2..-1//1)),
        else: rooted(path, config_dir)

    case File.read(path) do
      {:ok, content} -> String.trim(content)
      _ -> ""
    end
  end

  defp opencode_fields(raw) do
    {command, args} =
      case raw["command"] do
        [command | command_args] ->
          {command, command_args ++ (string_list_or_nil(raw["args"]) || [])}

        command ->
          {command, raw["args"]}
      end

    %{
      "enabled" => raw["enabled"] != false,
      "transport" =>
        case raw["type"] do
          "local" -> "stdio"
          "remote" -> "http"
          _ -> nil
        end,
      "command" => command,
      "args" => args,
      "env" => raw["environment"] || raw["env"],
      "url" => raw["url"],
      "headers" => raw["headers"],
      "timeout_ms" => timeout_ms(raw["timeout"])
    }
  end

  # Strip `//` and `/* */` comments and trailing commas outside JSON strings.
  defp strip_jsonc(text) do
    text
    |> strip_comments([])
    |> IO.iodata_to_binary()
    |> strip_trailing_commas([])
    |> IO.iodata_to_binary()
  end

  defp strip_comments(<<>>, acc), do: acc

  defp strip_comments(<<?", rest::binary>>, acc) do
    {string, rest} = take_string(rest, [?"])
    strip_comments(rest, [acc, string])
  end

  defp strip_comments(<<"//", rest::binary>>, acc) do
    case :binary.split(rest, "\n") do
      [_comment, rest] -> strip_comments(rest, [acc, ?\n])
      [_comment] -> acc
    end
  end

  defp strip_comments(<<"/*", rest::binary>>, acc) do
    case :binary.split(rest, "*/") do
      [_comment, rest] -> strip_comments(rest, [acc, ?\s])
      [_comment] -> acc
    end
  end

  defp strip_comments(<<char, rest::binary>>, acc), do: strip_comments(rest, [acc, char])

  defp strip_trailing_commas(<<>>, acc), do: acc

  defp strip_trailing_commas(<<?", rest::binary>>, acc) do
    {string, rest} = take_string(rest, [?"])
    strip_trailing_commas(rest, [acc, string])
  end

  defp strip_trailing_commas(<<?,, rest::binary>>, acc) do
    case String.trim_leading(rest) do
      <<closer, _::binary>> when closer in [?}, ?]] -> strip_trailing_commas(rest, acc)
      _ -> strip_trailing_commas(rest, [acc, ?,])
    end
  end

  defp strip_trailing_commas(<<char, rest::binary>>, acc),
    do: strip_trailing_commas(rest, [acc, char])

  defp take_string(<<?\\, char, rest::binary>>, acc), do: take_string(rest, [acc, ?\\, char])
  defp take_string(<<?", rest::binary>>, acc), do: {[acc, ?"], rest}
  defp take_string(<<char, rest::binary>>, acc), do: take_string(rest, [acc, char])
  defp take_string(<<>>, acc), do: {acc, <<>>}

  # ── translation into Lemon entries ───────────────────────────────────────────

  defp server(_name, nil, _provider, _scope), do: []

  defp server(name, fields, provider, scope) do
    command = fields["command"]
    url = fields["url"]

    transport =
      fields["transport"] ||
        cond do
          present?(command) -> "stdio"
          present?(url) -> "http"
          true -> "stdio"
        end

    with true <- valid_name?(name),
         false <- present?(command) and present?(url),
         {:ok, entry} <- transport_entry(transport, fields) do
      entry =
        [
          {"timeout_ms", positive_integer(fields["timeout_ms"])},
          {"ready_timeout_ms", positive_integer(fields["ready_timeout_ms"])},
          {"allow_tools", string_list_or_nil(fields["allow_tools"])},
          {"block_tools", string_list_or_nil(fields["block_tools"])}
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
        |> Map.new()
        |> Map.merge(entry)
        |> Map.put("name", name)

      [
        %{
          name: name,
          entry: entry,
          enabled: fields["enabled"] != false,
          source: %{provider: provider, scope: scope}
        }
      ]
    else
      _ -> []
    end
  end

  defp transport_entry("stdio", fields) do
    with true <- present?(fields["command"]),
         args when is_list(args) <- fields["args"] || [],
         true <- Enum.all?(args, &is_binary/1) do
      entry =
        %{"type" => "stdio", "command" => fields["command"], "args" => args}
        |> put_present("env", string_map(fields["env"]))
        |> put_present("cwd", if(is_binary(fields["cwd"]), do: fields["cwd"]))

      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp transport_entry(type, fields) when type in ["http", "sse"] do
    if present?(fields["url"]) do
      {:ok,
       %{"type" => type, "url" => fields["url"]}
       |> put_present("headers", string_map(fields["headers"]))}
    else
      :error
    end
  end

  defp transport_entry(_type, _fields), do: :error

  defp valid_name?(name) do
    is_binary(name) and byte_size(name) <= 128 and Config.validate_mcp_metadata(name: name) == :ok
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, value) when value == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp enabled_flag(raw) do
    not (raw["enabled"] in [false, "false", "FALSE", "0"] or raw["disabled"] in [true, "true"])
  end

  defp transport(type) when type in ["stdio", "http", "sse"], do: type
  defp transport(_type), do: nil

  defp timeout_ms(value) when is_number(value) and value > 0, do: round(value)
  defp timeout_ms(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp string_map(%{} = map),
    do: for({key, value} <- map, is_binary(key) and is_binary(value), into: %{}, do: {key, value})

  defp string_map(_value), do: %{}

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: []

  defp string_list_or_nil(values) when is_list(values), do: string_list(values)
  defp string_list_or_nil(_values), do: nil

  defp sorted(map) when is_map(map), do: Enum.sort_by(map, &elem(&1, 0))

  defp deep_merge(%{} = base, %{} = override) do
    Map.merge(base, override, fn
      _key, %{} = left, %{} = right -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp expand_env(value) when is_binary(value) do
    Regex.replace(@env_placeholder, value, fn whole, name, default_marker, default ->
      env = System.get_env(name)

      cond do
        env != nil and (default_marker == "" or env != "") -> env
        default_marker != "" -> default
        true -> whole
      end
    end)
  end

  defp expand_env(value) when is_list(value), do: Enum.map(value, &expand_env/1)

  defp expand_env(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, expand_env(item)} end)

  defp expand_env(value), do: value

  # Dotted key paths of string values matching `pattern`; map keys stay literal
  # everywhere, so only values can reference host data.
  defp references(value, pattern, path \\ [])

  defp references(value, pattern, path) when is_binary(value),
    do: if(Regex.match?(pattern, value), do: [key_path(path)], else: [])

  defp references(value, pattern, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> references(item, pattern, [index | path]) end)
  end

  defp references(value, pattern, path) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, item} -> references(item, pattern, [key | path]) end)
  end

  defp references(_value, _pattern, _path), do: []

  defp key_path([]), do: "."
  defp key_path(path), do: path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)

  defp rejected(name, provider, keys) do
    [
      {:rejected,
       %{
         "reason" => "host_value_reference",
         "provider" => provider,
         "server" => if(is_binary(name) and String.valid?(name), do: display(name), else: "?"),
         "keys" => keys |> Enum.take(@max_finding_keys) |> Enum.map(&display/1)
       }}
    ]
  end
end
