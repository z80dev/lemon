defmodule LemonMCP.Client.HTTP do
  @moduledoc """
  MCP Client GenServer for Streamable HTTP MCP servers.

  This client performs the MCP initialize handshake over HTTP POST and then
  exposes the same public tool/resource/prompt API shape as `LemonMCP.Client`.
  It accepts both JSON and per-request server-sent event responses from current
  Streamable HTTP servers, and returns OAuth protected-resource and
  authorization-server metadata when a server requires authentication during
  startup.

  `:origin_policy` restricts every HTTP destination, including OAuth discovery
  and token exchanges. `:destination_pin` is a trusted, process-local option
  computed by the host before resolving credentials, never a server config field.
  Policy clients connect directly to the pinned address while retaining the
  original Host and TLS identity. All requests reject redirects.
  """

  use GenServer

  alias LemonMCP.Protocol
  alias LemonMCP.HTTP.OriginPolicy

  require Logger

  @type client_state :: :disconnected | :initializing | :ready

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts = Keyword.take(opts, [:name, :timeout])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec state(GenServer.server()) :: client_state()
  def state(server), do: GenServer.call(server, :get_state)

  @spec list_tools(GenServer.server(), timeout()) ::
          {:ok, [Protocol.tool()]} | {:error, term()}
  def list_tools(server, timeout \\ 30_000), do: GenServer.call(server, :list_tools, timeout)

  @spec call_tool(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, [Protocol.content_item()]} | {:error, term()}
  def call_tool(server, tool_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(server, {:call_tool, tool_name, arguments}, timeout)
  end

  @spec list_resources(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_resources(server, timeout \\ 30_000),
    do: GenServer.call(server, :list_resources, timeout)

  @spec read_resource(GenServer.server(), String.t(), timeout()) ::
          {:ok, [map()]} | {:error, term()}
  def read_resource(server, uri, timeout \\ 30_000) do
    GenServer.call(server, {:read_resource, uri}, timeout)
  end

  @spec list_prompts(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, term()}
  def list_prompts(server, timeout \\ 30_000), do: GenServer.call(server, :list_prompts, timeout)

  @spec get_prompt(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def get_prompt(server, prompt_name, arguments \\ %{}, timeout \\ 30_000) do
    GenServer.call(server, {:get_prompt, prompt_name, arguments}, timeout)
  end

  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.call(server, :close)

  @spec server_info(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_info(server), do: GenServer.call(server, :server_info)

  @spec server_capabilities(GenServer.server()) :: {:ok, map()} | {:error, :not_connected}
  def server_capabilities(server), do: GenServer.call(server, :server_capabilities)

  @impl true
  def init(opts) do
    config = %{
      url: Keyword.fetch!(opts, :url),
      origin_policy: Keyword.get(opts, :origin_policy),
      destination_pin: nil,
      http_profile: :default,
      headers: Keyword.get(opts, :headers, []),
      oauth: Keyword.get(opts, :oauth, []),
      oauth_token_cache:
        Keyword.get(opts, :oauth_token_cache) || oauth_token_cache_from_opts(opts),
      client_name: Keyword.get(opts, :client_name, "lemon-mcp"),
      client_version: Keyword.get(opts, :client_version, "0.1.0"),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    }

    with {:ok, pin} <-
           destination_pin(config.url, config.origin_policy, Keyword.get(opts, :destination_pin)),
         :ok <- ensure_http_apps(),
         {:ok, profile} <- start_http_profile(config.origin_policy) do
      state =
        %{
          state: :initializing,
          config: %{config | destination_pin: pin, http_profile: profile},
          server_info: nil,
          server_capabilities: nil,
          protocol_version: nil,
          session_id: nil,
          oauth_access_token: nil,
          oauth_refresh_token: nil,
          oauth_metadata: nil
        }
        |> load_oauth_token_cache()

      with {:ok, state} <- initialize(state),
           {:ok, state} <- send_initialized_notification(state) do
        {:ok, %{state | state: :ready}}
      else
        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call(:list_tools, _from, %{state: :ready} = state) do
    {reply, state} =
      request_response(state, Protocol.tool_list_request(), fn
        %Protocol.ToolListResponse{result: result, error: nil} -> {:ok, result.tools}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, normalize_reply(reply), state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, _from, %{state: :ready} = state) do
    request = Protocol.tool_call_request(name: tool_name, arguments: arguments)

    {reply, state} =
      request_response(state, request, fn
        %Protocol.ToolCallResponse{result: result, error: nil} ->
          if result.isError do
            {:error, {:tool_error, result.content}}
          else
            {:ok, result.content}
          end

        other ->
          normalize_reply({:ok, other})
      end)

    {:reply, normalize_reply(reply), state}
  end

  @impl true
  def handle_call({:call_tool, _tool_name, _arguments}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:list_resources, _from, %{state: :ready} = state) do
    {reply, state} =
      request_response(state, Protocol.resource_list_request(), fn
        %Protocol.ResourceListResponse{result: result, error: nil} -> {:ok, result.resources}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, normalize_reply(reply), state}
  end

  @impl true
  def handle_call(:list_resources, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:read_resource, uri}, _from, %{state: :ready} = state) do
    {reply, state} =
      request_response(state, Protocol.resource_read_request(uri: uri), fn
        %Protocol.ResourceReadResponse{result: result, error: nil} -> {:ok, result.contents}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, normalize_reply(reply), state}
  end

  @impl true
  def handle_call({:read_resource, _uri}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:list_prompts, _from, %{state: :ready} = state) do
    {reply, state} =
      request_response(state, Protocol.prompt_list_request(), fn
        %Protocol.PromptListResponse{result: result, error: nil} -> {:ok, result.prompts}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, normalize_reply(reply), state}
  end

  @impl true
  def handle_call(:list_prompts, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call({:get_prompt, prompt_name, arguments}, _from, %{state: :ready} = state) do
    request = Protocol.prompt_get_request(name: prompt_name, arguments: arguments)

    {reply, state} =
      request_response(state, request, fn
        %Protocol.PromptGetResponse{result: result, error: nil} -> {:ok, result}
        other -> normalize_reply({:ok, other})
      end)

    {:reply, normalize_reply(reply), state}
  end

  @impl true
  def handle_call({:get_prompt, _prompt_name, _arguments}, _from, state) do
    {:reply, {:error, {:not_ready, state.state}}, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    {:reply, :ok, %{state | state: :disconnected}}
  end

  @impl true
  def handle_call(:server_info, _from, %{state: :ready, server_info: info} = state) do
    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_call(:server_info, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call(
        :server_capabilities,
        _from,
        %{state: :ready, server_capabilities: caps} = state
      ) do
    {:reply, {:ok, caps || %{}}, state}
  end

  @impl true
  def handle_call(:server_capabilities, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end


  defp initialize(state) do
    request =
      Protocol.initialize_request(
        client_name: state.config.client_name,
        client_version: state.config.client_version,
        capabilities: state.config.capabilities
      )

    case request_response(state, request, fn
           %Protocol.InitializeResponse{result: result, error: nil} -> {:ok, result}
           other -> normalize_reply({:ok, other})
         end) do
      {{:ok, result}, state} ->
        {:ok,
         %{
           state
           | server_info: result.serverInfo,
             server_capabilities: result.capabilities,
             protocol_version: result.protocolVersion
         }}

      {{:error, reason}, _state} ->
        {:error, reason}
    end
  end

  defp send_initialized_notification(state) do
    notification = Protocol.initialized_notification()

    case post_raw(notification, state) do
      {:ok, _response, state} -> {:ok, state}
      {:error, reason, _state} -> {:error, reason}
    end
  end

  defp request_response(state, request, mapper) do
    with {:ok, body, state} <- post_raw(request, state),
         {:ok, id} <- message_id(request),
         {:ok, response} <- decode_response_body(body, id) do
      {mapper.(response), state}
    else
      {:error, reason, state} -> {{:error, reason}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp post_raw(message, state) do
    post_raw(message, state, true)
  end

  defp post_raw(message, state, allow_oauth_retry?) do
    with {:ok, body} <- Protocol.encode(message) do
      headers = request_headers(state)
      case http_request(
             :post,
             state.config.url,
             headers,
             {~c"application/json", to_charlist(body)},
             state,
             state.config.destination_pin
           ) do
        {:ok, {{_version, status, _reason}, headers, response_body}} when status in 200..299 ->
          state = capture_session_id(state, headers)
          normalized_body = String.trim(to_string(response_body))
          content_type = response_header(headers, "content-type") || "application/json"

          cond do
            normalized_body in ["", "null"] ->
              {:ok, nil, state}

            String.contains?(content_type, "text/event-stream") ->
              decode_sse_response(normalized_body, state)

            true ->
              {:ok, normalized_body, state}
          end

        {:ok, {{_version, 401, reason}, headers, response_body}} ->
          with {:ok, discovered_metadata} <- auth_metadata(headers, state) do
            metadata =
              discovered_metadata ||
                state.oauth_metadata ||
                %{
                  "status" => 401,
                  "reason" => to_string(reason),
                  "body" => to_string(response_body)
                }

            case allow_oauth_retry? and maybe_authorize(metadata, state) do
              {:ok, state} -> post_raw(message, state, false)
              {:error, reason} -> {:error, reason, state}
              :error -> {:error, auth_required_reason(state, metadata), state}
              false -> {:error, auth_required_reason(state, metadata), state}
            end
          else
            {:error, reason} -> {:error, reason, state}
          end

        {:ok, {{_version, status, reason}, _headers, response_body}} ->
          error =
            if is_nil(state.config.origin_policy),
              do: {:http_error, status, to_string(reason), to_string(response_body)},
              else: :http_error
          {:error, error, state}

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp auth_required_reason(%{config: %{origin_policy: nil}}, metadata),
    do: {:auth_required, metadata}
  defp auth_required_reason(_state, _metadata), do: :auth_required

  defp decode_response_body(nil, _id), do: {:error, :missing_response_body}

  defp decode_response_body(body, id) do
    with {:ok, decoded} <- Protocol.decode(body),
         true <- response_id(decoded) == id do
      case decoded do
        %{error: error} when not is_nil(error) -> {:error, {:rpc_error, error}}
        _ -> {:ok, decoded}
      end
    else
      false -> {:error, :response_id_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_sse_response(body, state) do
    events =
      body
      |> parse_sse_events()
      |> Enum.filter(&(&1.event == "message"))

    case List.last(events) do
      %{data: data} -> {:ok, data, state}
      nil -> {:error, :missing_sse_response, state}
    end
  end

  defp parse_sse_events(body) do
    {events, event} =
      body
      |> String.split("\n")
      |> Enum.reduce({[], new_event()}, fn line, {events, event} ->
        parse_sse_line(String.trim_trailing(line, "\r"), events, event)
      end)

    events =
      if event.data == [] do
        events
      else
        [
          %{event: event.event || "message", data: Enum.reverse(event.data) |> Enum.join("\n")}
          | events
        ]
      end

    Enum.reverse(events)
  end

  defp parse_sse_line("", events, %{data: data} = event) when data != [] do
    {[%{event: event.event || "message", data: Enum.reverse(data) |> Enum.join("\n")} | events],
     new_event()}
  end

  defp parse_sse_line("", events, _event), do: {events, new_event()}
  defp parse_sse_line(":" <> _comment, events, event), do: {events, event}

  defp parse_sse_line("event:" <> value, events, event) do
    {events, %{event | event: trim_sse_value(value)}}
  end

  defp parse_sse_line("data:" <> value, events, event) do
    {events, %{event | data: [trim_sse_value(value) | event.data]}}
  end

  defp parse_sse_line(_line, events, event), do: {events, event}

  defp new_event, do: %{event: "message", data: []}
  defp trim_sse_value(" " <> value), do: value
  defp trim_sse_value(value), do: value

  defp normalize_reply({:error, {:rpc_error, _error}} = error), do: error

  defp normalize_reply({:error, reason}), do: {:error, reason}

  defp normalize_reply({:ok, %{error: error}}) when not is_nil(error),
    do: {:error, {:rpc_error, error}}

  defp normalize_reply({:ok, value}), do: {:ok, value}

  defp response_id(%{id: id}), do: id
  defp response_id(_), do: nil

  defp message_id(%{id: id}) when not is_nil(id), do: {:ok, id}
  defp message_id(_), do: {:error, :missing_request_id}

  defp ensure_http_apps do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp destination_pin(_url, nil, _pin), do: {:ok, nil}
  defp destination_pin(url, policy, nil), do: OriginPolicy.pin(url, policy)

  defp destination_pin(url, _policy, %{
         url: url,
         origin: origin,
         scheme: scheme,
         host: host,
         port: port,
         address: address
       } = pin) when scheme in ["http", "https"] do
    with {:ok, ^origin} <- OriginPolicy.canonical_origin(url),
         %URI{scheme: ^scheme, host: ^host, port: ^port} <- URI.parse(origin),
         rendered when is_list(rendered) <- :inet.ntoa(address) do
      {:ok, pin}
    else
      _ -> {:error, :invalid_destination_pin}
    end
  rescue
    _ -> {:error, :invalid_destination_pin}
  end

  defp destination_pin(_url, _policy, _pin), do: {:error, :invalid_destination_pin}

  defp start_http_profile(nil), do: {:ok, :default}

  defp start_http_profile(_policy) do
    # This profile never inherits operator proxies/cookies. It uses no pooled
    # connections: IP-keyed reuse could cross original TLS/Host identities.
    case :inets.start(:httpc, profile: :lemon_mcp_pinned) do
      {:ok, _pid} -> configure_pinned_profile()
      {:error, {:already_started, _pid}} -> configure_pinned_profile()
      {:error, _reason} -> {:error, :http_transport_unavailable}
    end
  end

  defp configure_pinned_profile do
    :ok = :httpc.set_options(
      [cookies: :disabled, max_keep_alive_length: 0, keep_alive_timeout: 0, ipfamily: :inet6fb4],
      :lemon_mcp_pinned
    )
    {:ok, :lemon_mcp_pinned}
  end

  defp http_request(method, url, headers, body, state, pin \\ :resolve) do
    policy = state.config.origin_policy

    with {:ok, pin} <-
           if(pin == :resolve, do: OriginPolicy.pin(url, policy), else: {:ok, pin}) do
      {url, headers, tls_opts} = pinned_request(url, headers, pin)
      timeout = state.config.timeout_ms
      http_opts = [timeout: timeout, connect_timeout: timeout, autoredirect: false] ++ tls_opts

      request =
        case body do
          nil -> {to_charlist(url), headers}
          {content_type, data} -> {to_charlist(url), headers, content_type, data}
        end

      case :httpc.request(method, request, http_opts, [body_format: :binary],
             state.config.http_profile
           ) do
        {:ok, {{_version, status, _reason}, _headers, _body}} when status in 300..399 ->
          {:error, :redirect_forbidden}

        {:error, reason} ->
          if is_nil(policy),
            do: {:error, {:http_request_failed, reason}},
            else: {:error, :http_request_failed}

        response ->
          response
      end
    end
  end

  defp pinned_request(url, headers, nil), do: {url, headers, []}

  defp pinned_request(url, headers, pin) do
    original = URI.parse(pin.origin)
    address = pin.address |> :inet.ntoa() |> to_string()
    uri = URI.parse(url)
    url = URI.to_string(%{uri | scheme: pin.scheme, host: address, port: pin.port, authority: nil})
    host = if String.contains?(original.host, ":"), do: "[#{original.host}]", else: original.host
    default_port = if pin.scheme == "https", do: 443, else: 80
    host = if pin.port == default_port, do: host, else: "#{host}:#{pin.port}"

    headers =
      [{~c"host", to_charlist(host)}, {~c"connection", ~c"close"} |
       Enum.reject(headers, fn {key, _value} ->
         String.downcase(to_string(key)) in ["host", "connection"]
       end)]

    tls_opts =
      if pin.scheme == "https" do
        reference =
          case :inet.parse_address(to_charlist(original.host)) do
            {:ok, ip} -> {:ip, ip}
            {:error, _} -> {:dns_id, to_charlist(original.host)}
          end

        sni = if elem(reference, 0) == :dns_id, do: elem(reference, 1), else: :disable

        [ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: sni,
          customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
          verify_fun: {&verify_original_peer/3, reference}
        ]]
      else
        []
      end

    {url, headers, tls_opts}
  end

  defp verify_original_peer(_cert, {:bad_cert, reason}, _reference), do: {:fail, reason}
  defp verify_original_peer(_cert, {:extension, _extension}, reference), do: {:unknown, reference}
  defp verify_original_peer(_cert, :valid, reference), do: {:valid, reference}

  defp verify_original_peer(cert, :valid_peer, reference) do
    if :public_key.pkix_verify_hostname(cert, [reference],
         match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
       ),
      do: {:valid, reference},
      else: {:fail, :hostname_check_failed}
  end

  defp auth_metadata(headers, state) do
    with header when is_binary(header) <- response_header(headers, "www-authenticate"),
         metadata_url when is_binary(metadata_url) <- challenge_param(header, "resource_metadata"),
         {:ok, metadata} <- fetch_resource_metadata(metadata_url, state) do
      {:ok,
       metadata
       |> Map.put("www_authenticate", header)
       |> Map.put("resource_metadata_url", metadata_url)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:ok, nil}
    end
  end

  defp fetch_resource_metadata(url, state) do
    case fetch_metadata_json(url, state) do
      {:ok, metadata} -> put_authorization_server_metadata(metadata, state)
      {:error, metadata} when is_map(metadata) -> {:ok, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_authorization_server_metadata(%{"authorization_servers" => servers} = metadata, state)
       when is_list(servers) do
    servers
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce_while({:ok, []}, fn issuer, {:ok, acc} ->
      case fetch_authorization_server_metadata(issuer, state) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} ->
        {:ok, Map.put(metadata, "authorization_server_metadata", Enum.reverse(results))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_authorization_server_metadata(metadata, _state), do: {:ok, metadata}

  defp fetch_authorization_server_metadata(issuer, state) do
    with metadata_url when is_binary(metadata_url) <- authorization_server_metadata_url(issuer),
         {:ok, metadata} <- fetch_metadata_json(metadata_url, state) do
      {:ok,
       metadata
       |> Map.put_new("issuer", issuer)
       |> Map.put("metadata_url", metadata_url)}
    else
      {:error, metadata} when is_map(metadata) -> {:ok, Map.put(metadata, "issuer", issuer)}
      {:error, reason} -> {:error, reason}
      _ -> {:ok, %{"issuer" => issuer, "metadata_error" => "invalid_issuer"}}
    end
  end

  defp authorization_server_metadata_url(issuer) do
    uri = URI.parse(issuer)

    with scheme when scheme in ["http", "https"] <- uri.scheme,
         host when is_binary(host) <- uri.host do
      path =
        case uri.path do
          nil -> ""
          "" -> ""
          "/" -> ""
          path -> String.trim_trailing(path, "/")
        end

      %{uri | path: "/.well-known/oauth-authorization-server" <> path, query: nil, fragment: nil}
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp fetch_metadata_json(url, state) do
    headers = http_headers([{"accept", "application/json"}])

    case http_request(:get, url, headers, nil, state) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        case Jason.decode(to_string(body)) do
          {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
          _ ->
            if is_nil(state.config.origin_policy),
              do: {:error, %{"metadata_error" => "invalid_json"}},
              else: {:error, :invalid_metadata}
        end

      {:ok, {{_version, status, reason}, _headers, _body}} ->
        if is_nil(state.config.origin_policy),
          do: {:error,
            %{"metadata_error" => "http_#{status}", "metadata_error_reason" => to_string(reason)}},
          else: {:error, :metadata_http_error}

      {:error, reason} ->
        if is_nil(state.config.origin_policy) and reason != :redirect_forbidden,
          do: {:error, %{"metadata_error" => inspect(reason)}},
          else: {:error, reason}
    end
  end

  defp challenge_param(header, name) do
    Regex.run(~r/(?:^|[, ])#{Regex.escape(name)}="([^"]+)"/, header, capture: :all_but_first)
    |> case do
      [value] -> value
      _ -> nil
    end
  end

  defp maybe_authorize(metadata, state) do
    with {:ok, oauth} <- oauth_options(state.config.oauth),
         token_endpoint when is_binary(token_endpoint) <- token_endpoint(metadata) do
      case maybe_fetch_refresh_token(token_endpoint, metadata, oauth, state) do
        {:ok, token} ->
          {:ok, put_oauth_token(state, metadata, token)}

        {:error, reason} ->
          {:error, reason}

        :error ->
          fetch_new_token(token_endpoint, metadata, oauth, state)
      end
    else
      _ -> :error
    end
  end

  defp fetch_new_token(token_endpoint, metadata, oauth, state) do
    cond do
      authorization_code_provider?(oauth) ->
        case fetch_authorization_code_token(token_endpoint, metadata, oauth, state) do
          {:ok, token} -> {:ok, put_oauth_token(state, metadata, token)}
          {:error, reason} -> {:error, reason}
          :error -> :error
        end

      client_credentials_oauth?(oauth) ->
        case fetch_client_credentials_token(token_endpoint, metadata, oauth, state) do
          {:ok, token} -> {:ok, put_oauth_token(state, metadata, token)}
          {:error, reason} -> {:error, reason}
          :error -> :error
        end

      true ->
        :error
    end
  end

  defp oauth_options(oauth) when is_map(oauth) do
    oauth
    |> Enum.map(fn {key, value} -> {normalize_oauth_key(key), value} end)
    |> oauth_options()
  end

  defp oauth_options(oauth) when is_list(oauth) do
    client_id = Keyword.get(oauth, :client_id)

    if is_binary(client_id) and client_id != "" do
      {:ok, oauth}
    else
      :error
    end
  end

  defp oauth_options(_oauth), do: :error

  defp oauth_token_cache_from_opts(opts) do
    loader = Keyword.get(opts, :oauth_token_loader)
    persister = Keyword.get(opts, :oauth_token_persister)

    case {loader, persister} do
      {load, save} when is_function(load, 0) and is_function(save, 1) ->
        [load: load, save: save]

      {load, nil} when is_function(load, 0) ->
        [load: load]

      {nil, save} when is_function(save, 1) ->
        [save: save]

      _ ->
        nil
    end
  end

  defp client_credentials_oauth?(oauth) do
    bearer_token?(Keyword.get(oauth, :client_id)) and
      bearer_token?(Keyword.get(oauth, :client_secret))
  end

  defp authorization_code_provider?(oauth) do
    provider = authorization_code_provider(oauth)
    is_function(provider, 1) or is_function(provider, 0)
  end

  defp authorization_code_provider(oauth) do
    Keyword.get(oauth, :authorization_code_provider) || Keyword.get(oauth, :auth_code_provider)
  end

  defp normalize_oauth_key(key) when is_atom(key), do: key

  defp normalize_oauth_key("client_id"), do: :client_id
  defp normalize_oauth_key("client-secret"), do: :client_secret
  defp normalize_oauth_key("client_secret"), do: :client_secret
  defp normalize_oauth_key("redirect_uri"), do: :redirect_uri
  defp normalize_oauth_key("redirect-uri"), do: :redirect_uri
  defp normalize_oauth_key("scope"), do: :scope
  defp normalize_oauth_key("scopes"), do: :scopes
  defp normalize_oauth_key("refresh_token"), do: :refresh_token
  defp normalize_oauth_key("refresh-token"), do: :refresh_token
  defp normalize_oauth_key("token_auth_method"), do: :token_auth_method
  defp normalize_oauth_key("token-auth-method"), do: :token_auth_method
  defp normalize_oauth_key("authorization_code_provider"), do: :authorization_code_provider
  defp normalize_oauth_key("authorization-code-provider"), do: :authorization_code_provider
  defp normalize_oauth_key("auth_code_provider"), do: :auth_code_provider
  defp normalize_oauth_key("auth-code-provider"), do: :auth_code_provider
  defp normalize_oauth_key(key), do: key

  defp token_endpoint(%{"authorization_server_metadata" => metadata}) when is_list(metadata) do
    Enum.find_value(metadata, fn
      %{"token_endpoint" => endpoint} when is_binary(endpoint) -> endpoint
      _ -> nil
    end)
  end

  defp token_endpoint(%{"token_endpoint" => endpoint}) when is_binary(endpoint), do: endpoint
  defp token_endpoint(_metadata), do: nil

  defp authorization_endpoint(%{"authorization_server_metadata" => metadata})
       when is_list(metadata) do
    Enum.find_value(metadata, fn
      %{"authorization_endpoint" => endpoint} when is_binary(endpoint) -> endpoint
      _ -> nil
    end)
  end

  defp authorization_endpoint(%{"authorization_endpoint" => endpoint}) when is_binary(endpoint),
    do: endpoint

  defp authorization_endpoint(_metadata), do: nil

  defp fetch_client_credentials_token(token_endpoint, metadata, oauth, state) do
    params = %{
      "grant_type" => "client_credentials",
      "client_id" => Keyword.fetch!(oauth, :client_id)
    }

    case put_client_auth(params, oauth) do
      {:ok, params, auth_headers} ->
        body =
          params
          |> maybe_put_scope(oauth)
          |> maybe_put_resource(metadata)
          |> URI.encode_query()

        headers =
          http_headers(
            [
              {"accept", "application/json"},
              {"content-type", "application/x-www-form-urlencoded"}
            ] ++ auth_headers
          )

        case oauth_token_request(token_endpoint, headers, body, state) do
          {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
            decode_oauth_token(response_body)

          {:error, reason} ->
            {:error, reason}

          _ ->
            :error
        end
      :error -> :error
    end
  end

  defp fetch_authorization_code_token(token_endpoint, metadata, oauth, state) do
    with {:ok, authorization_request} <- build_authorization_request(metadata, oauth),
         {:ok, code} <- request_authorization_code(oauth, authorization_request) do
      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "client_id" => Keyword.fetch!(oauth, :client_id),
        "code_verifier" => authorization_request.code_verifier
      }

      params =
        case Keyword.get(oauth, :redirect_uri) do
          uri when is_binary(uri) and uri != "" -> Map.put(params, "redirect_uri", uri)
          _ -> params
        end

      case put_client_auth(params, oauth) do
        {:ok, params, auth_headers} ->
          body =
            params
            |> maybe_put_scope(oauth)
            |> maybe_put_resource(metadata)
            |> URI.encode_query()

          headers =
            http_headers(
              [
                {"accept", "application/json"},
                {"content-type", "application/x-www-form-urlencoded"}
              ] ++ auth_headers
            )

          case oauth_token_request(token_endpoint, headers, body, state) do
            {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
              decode_oauth_token(response_body)

            {:error, reason} ->
              {:error, reason}

            _ ->
              :error
          end
        :error -> :error
      end
    else
      :error -> :error
    end
  end

  defp build_authorization_request(metadata, oauth) do
    with endpoint when is_binary(endpoint) <- authorization_endpoint(metadata),
         {:ok, verifier, challenge} <- pkce_pair() do
      state = authorization_state()

      params = %{
        "response_type" => "code",
        "client_id" => Keyword.fetch!(oauth, :client_id),
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      }

      params =
        case Keyword.get(oauth, :redirect_uri) do
          uri when is_binary(uri) and uri != "" -> Map.put(params, "redirect_uri", uri)
          _ -> params
        end

      params =
        params
        |> maybe_put_scope(oauth)
        |> maybe_put_resource(metadata)

      {:ok,
       %{
         authorization_url: endpoint <> "?" <> URI.encode_query(params),
         authorization_endpoint: endpoint,
         client_id: Keyword.fetch!(oauth, :client_id),
         code_challenge: challenge,
         code_challenge_method: "S256",
         code_verifier: verifier,
         redirect_uri: Keyword.get(oauth, :redirect_uri),
         resource: Map.get(metadata, "resource"),
         scope: Map.get(params, "scope"),
         state: state
       }}
    else
      _ -> :error
    end
  end

  defp request_authorization_code(oauth, authorization_request) do
    provider = authorization_code_provider(oauth)

    result =
      cond do
        is_function(provider, 1) -> provider.(authorization_request)
        is_function(provider, 0) -> provider.()
        true -> :error
      end

    normalize_authorization_code_result(result, authorization_request.state)
  end

  defp normalize_authorization_code_result({:ok, code}, _state)
       when is_binary(code) and code != "",
       do: {:ok, code}

  defp normalize_authorization_code_result({:ok, %{code: code, state: state}}, expected_state)
       when is_binary(code) and code != "" and state == expected_state,
       do: {:ok, code}

  defp normalize_authorization_code_result(
         {:ok, %{"code" => code, "state" => state}},
         expected_state
       )
       when is_binary(code) and code != "" and state == expected_state,
       do: {:ok, code}

  defp normalize_authorization_code_result(code, _state) when is_binary(code) and code != "",
    do: {:ok, code}

  defp normalize_authorization_code_result(_result, _state), do: :error

  defp pkce_pair do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {:ok, verifier, challenge}
  end

  defp authorization_state do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp maybe_fetch_refresh_token(token_endpoint, metadata, oauth, state) do
    refresh_token =
      cond do
        bearer_token?(state.oauth_refresh_token) -> state.oauth_refresh_token
        bearer_token?(Keyword.get(oauth, :refresh_token)) -> Keyword.get(oauth, :refresh_token)
        true -> nil
      end

    if bearer_token?(refresh_token) do
      fetch_refresh_token(token_endpoint, metadata, oauth, refresh_token, state)
    else
      :error
    end
  end

  defp fetch_refresh_token(token_endpoint, metadata, oauth, refresh_token, state) do
    params = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => Keyword.fetch!(oauth, :client_id)
    }

    case put_client_auth(params, oauth) do
      {:ok, params, auth_headers} ->
        body =
          params
          |> maybe_put_scope(oauth)
          |> maybe_put_resource(metadata)
          |> URI.encode_query()

        headers =
          http_headers(
            [
              {"accept", "application/json"},
              {"content-type", "application/x-www-form-urlencoded"}
            ] ++ auth_headers
          )

        case oauth_token_request(token_endpoint, headers, body, state) do
          {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
            decode_oauth_token(response_body)

          {:error, reason} ->
            {:error, reason}

          _ ->
            :error
        end
      :error -> :error
    end
  end

  defp oauth_token_request(url, headers, body, state) do
    case http_request(:post, url, headers,
           {~c"application/x-www-form-urlencoded", to_charlist(body)}, state
         ) do
      {:error, reason} when not is_nil(state.config.origin_policy) ->
        {:error, reason}
      {:error, :redirect_forbidden} -> {:error, :redirect_forbidden}
      {:error, _reason} -> :error
      response -> response
    end
  end

  defp put_oauth_token(state, metadata, token) do
    refresh_token =
      case Map.get(token, :refresh_token) do
        value when is_binary(value) and value != "" -> value
        _ -> state.oauth_refresh_token
      end

    state = %{
      state
      | oauth_access_token: token.access_token,
        oauth_refresh_token: refresh_token,
        oauth_metadata: metadata
    }

    # The fresh token is used for this connection either way; a failed save is
    # reported so a rotated refresh token is not lost silently. Only the
    # error's tag is logged: tokens and the server URL stay out of logs.
    case persist_oauth_token_cache(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "MCP OAuth token was refreshed but could not be saved to its token cache " <>
            "(#{inspect(reason)}); the next connection may need to authorize again"
        )
    end

    state
  end

  defp load_oauth_token_cache(state) do
    case cache_load(state.config.oauth_token_cache) do
      {:ok, token} -> apply_cached_oauth_token(state, token)
      _ -> state
    end
  end

  defp cache_load(nil), do: :error

  defp cache_load(load) when is_function(load, 0),
    do: normalize_cached_oauth_token(safe_call(load))

  defp cache_load(cache) when is_list(cache) do
    case Keyword.get(cache, :load) do
      load when is_function(load, 0) -> cache_load(load)
      _ -> :error
    end
  end

  defp cache_load(_cache), do: :error

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp normalize_cached_oauth_token({:ok, token}), do: normalize_cached_oauth_token(token)

  defp normalize_cached_oauth_token(token) when is_map(token) do
    access_token = Map.get(token, :access_token) || Map.get(token, "access_token")
    refresh_token = Map.get(token, :refresh_token) || Map.get(token, "refresh_token")
    metadata = Map.get(token, :metadata) || Map.get(token, "metadata")

    if bearer_token?(access_token) or bearer_token?(refresh_token) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         metadata: if(is_map(metadata), do: metadata, else: nil)
       }}
    else
      :error
    end
  end

  defp normalize_cached_oauth_token(_token), do: :error

  defp apply_cached_oauth_token(state, token) do
    %{
      state
      | oauth_access_token: token.access_token,
        oauth_refresh_token: token.refresh_token,
        oauth_metadata: token.metadata
    }
  end

  defp persist_oauth_token_cache(%{config: %{oauth_token_cache: nil}}), do: :ok

  defp persist_oauth_token_cache(state) do
    payload = %{
      access_token: state.oauth_access_token,
      refresh_token: state.oauth_refresh_token,
      metadata: state.oauth_metadata
    }

    case cache_save(state.config.oauth_token_cache, payload) do
      :ok -> :ok
      {:ok, _} -> :ok
      :no_save -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failed -> {:error, :token_cache_save_failed}
    end
  end

  defp cache_save(save, payload) when is_function(save, 1),
    do: safe_call(fn -> save.(payload) end)

  defp cache_save(cache, payload) when is_list(cache) do
    case Keyword.get(cache, :save) do
      save when is_function(save, 1) -> cache_save(save, payload)
      _ -> :no_save
    end
  end

  defp cache_save(_cache, _payload), do: :no_save

  defp put_client_auth(params, oauth) do
    case token_auth_method(oauth) do
      :client_secret_post ->
        case Keyword.get(oauth, :client_secret) do
          secret when is_binary(secret) and secret != "" ->
            {:ok, Map.put(params, "client_secret", secret), []}

          _ ->
            {:ok, params, []}
        end

      :client_secret_basic ->
        case Keyword.get(oauth, :client_secret) do
          secret when is_binary(secret) and secret != "" ->
            credentials = Base.encode64("#{Keyword.fetch!(oauth, :client_id)}:#{secret}")
            {:ok, Map.delete(params, "client_id"), [{"authorization", "Basic " <> credentials}]}

          _ ->
            :error
        end

      :error ->
        :error
    end
  end

  defp token_auth_method(oauth) do
    case Keyword.get(oauth, :token_auth_method, :client_secret_post) do
      method when method in [:client_secret_post, "client_secret_post", "post"] ->
        :client_secret_post

      method when method in [:client_secret_basic, :basic, "client_secret_basic", "basic"] ->
        :client_secret_basic

      _ ->
        :error
    end
  end

  defp maybe_put_scope(params, oauth) do
    scope =
      cond do
        is_binary(Keyword.get(oauth, :scope)) -> Keyword.get(oauth, :scope)
        is_list(Keyword.get(oauth, :scopes)) -> Enum.join(Keyword.get(oauth, :scopes), " ")
        true -> nil
      end

    if is_binary(scope) and scope != "", do: Map.put(params, "scope", scope), else: params
  end

  defp maybe_put_resource(params, %{"resource" => resource}) when is_binary(resource) do
    Map.put(params, "resource", resource)
  end

  defp maybe_put_resource(params, _metadata), do: params

  defp decode_oauth_token(response_body) do
    with {:ok, %{"access_token" => token} = response} <- Jason.decode(to_string(response_body)),
         true <- is_binary(token) and token != "",
         token_type <- Map.get(response, "token_type", "Bearer"),
         true <- String.downcase(to_string(token_type)) == "bearer" do
      {:ok,
       %{
         access_token: token,
         refresh_token: Map.get(response, "refresh_token")
       }}
    else
      _ -> :error
    end
  end

  defp request_headers(state) do
    base = [
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"}
    ]

    base =
      if state.protocol_version do
        [{"mcp-protocol-version", state.protocol_version} | base]
      else
        base
      end

    base =
      if state.session_id do
        [{"mcp-session-id", state.session_id} | base]
      else
        base
      end

    configured_headers = state.config.headers

    base =
      if bearer_token?(state.oauth_access_token) and
           not has_header?(configured_headers, "authorization") do
        [{"authorization", "Bearer " <> state.oauth_access_token} | base]
      else
        base
      end

    http_headers(base ++ configured_headers)
  end

  defp bearer_token?(token), do: is_binary(token) and token != ""

  defp has_header?(headers, name) do
    needle = String.downcase(name)

    Enum.any?(headers, fn
      {key, _value} -> key |> to_string() |> String.downcase() == needle
      _ -> false
    end)
  end

  defp capture_session_id(state, headers) do
    case response_header(headers, "mcp-session-id") do
      nil -> state
      "" -> state
      session_id -> %{state | session_id: session_id}
    end
  end

  defp response_header(headers, name) do
    needle = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} ->
        if key |> to_string() |> String.downcase() == needle do
          to_string(value)
        end

      _ ->
        nil
    end)
  end

  defp http_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end
end
