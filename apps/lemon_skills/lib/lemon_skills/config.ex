defmodule LemonSkills.Config do
  @moduledoc """
  Configuration management for skills.

  Handles:
  - Skills directory paths (global and project)
  - Skill enable/disable state
  - Per-skill configuration

  ## Directory Structure

  ### Global Skills

  Global skills are discovered from multiple locations (in precedence order):

      ~/.lemon/agent/
      ├── skill/              # Primary global skills directory
      │   ├── bun-file-io/
      │   │   └── SKILL.md
      │   └── git-workflow/
      │       └── SKILL.md
      └── skills.json         # Global skill configuration

      ~/.agents/skills/       # Harness-compatible global skills (optional)
      ├── some-skill/
      │   └── SKILL.md

  ### Project Skills

  Project skills are discovered from:

      <project>/.lemon/
      ├── skill/              # Project-specific skills
      │   └── my-custom-skill/
      │       └── SKILL.md
      └── skills.json         # Project skill configuration

      <project>/.agents/skills/  # Harness-compatible project skills (optional)
      └── another-skill/
          └── SKILL.md

  ### Ancestor Discovery

  Skills in `.agents/skills` directories are discovered automatically from the
  current working directory up to the git repository root (or filesystem root
  when not in a git repo). This allows organizing skills at different levels
  of a project hierarchy.

  For example, in a monorepo at `/home/user/myrepo` with cwd at
  `/home/user/myrepo/packages/feature`, the following skill directories
  would be discovered (in precedence order):

      1. /home/user/myrepo/packages/feature/.lemon/skill
      2. /home/user/myrepo/packages/feature/.agents/skills
      3. /home/user/myrepo/packages/.agents/skills
      4. /home/user/myrepo/.agents/skills

  ## Overrides

  The global agent directory defaults to `~/.lemon/agent` but can be overridden via:
  - `LEMON_AGENT_DIR` environment variable
  - `config :lemon_skills, :agent_dir, "/path"`

  If `:lemon_skills` doesn't specify `:agent_dir`, this module will fall back to
  `config :coding_agent, :agent_dir, ...` so the skill registry and coding agent
  share a single on-disk location by default.
  """

  @skills_config_filename "skills.json"
  @skills_usage_filename "skills.usage.json"
  @skills_curator_filename "skills.curator.json"
  @curator_report_dirname Path.join(["logs", "curator"])

  @typedoc "MCP server configuration type"
  @type mcp_server_config ::
          {:stdio, command :: String.t(), args :: [String.t()]}
          | {:stdio, command :: String.t(), args :: [String.t()], opts :: keyword()}
          | {:http, url :: String.t()}
          | {:http, url :: String.t(), opts :: keyword()}
          | {:sse, url :: String.t()}
          | {:sse, url :: String.t(), opts :: keyword()}

  @typedoc "MCP validation error type"
  @type mcp_validation_error :: {:invalid, mcp_server_config(), String.t()}

  @doc """
  Get the global agent directory used for skills/config.

  Returns a path like `~/.lemon/agent` unless overridden.
  """
  @spec agent_dir() :: String.t()
  def agent_dir do
    System.get_env("LEMON_AGENT_DIR") ||
      Application.get_env(:lemon_skills, :agent_dir) ||
      Application.get_env(:coding_agent, :agent_dir) ||
      Path.join(System.user_home!(), ".lemon/agent")
  end

  @doc """
  Get the global skills directory.

  Returns `~/.lemon/agent/skill`.
  """
  @spec global_skills_dir() :: String.t()
  def global_skills_dir do
    Path.join(agent_dir(), "skill")
  end

  @doc """
  Get the global skill drafts directory.

  Returns `~/.lemon/agent/skill_drafts`.  Draft skills live here until
  promoted (via `mix lemon.skill draft publish`) to the regular skill dir.
  """
  @spec global_draft_skills_dir() :: String.t()
  def global_draft_skills_dir do
    Path.join(agent_dir(), "skill_drafts")
  end

  @doc """
  Get the project skill drafts directory.

  Returns `<cwd>/.lemon/skill_drafts`.
  """
  @spec project_draft_skills_dir(String.t()) :: String.t()
  def project_draft_skills_dir(cwd) do
    Path.join([cwd, ".lemon", "skill_drafts"])
  end

  @doc """
  Get all global skills directories.

  Directories are returned in precedence order (first wins on key collisions):
  1. Lemon global skills (`~/.lemon/agent/skill` or `LEMON_AGENT_DIR/skill`)
  2. Harness-compatible skills (`~/.agents/skills`)
  """
  @spec global_skills_dirs() :: [String.t()]
  def global_skills_dirs do
    [
      global_skills_dir(),
      harness_global_skills_dir()
    ]
    |> Enum.uniq()
  end

  @doc """
  Get the harness-compatible global skills directory.

  Returns `~/.agents/skills` unless overridden for tests or isolated runtimes.
  """
  @spec harness_global_skills_dir() :: String.t()
  def harness_global_skills_dir do
    System.get_env("LEMON_HARNESS_SKILLS_DIR") ||
      Application.get_env(:lemon_skills, :harness_global_skills_dir) ||
      Path.join([System.user_home!(), ".agents", "skills"])
  end

  @doc """
  Get the project skills directory.

  Returns `<cwd>/.lemon/skill`.

  ## Parameters

  - `cwd` - The project working directory
  """
  @spec project_skills_dir(String.t()) :: String.t()
  def project_skills_dir(cwd) do
    Path.join([cwd, ".lemon", "skill"])
  end

  @doc """
  Get all project skills directories including `.agents/skills` paths.

  Discovers skills in `.agents/skills` directories from cwd up to git repo root
  (or filesystem root if not in a git repo), following Pi's package-manager pattern.

  Directories are returned in precedence order (first wins on key collisions):
  1. Project `.lemon/skill` (highest precedence)
  2. `.agents/skills` directories from cwd up to git root

  ## Parameters

  - `cwd` - The project working directory

  ## Examples

      # In a git repo at /home/user/myrepo with cwd at /home/user/myrepo/packages/feature
      # and skills in:
      #   - /home/user/myrepo/packages/.agents/skills/nested-skill
      #   - /home/user/myrepo/.agents/skills/repo-skill
      # Returns: ["/home/user/myrepo/packages/.lemon/skill",
      #           "/home/user/myrepo/packages/.agents/skills",
      #           "/home/user/myrepo/.agents/skills"]

      # Outside a git repo at /home/user/project with cwd at /home/user/project/a/b
      # Returns: ["/home/user/project/a/b/.lemon/skill",
      #           "/home/user/project/a/b/.agents/skills",
      #           "/home/user/project/a/.agents/skills",
      #           "/home/user/project/.agents/skills"]
  """
  @spec project_skills_dirs(String.t()) :: [String.t()]
  def project_skills_dirs(cwd) do
    # Start with the primary project skills directory
    dirs = [project_skills_dir(cwd)]

    # Collect .agents/skills directories from cwd up to git root or filesystem root
    dirs = dirs ++ collect_ancestor_agents_skill_dirs(cwd)

    dirs
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  # ============================================================================
  # Private Functions - Ancestor Skills Discovery
  # ============================================================================

  @doc """
  Find the git repository root from a starting directory.

  Returns the absolute path to the nearest ancestor containing `.git`, or `nil`
  when no git repository root is found.
  """
  @spec find_git_repo_root(String.t()) :: String.t() | nil
  def find_git_repo_root(start_dir) when is_binary(start_dir) do
    start_dir
    |> Path.expand()
    |> find_git_root_recursive()
  end

  def find_git_repo_root(_), do: nil

  @doc """
  Collect `.agents/skills` directories from the given directory up to git root.

  If no git repo root is found, it walks to filesystem root.
  Returns paths in precedence order (closest first).
  """
  @spec collect_ancestor_agents_skill_dirs(String.t()) :: [String.t()]
  def collect_ancestor_agents_skill_dirs(start_dir) when is_binary(start_dir) do
    resolved_start = Path.expand(start_dir)
    git_root = find_git_repo_root(resolved_start)

    resolved_start
    |> collect_ancestors(git_root)
    |> Enum.map(fn dir -> Path.join([dir, ".agents", "skills"]) end)
  end

  def collect_ancestor_agents_skill_dirs(_), do: []

  defp find_git_root_recursive(dir) do
    git_dir = Path.join(dir, ".git")

    cond do
      File.dir?(git_dir) or File.regular?(git_dir) ->
        dir

      Path.dirname(dir) == dir ->
        nil

      true ->
        find_git_root_recursive(Path.dirname(dir))
    end
  end

  # Collect ancestor directories from start_dir up to git_root or filesystem root.
  defp collect_ancestors(start_dir, git_root) do
    collect_ancestors_recursive(Path.expand(start_dir), git_root, [])
  end

  defp collect_ancestors_recursive(dir, git_root, acc) do
    new_acc = [dir | acc]

    cond do
      # Stop if we've reached the git repo root
      git_root && dir == git_root ->
        Enum.reverse(new_acc)

      # Stop if we've reached the filesystem root
      Path.dirname(dir) == dir ->
        Enum.reverse(new_acc)

      # Continue to parent
      true ->
        collect_ancestors_recursive(Path.dirname(dir), git_root, new_acc)
    end
  end

  @doc """
  Get the global skills configuration file path.
  """
  @spec global_config_file() :: String.t()
  def global_config_file do
    Path.join(agent_dir(), @skills_config_filename)
  end

  @doc """
  Get the global skills usage/curation sidecar path.
  """
  @spec global_usage_file() :: String.t()
  def global_usage_file do
    Path.join(agent_dir(), @skills_usage_filename)
  end

  @doc """
  Get the global skill curator state path.
  """
  @spec global_curator_state_file() :: String.t()
  def global_curator_state_file do
    Path.join(agent_dir(), @skills_curator_filename)
  end

  @doc """
  Get the global skill curator report directory.
  """
  @spec global_curator_report_dir() :: String.t()
  def global_curator_report_dir do
    Path.join(agent_dir(), @curator_report_dirname)
  end

  @doc """
  Get the project skills configuration file path.

  ## Parameters

  - `cwd` - The project working directory
  """
  @spec project_config_file(String.t()) :: String.t()
  def project_config_file(cwd) do
    Path.join([cwd, ".lemon", @skills_config_filename])
  end

  @doc """
  Get the project skills usage/curation sidecar path.
  """
  @spec project_usage_file(String.t()) :: String.t()
  def project_usage_file(cwd) do
    Path.join([cwd, ".lemon", @skills_usage_filename])
  end

  @doc """
  Get the project skill curator state path.
  """
  @spec project_curator_state_file(String.t()) :: String.t()
  def project_curator_state_file(cwd) do
    Path.join([cwd, ".lemon", @skills_curator_filename])
  end

  @doc """
  Get the project skill curator report directory.
  """
  @spec project_curator_report_dir(String.t()) :: String.t()
  def project_curator_report_dir(cwd) do
    Path.join([cwd, ".lemon", @curator_report_dirname])
  end

  @doc """
  Load the skills configuration.

  Merges global and project configuration, with project taking precedence.

  ## Parameters

  - `cwd` - The project working directory (optional)
  """
  @spec load_config(String.t() | nil) :: map()
  def load_config(cwd \\ nil) do
    global_config = load_config_file(global_config_file())

    if cwd do
      project_config = load_config_file(project_config_file(cwd))
      deep_merge(global_config, project_config)
    else
      global_config
    end
  end

  @doc """
  Save skill configuration.

  ## Parameters

  - `config` - The configuration map to save
  - `global` - Whether to save to global config (default: true)
  - `cwd` - Project directory for project config
  """
  @spec save_config(map(), boolean(), String.t() | nil) :: :ok | {:error, term()}
  def save_config(config, global \\ true, cwd \\ nil) do
    path =
      if global do
        global_config_file()
      else
        project_config_file(cwd)
      end

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        File.write(path, json)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if a skill is disabled.

  ## Parameters

  - `key` - The skill key
  - `cwd` - Project directory (optional)
  """
  @spec skill_disabled?(String.t(), String.t() | nil) :: boolean()
  def skill_disabled?(key, cwd \\ nil) do
    config = load_config(cwd)
    disabled = get_in(config, ["disabled"]) || []
    key in disabled
  end

  @doc """
  Enable a skill.

  ## Parameters

  - `key` - The skill key to enable

  ## Options

  - `:cwd` - Project directory (optional)
  - `:global` - Whether to modify global config (default: true)
  """
  @spec enable(String.t(), keyword()) :: :ok | {:error, term()}
  def enable(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    global = Keyword.get(opts, :global, true)

    config_path = if global, do: global_config_file(), else: project_config_file(cwd)
    config = load_config_file(config_path)

    disabled = Map.get(config, "disabled", [])
    disabled = List.delete(disabled, key)

    config = Map.put(config, "disabled", disabled)
    save_config(config, global, cwd)
  end

  @doc """
  Disable a skill.

  ## Parameters

  - `key` - The skill key to disable

  ## Options

  - `:cwd` - Project directory (optional)
  - `:global` - Whether to modify global config (default: true)
  """
  @spec disable(String.t(), keyword()) :: :ok | {:error, term()}
  def disable(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    global = Keyword.get(opts, :global, true)

    config_path = if global, do: global_config_file(), else: project_config_file(cwd)
    config = load_config_file(config_path)

    disabled = Map.get(config, "disabled", [])
    disabled = if key in disabled, do: disabled, else: [key | disabled]

    config = Map.put(config, "disabled", disabled)
    save_config(config, global, cwd)
  end

  @doc """
  Get skill-specific configuration.

  ## Parameters

  - `key` - The skill key
  - `cwd` - Project directory (optional)
  """
  @spec get_skill_config(String.t(), String.t() | nil) :: map()
  def get_skill_config(key, cwd \\ nil) do
    config = load_config(cwd)
    get_in(config, ["skills", key]) || %{}
  end

  @doc """
  Set skill-specific configuration.

  ## Parameters

  - `key` - The skill key
  - `skill_config` - The configuration to set

  ## Options

  - `:cwd` - Project directory (optional)
  - `:global` - Whether to modify global config (default: true)
  """
  @spec set_skill_config(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def set_skill_config(key, skill_config, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    global = Keyword.get(opts, :global, true)

    config_path = if global, do: global_config_file(), else: project_config_file(cwd)
    config = load_config_file(config_path)

    skills = Map.get(config, "skills", %{})
    skills = Map.put(skills, key, skill_config)

    config = Map.put(config, "skills", skills)
    save_config(config, global, cwd)
  end

  @doc """
  Ensure skills directories exist.
  """
  @spec ensure_dirs!() :: :ok
  def ensure_dirs! do
    File.mkdir_p!(global_skills_dir())
    :ok
  end

  # ============================================================================
  # MCP Server Configuration
  # ============================================================================

  @doc """
  Get configured MCP servers from application environment.

  Returns a list of MCP server configurations. Each configuration can be:
  - `{:stdio, command, args}` - Stdio transport with command and arguments
  - `{:stdio, command, args, opts}` - Stdio transport with filter options
  - `{:http, url}` - HTTP transport with URL
  - `{:http, url, opts}` - HTTP transport with URL and options
  - `{:sse, url}` - Legacy HTTP+SSE transport with URL
  - `{:sse, url, opts}` - Legacy HTTP+SSE transport with URL and options

  ## Configuration

  Configure MCP servers in your `config/config.exs`:

      config :lemon_skills, :mcp_servers, [
        {:stdio, "npx", ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]},
        {:stdio, "uvx", ["mcp-server-git", "--repository", "/path/to/repo"],
         allow_tools: ["git_status", "git_diff"]},
        {:http, "http://localhost:3000/mcp"},
        {:http, "https://api.example.com/mcp", [headers: [{"Authorization", "Bearer token"}]]},
        {:http, "https://oauth.example.com/mcp",
         [oauth: [
           client_id: "client",
           client_secret: "secret",
           scopes: ["tools"],
           token_auth_method: :client_secret_basic
         ]]},
        {:sse, "http://localhost:3001/sse"}
      ]

  Or via environment variable (JSON format):

      LEMON_MCP_SERVERS='[{"type":"stdio","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem"]}]'

  ## Examples

      iex> LemonSkills.Config.mcp_servers()
      [
        {:stdio, "npx", ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]},
        {:http, "http://localhost:3000/mcp"},
        {:sse, "http://localhost:3001/sse"}
      ]
  """
  @spec mcp_servers() :: [mcp_server_config()]
  def mcp_servers do
    # Check environment variable first
    case System.get_env("LEMON_MCP_SERVERS") do
      nil ->
        Application.get_env(:lemon_skills, :mcp_servers, [])

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, configs} when is_list(configs) ->
            Enum.flat_map(configs, &parse_mcp_server_config/1)

          _ ->
            require Logger
            Logger.warning("Invalid LEMON_MCP_SERVERS environment variable format")
            Application.get_env(:lemon_skills, :mcp_servers, [])
        end
    end
  end

  @doc """
  Validate MCP server configurations.

  Returns `{:ok, valid_configs}` for valid configurations, or
  `{:error, errors}` with a list of validation errors.

  ## Examples

      iex> configs = [{:stdio, "npx", ["-y", "server"]}, {:http, "invalid"}]
      iex> LemonSkills.Config.validate_mcp_servers(configs)
      {:error, [{:invalid, {:http, "invalid"}, "invalid HTTP URL: invalid"}]}
  """
  @spec validate_mcp_servers([mcp_server_config()]) ::
          {:ok, [mcp_server_config()]} | {:error, [mcp_validation_error()]}
  def validate_mcp_servers(configs) when is_list(configs) do
    {valid, errors} =
      Enum.reduce(configs, {[], []}, fn config, {valid_acc, error_acc} ->
        case do_validate_mcp_config(config) do
          :ok -> {[config | valid_acc], error_acc}
          {:error, reason} -> {valid_acc, [{:invalid, config, reason} | error_acc]}
        end
      end)

    if errors == [] do
      {:ok, Enum.reverse(valid)}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  # Internal validation - mirrors LemonSkills.McpSource.validate_config/1
  # to avoid circular dependency
  defp do_validate_mcp_config({:stdio, command, args})
       when is_binary(command) and is_list(args) do
    if String.trim(command) == "" do
      {:error, "stdio command cannot be empty"}
    else
      :ok
    end
  end

  defp do_validate_mcp_config({:stdio, command, args, opts})
       when is_binary(command) and is_list(args) and is_list(opts) do
    with :ok <- do_validate_mcp_config({:stdio, command, args}),
         :ok <- validate_mcp_filter_opts(opts) do
      :ok
    end
  end

  defp do_validate_mcp_config({:http, url, opts}) when is_binary(url) and is_list(opts) do
    with :ok <- validate_http_url(url),
         :ok <- validate_http_opts(opts) do
      :ok
    end
  end

  defp do_validate_mcp_config({:http, url}) when is_binary(url) do
    do_validate_mcp_config({:http, url, []})
  end

  defp do_validate_mcp_config({:sse, url, opts}) when is_binary(url) and is_list(opts) do
    with :ok <- validate_http_url(url),
         :ok <- validate_http_opts(opts) do
      :ok
    end
  end

  defp do_validate_mcp_config({:sse, url}) when is_binary(url) do
    do_validate_mcp_config({:sse, url, []})
  end

  defp do_validate_mcp_config(config) do
    {:error, "invalid MCP server config: #{inspect(config)}"}
  end

  @doc """
  Get MCP configuration for a specific project.

  Merges global and project-specific MCP configurations, with project
  configuration taking precedence.

  ## Parameters

  - `cwd` - Project working directory (optional)
  """
  @spec mcp_config(String.t() | nil) :: %{servers: [mcp_server_config()], enabled: boolean()}
  def mcp_config(cwd \\ nil) do
    global_config = load_mcp_config_from_file(global_mcp_config_file())

    project_config =
      if cwd do
        load_mcp_config_from_file(project_mcp_config_file(cwd))
      else
        %{}
      end

    # Merge configs - project takes precedence
    merged_servers =
      Map.get(project_config, "servers", []) ++
        Map.get(global_config, "servers", []) ++
        mcp_servers()

    # Convert JSON format to tuple format
    servers = Enum.flat_map(merged_servers, &parse_mcp_server_config/1)

    %{
      servers: servers,
      enabled: Map.get(project_config, "enabled", Map.get(global_config, "enabled", true))
    }
  end

  @doc """
  Get the global MCP configuration file path.
  """
  @spec global_mcp_config_file() :: String.t()
  def global_mcp_config_file do
    Path.join(agent_dir(), "mcp.json")
  end

  @doc """
  Get the project MCP configuration file path.

  ## Parameters

  - `cwd` - Project working directory
  """
  @spec project_mcp_config_file(String.t()) :: String.t()
  def project_mcp_config_file(cwd) do
    Path.join([cwd, ".lemon", "mcp.json"])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_config_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} when is_map(config) -> config
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, v1, v2 when is_map(v1) and is_map(v2) -> deep_merge(v1, v2)
      _key, _v1, v2 -> v2
    end)
  end

  # ============================================================================
  # MCP Configuration Helpers
  # ============================================================================

  defp load_mcp_config_from_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} when is_map(config) -> config
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  # Parse MCP server config from JSON format to tuple format
  defp parse_mcp_server_config(%{"type" => "stdio", "command" => command} = config)
       when is_binary(command) do
    args = Map.get(config, "args", [])

    opts =
      mcp_ready_timeout_opts(config) ++ mcp_filter_opts(config) ++ sampling_config_opts(config)

    if opts == [] do
      [{:stdio, command, args}]
    else
      [{:stdio, command, args, opts}]
    end
  end

  defp parse_mcp_server_config(%{"type" => "http", "url" => url} = config)
       when is_binary(url) do
    opts = http_config_opts(config)

    if opts == [] do
      [{:http, url}]
    else
      [{:http, url, opts}]
    end
  end

  defp parse_mcp_server_config(%{"type" => "sse", "url" => url} = config)
       when is_binary(url) do
    opts = sse_config_opts(config)

    if opts == [] do
      [{:sse, url}]
    else
      [{:sse, url, opts}]
    end
  end

  # Already in tuple format (from Application config)
  defp parse_mcp_server_config({:stdio, _command, _args} = config), do: [config]
  defp parse_mcp_server_config({:stdio, _command, _args, _opts} = config), do: [config]
  defp parse_mcp_server_config({:http, _url} = config), do: [config]
  defp parse_mcp_server_config({:http, _url, _opts} = config), do: [config]
  defp parse_mcp_server_config({:sse, _url} = config), do: [config]
  defp parse_mcp_server_config({:sse, _url, _opts} = config), do: [config]

  # Unknown format - skip
  defp parse_mcp_server_config(_config) do
    require Logger
    Logger.debug("Skipping unknown MCP server config format")
    []
  end

  defp http_config_opts(config) do
    header_opts =
      case Map.get(config, "headers") do
        headers when is_map(headers) -> [headers: Map.to_list(headers)]
        _ -> []
      end

    header_opts ++
      oauth_config_opts(config) ++ mcp_ready_timeout_opts(config) ++ mcp_filter_opts(config)
  end

  defp sse_config_opts(config) do
    header_opts =
      case Map.get(config, "headers") do
        headers when is_map(headers) -> [headers: Map.to_list(headers)]
        _ -> []
      end

    header_opts ++ mcp_timeout_opts(config) ++ mcp_filter_opts(config)
  end

  defp oauth_config_opts(%{"oauth" => oauth}) when is_map(oauth) do
    opts =
      [
        client_id: Map.get(oauth, "client_id"),
        client_secret: Map.get(oauth, "client_secret") || Map.get(oauth, "client-secret"),
        client_secret_secret:
          Map.get(oauth, "client_secret_secret") || Map.get(oauth, "client-secret-secret"),
        token_secret: Map.get(oauth, "token_secret") || Map.get(oauth, "token-secret"),
        flow: Map.get(oauth, "flow"),
        redirect_uri: Map.get(oauth, "redirect_uri") || Map.get(oauth, "redirect-uri"),
        scope: Map.get(oauth, "scope"),
        scopes: string_list(oauth, "scopes"),
        authorization_approval:
          if(Map.has_key?(oauth, "authorization_approval"),
            do: Map.get(oauth, "authorization_approval"),
            else: Map.get(oauth, "authorization-approval")
          ),
        authorization_timeout_ms:
          Map.get(oauth, "authorization_timeout_ms") ||
            Map.get(oauth, "authorization-timeout-ms"),
        token_auth_method:
          Map.get(oauth, "token_auth_method") || Map.get(oauth, "token-auth-method")
      ]
      |> Enum.reject(fn
        {:scopes, []} -> true
        {_key, nil} -> true
        {_key, ""} -> true
        _ -> false
      end)

    if opts == [], do: [], else: [oauth: opts]
  end

  defp oauth_config_opts(_config), do: []

  defp sampling_config_opts(%{"sampling" => sampling}) when is_map(sampling) do
    opts =
      [
        mode: Map.get(sampling, "mode"),
        reviewer: sampling_reviewer(sampling),
        max_tokens: Map.get(sampling, "max_tokens") || Map.get(sampling, "maxTokens"),
        allowed_models: string_list(sampling, "allowed_models")
      ]
      |> Enum.reject(fn
        {:allowed_models, []} -> true
        {_key, nil} -> true
        {_key, ""} -> true
        _ -> false
      end)

    if opts == [], do: [], else: [sampling_policy: opts]
  end

  defp sampling_config_opts(_config), do: []

  defp sampling_reviewer(%{"reviewer" => reviewer})
       when reviewer in ["ops_approval", "approval"] do
    :ops_approval
  end

  defp sampling_reviewer(%{"require_approval" => true}), do: :ops_approval
  defp sampling_reviewer(_sampling), do: nil

  defp mcp_filter_opts(config) do
    [
      allow_tools: string_list(config, "allow_tools"),
      block_tools: string_list(config, "block_tools"),
      allow_resources: string_list(config, "allow_resources"),
      block_resources: string_list(config, "block_resources"),
      allow_prompts: string_list(config, "allow_prompts"),
      block_prompts: string_list(config, "block_prompts")
    ]
    |> Enum.reject(fn {_key, value} -> value == [] end)
  end

  defp mcp_timeout_opts(config) do
    [
      ready_timeout_ms:
        Map.get(config, "ready_timeout_ms") || Map.get(config, "ready-timeout-ms"),
      timeout_ms: Map.get(config, "timeout_ms") || Map.get(config, "timeout-ms")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp mcp_ready_timeout_opts(config) do
    [
      ready_timeout_ms: Map.get(config, "ready_timeout_ms") || Map.get(config, "ready-timeout-ms")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp string_list(config, key) do
    case Map.get(config, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

  defp validate_mcp_filter_opts(opts) do
    allowed_keys = [
      :allow_tools,
      :block_tools,
      :allow_resources,
      :block_resources,
      :allow_prompts,
      :block_prompts
    ]

    case Enum.find(opts, fn {key, value} ->
           key in allowed_keys and not string_list?(value)
         end) do
      nil ->
        with :ok <-
               validate_positive_timeout(Keyword.get(opts, :ready_timeout_ms), "ready_timeout_ms"),
             :ok <- validate_positive_timeout(Keyword.get(opts, :timeout_ms), "timeout_ms") do
          validate_sampling_policy(Keyword.get(opts, :sampling_policy))
        end

      {key, _value} ->
        {:error, "#{key} must be a list of strings"}
    end
  end

  defp validate_positive_timeout(nil, _name), do: :ok
  defp validate_positive_timeout(value, _name) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_timeout(_value, name) do
    {:error, "#{name} must be a positive integer"}
  end

  defp validate_sampling_policy(nil), do: :ok

  defp validate_sampling_policy(policy) when is_list(policy) do
    mode = Keyword.get(policy, :mode)
    reviewer = Keyword.get(policy, :reviewer)
    max_tokens = Keyword.get(policy, :max_tokens)
    allowed_models = Keyword.get(policy, :allowed_models, [])
    approval_timeout_ms = Keyword.get(policy, :approval_timeout_ms)

    cond do
      not is_nil(mode) and
          mode not in [:model, :reviewed_model, :deny, "model", "reviewed_model", "deny"] ->
        {:error, "sampling_policy.mode must be model, reviewed_model, or deny"}

      not is_nil(reviewer) and
          not (is_function(reviewer, 1) or
                   reviewer in [:ops_approval, "ops_approval", :approval, "approval", true]) ->
        {:error, "sampling_policy.reviewer must be a function or ops_approval"}

      not is_nil(max_tokens) and (not is_integer(max_tokens) or max_tokens <= 0) ->
        {:error, "sampling_policy.max_tokens must be a positive integer"}

      not string_list?(allowed_models) ->
        {:error, "sampling_policy.allowed_models must be a list of strings"}

      not is_nil(approval_timeout_ms) and
          (not is_integer(approval_timeout_ms) or approval_timeout_ms <= 0) ->
        {:error, "sampling_policy.approval_timeout_ms must be a positive integer"}

      true ->
        :ok
    end
  end

  defp validate_sampling_policy(_policy), do: {:error, "sampling_policy must be a keyword list"}

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp validate_http_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        :ok

      _ ->
        {:error, "invalid HTTP URL: #{url}"}
    end
  end

  defp validate_http_opts(opts) do
    with :ok <- validate_mcp_filter_opts(opts),
         :ok <- validate_http_headers(Keyword.get(opts, :headers, [])),
         :ok <- validate_http_oauth(Keyword.get(opts, :oauth, [])) do
      :ok
    end
  end

  defp validate_http_headers(headers) when is_list(headers) do
    if Enum.all?(headers, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      :ok
    else
      {:error, "headers must be a list of string tuples"}
    end
  end

  defp validate_http_headers(_headers), do: {:error, "headers must be a list of string tuples"}

  defp validate_http_oauth([]), do: :ok
  defp validate_http_oauth(nil), do: :ok

  defp validate_http_oauth(oauth) when is_list(oauth) do
    client_id = Keyword.get(oauth, :client_id)
    client_secret = Keyword.get(oauth, :client_secret)
    client_secret_secret = Keyword.get(oauth, :client_secret_secret)
    token_secret = Keyword.get(oauth, :token_secret)
    flow = Keyword.get(oauth, :flow)
    redirect_uri = Keyword.get(oauth, :redirect_uri)
    scope = Keyword.get(oauth, :scope)
    scopes = Keyword.get(oauth, :scopes)
    authorization_timeout_ms = Keyword.get(oauth, :authorization_timeout_ms)
    token_auth_method = Keyword.get(oauth, :token_auth_method)
    authorization_code_provider = Keyword.get(oauth, :authorization_code_provider)

    cond do
      not is_binary(client_id) or client_id == "" ->
        {:error, "oauth.client_id must be a non-empty string"}

      requires_client_secret?(flow, authorization_code_provider) and
        not configured_secret?(client_secret) and not configured_secret?(client_secret_secret) ->
        {:error, "oauth.client_secret must be a non-empty string"}

      not is_nil(client_secret_secret) and not configured_secret?(client_secret_secret) ->
        {:error, "oauth.client_secret_secret must be a non-empty string"}

      not is_nil(token_secret) and not configured_secret?(token_secret) ->
        {:error, "oauth.token_secret must be a non-empty string"}

      not is_nil(flow) and not oauth_flow?(flow) ->
        {:error, "oauth.flow must be client_credentials or authorization_code_pkce"}

      not is_nil(redirect_uri) and not is_binary(redirect_uri) ->
        {:error, "oauth.redirect_uri must be a string"}

      not is_nil(scope) and not is_binary(scope) ->
        {:error, "oauth.scope must be a string"}

      not is_nil(scopes) and not string_list?(scopes) ->
        {:error, "oauth.scopes must be a list of strings"}

      not is_nil(authorization_timeout_ms) and
          (not is_integer(authorization_timeout_ms) or authorization_timeout_ms <= 0) ->
        {:error, "oauth.authorization_timeout_ms must be a positive integer"}

      not is_nil(token_auth_method) and
          token_auth_method not in [
            :client_secret_post,
            :client_secret_basic,
            :post,
            :basic,
            "client_secret_post",
            "client_secret_basic",
            "post",
            "basic"
          ] ->
        {:error, "oauth.token_auth_method must be client_secret_post or client_secret_basic"}

      true ->
        :ok
    end
  end

  defp validate_http_oauth(_oauth), do: {:error, "oauth must be a keyword list"}

  defp requires_client_secret?(flow, authorization_code_provider) do
    not auth_code_flow?(flow) and not is_function(authorization_code_provider)
  end

  defp configured_secret?(value), do: is_binary(value) and value != ""

  defp oauth_flow?(flow),
    do:
      flow in [
        :client_credentials,
        :authorization_code_pkce,
        "client_credentials",
        "authorization_code_pkce",
        "pkce"
      ]

  defp auth_code_flow?(flow),
    do: flow in [:authorization_code_pkce, "authorization_code_pkce", "pkce"]
end
