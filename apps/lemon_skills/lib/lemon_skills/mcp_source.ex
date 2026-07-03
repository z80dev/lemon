defmodule LemonSkills.McpSource do
  @moduledoc """
  MCP (Model Context Protocol) source for discovering and caching tools from MCP servers.

  This module manages connections to external MCP servers, caches discovered tools,
  and provides a unified interface for tool discovery and invocation.
  """

  use GenServer

  require Logger

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonCore.OAuth.LocalCallbackListener
  alias LemonCore.Secrets

  @default_cache_ttl_ms :timer.minutes(5)
  @default_refresh_interval_ms :timer.minutes(1)
  @client_ready_timeout_ms 5_000
  @client_request_timeout_ms 10_000
  @oauth_authorization_timeout_ms :timer.minutes(5)

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
  """
  def start_link(opts \\ []) do
    if mcp_enabled?() do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    else
      GenServer.start_link(__MODULE__, [disabled: true], name: __MODULE__)
    end
  end

  @doc """
  Discover all tools from configured MCP servers.
  """
  @spec discover_tools(keyword()) :: [AgentTool.t()]
  def discover_tools(opts \\ []) do
    GenServer.call(__MODULE__, {:discover_tools, opts}, :infinity)
  end

  @doc """
  Get a specific tool by name from MCP sources.
  """
  @spec get_tool(String.t()) :: {:ok, AgentTool.t()} | :error
  def get_tool(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:get_tool, name})
  end

  @doc """
  Call a tool from an MCP server.
  """
  @spec call_tool(String.t(), map(), keyword()) ::
          {:ok, AgentToolResult.t()} | {:error, term()}
  def call_tool(tool_name, params, opts \\ []) do
    GenServer.call(__MODULE__, {:call_tool, tool_name, params, opts}, :infinity)
  end

  @doc """
  Refresh the tool cache from all MCP servers.
  """
  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :refresh, :infinity)
  end

  @doc """
  Get the status of all configured MCP servers.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Validate an MCP server configuration.
  """
  @spec validate_config(server_config()) :: :ok | {:error, String.t()}
  def validate_config({:stdio, command, args})
      when is_binary(command) and is_list(args) do
    if String.trim(command) == "" do
      {:error, "stdio command cannot be empty"}
    else
      :ok
    end
  end

  def validate_config({:stdio, command, args, opts})
      when is_binary(command) and is_list(args) and is_list(opts) do
    with :ok <- validate_config({:stdio, command, args}),
         :ok <- validate_filter_opts(opts) do
      :ok
    end
  end

  def validate_config({:http, url, opts}) when is_binary(url) and is_list(opts) do
    with :ok <- validate_http_url(url),
         :ok <- validate_http_opts(opts) do
      :ok
    end
  end

  def validate_config({:http, url}) when is_binary(url) do
    validate_config({:http, url, []})
  end

  def validate_config({:sse, url, opts}) when is_binary(url) and is_list(opts) do
    with :ok <- validate_http_url(url),
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
  Check if MCP support is available and enabled.
  """
  @spec mcp_enabled?() :: boolean()
  def mcp_enabled? do
    disabled =
      Application.get_env(:lemon_skills, :mcp_disabled, false) ||
        System.get_env("LEMON_MCP_DISABLED") in ["1", "true", "TRUE", "yes", "YES"]

    if disabled do
      false
    else
      match?({:ok, _client_mod}, stdio_client_module())
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    disabled = Keyword.get(opts, :disabled, false)

    if disabled do
      {:ok, %{disabled: true, tool_cache: %{}, servers: %{}}}
    else
      cache_ttl = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)
      refresh_interval = Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms)

      state = %{
        disabled: false,
        servers: %{},
        tool_cache: %{},
        config_key: nil,
        cache_ttl_ms: cache_ttl,
        refresh_interval_ms: refresh_interval,
        refresh_timer: nil
      }

      state = initialize_servers(state, opts)
      state = schedule_refresh(state)

      {:ok, state}
    end
  end

  @impl true
  def handle_call({:discover_tools, _opts}, _from, %{disabled: true} = state) do
    {:reply, [], state}
  end

  @impl true
  def handle_call({:discover_tools, opts}, _from, state) do
    force_refresh = Keyword.get(opts, :force_refresh, false)
    state = maybe_reload_servers(state, opts)

    {tools, state} =
      if force_refresh or cache_expired?(state) do
        refresh_tools(state)
      else
        {cached_tools(state), state}
      end

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:get_tool, _name}, _from, %{disabled: true} = state) do
    {:reply, :error, state}
  end

  @impl true
  def handle_call({:get_tool, name}, _from, state) do
    result =
      case Map.get(state.tool_cache, name) do
        nil -> :error
        %{tool: tool} -> {:ok, tool}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:call_tool, _tool_name, _params, _opts}, _from, %{disabled: true} = state) do
    {:reply, {:error, :mcp_disabled}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, params, opts}, _from, state) do
    state = maybe_reload_servers(state, opts)

    reply =
      case Map.get(state.tool_cache, tool_name) do
        nil ->
          {:error, :not_found}

        %{server_name: server_name, original_name: original_name} ->
          case Map.get(state.servers, server_name) do
            %{client: client, client_module: client_mod, connected: true} when is_pid(client) ->
              call_mcp_entry(client_mod, client, original_name, params, opts)

            _ ->
              {:error, :not_connected}
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:refresh, _from, %{disabled: true} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {_tools, state} = state |> maybe_reload_servers([]) |> refresh_tools()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, %{disabled: true} = state) do
    {:reply, %{disabled: true, servers: %{}, cached_tools: 0}, state}
  end

  @impl true
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

  @impl true
  def handle_info(:periodic_refresh, %{disabled: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:periodic_refresh, state) do
    state =
      if cache_expired?(state) do
        {_, new_state} = refresh_tools(state)
        new_state
      else
        state
      end

    state = schedule_refresh(state)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp initialize_servers(state, opts) do
    config = LemonSkills.Config.mcp_config(Keyword.get(opts, :cwd))
    config_key = :erlang.phash2(config.servers)

    if config.enabled do
      configs = config.servers

      servers =
        Enum.reduce(configs, %{}, fn cfg, acc ->
          name = server_name(cfg)

          server = %{
            config: cfg,
            client: nil,
            client_module: nil,
            connected: false,
            last_error: nil,
            tools: [],
            resources: [],
            prompts: [],
            capabilities: %{}
          }

          Map.put(acc, name, server)
        end)

      %{state | servers: servers, tool_cache: %{}, config_key: config_key}
    else
      %{state | servers: %{}, tool_cache: %{}, config_key: config_key}
    end
  end

  defp server_name({:stdio, command, args}) do
    :crypto.hash(:md5, :erlang.term_to_binary({:stdio, command, args}))
    |> Base.encode16(case: :lower)
    |> String.to_atom()
  end

  defp server_name({:stdio, command, args, opts}) do
    :crypto.hash(:md5, :erlang.term_to_binary({:stdio, command, args, opts}))
    |> Base.encode16(case: :lower)
    |> String.to_atom()
  end

  defp server_name({:http, url, _opts}) do
    :crypto.hash(:md5, url)
    |> Base.encode16(case: :lower)
    |> String.to_atom()
  end

  defp server_name({:http, url}) do
    server_name({:http, url, []})
  end

  defp server_name({:sse, url, _opts}) do
    :crypto.hash(:md5, url)
    |> Base.encode16(case: :lower)
    |> String.to_atom()
  end

  defp server_name({:sse, url}) do
    server_name({:sse, url, []})
  end

  defp cache_expired?(state) do
    if map_size(state.tool_cache) == 0 do
      true
    else
      now = System.monotonic_time(:millisecond)

      Enum.any?(state.tool_cache, fn {_name, cached} ->
        now - cached.cached_at > state.cache_ttl_ms
      end)
    end
  end

  defp cached_tools(state) do
    state.tool_cache
    |> Map.values()
    |> Enum.map(& &1.tool)
    |> Enum.sort_by(& &1.name)
  end

  defp refresh_tools(state) do
    {servers, tool_cache} =
      Enum.reduce(state.servers, {%{}, %{}}, fn {server_name, server}, {servers_acc, cache_acc} ->
        {server, tools} = refresh_server(server_name, server)

        cache_entries =
          Map.new(tools, fn {tool, original_name} ->
            {tool.name,
             %{
               tool: tool,
               cached_at: System.monotonic_time(:millisecond),
               server_name: server_name,
               original_name: original_name
             }}
          end)

        {Map.put(servers_acc, server_name, server), Map.merge(cache_acc, cache_entries)}
      end)

    tools =
      tool_cache
      |> Map.values()
      |> Enum.map(& &1.tool)
      |> Enum.sort_by(& &1.name)

    {tools, %{state | servers: servers, tool_cache: tool_cache}}
  end

  defp maybe_reload_servers(state, opts) do
    config = LemonSkills.Config.mcp_config(Keyword.get(opts, :cwd))
    config_key = :erlang.phash2(config.servers)

    if config_key == state.config_key do
      state
    else
      Enum.each(state.servers, fn {_name, server} -> close_client(server) end)
      initialize_servers(state, opts)
    end
  end

  defp refresh_server(_server_name, %{config: config} = server) when elem(config, 0) == :stdio do
    {command, _args, opts} = stdio_parts(config)
    filters = filter_config(opts)

    case ensure_client(server, :stdio) do
      {:ok, client} ->
        client_mod = server_client_module(:stdio)

        case client_call(client_mod, :list_tools, [client, @client_request_timeout_ms]) do
          {:ok, tools} ->
            capabilities = client_capabilities(client_mod, client)

            wrapped =
              tools
              |> Enum.filter(&tool_allowed?(&1, filters))
              |> Enum.map(&wrap_mcp_tool(command, &1))

            {resource_tools, resources} =
              resource_utility_tools(command, client_mod, client, filters)

            {prompt_tools, prompts} = prompt_utility_tools(command, client_mod, client, filters)
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

          {:error, reason} ->
            {%{
               server
               | connected: false,
                 client_module: client_mod,
                 last_error: inspect(reason),
                 tools: [],
                 resources: [],
                 prompts: [],
                 capabilities: %{}
             }, []}
        end

      {:error, reason} ->
        {%{
           server
           | connected: false,
             client_module: nil,
             last_error: inspect(reason),
             tools: [],
             resources: [],
             prompts: [],
             capabilities: %{}
         }, []}
    end
  end

  defp refresh_server(_server_name, %{config: config} = server) when elem(config, 0) == :http do
    {url, opts} = http_parts(config)
    filters = filter_config(opts)

    case ensure_client(server, :http) do
      {:ok, client} ->
        client_mod = server_client_module(:http)

        case client_call(client_mod, :list_tools, [client, @client_request_timeout_ms]) do
          {:ok, tools} ->
            capabilities = client_capabilities(client_mod, client)

            wrapped =
              tools
              |> Enum.filter(&tool_allowed?(&1, filters))
              |> Enum.map(&wrap_mcp_tool(url, &1))

            {resource_tools, resources} = resource_utility_tools(url, client_mod, client, filters)
            {prompt_tools, prompts} = prompt_utility_tools(url, client_mod, client, filters)
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

          {:error, reason} ->
            {%{
               server
               | connected: false,
                 client_module: client_mod,
                 last_error: inspect(reason),
                 tools: [],
                 resources: [],
                 prompts: [],
                 capabilities: %{}
             }, []}
        end

      {:error, reason} ->
        {%{
           server
           | connected: false,
             client_module: nil,
             last_error: inspect(reason),
             tools: [],
             resources: [],
             prompts: [],
             capabilities: %{}
         }, []}
    end
  end

  defp refresh_server(_server_name, %{config: config} = server) when elem(config, 0) == :sse do
    {url, opts} = http_parts(config)
    filters = filter_config(opts)

    case ensure_client(server, :sse) do
      {:ok, client} ->
        client_mod = server_client_module(:sse)

        case client_call(client_mod, :list_tools, [client, @client_request_timeout_ms]) do
          {:ok, tools} ->
            capabilities = client_capabilities(client_mod, client)

            wrapped =
              tools
              |> Enum.filter(&tool_allowed?(&1, filters))
              |> Enum.map(&wrap_mcp_tool(url, &1))

            {resource_tools, resources} = resource_utility_tools(url, client_mod, client, filters)
            {prompt_tools, prompts} = prompt_utility_tools(url, client_mod, client, filters)
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

          {:error, reason} ->
            {%{
               server
               | connected: false,
                 client_module: client_mod,
                 last_error: inspect(reason),
                 tools: [],
                 resources: [],
                 prompts: [],
                 capabilities: %{}
             }, []}
        end

      {:error, reason} ->
        {%{
           server
           | connected: false,
             client_module: nil,
             last_error: inspect(reason),
             tools: [],
             resources: [],
             prompts: [],
             capabilities: %{}
         }, []}
    end
  end

  defp ensure_client(%{client: client}, _transport) when is_pid(client) do
    if Process.alive?(client), do: {:ok, client}, else: {:error, :client_down}
  end

  defp ensure_client(%{config: config}, :stdio) do
    {command, args, source_opts} = stdio_parts(config)

    opts =
      [
        command: command,
        args: args,
        timeout_ms: @client_request_timeout_ms
      ] ++ sampling_client_opts(command, source_opts)

    with {:ok, client_mod} <- stdio_client_module(),
         {:ok, client} <- apply(client_mod, :start_link, [opts]),
         :ok <- await_ready(client_mod, client, client_ready_timeout_ms(source_opts)) do
      {:ok, client}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp ensure_client(%{config: config}, :http) do
    {url, opts} = http_parts(config)
    oauth = resolved_http_oauth(Keyword.get(opts, :oauth, []))

    client_opts =
      [
        url: url,
        headers: Keyword.get(opts, :headers, []),
        oauth: oauth,
        timeout: client_start_timeout(oauth, opts),
        timeout_ms: @client_request_timeout_ms
      ] ++ oauth_token_cache_opts(url, opts)

    with {:ok, client_mod} <- http_client_module(),
         {:ok, client} <- apply(client_mod, :start_link, [client_opts]),
         :ok <- await_ready(client_mod, client, client_ready_timeout_ms(opts)) do
      {:ok, client}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp ensure_client(%{config: config}, :sse) do
    {url, opts} = http_parts(config)
    ready_timeout_ms = client_ready_timeout_ms(opts)

    client_opts = [
      url: url,
      headers: Keyword.get(opts, :headers, []),
      timeout: ready_timeout_ms,
      timeout_ms: Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)
    ]

    with {:ok, client_mod} <- sse_client_module(),
         {:ok, client} <- apply(client_mod, :start_link, [client_opts]),
         :ok <- await_ready(client_mod, client, ready_timeout_ms) do
      {:ok, client}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
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

      [
        oauth_token_cache: [
          load: fn -> load_oauth_token_secret(secret_name) end,
          save: fn token -> save_oauth_token_secret(secret_name, url, oauth, token) end
        ]
      ]
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

    fn authorization_request ->
      with {:ok, listener} <- LocalCallbackListener.start(redirect_uri) do
        notify_authorization_request(observer, authorization_request)

        Logger.info(
          "MCP OAuth authorization required for #{authorization_request.resource || "server"}: #{authorization_request.authorization_url}"
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

    with {:ok, content} <-
           client_call(client_mod, :call_tool, [client, original_name, params, timeout]) do
      {:ok, %AgentToolResult{content: content_blocks(content), details: %{mcp: true}}}
    else
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
      {:ok, %AgentToolResult{content: json_content(filtered), details: %{mcp: true}}}
    end
  end

  defp call_mcp_entry(client_mod, client, {:utility, :read_resource, filters}, params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    with {:ok, uri} <- required_string(params, "uri"),
         :ok <- ensure_resource_allowed(uri, filters),
         {:ok, contents} <- client_call(client_mod, :read_resource, [client, uri, timeout]) do
      {:ok, %AgentToolResult{content: json_content(contents), details: %{mcp: true}}}
    end
  end

  defp call_mcp_entry(client_mod, client, {:utility, :list_prompts, filters}, _params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    with {:ok, prompts} <- client_call(client_mod, :list_prompts, [client, timeout]) do
      filtered = Enum.filter(prompts, &prompt_allowed?(&1, filters))
      {:ok, %AgentToolResult{content: json_content(filtered), details: %{mcp: true}}}
    end
  end

  defp call_mcp_entry(client_mod, client, {:utility, :get_prompt, filters}, params, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @client_request_timeout_ms)

    with {:ok, name} <- required_string(params, "name"),
         :ok <- ensure_prompt_allowed(name, filters),
         arguments <- Map.get(params, "arguments", %{}),
         true <- is_map(arguments) || {:error, {:invalid_param, "arguments must be an object"}},
         {:ok, prompt} <- client_call(client_mod, :get_prompt, [client, name, arguments, timeout]) do
      {:ok, %AgentToolResult{content: json_content(prompt), details: %{mcp: true}}}
    end
  end

  defp client_call({:ok, client_mod}, function, args), do: client_call(client_mod, function, args)
  defp client_call({:error, reason}, _function, _args), do: {:error, reason}

  defp client_call(client_mod, function, args) when is_atom(client_mod) do
    apply(client_mod, function, args)
  end

  defp stdio_client_module do
    client_mod = Module.concat(["Lemon" <> "MCP", "Client"])

    if Code.ensure_loaded?(client_mod) do
      {:ok, client_mod}
    else
      {:error, :mcp_client_not_available}
    end
  end

  defp http_client_module do
    client_mod = Module.concat(["Lemon" <> "MCP", "Client", "HTTP"])

    if Code.ensure_loaded?(client_mod) do
      {:ok, client_mod}
    else
      {:error, :mcp_http_client_not_available}
    end
  end

  defp sse_client_module do
    client_mod = Module.concat(["Lemon" <> "MCP", "Client", "SSE"])

    if Code.ensure_loaded?(client_mod) do
      {:ok, client_mod}
    else
      {:error, :mcp_sse_client_not_available}
    end
  end

  defp server_client_module(:stdio), do: elem(stdio_client_module(), 1)
  defp server_client_module(:http), do: elem(http_client_module(), 1)
  defp server_client_module(:sse), do: elem(sse_client_module(), 1)

  defp await_ready(client_mod, client, timeout_ms) do
    await_ready_until(client_mod, client, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_ready_until(client_mod, client, deadline) do
    cond do
      apply(client_mod, :state, [client]) == :ready ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :ready_timeout}

      true ->
        Process.sleep(50)
        await_ready_until(client_mod, client, deadline)
    end
  end

  defp wrap_mcp_tool(command, mcp_tool) do
    original_name = map_value(mcp_tool, "name") || map_value(mcp_tool, :name)
    tool_name = "mcp_#{server_slug(command)}_#{tool_slug(original_name)}"
    description = map_value(mcp_tool, "description") || map_value(mcp_tool, :description) || ""
    parameters = map_value(mcp_tool, "inputSchema") || map_value(mcp_tool, :inputSchema) || %{}

    {%AgentTool{
       name: tool_name,
       description: description,
       parameters: parameters,
       label: "MCP #{original_name}",
       execute: fn _tool_call_id, params, _signal, _on_update ->
         call_tool(tool_name, params)
       end
     }, {:tool, original_name}}
  end

  defp resource_utility_tools(command, client_mod, client, filters) do
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

  defp prompt_utility_tools(command, client_mod, client, filters) do
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

    {%AgentTool{
       name: tool_name,
       description: description,
       parameters: parameters,
       label: "MCP #{suffix}",
       execute: fn _tool_call_id, params, _signal, _on_update ->
         call_tool(tool_name, params)
       end
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

  defp filter_config(opts) do
    %{
      allow_tools: Keyword.get(opts, :allow_tools, []),
      block_tools: Keyword.get(opts, :block_tools, []),
      allow_resources: Keyword.get(opts, :allow_resources, []),
      block_resources: Keyword.get(opts, :block_resources, []),
      allow_prompts: Keyword.get(opts, :allow_prompts, []),
      block_prompts: Keyword.get(opts, :block_prompts, [])
    }
  end

  defp sampling_client_opts(command, opts) do
    case Keyword.get(opts, :sampling_policy) || Keyword.get(opts, :sampling) do
      policy when is_list(policy) ->
        [sampling_policy: normalize_sampling_policy(command, policy)]

      _ ->
        []
    end
  end

  defp normalize_sampling_policy(command, policy) do
    policy
    |> Keyword.update(:mode, :deny, &normalize_sampling_mode/1)
    |> maybe_put_ops_approval_reviewer(command)
    |> Keyword.drop([:approval_context, :approval_timeout_ms])
  end

  defp normalize_sampling_mode("model"), do: :model
  defp normalize_sampling_mode("reviewed_model"), do: :reviewed_model
  defp normalize_sampling_mode("deny"), do: :deny
  defp normalize_sampling_mode(mode), do: mode

  defp maybe_put_ops_approval_reviewer(policy, command) do
    case Keyword.get(policy, :reviewer) do
      reviewer when reviewer in [:ops_approval, "ops_approval", :approval, "approval", true] ->
        Keyword.put(policy, :reviewer, sampling_approval_reviewer(command, policy))

      _ ->
        policy
    end
  end

  defp sampling_approval_reviewer(command, policy) do
    context = Keyword.get(policy, :approval_context, [])
    timeout_ms = Keyword.get(policy, :approval_timeout_ms, 300_000)

    fn summary ->
      case LemonCore.ExecApprovals.request(%{
             run_id: approval_context_value(context, :run_id, "mcp-sampling"),
             session_key: approval_context_value(context, :session_key, "agent:mcp:main"),
             agent_id: approval_context_value(context, :agent_id, nil),
             tool: "mcp_#{server_slug(command)}_sampling",
             action: sampling_approval_action(command, summary),
             rationale: sampling_approval_rationale(command, summary),
             expires_in_ms: timeout_ms
           }) do
        {:ok, :approved, _scope} -> :approve
        {:ok, :denied} -> {:reject, :approval_denied}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp approval_context_value(context, key, default) when is_list(context) do
    Keyword.get(context, key, default)
  end

  defp approval_context_value(context, key, default) when is_map(context) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key)) || default
  end

  defp approval_context_value(_context, _key, default), do: default

  defp sampling_approval_action(command, summary) do
    %{
      type: "mcp_sampling",
      server: server_slug(command),
      request_hash: Map.get(summary, :request_hash),
      message_count: Map.get(summary, :message_count),
      roles: Map.get(summary, :roles, []),
      content_kinds: Map.get(summary, :content_kinds, %{}),
      text_char_count: Map.get(summary, :text_char_count),
      max_tokens: Map.get(summary, :max_tokens),
      requested_model: Map.get(summary, :requested_model)
    }
  end

  defp sampling_approval_rationale(command, summary) do
    [
      "MCP sampling request",
      "server=#{server_slug(command)}",
      "messages=#{Map.get(summary, :message_count, 0)}",
      "roles=#{summary |> Map.get(:roles, []) |> Enum.join(",")}",
      "content=#{summary |> Map.get(:content_kinds, %{}) |> format_content_kinds()}",
      "text_chars=#{Map.get(summary, :text_char_count, 0)}",
      "max_tokens=#{Map.get(summary, :max_tokens) || "unknown"}",
      "model=#{Map.get(summary, :requested_model) || "unspecified"}",
      "request=#{Map.get(summary, :request_hash)}"
    ]
    |> Enum.join("; ")
  end

  defp format_content_kinds(kinds) when is_map(kinds) do
    kinds
    |> Enum.sort_by(fn {kind, _count} -> to_string(kind) end)
    |> Enum.map_join(",", fn {kind, count} -> "#{kind}:#{count}" end)
  end

  defp format_content_kinds(_), do: ""

  defp short_hash(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp tool_allowed?(tool, filters) do
    tool
    |> names_for(["name"])
    |> allowed?(filters.allow_tools, filters.block_tools)
  end

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
      apply(client_mod, :close, [client])
    end

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
