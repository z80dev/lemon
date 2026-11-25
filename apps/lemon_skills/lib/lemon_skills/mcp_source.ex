defmodule LemonSkills.McpSource do
  @moduledoc """
  MCP (Model Context Protocol) tool source: connects to configured MCP servers,
  caches the tools they advertise, and invokes them on behalf of an agent.

  The application starts a global source under `LemonSkills.McpSource`.
  Session owners can start isolated instances with `name: nil` (or a registered
  name) and `configs: [...]`; explicit configurations never reload global config.
  Per-instance discovery and calls accept the source pid. Cached tool closures
  capture that pid, so they cannot cross into a replacement session.

  ## Configuration

  Servers come from `LemonSkills.Config.mcp_servers/0`, which reads the
  `LEMON_MCP_SERVERS` environment variable (a JSON array) and falls back to
  `config :lemon_skills, :mcp_servers`. Each entry is a `t:server_config/0`
  tuple: `:stdio` (command plus args), `:http`, or `:sse` (URL). Validate one
  with `validate_config/1` before installing it.

  ## Disabled mode

  MCP is off when `config :lemon_skills, :mcp_disabled` is true, when
  `LEMON_MCP_DISABLED` is set to a truthy value, or when no MCP client library
  is available in the release. The GenServer still starts — it is part of the
  supervision tree either way — but answers as an empty source: `[]` from
  `discover_tools/1`, `:error` from `get_tool/1`, and
  `{:error, :mcp_disabled}` from `call_tool/3`. Check with `mcp_enabled?/0`.

  ## Caching and scopes

  Each working directory is a scope with its own server list (stdio servers
  run in that directory). A configuration load replaces only its own scope's
  list and cached tools; other scopes keep theirs. A project scope is held by
  the processes that discovered it (normally a session): when the last one
  exits, the scope is evicted and the clients no other scope uses are closed.
  At most `:max_project_scopes` project scopes stay loaded (default 16, or
  `config :lemon_skills, :mcp_max_project_scopes`); beyond that
  the least recently used scope is evicted and reloads on its next discovery.

  `discover_tools/2` reloads the scope's configuration and serves the committed
  snapshot of its connected servers. It waits at most `:discovery_wait_ms`
  (default ten seconds, or `config :lemon_skills, :mcp_discovery_wait_ms`) for
  servers that have no usable connection yet; slower servers keep connecting
  in the background, one supervised worker per server, and appear in later
  discoveries. A connected server's snapshot is refreshed in the background
  once it is older than five minutes. Pass `force_refresh: true`, or call
  `refresh/0`, to re-ask every server and wait for the result (at most ten
  minutes, including OAuth; expiry returns `{:error, :timeout}`).

  A failed startup, failed discovery or lost connection retries with jittered
  exponential backoff (about 0.5, 1, 2 and 4 seconds); after that, or after
  more than five failures within thirty seconds, the server is unavailable
  until an explicit `refresh/0`. Periodic refreshes never retry it.

  Status, inventory and approval reads serve committed state and never wait for
  a worker. Tool requests retain their configured timeout (at most five
  minutes). A dispatched request that times out or loses its connection returns
  `{:error, :outcome_unknown}`: it may have executed and must not be replayed.
  Closing a source cancels its workers and releases provisional and live clients.

  ## Native workload ownership

  Stdio clients use `LemonCore.NativeProcess.open/2` through the standalone MCP
  library's host callback. When native tracking is enabled, client startup and
  dispatched protocol requests record unsupported whole-workload ownership:
  a local process group cannot contain arbitrary MCP descendants or remote work.
  Failed responses and timeouts retain that uncertainty. Cached reads and proven
  pre-dispatch refusals (such as a missing executable or invalid tool parameters)
  do not record work.
  """

  use GenServer

  require Logger

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.OAuth.LocalCallbackListener
  alias LemonCore.Secrets
  alias LemonMCP.Client

  @default_cache_ttl_ms :timer.minutes(5)
  @default_refresh_interval_ms :timer.minutes(1)
  @default_discovery_wait_ms :timer.seconds(10)
  @default_max_project_scopes 16
  @client_ready_timeout_ms 5_000
  @client_request_timeout_ms 10_000
  # MCP caller policy: one ten-minute budget covers configuration I/O,
  # discovery and OAuth for forced refreshes. Tool calls inherit the existing
  # five-minute request cap; five seconds allows local reply delivery.
  @operation_timeout_ms :timer.minutes(10)
  @call_timeout_ms :timer.minutes(5) + 5_000
  @oauth_authorization_timeout_ms :timer.minutes(5)
  @reconnect_base_ms 500
  @reconnect_attempts 4
  @crash_window_ms 30_000
  @crash_storm_limit 5
  @list_changed_methods [
    "notifications/tools/list_changed",
    "notifications/resources/list_changed",
    "notifications/prompts/list_changed"
  ]

  @typedoc "MCP server configuration"
  @type server_config ::
          {:stdio, command :: String.t(), args :: [String.t()]}
          | {:stdio, command :: String.t(), args :: [String.t()], opts :: keyword()}
          | {:http, url :: String.t(), opts :: keyword()}
          | {:sse, url :: String.t(), opts :: keyword()}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the MCP source GenServer.

  ## Options

  - `:name` — registration (default `#{inspect(__MODULE__)}`; `nil` for none)
  - `:configs` / `:cwd` — explicit server configurations and their directory;
    such a source never reloads global configuration
  - `:owner`, `:custodian` — processes whose exit stops the source
  - `:cache_ttl_ms`, `:refresh_interval_ms` — snapshot age and refresh tick
  - `:discovery_wait_ms` — bound for a plain `discover_tools/2`
  - `:max_project_scopes` — loaded project scopes before LRU eviction
  """
  def start_link(opts \\ []) do
    opts = Keyword.put(opts, :disabled, not mcp_enabled?())

    registration =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, registration)
  end

  @doc """
  Returns the tools of the connected MCP servers configured for one scope.

  Each tool is a `LemonAgent.Types.AgentTool` whose `execute` closure routes back
  through `call_tool/3`, so the caller can merge them straight into an agent's
  tool list. The calling process holds the `:cwd` project scope until it exits.

  ## Options

  - `:cwd` — project scope (default: the global scope)
  - `:force_refresh` — re-query every server of the scope and wait for the
    result instead of serving the snapshot (default: `false`)

  Without `:force_refresh` the reply is bounded by `:discovery_wait_ms`: servers
  still connecting after that are omitted and keep connecting in the background.

  Returns `[]` when MCP is disabled, and also when it is enabled but no server is
  configured or reachable — a caller cannot distinguish those cases from the
  return value alone; use `status/0` or `mcp_enabled?/0` for that.
  Worker admission, configuration-load or deadline failures return
  `{:error, reason}` rather than treating an unavailable discovery as an empty
  successful inventory.
  """
  @spec discover_tools(keyword()) :: [AgentTool.t()] | {:error, atom()}
  def discover_tools(opts \\ []), do: discover_tools(__MODULE__, opts)

  @spec discover_tools(GenServer.server(), keyword()) :: [AgentTool.t()] | {:error, atom()}
  def discover_tools(server, opts) do
    GenServer.call(server, {:discover_tools, opts}, @operation_timeout_ms + 5_000)
  end

  @doc "Discover all configured clients, failing closed if any connection or discovery fails."
  def discover_ready(server),
    do: GenServer.call(server, :discover_ready, @operation_timeout_ms + 5_000)

  @doc """
  Stable profile-native execution alias for a public server name, HTTP endpoint,
  and raw remote tool name. The public endpoint includes path/query; host/scheme
  case and default ports are canonicalized. Credentials, allowlists and DNS pins
  never enter the identity. Aliases are at most 64 ASCII bytes.
  """
  @spec execution_name(String.t(), String.t(), String.t()) :: String.t()
  def execution_name(name, url, raw_name) do
    profile_alias(name, url, {:tool, raw_name}, "mcp_#{server_slug(name)}_#{tool_slug(raw_name)}")
  end

  @doc false
  def valid_remote_name?(name),
    do:
      is_binary(name) and String.valid?(name) and byte_size(name) in 1..128 and
        not Regex.match?(~r/[\x00-\x20\x7f]/, name)

  defp profile_alias(name, url, selector, prefix) do
    uri = URI.parse(url)
    scheme = String.downcase(uri.scheme)
    host = String.downcase(uri.host)
    default_port = if scheme == "https", do: 443, else: 80
    port = if uri.port == default_port, do: nil, else: uri.port

    endpoint =
      URI.to_string(%{uri | scheme: scheme, host: host, port: port, path: uri.path || "/"})

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({name, endpoint, selector}))
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    String.slice(prefix, 0, 31) <> "_" <> digest
  end

  @doc """
  Read the connected clients' raw-name tool inventory, independent of executable
  allowlists. Credentials are scrubbed before leaving the source; schemas that
  would require redaction are omitted rather than silently changed.
  """
  def remote_tools(server) do
    GenServer.call(server, :remote_tools, @operation_timeout_ms + 5_000)
  catch
    :exit, _ -> {:error, :discovery_failed}
  end

  @doc """
  Return locally configured approval modes keyed by published tool name.

  `:tool_approvals` selectors are raw remote tool names, or MCP method names
  `resources/list`, `resources/read`, `prompts/list`, and `prompts/get` for the
  host-provided utility tools. Remote metadata never supplies approval policy.
  Profile-owned HTTP sessions report `:never` here only to defer to the native
  ToolPolicy/approval floor; this metadata is not an authorization grant.
  """
  def approval_policy(server \\ __MODULE__), do: GenServer.call(server, :approval_policy)

  @doc """
  Looks up a single discovered tool by its namespaced name.

  Returns `{:ok, tool}` when the name is in the current cache, and `:error` when
  it is not — including when MCP is disabled, or when the tool exists on a server
  that has not been discovered yet (call `discover_tools/1` first).
  """
  @spec get_tool(String.t()) :: {:ok, AgentTool.t()} | :error
  def get_tool(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get_tool, name})
  end

  @doc """
  Invokes a discovered MCP tool and returns its result.

  `tool_name` is the namespaced name from `discover_tools/1` and `params` is the
  argument map matching that tool's schema. `opts` is passed through to the MCP
  client for the request.

  Returns `{:ok, %LemonAgent.Types.AgentToolResult{}}` on success, or
  `{:error, reason}`: `:mcp_disabled` when MCP is off, `:not_found` when the name
  is not in the tool cache, `:not_connected` when the owning server is configured
  but its client is down, or the error term the MCP client reported. Requests
  default to 10 seconds (maximum 5 minutes). A timeout or lost connection after
  dispatch returns `:outcome_unknown`, never proof of cancellation; invocations
  are never automatically replayed.
  """
  @spec call_tool(String.t(), map(), keyword()) ::
          {:ok, AgentToolResult.t()} | {:error, term()}
  def call_tool(tool_name, params, opts \\ []),
    do: call_tool(__MODULE__, tool_name, params, opts)

  def call_tool(server, tool_name, params, opts) do
    GenServer.call(server, {:call_tool, tool_name, params, opts}, @call_timeout_ms)
  catch
    :exit, {:noproc, _} -> {:error, :not_connected}
    :exit, _ -> {:error, :outcome_unknown}
  end

  @doc """
  Re-queries every configured MCP server and replaces the tool cache.

  Returns `:ok` after refresh, or `{:error, :timeout}` if its overall deadline expires.
  """
  @spec refresh(GenServer.server()) :: :ok | {:error, atom()}
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh, @operation_timeout_ms + 5_000)
  end

  @doc """
  Returns a map describing every configured MCP server: its connection state and
  the tools it contributed. Intended for diagnostics (`mix lemon.doctor`, the
  control plane status method), not for control flow.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  Returns a credential-free inventory of the servers configured for one scope
  (`cwd: nil`, the default, is the global/application scope), in configuration
  order.

  Each server reports a stable `id` (configuration digest prefix), the configured
  `name`, a `label` (executable basename or URL host — never arguments, paths,
  URL credentials, headers or environment), its transport, connection state, the
  source's fixed `last_error` text, counts, approval default, and the published
  tools (published name, raw remote name or utility kind, remote description).

  This is a pure read: it neither reloads configuration nor connects. A scope
  that has never been discovered reports `loaded: false`. `project_scopes` lists
  every project directory a session has loaded (for project trust status).
  `refresh/0` reloads every loaded scope and reconnects.
  """
  @spec inventory(keyword()) :: map()
  def inventory(opts \\ []), do: inventory(__MODULE__, opts)

  @spec inventory(GenServer.server(), keyword()) :: map()
  def inventory(server, opts), do: GenServer.call(server, {:inventory, opts})

  @doc """
  Checks one server configuration without installing it.

  Returns `:ok`, or `{:error, message}` with a human-readable reason: an empty
  stdio command, a URL that is not valid HTTP(S), or a tuple that is not a
  recognised `t:server_config/0` shape at all. `LemonSkills.Config.mcp_servers/0`
  entries are checked with the same rules by
  `LemonSkills.Config.validate_mcp_servers/1`.
  """
  @spec validate_config(server_config()) :: :ok | {:error, String.t()}
  def validate_config({:stdio, command, args})
      when is_binary(command) and is_list(args) do
    cond do
      String.trim(command) == "" -> {:error, "stdio command cannot be empty"}
      not Enum.all?(args, &is_binary/1) -> {:error, "stdio args must be strings"}
      true -> :ok
    end
  end

  def validate_config({:stdio, command, args, opts})
      when is_binary(command) and is_list(args) and is_list(opts) do
    with :ok <- LemonSkills.Config.validate_mcp_metadata(opts) do
      case LemonSkills.Config.validate_mcp_servers([{:stdio, command, args, opts}]) do
        {:ok, _} -> :ok
        {:error, [{:invalid, _, reason}]} -> {:error, reason}
      end
    end
  end

  def validate_config({:http, url, opts}) when is_binary(url) and is_list(opts) do
    with :ok <- LemonSkills.Config.validate_mcp_metadata(opts),
         :ok <- validate_http_url(url),
         :ok <- validate_http_opts(opts) do
      :ok
    end
  end

  def validate_config({:http, url}) when is_binary(url) do
    validate_config({:http, url, []})
  end

  def validate_config({:sse, url, opts}) when is_binary(url) and is_list(opts) do
    with :ok <- LemonSkills.Config.validate_mcp_metadata(opts),
         :ok <- validate_http_url(url),
         :ok <- validate_http_opts(opts) do
      :ok
    end
  end

  def validate_config({:sse, url}) when is_binary(url) do
    validate_config({:sse, url, []})
  end

  def validate_config(config) do
    {:error, "invalid MCP server config: #{inspect(config)}"}
  end

  @doc """
  True when MCP tools can be used in this runtime.

  False when `config :lemon_skills, :mcp_disabled` is true or when
  `LEMON_MCP_DISABLED` is `1`/`true`/`yes` (any case). Read at boot to decide
  how the GenServer starts, and safe to call from anywhere afterwards — it
  consults configuration, not the server's state.
  """
  @spec mcp_enabled?() :: boolean()
  def mcp_enabled? do
    not (Application.get_env(:lemon_skills, :mcp_disabled, false) ||
           System.get_env("LEMON_MCP_DISABLED") in ["1", "true", "TRUE", "yes", "YES"])
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    disabled = Keyword.get(opts, :disabled, false)

    monitor_refs =
      for key <- [:owner, :custodian], pid = Keyword.get(opts, key), is_pid(pid), into: %{} do
        {key, Process.monitor(pid)}
      end

    owner_refs = Map.values(monitor_refs)

    if disabled do
      {:ok,
       %{
         disabled: true,
         tool_cache: %{},
         servers: %{},
         owner_refs: owner_refs,
         custodian_ref: monitor_refs[:custodian]
       }}
    else
      state = %{
        disabled: false,
        servers: %{},
        tool_cache: %{},
        scopes: %{},
        cache_ttl_ms: Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms),
        refresh_interval_ms:
          Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms),
        discovery_wait_ms:
          Keyword.get_lazy(opts, :discovery_wait_ms, fn ->
            Application.get_env(:lemon_skills, :mcp_discovery_wait_ms, @default_discovery_wait_ms)
          end),
        max_project_scopes:
          Keyword.get_lazy(opts, :max_project_scopes, fn ->
            Application.get_env(
              :lemon_skills,
              :mcp_max_project_scopes,
              @default_max_project_scopes
            )
          end),
        refresh_timer: nil,
        configs: Keyword.get(opts, :configs),
        cwd: Keyword.get(opts, :cwd),
        source: self(),
        owner_refs: owner_refs,
        custodian_ref: monitor_refs[:custodian],
        scope_owners: %{},
        owner_monitors: %{},
        scope_used: %{},
        load_seq: 0,
        applied_load: %{},
        workers: %{},
        waiters: %{},
        sweep: nil,
        invocations: %{}
      }

      state =
        case start_load(state, own_scope(state)) do
          {:ok, state, _ref} -> state
          {:error, _reason} -> state
        end

      {:ok, schedule_refresh(state)}
    end
  end

  @impl true
  def handle_call(:discover_ready, _from, %{disabled: true} = state) do
    {:reply, {:error, :mcp_disabled}, state}
  end

  def handle_call(:discover_ready, from, state) do
    {:noreply, add_waiter(state, from, :ready, [own_scope(state)], @operation_timeout_ms)}
  end

  def handle_call(:remote_tools, _from, %{disabled: true} = state) do
    {:reply, {:error, :mcp_disabled}, state}
  end

  def handle_call(:remote_tools, from, state) do
    servers = state.servers

    case start_task(fn -> remote_tool_inventory(servers) end) do
      {:ok, task} ->
        {:noreply, track_invocation(state, task, from, @operation_timeout_ms, {:error, :timeout})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:approval_policy, _from, state) do
    policies =
      Map.new(state.tool_cache, fn {name, entry} ->
        config = state.servers[entry.server_name].config

        opts =
          case config do
            {:stdio, _, _, opts} -> opts
            {transport, _, opts} when transport in [:http, :sse] -> opts
            _ -> []
          end

        default = Keyword.get(opts, :approval, :never)
        selector = approval_selector(entry.original_name)
        mode = Map.get(Keyword.get(opts, :tool_approvals, %{}), selector, default)

        mode = if Keyword.get(opts, :profile_owned, false), do: :never, else: mode
        {name, if(mode in [:never, "never"], do: :never, else: :always)}
      end)

    {:reply, policies, state}
  end

  def handle_call({:discover_tools, _opts}, _from, %{disabled: true} = state) do
    {:reply, [], state}
  end

  # The caller holds a project scope until it exits. A plain discovery serves
  # the committed snapshot once the scope's configuration is loaded, waiting
  # at most `discovery_wait_ms` for servers that have no usable connection
  # yet; refreshes continue in the background.
  def handle_call({:discover_tools, opts}, {pid, _} = from, state) do
    scope = source_scope(state, opts)
    state = state |> hold_scope(scope, pid) |> touch_scope(scope)

    {mode, timeout} =
      if Keyword.get(opts, :force_refresh, false),
        do: {:force, @operation_timeout_ms},
        else: {:snapshot, state.discovery_wait_ms}

    {:noreply, add_waiter(state, from, mode, [scope], timeout)}
  end

  def handle_call({:get_tool, _name}, _from, %{disabled: true} = state) do
    {:reply, :error, state}
  end

  def handle_call({:get_tool, name}, _from, state) do
    result =
      case Map.get(state.tool_cache, name) do
        nil -> :error
        %{tool: tool} -> {:ok, tool}
      end

    {:reply, result, state}
  end

  def handle_call({:call_tool, _tool_name, _params, _opts}, _from, %{disabled: true} = state) do
    {:reply, {:error, :mcp_disabled}, state}
  end

  def handle_call({:call_tool, tool_name, params, opts}, from, state) do
    case Map.get(state.tool_cache, tool_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{server_name: server_name, original_name: original_name} ->
        case Map.get(state.servers, server_name) do
          %{client: client, client_module: client_mod, connected: true, config: config}
          when is_pid(client) ->
            if executable_call_allowed?(config, original_name) do
              timeout = request_timeout(opts, config)

              case start_task(fn ->
                     try do
                       case call_mcp_entry(client_mod, client, original_name, params,
                              timeout_ms: timeout
                            ) do
                         {:error, reason}
                         when reason in [:timeout, :not_connected, :connection_closed] ->
                           {:error, :outcome_unknown}

                         reply ->
                           reply
                       end
                     rescue
                       _ -> {:error, :invalid_tool_result}
                     catch
                       :exit, _ -> {:error, :outcome_unknown}
                     end
                   end) do
                {:ok, task} ->
                  # Invocation caller policy: the protocol deadline owns remote
                  # timeout; one second only bounds local worker/reply teardown.
                  state =
                    state
                    |> touch_server_scopes(server_name)
                    |> track_invocation(task, from, timeout + 1_000, {:error, :outcome_unknown})

                  {:noreply, state}

                {:error, reason} ->
                  {:reply, {:error, reason}, state}
              end
            else
              {:reply, {:error, :not_found}, state}
            end

          _ ->
            {:reply, {:error, :not_connected}, state}
        end
    end
  end

  def handle_call(:refresh, _from, %{disabled: true} = state) do
    {:reply, :ok, state}
  end

  # Clears every backoff and breaker, reloads the global scope and every
  # loaded project scope (so revoked project servers are evicted rather than
  # reconnected), then refreshes every server.
  def handle_call(:refresh, from, state) do
    state = reset_backoff(state)
    scopes = Enum.uniq([own_scope(state) | Map.keys(state.scopes)])
    {:noreply, add_waiter(state, from, :refresh, scopes, @operation_timeout_ms)}
  end

  def handle_call(:status, _from, %{disabled: true} = state) do
    {:reply, %{disabled: true, servers: %{}, cached_tools: 0}, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      disabled: false,
      servers:
        Map.new(state.servers, fn {name, server} ->
          {name,
           %{
             connected: server.connected,
             tool_count: length(server.tools),
             resource_count: length(Map.get(server, :resources, [])),
             prompt_count: length(Map.get(server, :prompts, [])),
             capabilities: Map.get(server, :capabilities, %{}),
             last_error: server.last_error
           }}
        end),
      cached_tools: map_size(state.tool_cache),
      cache_ttl_ms: state.cache_ttl_ms
    }

    {:reply, status, state}
  end

  def handle_call({:inventory, _opts}, _from, %{disabled: true} = state) do
    {:reply, %{disabled: true, loaded: false, servers: [], project_scopes: []}, state}
  end

  def handle_call({:inventory, opts}, _from, state) do
    scope = source_scope(state, opts)
    project_scopes = state.scopes |> Map.keys() |> Enum.filter(&is_binary/1) |> Enum.sort()

    reply =
      case Map.fetch(state.scopes, scope) do
        {:ok, names} ->
          servers =
            names
            |> Enum.flat_map(fn name ->
              case Map.fetch(state.servers, name) do
                {:ok, server} -> [inventory_entry(name, server, state.tool_cache)]
                :error -> []
              end
            end)

          %{disabled: false, loaded: true, servers: servers, project_scopes: project_scopes}

        :error ->
          %{disabled: false, loaded: false, servers: [], project_scopes: project_scopes}
      end

    {:reply, reply, state}
  end

  # A worker registers each client it starts, so cancelling the worker also
  # releases its provisional clients.
  def handle_call({:worker_client, worker, client, mod}, _from, state) do
    case Enum.find(Map.get(state, :workers, %{}), fn {_ref, w} -> w.task.pid == worker end) do
      {ref, w} ->
        Process.link(client)
        workers = Map.put(state.workers, ref, %{w | clients: Map.put(w.clients, client, mod)})
        {:reply, :ok, %{state | workers: workers}}

      nil ->
        kill_client(client)
        {:reply, {:error, :discovery_failed}, state}
    end
  end

  def handle_call({:handoff_custodian, custodian}, _from, state) do
    if state.custodian_ref, do: Process.demonitor(state.custodian_ref, [:flush])
    ref = Process.monitor(custodian)
    refs = [ref | List.delete(state.owner_refs, state.custodian_ref)]
    {:reply, :ok, %{state | custodian_ref: ref, owner_refs: refs}}
  end

  @impl true
  def handle_cast(:close, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(:periodic_refresh, %{disabled: true} = state) do
    {:noreply, state}
  end

  # Only connected servers whose snapshot is older than the cache TTL are
  # refreshed. Disconnected servers retry on their own backoff timer, and an
  # unavailable server waits for an explicit `refresh/1`.
  def handle_info(:periodic_refresh, state) do
    now = System.monotonic_time(:millisecond)

    state =
      Enum.reduce(state.servers, state, fn {name, server}, state ->
        if server.connected and stale?(server, state, now),
          do: start_refresh(state, name),
          else: state
      end)

    {:noreply, state |> start_trust_sweep() |> schedule_refresh()}
  end

  def handle_info({ref, result}, %{workers: workers} = state) when is_map_key(workers, ref) do
    {:noreply, worker_done(state, ref, result)}
  end

  def handle_info({ref, result}, %{invocations: invocations} = state)
      when is_map_key(invocations, ref) do
    {invocation, invocations} = Map.pop(invocations, ref)
    finish_invocation(invocation, result)
    {:noreply, %{state | invocations: invocations}}
  end

  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:waiter_timeout, ref}, state) do
    case state.waiters do
      %{^ref => waiter} ->
        {:noreply, reply_waiter(state, ref, waiter, waiter_timeout(state, waiter))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:invocation_timeout, ref}, state) do
    case Map.pop(state.invocations, ref) do
      {nil, _} ->
        {:noreply, state}

      {invocation, invocations} ->
        Process.exit(invocation.task.pid, :kill)
        finish_invocation(invocation, invocation.timeout_reply)
        {:noreply, %{state | invocations: invocations}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    cond do
      ref in state.owner_refs ->
        {:stop, :normal, state}

      state.disabled ->
        {:noreply, state}

      Map.has_key?(state.workers, ref) ->
        {:noreply, worker_failed(state, ref)}

      true ->
        state =
          state
          |> down_invocations(ref)
          |> down_waiters(ref)
          |> release_owner(pid, ref)
          |> progress_waiters()

        {:noreply, state}
    end
  end

  def handle_info({:EXIT, client, _reason}, state) do
    case Enum.find(state.servers, fn {_name, server} -> server.client == client end) do
      {name, server} ->
        server = %{
          server
          | client: nil,
            connected: false,
            last_error: "client disconnected; reconnecting"
        }

        {:noreply, put_server(state, name, record_failure(name, server))}

      nil ->
        {:noreply, state}
    end
  end

  # A notification can arrive from a new client before its refresh commits:
  # an in-flight refresh runs once more after it completes.
  def handle_info({:mcp_notification, name, token, %{method: method}}, state)
      when method in @list_changed_methods do
    case state.servers[name] do
      %{refresh: ref} = server when is_reference(ref) ->
        {:noreply, put_server(state, name, %{server | refresh_again: true})}

      %{notification_token: ^token, connected: true} ->
        {:noreply, state |> start_refresh(name) |> progress_waiters()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:mcp_notification, _, _, _}, state), do: {:noreply, state}

  def handle_info({:mcp_reconnect, name, token}, state) do
    case state.servers[name] do
      %{reconnect_token: ^token, unavailable: false} = server ->
        state = put_server(state, name, %{server | reconnect_timer: nil, reconnect_token: nil})
        {:noreply, state |> start_refresh(name) |> progress_waiters()}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{disabled: true}), do: :ok

  def terminate(_reason, state) do
    Enum.each(state.workers, fn {_ref, worker} ->
      Process.exit(worker.task.pid, :kill)
      Enum.each(worker.clients, fn {client, _} -> kill_client(client) end)
    end)

    Enum.each(state.invocations, fn {_, invocation} ->
      Process.exit(invocation.task.pid, :kill)
    end)

    Enum.each(state.servers, fn {_name, server} -> kill_client(server.client) end)
  end

  # ============================================================================
  # Waiters: callers blocked on configuration loads and server refreshes
  # ============================================================================

  # A waiter first waits for the configuration loads it started, then for the
  # server refreshes its mode needs, and is answered from committed state.
  # Modes: `:snapshot` (plain discovery), `:force` (`force_refresh: true`),
  # `:ready` (fail-closed session discovery) and `:refresh`.
  defp add_waiter(state, from, mode, scopes, timeout) do
    started =
      Enum.reduce_while(scopes, {:ok, state, %{}}, fn scope, {:ok, state, loads} ->
        case start_load(state, scope) do
          {:ok, state, ref} -> {:cont, {:ok, state, Map.put(loads, scope, ref)}}
          {:error, reason} -> {:halt, {:error, reason, state}}
        end
      end)

    case started do
      {:ok, state, loads} ->
        ref = make_ref()

        waiter = %{
          from: from,
          caller_ref: Process.monitor(elem(from, 0)),
          timer: Process.send_after(self(), {:waiter_timeout, ref}, timeout),
          mode: mode,
          scopes: scopes,
          loads: loads,
          refreshes: nil,
          untrusted: false
        }

        progress_waiters(%{state | waiters: Map.put(state.waiters, ref, waiter)})

      {:error, reason, state} ->
        GenServer.reply(from, {:error, reason})
        state
    end
  end

  defp progress_waiters(state) do
    Enum.reduce(state.waiters, state, fn {ref, waiter}, state ->
      progress_waiter(state, ref, waiter)
    end)
  end

  defp progress_waiter(state, ref, %{refreshes: nil} = waiter) do
    if Enum.any?(waiter.loads, fn {_scope, load} -> Map.has_key?(state.workers, load) end) do
      state
    else
      {state, refreshes} = begin_refreshes(state, waiter)
      waiter = %{waiter | refreshes: refreshes}
      progress_waiter(%{state | waiters: Map.put(state.waiters, ref, waiter)}, ref, waiter)
    end
  end

  defp progress_waiter(state, ref, waiter) do
    pending? =
      Enum.any?(waiter.refreshes, fn {name, worker} ->
        match?(%{refresh: ^worker}, state.servers[name])
      end)

    if pending?, do: state, else: reply_waiter(state, ref, waiter, waiter_reply(state, waiter))
  end

  defp begin_refreshes(state, %{mode: :ready, untrusted: true}), do: {state, %{}}

  defp begin_refreshes(state, waiter) do
    now = System.monotonic_time(:millisecond)

    names =
      if waiter.mode == :refresh,
        do: Map.keys(state.servers),
        else: waiter.scopes |> Enum.flat_map(&Map.get(state.scopes, &1, [])) |> Enum.uniq()

    Enum.reduce(names, {state, %{}}, fn name, {state, refreshes} ->
      server = state.servers[name]

      start? =
        waiter.mode != :snapshot or not server.connected or is_nil(server.discovered_at) or
          stale?(server, state, now)

      state = if start?, do: start_refresh(state, name), else: state
      server = state.servers[name]

      # A snapshot waits only for servers without a usable connection; a
      # connected server keeps serving its snapshot while it refreshes.
      wait? =
        is_reference(server.refresh) and
          (waiter.mode != :snapshot or not server.connected or is_nil(server.discovered_at))

      {state, if(wait?, do: Map.put(refreshes, name, server.refresh), else: refreshes)}
    end)
  end

  defp waiter_reply(_state, %{mode: :refresh}), do: :ok
  defp waiter_reply(_state, %{mode: :ready, untrusted: true}), do: {:error, :project_untrusted}

  defp waiter_reply(state, %{mode: :ready}) do
    servers = Map.values(state.servers)

    cond do
      Enum.any?(servers, &(&1.last_error == "connection failed")) ->
        {:error, :connection_failed}

      Enum.any?(servers, &(not &1.connected)) ->
        {:error, :discovery_failed}

      true ->
        {:ok, connected_tools(state, Map.keys(state.servers))}
    end
  end

  defp waiter_reply(state, %{scopes: [scope]}) do
    case Map.fetch(state.scopes, scope) do
      {:ok, names} -> connected_tools(state, names)
      :error -> {:error, :discovery_failed}
    end
  end

  # A plain discovery past its wait bound serves the committed snapshot of a
  # loaded scope; nothing else is ever reported as an empty success.
  defp waiter_timeout(state, %{mode: :snapshot, scopes: [scope]} = waiter) do
    if Map.has_key?(state.scopes, scope),
      do: waiter_reply(state, waiter),
      else: {:error, :timeout}
  end

  defp waiter_timeout(_state, _waiter), do: {:error, :timeout}

  defp reply_waiter(state, ref, waiter, reply) do
    Process.cancel_timer(waiter.timer)
    Process.demonitor(waiter.caller_ref, [:flush])
    GenServer.reply(waiter.from, reply)
    %{state | waiters: Map.delete(state.waiters, ref)}
  end

  defp down_waiters(state, ref) do
    case Enum.find(state.waiters, fn {_ref, waiter} -> waiter.caller_ref == ref end) do
      {waiter_ref, waiter} ->
        Process.cancel_timer(waiter.timer)
        %{state | waiters: Map.delete(state.waiters, waiter_ref)}

      nil ->
        state
    end
  end

  defp connected_tools(state, names) do
    names = MapSet.new(names)

    state.tool_cache
    |> Map.values()
    |> Enum.filter(fn entry ->
      MapSet.member?(names, entry.server_name) and
        match?(%{connected: true}, state.servers[entry.server_name])
    end)
    |> Enum.map(& &1.tool)
    |> Enum.sort_by(& &1.name)
  end

  # ============================================================================
  # Workers: configuration loads, per-server refreshes and trust sweeps
  # ============================================================================

  defp start_worker(state, kind, fun) do
    case start_task(fun) do
      {:ok, task} ->
        worker = %{kind: kind, task: task, clients: %{}}
        {:ok, %{state | workers: Map.put(state.workers, task.ref, worker)}, task.ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Configuration and project trust are file I/O, so they load in a worker.
  defp start_load(state, scope) do
    seq = state.load_seq + 1
    explicit = state.configs
    known = Map.new(state.servers, fn {name, server} -> {name, server.config} end)
    state = %{state | load_seq: seq}

    start_worker(state, {:load, scope, seq}, fn ->
      {:loaded, load_scope(scope, explicit, known)}
    end)
  end

  defp load_scope(scope, explicit, known) do
    configs =
      case explicit do
        nil ->
          config = LemonSkills.Config.mcp_config(scope)
          if config.enabled, do: config.servers, else: []

        configs ->
          configs
      end

    # Explicit project-origin configs (e.g. `lemon mcp test`) must not report a
    # ready session after their trust was revoked.
    untrusted_explicit = is_list(explicit) and Enum.any?(configs, &(not trusted_config?(&1)))

    configs =
      configs
      |> Enum.filter(&(validate_config(&1) == :ok))
      |> Enum.map(&scope_config(&1, scope))

    candidates = Map.merge(known, Map.new(configs, &{server_name(&1), &1}))

    %{
      configs: configs,
      untrusted: untrusted_names(candidates),
      untrusted_explicit: untrusted_explicit
    }
  end

  defp start_refresh(state, name) do
    case state.servers[name] do
      %{refresh: nil, reconnect_timer: nil, unavailable: false} = server ->
        source = state.source

        case start_worker(state, {:refresh, name}, fn ->
               {:refreshed, refresh_worker(name, server, source)}
             end) do
          {:ok, state, ref} ->
            put_server(state, name, %{server | refresh: ref, refresh_again: false})

          {:error, _reason} ->
            state
        end

      _ ->
        state
    end
  end

  # Every spawn and reconnect re-checks a project-origin server's provenance.
  defp refresh_worker(name, server, source) do
    if trusted_config?(server.config) do
      {server, wrapped} = refresh_server(name, server)
      {server, entries} = publish_tools(name, server, wrapped, source)
      {:ok, server, entries}
    else
      :untrusted
    end
  end

  defp start_trust_sweep(%{sweep: nil} = state) do
    configs =
      for {name, server} <- state.servers,
          project_provenance(server.config) != nil,
          into: %{},
          do: {name, server.config}

    if configs == %{} do
      state
    else
      case start_worker(state, :sweep, fn -> {:swept, untrusted_names(configs)} end) do
        {:ok, state, ref} -> %{state | sweep: ref}
        {:error, _reason} -> state
      end
    end
  end

  defp start_trust_sweep(state), do: state

  defp worker_done(state, ref, result) do
    Process.demonitor(ref, [:flush])
    {worker, workers} = Map.pop(state.workers, ref)
    state = %{state | workers: workers}

    state =
      case {worker.kind, result} do
        {{:load, scope, seq}, {:loaded, loaded}} ->
          apply_load(state, ref, scope, seq, loaded)

        {{:refresh, name}, {:refreshed, refreshed}} ->
          commit_refresh(state, name, ref, worker, refreshed)

        {:sweep, {:swept, untrusted}} ->
          evict_servers(%{state | sweep: nil}, untrusted)
      end

    progress_waiters(state)
  end

  defp worker_failed(state, ref) do
    {worker, workers} = Map.pop(state.workers, ref)
    Enum.each(worker.clients, fn {client, _} -> kill_client(client) end)
    state = %{state | workers: workers}

    state =
      case worker.kind do
        {:refresh, name} ->
          case state.servers[name] do
            %{refresh: ^ref} = server ->
              refresh_failed(state, name, server, "tool discovery failed")

            _ ->
              state
          end

        :sweep ->
          %{state | sweep: nil}

        {:load, _scope, _seq} ->
          state
      end

    progress_waiters(state)
  end

  defp stop_worker(state, nil), do: state

  defp stop_worker(state, ref) do
    case Map.pop(state.workers, ref) do
      {nil, _workers} ->
        state

      {worker, workers} ->
        Process.exit(worker.task.pid, :kill)
        Process.demonitor(ref, [:flush])
        Enum.each(worker.clients, fn {client, _} -> kill_client(client) end)
        %{state | workers: workers}
    end
  end

  # A configuration load replaces only its own scope's server list: servers no
  # scope references any longer are closed, and untrusted project servers are
  # evicted from every scope. Other scopes' cached tools are untouched. Loading
  # never connects; the waiter that needs a server starts it.
  defp apply_load(state, ref, scope, seq, loaded) do
    state =
      if loaded.untrusted_explicit,
        do: %{
          state
          | waiters:
              Map.new(state.waiters, fn {wref, waiter} ->
                {wref,
                 if(ref in Map.values(waiter.loads),
                   do: %{waiter | untrusted: true},
                   else: waiter
                 )}
              end)
        },
        else: state

    cond do
      # Superseded by a newer load, or the scope was evicted after it started.
      seq <= Map.get(state.applied_load, scope, 0) ->
        state

      project_scope?(state, scope) and not Map.has_key?(state.scope_owners, scope) ->
        state

      true ->
        new? = not Map.has_key?(state.scopes, scope)

        names =
          loaded.configs
          |> Enum.map(&server_name/1)
          |> Enum.reject(&MapSet.member?(loaded.untrusted, &1))
          |> Enum.uniq()

        state = %{
          state
          | scopes: Map.put(state.scopes, scope, names),
            applied_load: Map.put(state.applied_load, scope, seq)
        }

        state =
          loaded.configs
          |> Enum.reject(&MapSet.member?(loaded.untrusted, server_name(&1)))
          |> Enum.reduce(state, fn config, state ->
            name = server_name(config)

            if Map.has_key?(state.servers, name),
              do: state,
              else: put_server(state, name, new_server(state.source, config))
          end)
          |> evict_servers(loaded.untrusted)
          |> drop_unreferenced()

        if new? and project_scope?(state, scope),
          do: enforce_scope_cap(state, scope),
          else: state
    end
  end

  defp new_server(source, config) do
    %{
      source: source,
      config: config,
      client: nil,
      client_module: nil,
      connected: false,
      last_error: nil,
      tools: [],
      resources: [],
      prompts: [],
      capabilities: %{},
      notification_token: make_ref(),
      reconnect_timer: nil,
      reconnect_token: nil,
      reconnect_attempt: 0,
      crashes: [],
      unavailable: false,
      refresh: nil,
      refresh_again: false,
      discovered_at: nil
    }
  end

  # Commits one server's refresh. A result for a server that was evicted or
  # superseded only releases the worker's clients.
  defp commit_refresh(state, name, ref, worker, result) do
    case state.servers[name] do
      %{refresh: ^ref} = current ->
        current = %{current | refresh: nil}

        state =
          case result do
            :untrusted ->
              release_clients(worker, nil)
              evict_servers(put_server(state, name, current), [name])

            {:ok, %{connected: true, client: client} = server, entries}
            when is_pid(client) ->
              if Process.alive?(client),
                do: refresh_succeeded(state, name, current, server, entries, worker),
                else: refresh_failed(state, name, current, server.last_error, worker)

            {:ok, server, _entries} ->
              refresh_failed(state, name, current, server.last_error, worker)
          end

        case state.servers[name] do
          %{refresh_again: true} -> start_refresh(state, name)
          _ -> state
        end

      _ ->
        release_clients(worker, nil)
        state
    end
  end

  defp refresh_succeeded(state, name, current, server, entries, worker) do
    release_clients(worker, server.client)
    if current.reconnect_timer, do: Process.cancel_timer(current.reconnect_timer)

    current =
      current
      |> Map.merge(
        Map.take(server, [
          :client,
          :client_module,
          :connected,
          :tools,
          :resources,
          :prompts,
          :capabilities,
          :notification_token
        ])
      )
      |> Map.merge(%{
        last_error: nil,
        reconnect_timer: nil,
        reconnect_token: nil,
        reconnect_attempt: 0,
        discovered_at: System.monotonic_time(:millisecond)
      })

    cache =
      state.tool_cache
      |> Map.reject(fn {_name, entry} -> entry.server_name == name end)
      |> Map.merge(entries)

    put_server(%{state | tool_cache: cache}, name, current)
  end

  # A failed startup or discovery uses the same backoff and crash-storm
  # breaker as a lost connection, unless a crash already scheduled them.
  defp refresh_failed(state, name, current, last_error, worker \\ nil) do
    if worker, do: release_clients(worker, nil)

    if is_pid(current.client) and Process.alive?(current.client),
      do: kill_client(current.client)

    failed = %{
      current
      | client: nil,
        connected: false,
        refresh: nil,
        last_error: last_error || "tool discovery failed",
        tools: [],
        resources: [],
        prompts: [],
        capabilities: %{}
    }

    failed =
      if current.reconnect_timer || current.unavailable,
        do: %{failed | last_error: current.last_error},
        else: record_failure(name, failed)

    cache = Map.reject(state.tool_cache, fn {_name, entry} -> entry.server_name == name end)
    put_server(%{state | tool_cache: cache}, name, failed)
  end

  defp release_clients(worker, keep) do
    Enum.each(worker.clients, fn {client, _} -> if client != keep, do: kill_client(client) end)
  end

  defp record_failure(name, server) do
    now = System.monotonic_time(:millisecond)
    crashes = [now | Enum.filter(server.crashes, &(now - &1 < @crash_window_ms))]
    server = %{server | crashes: crashes}

    if length(crashes) > @crash_storm_limit,
      do: %{server | unavailable: true, last_error: "server unavailable: crash storm"},
      else: schedule_reconnect(name, server)
  end

  # Jittered exponential backoff: attempt n waits between half and all of
  # base * 2^n. After @reconnect_attempts attempts the server is unavailable
  # until an explicit refresh.
  defp schedule_reconnect(_name, %{unavailable: true} = server), do: server

  defp schedule_reconnect(_name, %{reconnect_attempt: attempt} = server)
       when attempt >= @reconnect_attempts do
    %{server | unavailable: true, last_error: "server unavailable: reconnect exhausted"}
  end

  defp schedule_reconnect(name, server) do
    delay = @reconnect_base_ms * Integer.pow(2, server.reconnect_attempt)
    delay = delay - :rand.uniform(div(delay, 2)) + 1
    token = make_ref()

    %{
      server
      | reconnect_token: token,
        reconnect_timer: Process.send_after(self(), {:mcp_reconnect, name, token}, delay),
        reconnect_attempt: server.reconnect_attempt + 1
    }
  end

  defp reset_backoff(state) do
    servers =
      Map.new(state.servers, fn {name, server} ->
        if server.reconnect_timer, do: Process.cancel_timer(server.reconnect_timer)

        {name,
         %{
           server
           | reconnect_timer: nil,
             reconnect_token: nil,
             reconnect_attempt: 0,
             crashes: [],
             unavailable: false
         }}
      end)

    %{state | servers: servers}
  end

  defp stale?(%{discovered_at: nil}, _state, _now), do: false
  defp stale?(server, state, now), do: now - server.discovered_at > state.cache_ttl_ms

  defp put_server(state, name, server),
    do: %{state | servers: Map.put(state.servers, name, server)}

  # Closes and forgets servers in every scope, cancelling their reconnects
  # and in-flight refreshes.
  defp evict_servers(state, names) do
    present = Enum.filter(names, &Map.has_key?(state.servers, &1))

    if present == [] do
      state
    else
      state =
        Enum.reduce(present, state, fn name, state ->
          server = state.servers[name]
          if server.reconnect_timer, do: Process.cancel_timer(server.reconnect_timer)
          close_client_async(server)
          stop_worker(state, server.refresh)
        end)

      evicted = MapSet.new(present)

      %{
        state
        | servers: Map.drop(state.servers, present),
          scopes:
            Map.new(state.scopes, fn {scope, names} ->
              {scope, Enum.reject(names, &MapSet.member?(evicted, &1))}
            end),
          tool_cache:
            Map.reject(state.tool_cache, fn {_, entry} ->
              MapSet.member?(evicted, entry.server_name)
            end)
      }
    end
  end

  defp drop_unreferenced(state) do
    retained = state.scopes |> Map.values() |> List.flatten() |> MapSet.new()

    evict_servers(
      state,
      for({name, _} <- state.servers, not MapSet.member?(retained, name), do: name)
    )
  end

  # Closing can take the client's own shutdown time; it never runs in the
  # source process.
  defp close_client_async(%{client: client} = server) when is_pid(client) do
    case Task.Supervisor.start_child(LemonSkills.TaskSupervisor, fn -> close_client(server) end) do
      {:ok, _pid} -> :ok
      _ -> kill_client(client)
    end
  catch
    :exit, _ -> kill_client(client)
  end

  defp close_client_async(_server), do: :ok

  defp untrusted_names(configs_by_name) do
    {names, _checked} =
      Enum.reduce(configs_by_name, {MapSet.new(), %{}}, fn {name, config}, {names, checked} ->
        case project_provenance(config) do
          nil ->
            {names, checked}

          provenance ->
            trusted =
              Map.get_lazy(checked, provenance, fn ->
                LemonSkills.McpDiscovery.project_trusted?(provenance)
              end)

            {if(trusted, do: names, else: MapSet.put(names, name)),
             Map.put(checked, provenance, trusted)}
        end
      end)

    names
  end

  # ============================================================================
  # Project scopes: held by live callers, bounded by max_project_scopes
  # ============================================================================

  defp own_scope(state), do: scope_key(cwd: state.cwd)

  defp project_scope?(state, scope), do: is_binary(scope) and scope != own_scope(state)

  defp hold_scope(state, scope, pid) do
    if project_scope?(state, scope) do
      owners = Map.update(state.scope_owners, scope, MapSet.new([pid]), &MapSet.put(&1, pid))

      monitors =
        Map.put_new_lazy(state.owner_monitors, pid, fn -> Process.monitor(pid) end)

      %{state | scope_owners: owners, owner_monitors: monitors}
    else
      state
    end
  end

  defp release_owner(state, pid, ref) do
    case state.owner_monitors do
      %{^pid => ^ref} ->
        state = %{state | owner_monitors: Map.delete(state.owner_monitors, pid)}

        Enum.reduce(state.scope_owners, state, fn {scope, owners}, state ->
          cond do
            not MapSet.member?(owners, pid) ->
              state

            MapSet.size(owners) == 1 ->
              evict_scope(state, scope)

            true ->
              %{
                state
                | scope_owners: Map.put(state.scope_owners, scope, MapSet.delete(owners, pid))
              }
          end
        end)

      _ ->
        state
    end
  end

  # Forgets a project scope and closes the servers no other scope references.
  # A load still in flight for it is discarded when it completes.
  defp evict_scope(state, scope) do
    owners = Map.get(state.scope_owners, scope, MapSet.new())
    scope_owners = Map.delete(state.scope_owners, scope)
    held = scope_owners |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    monitors =
      Enum.reduce(owners, state.owner_monitors, fn pid, monitors ->
        if MapSet.member?(held, pid) do
          monitors
        else
          if ref = monitors[pid], do: Process.demonitor(ref, [:flush])
          Map.delete(monitors, pid)
        end
      end)

    drop_unreferenced(%{
      state
      | scopes: Map.delete(state.scopes, scope),
        scope_owners: scope_owners,
        owner_monitors: monitors,
        scope_used: Map.delete(state.scope_used, scope),
        applied_load: Map.put(state.applied_load, scope, state.load_seq)
    })
  end

  # Past the cap the least recently used project scopes are evicted (their
  # stdio clients close); a later discovery in that directory reloads them.
  defp enforce_scope_cap(state, keep) do
    loaded = state.scopes |> Map.keys() |> Enum.filter(&project_scope?(state, &1))
    excess = length(loaded) - state.max_project_scopes

    if excess > 0 do
      loaded
      |> List.delete(keep)
      |> Enum.sort_by(&Map.get(state.scope_used, &1, 0))
      |> Enum.take(excess)
      |> Enum.reduce(state, &evict_scope(&2, &1))
    else
      state
    end
  end

  defp touch_scope(state, scope) do
    if project_scope?(state, scope),
      do: %{
        state
        | scope_used: Map.put(state.scope_used, scope, System.monotonic_time(:millisecond))
      },
      else: state
  end

  defp touch_server_scopes(state, name) do
    Enum.reduce(state.scopes, state, fn {scope, names}, state ->
      if name in names, do: touch_scope(state, scope), else: state
    end)
  end

  # ============================================================================
  # Invocations and remote inventory
  # ============================================================================

  # Workers and invocations run under the capped skills task supervisor and
  # are linked to this source, so they never outlive it.
  defp start_task(fun) do
    owner = self()

    {:ok,
     Task.Supervisor.async_nolink(LemonSkills.TaskSupervisor, fn ->
       Process.link(owner)
       fun.()
     end)}
  rescue
    # async_nolink raises before spawning when this capped supervisor is full.
    RuntimeError -> {:error, :task_capacity_reached}
  catch
    :exit, {:noproc, _} -> {:error, :task_supervisor_unavailable}
  end

  defp kill_client(client) when is_pid(client), do: Process.exit(client, :kill)
  defp kill_client(_), do: :ok

  defp track_invocation(state, task, from, timeout, timeout_reply) do
    invocation = %{
      task: task,
      from: from,
      caller_ref: Process.monitor(elem(from, 0)),
      timer: Process.send_after(self(), {:invocation_timeout, task.ref}, timeout),
      timeout_reply: timeout_reply
    }

    %{state | invocations: Map.put(state.invocations, task.ref, invocation)}
  end

  defp finish_invocation(invocation, reply) do
    Process.cancel_timer(invocation.timer)
    Process.demonitor(invocation.task.ref, [:flush])
    Process.demonitor(invocation.caller_ref, [:flush])
    GenServer.reply(invocation.from, reply)
  end

  defp down_invocations(state, ref) do
    {dead, live} =
      Enum.split_with(state.invocations, fn {task_ref, invocation} ->
        task_ref == ref or invocation.caller_ref == ref
      end)

    Enum.each(dead, fn {_ref, invocation} ->
      Process.exit(invocation.task.pid, :kill)
      finish_invocation(invocation, {:error, :outcome_unknown})
    end)

    %{state | invocations: Map.new(live)}
  end

  defp remote_tool_inventory(servers) do
    Enum.reduce_while(servers, {:ok, []}, fn
      {_,
       %{
         connected: true,
         client: client,
         client_module: mod,
         config: config,
         capabilities: capabilities
       }},
      {:ok, acc} ->
        values = config_redact_values(config)
        public_name = Keyword.get(config_options(config), :name)

        with true <- scrub_inventory(public_name, values) == public_name,
             {:ok, tools} when is_list(tools) <- list_advertised_tools(mod, client, capabilities) do
          {:cont, {:ok, acc ++ Enum.map(tools, &scrub_remote_tool(&1, values))}}
        else
          _ -> {:halt, {:error, :discovery_failed}}
        end

      _, _ ->
        {:halt, {:error, :discovery_failed}}
    end)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp notification_opts(server) do
    owner = server.source
    name = server_name(server.config)
    token = server.notification_token

    [
      notification_handler: fn notification ->
        send(owner, {:mcp_notification, name, token, notification})
        :ok
      end
    ]
  end

  defp approval_selector({:tool, raw_name}), do: raw_name
  defp approval_selector({:utility, :list_resources, _}), do: "resources/list"
  defp approval_selector({:utility, :read_resource, _}), do: "resources/read"
  defp approval_selector({:utility, :list_prompts, _}), do: "prompts/list"
  defp approval_selector({:utility, :get_prompt, _}), do: "prompts/get"

  defp inventory_entry(name, server, tool_cache) do
    {transport, label, opts} = inventory_identity(server.config)

    tools =
      tool_cache
      |> Enum.filter(fn {_published, entry} -> entry.server_name == name end)
      |> Enum.map(fn {published, entry} ->
        {kind, remote} =
          case entry.original_name do
            {:tool, raw} -> {:tool, raw}
            {:utility, kind, _filters} -> {kind, nil}
          end

        %{name: published, remote_name: remote, kind: kind, description: entry.tool.description}
      end)
      |> Enum.sort_by(&{&1.kind != :tool, &1.name})

    %{
      id: String.slice(name, 0, 16),
      name: Keyword.get(opts, :name),
      label: label,
      transport: transport,
      connected: server.connected,
      last_error: server.last_error,
      tool_count: length(server.tools),
      resource_count: length(Map.get(server, :resources, [])),
      prompt_count: length(Map.get(server, :prompts, [])),
      approval:
        if(Keyword.get(opts, :approval, :never) in [:never, "never"], do: :never, else: :always),
      tools: tools
    }
  end

  defp inventory_identity({:stdio, command, args}),
    do: inventory_identity({:stdio, command, args, []})

  defp inventory_identity({:stdio, command, _args, opts}),
    do: {:stdio, command |> String.trim() |> Path.basename(), opts}

  defp inventory_identity({transport, url}) when transport in [:http, :sse],
    do: inventory_identity({transport, url, []})

  defp inventory_identity({transport, url, opts}) when transport in [:http, :sse] do
    label =
      case URI.parse(url) do
        %URI{host: host, port: port, scheme: scheme} when is_binary(host) and host != "" ->
          if port in [nil, URI.default_port(scheme)], do: host, else: "#{host}:#{port}"

        _ ->
          nil
      end

    {transport, label, opts}
  end

  defp scope_key(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> nil
      cwd -> Path.expand(cwd)
    end
  end

  defp source_scope(%{configs: configs, cwd: cwd}, _opts) when is_list(configs),
    do: scope_key(cwd: cwd)

  defp source_scope(_state, opts), do: scope_key(opts)

  defp server_name(config) do
    :crypto.hash(:sha256, :erlang.term_to_binary(config))
    |> Base.encode16(case: :lower)
  end

  defp legacy_execution_name(prefix, server_name, original_name) do
    digest = short_hash(:erlang.term_to_binary({server_name, original_name}))
    String.slice(prefix, 0, 47) <> "_" <> digest
  end

  # Names one server's discovered tools and builds its cache entries. Tool
  # closures capture this source's pid, so they cannot cross into another.
  defp publish_tools(server_name, server, wrapped, source) do
    tools =
      Enum.map(wrapped, fn {tool, original_name} ->
        name = published_name(server.config, server_name, tool, original_name)

        tool = %{
          tool
          | name: name,
            execute: fn _id, params, _signal, _update -> call_tool(source, name, params, []) end
        }

        {tool, original_name}
      end)

    now = System.monotonic_time(:millisecond)

    entries =
      Map.new(tools, fn {tool, original_name} ->
        {tool.name,
         %{tool: tool, cached_at: now, server_name: server_name, original_name: original_name}}
      end)

    {%{server | tools: Enum.map(tools, &elem(&1, 0))}, entries}
  end

  defp published_name({:http, url, opts}, server_name, tool, original_name) do
    if Keyword.get(opts, :profile_owned, false) do
      profile_name = Keyword.fetch!(opts, :name)

      case original_name do
        {:tool, raw_name} ->
          execution_name(profile_name, url, raw_name)

        {:utility, _, _} ->
          profile_alias(
            profile_name,
            url,
            {:utility, approval_selector(original_name)},
            tool.name
          )
      end
    else
      legacy_execution_name(tool.name, server_name, original_name)
    end
  end

  defp published_name(_config, server_name, tool, original_name),
    do: legacy_execution_name(tool.name, server_name, original_name)

  defp scope_config({:stdio, command, args}, scope),
    do: scope_config({:stdio, command, args, []}, scope)

  defp scope_config({:stdio, command, args, opts}, scope) do
    cwd = Keyword.get(opts, :cwd, scope)
    opts = if cwd, do: Keyword.put(opts, :cwd, Path.expand(cwd, scope || File.cwd!())), else: opts
    {:stdio, command, args, opts}
  end

  defp scope_config(config, _scope), do: config

  defp project_provenance(config) do
    case config do
      {:stdio, _command, _args, opts} -> Keyword.get(opts, :project_trust)
      {transport, _url, opts} when transport in [:http, :sse] -> Keyword.get(opts, :project_trust)
      _ -> nil
    end
  end

  defp trusted_config?(config) do
    case project_provenance(config) do
      nil -> true
      provenance -> LemonSkills.McpDiscovery.project_trusted?(provenance)
    end
  end

  defp refresh_server(name, server) do
    server =
      if is_pid(server.client) and Process.alive?(server.client),
        do: server,
        else: %{server | notification_token: make_ref()}

    do_refresh_server(name, server)
  end

  defp do_refresh_server(_server_name, %{config: config} = server)
       when elem(config, 0) == :stdio do
    {command, _args, opts} = stdio_parts(config)
    command = Keyword.get(opts, :name, command)
    filters = filter_config(opts)

    case ensure_client(server, :stdio) do
      {:ok, client} ->
        client_mod = server_client_module(:stdio)
        capabilities = client_capabilities(client_mod, client)

        case list_advertised_tools(client_mod, client, capabilities) do
          {:ok, tools} ->
            wrapped =
              tools
              |> Enum.filter(&tool_allowed?(&1, filters))
              |> Enum.map(&wrap_mcp_tool(command, &1))

            {resource_tools, resources} =
              resource_utility_tools(command, client_mod, client, filters, capabilities)

            {prompt_tools, prompts} =
              prompt_utility_tools(command, client_mod, client, filters, capabilities)

            wrapped = wrapped ++ resource_tools ++ prompt_tools
            agent_tools = Enum.map(wrapped, fn {tool, _original_name} -> tool end)

            {%{
               server
               | client: client,
                 client_module: client_mod,
                 connected: true,
                 last_error: nil,
                 tools: agent_tools,
                 resources: resources,
                 prompts: prompts,
                 capabilities: capabilities
             }, wrapped}

          {:error, _reason} ->
            close_client(%{client: client, client_module: client_mod})

            {%{
               server
               | connected: false,
                 client_module: client_mod,
                 last_error: "tool discovery failed",
                 tools: [],
                 resources: [],
                 prompts: [],
                 capabilities: %{}
             }, []}
        end

      {:error, _reason} ->
        {%{
           server
           | connected: false,
             client_module: nil,
             last_error: "connection failed",
             tools: [],
             resources: [],
             prompts: [],
             capabilities: %{}
         }, []}
    end
  end

  defp do_refresh_server(_server_name, %{config: config} = server)
       when elem(config, 0) == :http do
    {url, opts} = http_parts(config)
    url = Keyword.get(opts, :name, url)
    filters = filter_config(opts)

    case ensure_client(server, :http) do
      {:ok, client} ->
        client_mod = server_client_module(:http)
        capabilities = client_capabilities(client_mod, client)

        case list_advertised_tools(client_mod, client, capabilities) do
          {:ok, tools} ->
            wrapped =
              tools
              |> Enum.filter(&tool_allowed?(&1, filters))
              |> Enum.map(&wrap_mcp_tool(url, &1))

            {resource_tools, resources} =
              resource_utility_tools(url, client_mod, client, filters, capabilities)

            {prompt_tools, prompts} =
              prompt_utility_tools(url, client_mod, client, filters, capabilities)

            wrapped = wrapped ++ resource_tools ++ prompt_tools
            agent_tools = Enum.map(wrapped, fn {tool, _original_name} -> tool end)

            {%{
               server
               | client: client,
                 client_module: client_mod,
                 connected: true,
                 last_error: nil,
                 tools: agent_tools,
                 resources: resources,
                 prompts: prompts,
                 capabilities: capabilities
             }, wrapped}

          {:error, _reason} ->
            close_client(%{client: client, client_module: client_mod})

            {%{
               server
               | connected: false,
                 client_module: client_mod,
                 last_error: "tool discovery failed",
                 tools: [],
                 resources: [],
                 prompts: [],
                 capabilities: %{}
             }, []}
        end

      {:error, _reason} ->
        {%{
           server
           | connected: false,
             client_module: nil,
             last_error: "connection failed",
             tools: [],
             resources: [],
             prompts: [],
             capabilities: %{}
         }, []}
    end
  end

  defp do_refresh_server(_server_name, %{config: config} = server) when elem(config, 0) == :sse do
    {url, opts} = http_parts(config)
    url = Keyword.get(opts, :name, url)
    filters = filter_config(opts)

    case ensure_client(server, :sse) do
      {:ok, client} ->
        client_mod = server_client_module(:sse)
        capabilities = client_capabilities(client_mod, client)

        case list_advertised_tools(client_mod, client, capabilities) do
          {:ok, tools} ->
            wrapped =
              tools
              |> Enum.filter(&tool_allowed?(&1, filters))
              |> Enum.map(&wrap_mcp_tool(url, &1))

            {resource_tools, resources} =
              resource_utility_tools(url, client_mod, client, filters, capabilities)

            {prompt_tools, prompts} =
              prompt_utility_tools(url, client_mod, client, filters, capabilities)

            wrapped = wrapped ++ resource_tools ++ prompt_tools
            agent_tools = Enum.map(wrapped, fn {tool, _original_name} -> tool end)

            {%{
               server
               | client: client,
                 client_module: client_mod,
                 connected: true,
                 last_error: nil,
                 tools: agent_tools,
                 resources: resources,
                 prompts: prompts,
                 capabilities: capabilities
             }, wrapped}

          {:error, _reason} ->
            close_client(%{client: client, client_module: client_mod})

            {%{
               server
               | connected: false,
                 client_module: client_mod,
                 last_error: "tool discovery failed",
                 tools: [],
                 resources: [],
                 prompts: [],
                 capabilities: %{}
             }, []}
        end

      {:error, _reason} ->
        {%{
           server
           | connected: false,
             client_module: nil,
             last_error: "connection failed",
             tools: [],
             resources: [],
             prompts: [],
             capabilities: %{}
         }, []}
    end
  end

  defp ensure_client(%{client: client} = server, transport) when is_pid(client) do
    client_mod = server_client_module(transport)

    if Process.alive?(client) and client_call(client_mod, :state, [client]) == :ready do
      {:ok, client}
    else
      close_client(server)
      ensure_client(%{server | client: nil}, transport)
    end
  end

  # Every spawn and reconnect re-checks a project-origin server's provenance.
  defp ensure_client(%{config: config} = server, transport) do
    if trusted_config?(config),
      do: start_client(server, transport),
      else: {:error, :project_untrusted}
  end

  defp start_client(%{config: config} = server, :stdio) do
    {command, args, source_opts} = stdio_parts(config)

    opts =
      [
        command: command,
        args: args,
        cwd: Keyword.get(source_opts, :cwd),
        env: Keyword.get(source_opts, :env, []),
        port_open: &LemonCore.NativeProcess.open/2,
        timeout_ms: Keyword.get(source_opts, :timeout_ms, @client_request_timeout_ms)
      ] ++ notification_opts(server)

    case System.find_executable(command) do
      executable when is_binary(executable) ->
        start_ready_client(Client, opts, client_ready_timeout_ms(source_opts), server.source)

      nil ->
        {:error, :executable_not_found}
    end
  end

  defp start_client(%{config: config} = server, :http) do
    {url, opts} = http_parts(config)
    oauth = resolved_http_oauth(Keyword.get(opts, :oauth, []))

    client_opts =
      [
        url: url,
        headers: Keyword.get(opts, :headers, []),
        oauth: oauth,
        timeout: client_start_timeout(oauth, opts),
        timeout_ms: Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)
      ] ++
        Keyword.take(opts, [:origin_policy, :destination_pin]) ++
        oauth_token_cache_opts(url, opts) ++ notification_opts(server)

    start_ready_client(Client.HTTP, client_opts, client_ready_timeout_ms(opts), server.source)
  end

  defp start_client(%{config: config} = server, :sse) do
    {url, opts} = http_parts(config)
    ready_timeout_ms = client_ready_timeout_ms(opts)

    client_opts =
      [
        url: url,
        headers: Keyword.get(opts, :headers, []),
        timeout: ready_timeout_ms,
        timeout_ms: Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)
      ] ++ Keyword.take(opts, [:origin_policy]) ++ notification_opts(server)

    start_ready_client(Client.SSE, client_opts, ready_timeout_ms, server.source)
  end

  defp start_ready_client(client_mod, opts, timeout, source) do
    # Startup may dispatch remote work even if readiness subsequently fails.
    LemonCore.NativeProcess.unsupported!()

    # start_link can return an init error and deliver the linked child's exit.
    # Shield that startup window so a failed handshake remains connection_failed
    # rather than crashing the whole discovery worker. The source still owns
    # cancellation and can kill this worker even while it traps linked exits.
    trap_exit = Process.flag(:trap_exit, true)

    try do
      with {:ok, client} <- client_mod.start_link(opts),
           :ok <- GenServer.call(source, {:worker_client, self(), client, client_mod}) do
        Process.unlink(client)

        case await_ready(client_mod, client, timeout) do
          :ok ->
            {:ok, client}

          error ->
            close_client(%{client: client, client_module: client_mod})
            error
        end
      end
    after
      Process.flag(:trap_exit, trap_exit)
      if not Process.alive?(source), do: exit(:shutdown)
    end
  end

  defp oauth_token_cache_opts(url, opts) do
    oauth = Keyword.get(opts, :oauth, [])
    configured_secret = Keyword.get(oauth, :token_secret)

    persist? =
      Keyword.get(opts, :persist_oauth_tokens, false) == true or is_binary(configured_secret)

    if persist? do
      secret_name =
        configured_secret || Keyword.get(opts, :oauth_token_secret) ||
          oauth_token_secret_name(url)

      cache = [load: fn -> load_oauth_token_secret(secret_name) end]

      cache =
        if Keyword.get(opts, :volatile_credentials, false) do
          cache
        else
          Keyword.put(cache, :save, fn token ->
            save_oauth_token_secret(secret_name, url, oauth, token)
          end)
        end

      [oauth_token_cache: cache]
    else
      []
    end
  end

  defp resolved_http_oauth(oauth) when is_list(oauth) do
    oauth
    |> maybe_resolve_client_secret()
    |> maybe_put_loopback_authorization_provider()
    |> Keyword.drop([:client_secret_secret, :token_secret])
  end

  defp resolved_http_oauth(oauth), do: oauth

  defp client_start_timeout(oauth, opts) when is_list(oauth) do
    timeout = Keyword.get(oauth, :authorization_timeout_ms)
    ready_timeout = client_ready_timeout_ms(opts)

    if authorization_code_provider?(oauth) and is_integer(timeout) and timeout > 0 do
      max(authorization_attempt_count(oauth) * timeout + 5_000, ready_timeout)
    else
      ready_timeout
    end
  end

  defp client_start_timeout(_oauth, opts), do: client_ready_timeout_ms(opts)

  defp authorization_attempt_count(oauth) do
    if authorization_approval_enabled?(oauth), do: 2, else: 1
  end

  defp maybe_resolve_client_secret(oauth) do
    cond do
      is_binary(Keyword.get(oauth, :client_secret)) and Keyword.get(oauth, :client_secret) != "" ->
        oauth

      is_binary(Keyword.get(oauth, :client_secret_secret)) and
          Keyword.get(oauth, :client_secret_secret) != "" ->
        case Secrets.resolve(Keyword.fetch!(oauth, :client_secret_secret), env_fallback: true) do
          {:ok, secret, _source} -> Keyword.put(oauth, :client_secret, secret)
          _ -> oauth
        end

      true ->
        oauth
    end
  end

  defp maybe_put_loopback_authorization_provider(oauth) do
    redirect_uri = Keyword.get(oauth, :redirect_uri)

    cond do
      authorization_code_provider?(oauth) ->
        oauth

      not pkce_flow?(Keyword.get(oauth, :flow)) ->
        oauth

      not LocalCallbackListener.local_redirect_uri?(redirect_uri) ->
        oauth

      true ->
        Keyword.put(
          oauth,
          :authorization_code_provider,
          loopback_authorization_code_provider(oauth)
        )
    end
  end

  defp authorization_code_provider?(oauth) do
    provider =
      Keyword.get(oauth, :authorization_code_provider) || Keyword.get(oauth, :auth_code_provider)

    is_function(provider, 1) or is_function(provider, 0)
  end

  defp pkce_flow?(flow) when flow in [:authorization_code_pkce, "authorization_code_pkce"],
    do: true

  defp pkce_flow?(_flow), do: false

  defp loopback_authorization_code_provider(oauth) do
    redirect_uri = Keyword.fetch!(oauth, :redirect_uri)
    observer = Keyword.get(oauth, :authorization_request_observer)
    timeout = authorization_timeout_ms(oauth)

    approval_context =
      Keyword.get(oauth, :authorization_approval_context) ||
        Keyword.get(oauth, :approval_context, [])

    channel? = authorization_approval_enabled?(oauth) or authorization_observer?(observer)

    fn authorization_request ->
      with :ok <- require_authorization_channel(channel?, authorization_request),
           {:ok, listener} <-
             LocalCallbackListener.start(redirect_uri,
               expected_state: authorization_request.state
             ) do
        notify_authorization_request(observer, authorization_request)

        # The URL carries state and the PKCE challenge: it reaches the operator
        # only through the approval request or observer, never the log.
        Logger.info(
          "MCP OAuth authorization required for #{authorization_request.resource || "server"} " <>
            "(request #{short_hash(authorization_request.state || "")}); " <>
            "open the authorization URL from the approval request"
        )

        try do
          with :ok <-
                 maybe_request_authorization_approval(
                   authorization_request,
                   oauth,
                   approval_context,
                   timeout
                 ),
               {:ok, callback_url} <- LocalCallbackListener.wait(listener, timeout),
               {:ok, callback} <- parse_loopback_authorization_callback(callback_url) do
            {:ok, callback}
          end
        after
          LocalCallbackListener.stop(listener)
        end
      end
    end
  end

  defp authorization_observer?(observer), do: is_function(observer, 1) or is_pid(observer)

  # The authorization URL is never logged, so without an approval request or an
  # observer nobody could open it: fail now instead of waiting out the timeout.
  defp require_authorization_channel(true, _authorization_request), do: :ok

  defp require_authorization_channel(false, authorization_request) do
    Logger.warning(
      "MCP OAuth authorization for #{authorization_request.resource || "server"} cannot be " <>
        "delivered: authorization_approval is disabled and no authorization_request_observer " <>
        "is configured. Enable authorization_approval, set an observer, or supply an " <>
        "authorization_code_provider."
    )

    {:error, :mcp_oauth_authorization_channel_required}
  end

  defp authorization_timeout_ms(oauth) do
    case Keyword.get(oauth, :authorization_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @oauth_authorization_timeout_ms
    end
  end

  defp maybe_request_authorization_approval(authorization_request, oauth, context, timeout) do
    if authorization_approval_enabled?(oauth) do
      case LemonCore.ExecApprovals.request(%{
             run_id:
               approval_context_value(
                 context,
                 :run_id,
                 "mcp-oauth-#{server_slug(authorization_request.resource || "server")}"
               ),
             session_key: approval_context_value(context, :session_key, "agent:mcp:oauth"),
             agent_id: approval_context_value(context, :agent_id, nil),
             tool: "mcp_#{server_slug(authorization_request.resource || "server")}_oauth",
             action: authorization_approval_action(authorization_request),
             rationale: authorization_approval_rationale(authorization_request),
             expires_in_ms: timeout
           }) do
        {:ok, :approved, _scope} -> :ok
        {:ok, :denied} -> {:error, :oauth_authorization_denied}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp authorization_approval_enabled?(oauth) do
    Keyword.get(oauth, :authorization_approval, true) not in [
      false,
      "false",
      :disabled,
      "disabled"
    ]
  end

  defp authorization_approval_action(authorization_request) do
    %{
      type: "mcp_oauth_authorization",
      authorization_url: authorization_request.authorization_url,
      resource: authorization_request.resource,
      client_id: authorization_request.client_id,
      redirect_uri: authorization_request.redirect_uri,
      scope: authorization_request.scope,
      state_hash: short_hash(authorization_request.state || "")
    }
  end

  defp authorization_approval_rationale(authorization_request) do
    [
      "MCP OAuth authorization required",
      "resource=#{authorization_request.resource || "server"}",
      "client=#{authorization_request.client_id || "unknown"}",
      "scope=#{authorization_request.scope || "unspecified"}",
      "open the authorization URL, complete login, then approve once to continue"
    ]
    |> Enum.join("; ")
  end

  defp notify_authorization_request(observer, authorization_request)
       when is_function(observer, 1) do
    observer.(authorization_request)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp notify_authorization_request(observer, authorization_request) when is_pid(observer) do
    send(observer, {:mcp_oauth_authorization_request, authorization_request})
    :ok
  end

  defp notify_authorization_request(_observer, _authorization_request), do: :ok

  defp parse_loopback_authorization_callback(callback_url) when is_binary(callback_url) do
    params =
      callback_url
      |> URI.parse()
      |> Map.get(:query)
      |> case do
        query when is_binary(query) -> URI.decode_query(query)
        _ -> %{}
      end

    cond do
      is_binary(params["error"]) and params["error"] != "" ->
        {:error, {:oauth_callback_error, params["error"], params["error_description"]}}

      is_binary(params["code"]) and params["code"] != "" and is_binary(params["state"]) and
          params["state"] != "" ->
        {:ok, %{code: params["code"], state: params["state"]}}

      true ->
        {:error, :invalid_oauth_callback}
    end
  end

  defp oauth_token_secret_name(url) do
    hash =
      :crypto.hash(:sha256, url)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "mcp_oauth_http_#{hash}"
  end

  defp load_oauth_token_secret(secret_name) do
    with {:ok, json} <- Secrets.get(secret_name, env_fallback: false),
         {:ok, token} <- Jason.decode(json) do
      {:ok, token}
    else
      _ -> nil
    end
  end

  defp save_oauth_token_secret(secret_name, url, oauth, token) when is_map(token) do
    token =
      token
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    metadata = Map.get(token, "metadata")
    resource = if is_map(metadata), do: Map.get(metadata, "resource"), else: nil

    token =
      Map.merge(token, %{
        "version" => 1,
        "client_id" => Keyword.get(oauth, :client_id),
        "scope" => oauth_scope(oauth),
        "resource" => resource || url,
        "updated_at" => LemonCore.Clock.now_ms()
      })

    case Jason.encode(token) do
      {:ok, json} -> Secrets.set(secret_name, json, provider: "mcp_oauth")
      _ -> :error
    end
  end

  defp oauth_scope(oauth) do
    cond do
      is_binary(Keyword.get(oauth, :scope)) -> Keyword.get(oauth, :scope)
      is_list(Keyword.get(oauth, :scopes)) -> Enum.join(Keyword.get(oauth, :scopes), " ")
      true -> nil
    end
  end

  defp call_mcp_entry(client_mod, client, {:tool, original_name}, params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    case client_call(client_mod, :call_tool, [client, original_name, params, timeout]) do
      {:ok, content} ->
        {:ok,
         %AgentToolResult{
           content: content_blocks(content),
           details: %{mcp: true},
           trust: :untrusted
         }}

      {:error, {:tool_error, content}} ->
        {:error, {:tool_error, content_blocks(content)}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp call_mcp_entry(client_mod, client, {:utility, :list_resources, filters}, _params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    with {:ok, resources} <- client_call(client_mod, :list_resources, [client, timeout]) do
      filtered = Enum.filter(resources, &resource_allowed?(&1, filters))

      {:ok,
       %AgentToolResult{content: json_content(filtered), details: %{mcp: true}, trust: :untrusted}}
    end
  end

  defp call_mcp_entry(client_mod, client, {:utility, :read_resource, filters}, params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    with {:ok, uri} <- required_string(params, "uri"),
         :ok <- ensure_resource_allowed(uri, filters),
         {:ok, contents} <- client_call(client_mod, :read_resource, [client, uri, timeout]) do
      {:ok,
       %AgentToolResult{content: json_content(contents), details: %{mcp: true}, trust: :untrusted}}
    end
  end

  defp call_mcp_entry(client_mod, client, {:utility, :list_prompts, filters}, _params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    with {:ok, prompts} <- client_call(client_mod, :list_prompts, [client, timeout]) do
      filtered = Enum.filter(prompts, &prompt_allowed?(&1, filters))

      {:ok,
       %AgentToolResult{content: json_content(filtered), details: %{mcp: true}, trust: :untrusted}}
    end
  end

  defp call_mcp_entry(client_mod, client, {:utility, :get_prompt, filters}, params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    with {:ok, name} <- required_string(params, "name"),
         :ok <- ensure_prompt_allowed(name, filters),
         arguments <- Map.get(params, "arguments", %{}),
         true <- is_map(arguments) || {:error, {:invalid_param, "arguments must be an object"}},
         {:ok, prompt} <- client_call(client_mod, :get_prompt, [client, name, arguments, timeout]) do
      {:ok,
       %AgentToolResult{content: json_content(prompt), details: %{mcp: true}, trust: :untrusted}}
    end
  end

  defp client_call({:ok, client_mod}, function, args), do: client_call(client_mod, function, args)
  defp client_call({:error, reason}, _function, _args), do: {:error, reason}

  defp client_call(client_mod, function, args) when is_atom(client_mod) do
    # Cached state/capability reads are local. Keep uncertainty after any
    # dispatched protocol operation, including failed discovery and timeouts.
    if function in [
         :list_tools,
         :call_tool,
         :list_resources,
         :read_resource,
         :list_prompts,
         :get_prompt
       ] and function_exported?(client_mod, function, length(args)) do
      LemonCore.NativeProcess.unsupported!()
    end

    apply(client_mod, function, args)
  rescue
    _ -> {:error, :client_error}
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :not_connected}
  end

  defp server_client_module(:stdio), do: Client
  defp server_client_module(:http), do: Client.HTTP
  defp server_client_module(:sse), do: Client.SSE

  defp await_ready(client_mod, client, timeout_ms) do
    case await_ready_until(client_mod, client, System.monotonic_time(:millisecond) + timeout_ms) do
      :ok ->
        :ok

      error ->
        close_client(%{client: client, client_module: client_mod})
        error
    end
  end

  # A client that exits before its handshake (e.g. the stdio server process
  # failed to start) cannot become ready; report that now instead of blocking
  # this server for the rest of the ready deadline.
  defp await_ready_until(client_mod, client, deadline) do
    case client_call(client_mod, :state, [client]) do
      :ready ->
        :ok

      {:error, :not_connected} = error ->
        error

      _starting ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :ready_timeout}
        else
          Process.sleep(50)
          await_ready_until(client_mod, client, deadline)
        end
    end
  end

  defp wrap_mcp_tool(command, mcp_tool) do
    original_name = map_value(mcp_tool, "name") || map_value(mcp_tool, :name)
    tool_name = "mcp_#{server_slug(command)}_#{tool_slug(original_name)}"
    description = map_value(mcp_tool, "description") || map_value(mcp_tool, :description) || ""
    parameters = map_value(mcp_tool, "inputSchema") || map_value(mcp_tool, :inputSchema) || %{}

    # MCP's configured request deadline owns cancellation/unknown-outcome
    # classification; an independent AgentTool timer would race that reply.
    {%AgentTool{
       name: tool_name,
       effect: mcp_effect(mcp_tool),
       timeout_ms: :infinity,
       description: description,
       parameters: parameters,
       label: "MCP #{original_name}",
       execute: nil
     }, {:tool, original_name}}
  end

  defp mcp_effect(tool) do
    annotations = map_value(tool, "annotations") || map_value(tool, :annotations) || %{}

    if (map_value(annotations, "readOnlyHint") || map_value(annotations, :readOnlyHint)) === true,
      do: :none,
      else: :external
  end

  defp list_advertised_tools(_client_mod, _client, %{tools: false}), do: {:ok, []}

  defp list_advertised_tools(client_mod, client, _capabilities),
    do: client_call(client_mod, :list_tools, [client, @client_request_timeout_ms])

  defp resource_utility_tools(_command, _client_mod, _client, %{enabled_tools: names}, _caps)
       when is_list(names),
       do: {[], []}

  defp resource_utility_tools(_command, _client_mod, _client, _filters, %{resources: false}),
    do: {[], []}

  defp resource_utility_tools(command, client_mod, client, filters, _capabilities) do
    case client_call(client_mod, :list_resources, [client, @client_request_timeout_ms]) do
      {:ok, resources} ->
        resources = Enum.filter(resources, &resource_allowed?(&1, filters))

        {[
           utility_tool(
             command,
             "resources_list",
             "List MCP resources",
             %{
               "type" => "object",
               "properties" => %{}
             },
             {:utility, :list_resources, filters}
           ),
           utility_tool(
             command,
             "resource_read",
             "Read an MCP resource by URI",
             %{
               "type" => "object",
               "properties" => %{
                 "uri" => %{"type" => "string", "description" => "MCP resource URI"}
               },
               "required" => ["uri"]
             },
             {:utility, :read_resource, filters}
           )
         ], resources}

      _ ->
        {[], []}
    end
  end

  defp prompt_utility_tools(_command, _client_mod, _client, %{enabled_tools: names}, _caps)
       when is_list(names),
       do: {[], []}

  defp prompt_utility_tools(_command, _client_mod, _client, _filters, %{prompts: false}),
    do: {[], []}

  defp prompt_utility_tools(command, client_mod, client, filters, _capabilities) do
    case client_call(client_mod, :list_prompts, [client, @client_request_timeout_ms]) do
      {:ok, prompts} ->
        prompts = Enum.filter(prompts, &prompt_allowed?(&1, filters))

        {[
           utility_tool(
             command,
             "prompts_list",
             "List MCP prompts",
             %{
               "type" => "object",
               "properties" => %{}
             },
             {:utility, :list_prompts, filters}
           ),
           utility_tool(
             command,
             "prompt_get",
             "Get an MCP prompt by name",
             %{
               "type" => "object",
               "properties" => %{
                 "name" => %{"type" => "string", "description" => "MCP prompt name"},
                 "arguments" => %{"type" => "object", "description" => "Prompt arguments"}
               },
               "required" => ["name"]
             },
             {:utility, :get_prompt, filters}
           )
         ], prompts}

      _ ->
        {[], []}
    end
  end

  defp utility_tool(command, suffix, description, parameters, call_spec) do
    tool_name = "mcp_#{server_slug(command)}_#{suffix}"

    # Utilities use the same bounded MCP request owner, not a second tool timer.
    {%AgentTool{
       name: tool_name,
       effect: :none,
       timeout_ms: :infinity,
       description: description,
       parameters: parameters,
       label: "MCP #{suffix}",
       execute: nil
     }, call_spec}
  end

  defp content_blocks(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        %TextContent{text: text}

      %{type: "text", text: text} when is_binary(text) ->
        %TextContent{text: text}

      item ->
        %TextContent{text: Jason.encode!(item)}
    end)
  end

  defp content_blocks(content), do: [%TextContent{text: inspect(content)}]

  defp json_content(value), do: [%TextContent{text: Jason.encode!(value)}]

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_param, key}}
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  defp stdio_parts({:stdio, command, args}), do: {command, args, []}
  defp stdio_parts({:stdio, command, args, opts}), do: {command, args, opts}

  defp http_parts({:http, url}), do: {url, []}
  defp http_parts({:http, url, opts}), do: {url, opts}
  defp http_parts({:sse, url}), do: {url, []}
  defp http_parts({:sse, url, opts}), do: {url, opts}

  defp client_ready_timeout_ms(opts) do
    Keyword.get(opts, :ready_timeout_ms, @client_ready_timeout_ms)
  end

  defp request_timeout(opts, config) do
    source_opts =
      case config do
        {:stdio, _, _, opts} -> opts
        {:stdio, _, _} -> []
        {_, _, opts} -> opts
        _ -> []
      end

    case Keyword.get(
           opts,
           :timeout_ms,
           Keyword.get(source_opts, :timeout_ms, @client_request_timeout_ms)
         ) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, 300_000)
      _ -> @client_request_timeout_ms
    end
  end

  defp filter_config(opts) do
    %{
      profile_owned: Keyword.get(opts, :profile_owned, false),
      enabled_tools: Keyword.get(opts, :enabled_tools),
      allow_tools: Keyword.get(opts, :allow_tools, []),
      block_tools: Keyword.get(opts, :block_tools, []),
      allow_resources: Keyword.get(opts, :allow_resources, []),
      block_resources: Keyword.get(opts, :block_resources, []),
      allow_prompts: Keyword.get(opts, :allow_prompts, []),
      block_prompts: Keyword.get(opts, :block_prompts, [])
    }
  end

  defp approval_context_value(context, key, default) when is_list(context) do
    Keyword.get(context, key, default)
  end

  defp approval_context_value(context, key, default) when is_map(context) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key)) || default
  end

  defp approval_context_value(_context, _key, default), do: default

  defp short_hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp tool_allowed?(tool, filters) do
    names = names_for(tool, ["name"])

    Enum.any?(names, &(String.valid?(&1) and &1 != "")) and
      (not filters.profile_owned or Enum.any?(names, &valid_remote_name?/1)) and
      (is_nil(filters.enabled_tools) or Enum.any?(names, &(&1 in filters.enabled_tools))) and
      allowed?(names, filters.allow_tools, filters.block_tools)
  end

  defp executable_call_allowed?(config, {:tool, name}),
    do: tool_allowed?(%{"name" => name}, filter_config(config_options(config)))

  defp executable_call_allowed?(config, {:utility, _, _}),
    do: not Keyword.has_key?(config_options(config), :enabled_tools)

  defp config_options({:stdio, _, _, opts}), do: opts
  defp config_options({transport, _, opts}) when transport in [:http, :sse], do: opts
  defp config_options(_), do: []

  defp config_redact_values(config) do
    opts = config_options(config)

    (Keyword.get(opts, :redact_values, []) ++
       Enum.map(Keyword.get(opts, :headers, []), &elem(&1, 1)))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp scrub_remote_tool(tool, values) do
    name = map_value(tool, "name") || map_value(tool, :name)
    schema = map_value(tool, "inputSchema") || map_value(tool, :inputSchema)
    annotations = map_value(tool, "annotations") || map_value(tool, :annotations) || %{}

    %{
      "name" => if(scrub_inventory(name, values) == name, do: name, else: nil),
      "description" =>
        scrub_inventory(
          map_value(tool, "description") || map_value(tool, :description) || "",
          values
        ),
      "inputSchema" => if(safe_inventory_schema?(schema, values), do: schema, else: nil),
      "annotations" => %{
        "readOnlyHint" =>
          (map_value(annotations, "readOnlyHint") || map_value(annotations, :readOnlyHint)) ===
            true
      }
    }
  end

  defp safe_inventory_schema?(schema, values) when is_map(schema) do
    case Jason.encode(schema) do
      {:ok, json} when byte_size(json) <= 32_768 -> scrub_inventory(schema, values) == schema
      _ -> false
    end
  rescue
    _ -> false
  end

  defp safe_inventory_schema?(_, _), do: false

  defp scrub_inventory(value, values) when is_binary(value) do
    value = Enum.reduce(values, value, &String.replace(&2, &1, "[REDACTED]"))
    LemonCore.Redact.text(value, drop_keys: true)
  end

  defp scrub_inventory(value, values) when is_map(value),
    do:
      Map.new(value, fn {key, nested} ->
        {scrub_inventory(key, values), scrub_inventory(nested, values)}
      end)

  defp scrub_inventory(value, values) when is_list(value),
    do: Enum.map(value, &scrub_inventory(&1, values))

  defp scrub_inventory(value, _values), do: value

  defp resource_allowed?(resource, filters) do
    resource
    |> names_for(["uri", "name"])
    |> allowed?(filters.allow_resources, filters.block_resources)
  end

  defp prompt_allowed?(prompt, filters) do
    prompt
    |> names_for(["name"])
    |> allowed?(filters.allow_prompts, filters.block_prompts)
  end

  defp names_for(map, keys) do
    keys
    |> Enum.flat_map(fn key -> [map_value(map, key), map_value(map, String.to_atom(key))] end)
    |> Enum.filter(&is_binary/1)
  end

  defp allowed?(values, allow, block) do
    allowed_by_allow = allow == [] or Enum.any?(values, &(&1 in allow))
    blocked_by_block = Enum.any?(values, &(&1 in block))
    allowed_by_allow and not blocked_by_block
  end

  defp ensure_resource_allowed(uri, filters) do
    if allowed?([uri], filters.allow_resources, filters.block_resources) do
      :ok
    else
      {:error, {:blocked_resource, uri}}
    end
  end

  defp ensure_prompt_allowed(name, filters) do
    if allowed?([name], filters.allow_prompts, filters.block_prompts) do
      :ok
    else
      {:error, {:blocked_prompt, name}}
    end
  end

  defp client_capabilities(client_mod, client) do
    case client_call(client_mod, :server_capabilities, [client]) do
      {:ok, capabilities} when is_map(capabilities) -> capability_summary(capabilities)
      _ -> %{}
    end
  end

  defp validate_http_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        :ok

      _ ->
        {:error, "invalid HTTP URL: #{url}"}
    end
  end

  defp capability_summary(capabilities) do
    %{
      tools: Map.has_key?(capabilities, "tools") or Map.has_key?(capabilities, :tools),
      resources:
        Map.has_key?(capabilities, "resources") or Map.has_key?(capabilities, :resources),
      prompts: Map.has_key?(capabilities, "prompts") or Map.has_key?(capabilities, :prompts)
    }
  end

  defp validate_filter_opts(opts) do
    allowed_keys = [
      :enabled_tools,
      :allow_tools,
      :block_tools,
      :allow_resources,
      :block_resources,
      :allow_prompts,
      :block_prompts
    ]

    case Enum.find(opts, fn {key, value} -> key in allowed_keys and not string_list?(value) end) do
      nil ->
        with :ok <-
               validate_positive_timeout(Keyword.get(opts, :ready_timeout_ms), "ready_timeout_ms") do
          validate_positive_timeout(Keyword.get(opts, :timeout_ms), "timeout_ms")
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

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp validate_http_opts(opts) do
    with :ok <- validate_filter_opts(opts),
         :ok <- validate_http_headers(Keyword.get(opts, :headers, [])),
         :ok <- validate_http_token_persistence(opts),
         :ok <- validate_http_oauth(Keyword.get(opts, :oauth, [])) do
      :ok
    end
  end

  defp validate_http_token_persistence(opts) do
    persist? = Keyword.get(opts, :persist_oauth_tokens)
    secret = Keyword.get(opts, :oauth_token_secret)

    cond do
      not is_nil(persist?) and not is_boolean(persist?) ->
        {:error, "persist_oauth_tokens must be a boolean"}

      not is_nil(secret) and (not is_binary(secret) or secret == "") ->
        {:error, "oauth_token_secret must be a non-empty string"}

      true ->
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

  defp server_slug(command) do
    command
    |> Path.basename()
    |> tool_slug()
  end

  defp tool_slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp tool_slug(_), do: "tool"

  defp close_client(%{client: client, client_module: client_mod})
       when is_pid(client) and is_atom(client_mod) do
    if Process.alive?(client) do
      client_call(client_mod, :close, [client])
      if Process.alive?(client), do: GenServer.stop(client, :shutdown, 5_000)
    end

    :ok
  catch
    :exit, _ ->
      Process.exit(client, :kill)
      :ok
  end

  defp close_client(_server), do: :ok

  defp schedule_refresh(state) do
    if state.refresh_timer do
      Process.cancel_timer(state.refresh_timer)
    end

    timer = Process.send_after(self(), :periodic_refresh, state.refresh_interval_ms)
    %{state | refresh_timer: timer}
  end
end
