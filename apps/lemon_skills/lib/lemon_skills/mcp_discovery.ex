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

  ## Switches

  Discovery is on unless `config :lemon_skills, :mcp_external_discovery, false`
  or `LEMON_MCP_EXTERNAL_DISCOVERY` is `0`/`false`/`no`. User-level files of
  other tools (`claude`, `codex`, `gemini`, `opencode`, `cursor`, `windsurf`)
  additionally require `config :lemon_skills, :mcp_external_user_discovery, true`
  or `LEMON_MCP_EXTERNAL_USER_DISCOVERY=1`; a set `CLAUDE_CONFIG_DIR` opts in
  the Claude Code user files. The omp user file is read by default.

  User-level files are read from `config :lemon_skills, :mcp_discovery_home`
  when set, otherwise from the user's home directory unless an agent-directory
  override isolates the runtime (see `LemonSkills.Config.mcp_discovery_home/0`).

  ## Values

  `${VAR}` and `${VAR:-default}` are expanded in the JSON-based provider files
  (not Codex or OpenCode); unresolved placeholders stay literal. OpenCode files
  use OpenCode's own `{env:VAR}` / `{file:path}` substitution and accept JSONC.
  Substitution runs once on decoded string values: environment bytes stay exact,
  file contents are trimmed, and inserted text is never expanded again.
  Codex `env_vars`, `env_http_headers` and `bearer_token_env_var` read the
  current environment. Imported entries carry command, arguments, environment,
  working directory, URL, headers, timeouts and tool filters; tool-specific
  OAuth/auth blocks are not imported.
  """

  alias LemonCore.{JSONPayload, ProfileStore, Redact}
  alias LemonSkills.{Config, McpSession, McpSource}

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
  first-name-wins merge. Configuration import never opens MCP sessions.
  """
  @spec discover(String.t() | nil, keyword()) :: [server()]
  @spec discover(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def discover(server_or_cwd, cwd_or_opts \\ [])

  def discover(server, cwd) when is_map(server) or not is_list(cwd) do
    with {:ok, [server]} <- ProfileStore.normalize_mcp_servers([server]) do
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
    else
      _ -> {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :discovery_failed}
  catch
    _, _ -> {:error, :discovery_failed}
  end

  def discover(cwd, opts) when (is_binary(cwd) or is_nil(cwd)) and is_list(opts) do
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

    Enum.flat_map(@providers, &provider(&1, ctx))
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
      path |> read_json() |> mcp_servers_map() |> json_servers("omp", scope)
    end)
  end

  defp provider(:claude, ctx) do
    {user_dir, user_file} = claude_user_paths(ctx)
    user_document = if user_file, do: read_json(user_file)

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
      |> Enum.map(fn path -> fn -> path |> read_json() |> mcp_servers_map() end end)
      |> first_with_servers()
      |> json_servers("claude", :project)

    user_mcp_json =
      for dir <- List.wrap(user_dir),
          do: fn -> dir |> Path.join("mcp.json") |> read_json() |> mcp_servers_map() end

    user =
      [fn -> mcp_servers_map(user_document) end | user_mcp_json]
      |> first_with_servers()
      |> json_servers("claude", :global)

    local ++ project ++ user
  end

  defp provider(:codex, ctx) do
    project = for path <- project_path(ctx, [".codex", "config.toml"]), do: {path, :project}
    user = for path <- foreign_user_path(ctx, [".codex", "config.toml"]), do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} -> codex_servers(path, scope) end)
  end

  defp provider(:gemini, ctx) do
    project = for path <- project_path(ctx, [".gemini", "settings.json"]), do: {path, :project}
    user = for path <- foreign_user_path(ctx, [".gemini", "settings.json"]), do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} ->
      path
      |> read_json()
      |> mcp_servers_map()
      |> expand_env()
      |> sorted()
      |> Enum.flat_map(fn {name, raw} -> server(name, gemini_fields(raw), "gemini", scope) end)
    end)
  end

  defp provider(:opencode, ctx), do: opencode_servers(ctx)

  defp provider(:cursor, ctx) do
    project = for path <- project_path(ctx, [".cursor", "mcp.json"]), do: {path, :project}
    user = for path <- foreign_user_path(ctx, [".cursor", "mcp.json"]), do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} ->
      path |> read_json() |> mcp_servers_map() |> json_servers("cursor", scope)
    end)
  end

  defp provider(:windsurf, ctx) do
    project =
      for path <- project_path(ctx, [".windsurf", "mcp_config.json"]), do: {path, :project}

    user =
      for path <- foreign_user_path(ctx, [".codeium", "windsurf", "mcp_config.json"]),
          do: {path, :global}

    Enum.flat_map(project ++ user, fn {path, scope} ->
      path
      |> read_json()
      |> mcp_servers_map()
      |> expand_env()
      |> sorted()
      |> Enum.flat_map(fn {name, raw} ->
        fields =
          if is_map(raw), do: Map.put(raw, "url", raw["serverUrl"] || raw["url"]), else: raw

        server(name, json_fields(fields), "windsurf", scope)
      end)
    end)
  end

  defp provider(:vscode, ctx) do
    Enum.flat_map(project_path(ctx, [".vscode", "mcp.json"]), fn path ->
      document = read_json(path)

      servers =
        case document do
          %{"servers" => %{} = servers} -> servers
          %{"mcp" => %{"servers" => %{} = servers}} -> servers
          _ -> %{}
        end

      servers
      |> replace_workspace_folder(ctx.cwd)
      |> expand_env()
      |> sorted()
      |> Enum.flat_map(fn {name, raw} ->
        fields = if is_map(raw), do: Map.put_new(raw, "type", raw["transport"]), else: raw
        server(name, json_fields(fields), "vscode", :project)
      end)
    end)
  end

  defp provider(:mcp_json, ctx) do
    for file <- ["mcp.json", ".mcp.json"],
        path <- project_path(ctx, [file]),
        server <- path |> read_json() |> mcp_servers_map() |> json_servers("mcp-json", :project),
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

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = document} <- Jason.decode(bytes) do
      document
    else
      _ -> nil
    end
  end

  defp mcp_servers_map(%{"mcpServers" => %{} = servers}), do: servers
  defp mcp_servers_map(_document), do: %{}

  defp json_servers(servers, provider, scope) do
    servers
    |> expand_env()
    |> sorted()
    |> Enum.flat_map(fn {name, raw} -> server(name, json_fields(raw), provider, scope) end)
  end

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

  defp codex_servers(path, scope) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"mcp_servers" => %{} = servers}} <- Toml.decode(bytes) do
      config_dir = Path.dirname(path)

      servers
      |> sorted()
      |> Enum.flat_map(fn {name, raw} ->
        server(name, codex_fields(raw, config_dir), "codex", scope)
      end)
    else
      _ -> []
    end
  end

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
      case read_opencode(path, ctx.home) do
        %{"mcp" => %{} = servers} ->
          Enum.reduce(servers, merged, fn
            {name, %{} = raw}, acc ->
              Map.update(acc, name, {raw, scope}, fn {previous, _scope} ->
                {deep_merge(previous, raw), scope}
              end)

            _, acc ->
              acc
          end)

        _ ->
          merged
      end
    end)
    |> sorted()
    |> Enum.flat_map(fn {name, {raw, scope}} ->
      server(name, opencode_fields(raw), "opencode", scope)
    end)
  end

  defp read_opencode(path, home) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = document} <- bytes |> strip_jsonc() |> Jason.decode() do
      substitute_opencode(document, Path.dirname(path), home)
    else
      _ -> nil
    end
  end

  # Match both directives in one pass so inserted values cannot become imports
  # or interpolation directives, regardless of which source supplied them.
  defp substitute_opencode(value, config_dir, home) when is_binary(value) do
    Regex.replace(~r/\{(env|file):([^}]+)\}/, value, fn
      _, "env", name -> System.get_env(name) || ""
      _, "file", path -> opencode_file(path, config_dir, home)
    end)
  end

  defp substitute_opencode(value, config_dir, home) when is_list(value),
    do: Enum.map(value, &substitute_opencode(&1, config_dir, home))

  defp substitute_opencode(value, config_dir, home) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, substitute_opencode(item, config_dir, home)} end)

  defp substitute_opencode(value, _config_dir, _home), do: value

  defp opencode_file(path, config_dir, home) do
    path =
      cond do
        String.starts_with?(path, "~/") and is_binary(home) ->
          Path.join(home, String.slice(path, 2..-1//1))

        String.starts_with?(path, "~/") ->
          nil

        true ->
          rooted(path, config_dir)
      end

    case path && File.read(path) do
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
end
