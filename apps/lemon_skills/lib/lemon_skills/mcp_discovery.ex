defmodule LemonSkills.McpDiscovery do
  @moduledoc """
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
  Codex `env_vars`, `env_http_headers` and `bearer_token_env_var` read the
  current environment. Imported entries carry command, arguments, environment,
  working directory, URL, headers, timeouts and tool filters; tool-specific
  OAuth/auth blocks are not imported.
  """

  alias LemonSkills.Config

  @type scope :: :project | :global
  @type source :: %{provider: String.t(), scope: scope()}
  @type server :: %{name: String.t(), entry: map(), enabled: boolean(), source: source()}

  @providers [:omp, :claude, :codex, :gemini, :opencode, :cursor, :windsurf, :vscode, :mcp_json]
  @falsy ["0", "false", "FALSE", "False", "no", "NO", "No"]
  @truthy ["1", "true", "TRUE", "True", "yes", "YES", "Yes"]
  @env_placeholder ~r/\$\{([^}:]+)(:-([^}]*))?\}/

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

  @doc """
  Discover external MCP servers for `cwd` (`nil` reads only user-level files).

  Options: `:home` (defaults to `LemonSkills.Config.mcp_discovery_home/0`),
  `:user_sources` (defaults to `user_sources_enabled?/0`) and
  `:claude_config_dir` (defaults to `CLAUDE_CONFIG_DIR`). Returns servers in
  precedence order; duplicate names are kept for the caller's first-name-wins
  merge.
  """
  @spec discover(String.t() | nil, keyword()) :: [server()]
  def discover(cwd, opts \\ []) do
    ctx = %{
      cwd: if(is_binary(cwd), do: Path.expand(cwd)),
      home: Keyword.get_lazy(opts, :home, &Config.mcp_discovery_home/0),
      user_sources: Keyword.get_lazy(opts, :user_sources, &user_sources_enabled?/0),
      claude_config_dir:
        Keyword.get_lazy(opts, :claude_config_dir, fn -> System.get_env("CLAUDE_CONFIG_DIR") end)
    }

    Enum.flat_map(@providers, &provider(&1, ctx))
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
  defp project_path(%{cwd: cwd}, segments), do: [Path.join([cwd | segments])]

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
         text = substitute_opencode(bytes, Path.dirname(path), home),
         {:ok, %{} = document} <- text |> strip_jsonc() |> Jason.decode() do
      document
    else
      _ -> nil
    end
  end

  defp substitute_opencode(text, config_dir, home) do
    text = Regex.replace(~r/\{env:([^}]+)\}/, text, fn _, name -> System.get_env(name) || "" end)

    Regex.split(~r/\{file:[^}]+\}/, text, include_captures: true)
    |> Enum.reduce({[], ""}, fn part, {acc, preceding} ->
      if String.starts_with?(part, "{file:") and String.ends_with?(part, "}") and
           not comment_line?(preceding) do
        {[acc, opencode_file(String.slice(part, 6..-2//1), config_dir, home)], preceding <> part}
      else
        {[acc, part], preceding <> part}
      end
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp comment_line?(preceding) do
    preceding
    |> String.split("\n")
    |> List.last()
    |> String.trim_leading()
    |> String.starts_with?("//")
  end

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
      {:ok, content} -> content |> String.trim() |> Jason.encode!() |> String.slice(1..-2//1)
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
