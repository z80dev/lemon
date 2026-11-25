defmodule LemonMCP.HTTP.OAuth do
  @moduledoc false

  # OAuth for `LemonMCP.Client.HTTP`: protected-resource and authorization-
  # server discovery, token grants and the token cache boundary.
  #
  # Functions take the client's `ctx`: a map with `:config` (the client config:
  # `:url`, `:origin_policy`, `:peer_owner`, `:timeout_ms`, `:oauth`,
  # `:oauth_token_cache`) and the grant fields `:oauth_access_token`,
  # `:oauth_refresh_token`, `:oauth_metadata` and `:oauth_issuer`. Grants are
  # returned as an updated `ctx`; `tokens/1` extracts the grant fields so a
  # worker can hand a grant back to the client process.
  #
  # Discovery is bound to the configured URL: the protected resource must be
  # that URL, the authorization-server `issuer` must equal the requested
  # issuer, and token/authorization endpoints must be HTTPS (or literal
  # loopback) on the issuer's origin unless an origin policy allowlists them.
  # OAuth connections are always DNS-pinned; without a policy only public
  # addresses, the server's own origin and (for a loopback server) loopback are
  # allowed.

  alias LemonMCP.HTTP.OriginPolicy
  alias LemonMCP.HTTP.Transport

  require Logger

  # Keys Lemon adds to discovered metadata; never accepted from a server.
  @internal_metadata_keys [
    "authorization_server_metadata",
    "metadata_url",
    "resource_metadata_url",
    "www_authenticate"
  ]

  @token_fields [:oauth_access_token, :oauth_refresh_token, :oauth_metadata, :oauth_issuer]

  @doc "Empty grant fields for a new client context."
  def empty_tokens, do: Map.new(@token_fields, &{&1, nil})

  @doc "The grant fields of `ctx`."
  def tokens(ctx), do: Map.take(ctx, @token_fields)

  @doc "Validates the operator OAuth options before any networking."
  def validate_config(oauth), do: validate_oauth_config(oauth)

  @doc "Builds the token-cache spec from `:oauth_token_loader`/`:oauth_token_persister`."
  def token_cache(opts), do: oauth_token_cache_from_opts(opts)

  @doc "Applies a cached grant, if the cache holds one usable by this client."
  def load_tokens(ctx), do: load_oauth_token_cache(ctx)

  @doc "True when OAuth client options are configured."
  def configured?(ctx), do: match?({:ok, _}, oauth_options(ctx.config.oauth))

  @doc "True when a new grant uses the interactive authorization-code provider."
  def interactive?(ctx) do
    case oauth_options(ctx.config.oauth) do
      {:ok, oauth} -> authorization_code_provider?(oauth)
      :error -> false
    end
  end

  @doc """
  Discovers the metadata named by a 401 challenge. Falls back to the cached
  metadata, then to the bare challenge.
  """
  def challenge_metadata(headers, reason, body, ctx) do
    case auth_metadata(headers, ctx) do
      {:ok, discovered} ->
        {:ok,
         discovered || ctx.oauth_metadata ||
           %{"status" => 401, "reason" => to_string(reason), "body" => to_string(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The error a caller receives when the server still requires authorization."
  def required_reason(%{config: %{origin_policy: nil}}, metadata), do: {:auth_required, metadata}
  def required_reason(_ctx, _metadata), do: :auth_required

  @doc """
  Obtains a grant for `metadata`: the refresh-token grant first, then a new grant.

  With `interactive? = false` a new grant that needs the authorization-code
  provider returns `:interactive_required` instead of invoking it. Returns
  `{:ok, ctx}` with the new grant (already offered to the token cache),
  `{:error, reason}`, or `:error` when no configured flow applies.
  """
  def authorize(metadata, ctx, interactive?) do
    with {:ok, oauth} <- oauth_options(ctx.config.oauth),
         {:ok, target} <- oauth_target(metadata, ctx),
         :ok <- require_bound_issuer(target, ctx),
         :ok <- require_operator_issuer(target, oauth, ctx) do
      case maybe_fetch_refresh_token(target, oauth, ctx) do
        {:ok, token} ->
          {:ok, put_oauth_token(ctx, metadata, target, token)}

        {:error, reason} ->
          {:error, reason}

        :error ->
          fetch_new_token(target, metadata, oauth, ctx, interactive?)
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> :error
    end
  end

  @doc "True for a non-empty bearer credential."
  def bearer_token?(token), do: is_binary(token) and token != ""

  defp auth_metadata(headers, state) do
    with header when is_binary(header) <- Transport.response_header(headers, "www-authenticate"),
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
      {:ok, metadata} ->
        # Server JSON never supplies Lemon's own enrichment fields: AS records
        # are built only from validated discovery below.
        metadata = Map.drop(metadata, @internal_metadata_keys)

        with :ok <- validate_resource(metadata, state),
             do: put_authorization_server_metadata(metadata, state)

      {:error, metadata} when is_map(metadata) ->
        {:ok, metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # RFC 9728 §3.3: the protected resource must be the configured MCP URL, so
  # the server cannot choose the audience of the tokens Lemon requests.
  defp validate_resource(%{"resource" => resource}, state) when is_binary(resource) do
    if same_resource?(resource, state.config.url),
      do: :ok,
      else: {:error, :invalid_oauth_metadata}
  end

  defp validate_resource(_metadata, _state), do: {:error, :invalid_oauth_metadata}

  defp same_resource?(resource, configured) do
    with {:ok, origin} <- OriginPolicy.canonical_origin(resource),
         {:ok, ^origin} <- OriginPolicy.canonical_origin(configured) do
      resource_path(resource) == resource_path(configured)
    else
      _ -> false
    end
  end

  defp resource_path(url) do
    uri = URI.parse(url)
    {if(uri.path in [nil, ""], do: "/", else: uri.path), uri.query}
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_authorization_server_metadata(metadata, _state), do: {:ok, metadata}

  defp fetch_authorization_server_metadata(issuer, state) do
    with {:ok, metadata_url} <- authorization_server_metadata_url(issuer),
         {:ok, metadata} <- fetch_metadata_json(metadata_url, state),
         :ok <- validate_authorization_server_metadata(metadata, issuer, state) do
      {:ok, Map.put(metadata, "metadata_url", metadata_url)}
    else
      {:error, metadata} when is_map(metadata) -> {:ok, Map.put(metadata, "issuer", issuer)}
      {:error, reason} -> {:error, reason}
    end
  end

  # RFC 8414 §3: the issuer identifier has no query or fragment, and the
  # returned `issuer` must be identical to the one requested.
  defp authorization_server_metadata_url(issuer) when is_binary(issuer) do
    uri = URI.parse(issuer)

    with {:ok, _origin} <- OriginPolicy.canonical_origin(issuer),
         nil <- uri.query,
         nil <- uri.fragment do
      path =
        case uri.path do
          nil -> ""
          "" -> ""
          "/" -> ""
          path -> String.trim_trailing(path, "/")
        end

      {:ok,
       %{uri | path: "/.well-known/oauth-authorization-server" <> path}
       |> URI.to_string()}
    else
      _ -> {:error, :invalid_oauth_metadata}
    end
  end

  defp authorization_server_metadata_url(_issuer), do: {:error, :invalid_oauth_metadata}

  defp validate_authorization_server_metadata(metadata, issuer, state) do
    with true <- Map.get(metadata, "issuer") === issuer || {:error, :invalid_oauth_metadata},
         :ok <- validate_optional_endpoint(metadata, "token_endpoint", issuer, state) do
      validate_optional_endpoint(metadata, "authorization_endpoint", issuer, state)
    end
  end

  defp validate_optional_endpoint(metadata, key, issuer, state) do
    case Map.fetch(metadata, key) do
      :error -> :ok
      {:ok, endpoint} -> validate_oauth_endpoint(endpoint, issuer, state)
    end
  end

  # A token or authorization endpoint must be HTTPS (or literal loopback) and,
  # without an operator allowlist, on the issuer's own origin; with one, its
  # origin must be allowlisted. The authorization URL is opened by a browser,
  # never pinned, so membership is checked here before it is exposed.
  defp validate_oauth_endpoint(endpoint, issuer, state) when is_binary(endpoint) do
    with {:ok, origin} <- oauth_origin(endpoint),
         :ok <- require_secure_oauth_origin(origin),
         {:ok, issuer_origin} <- oauth_origin(issuer) do
      case state.config.origin_policy do
        nil when origin == issuer_origin -> :ok
        nil -> {:error, :origin_not_allowed}
        policy -> OriginPolicy.authorize_origin(endpoint, policy)
      end
    end
  end

  defp validate_oauth_endpoint(_endpoint, _issuer, _state), do: {:error, :invalid_oauth_metadata}

  defp oauth_origin(url) do
    case OriginPolicy.canonical_origin(url) do
      {:ok, origin} -> {:ok, origin}
      {:error, _} -> {:error, :invalid_oauth_metadata}
    end
  end

  defp require_secure_oauth_origin(origin) do
    case URI.parse(origin) do
      %URI{scheme: "https"} -> :ok
      %URI{scheme: "http", host: host} -> loopback_or_insecure(host)
      _ -> {:error, :insecure_oauth_endpoint}
    end
  end

  defp loopback_or_insecure(host) do
    if LemonCore.LoopbackListener.literal_loopback?(host),
      do: :ok,
      else: {:error, :insecure_oauth_endpoint}
  end

  # Every OAuth discovery and token connection is HTTPS (or literal loopback)
  # and address-pinned. The operator policy applies when configured; otherwise
  # destinations must be public, except the configured server's own origin and,
  # for a literal-loopback server, other literal-loopback origins.
  defp oauth_pin(url, state) do
    with {:ok, origin} <- oauth_origin(url),
         :ok <- require_secure_oauth_origin(origin) do
      OriginPolicy.pin(url, state.config.origin_policy || implicit_oauth_policy(origin, state))
    end
  end

  defp implicit_oauth_policy(origin, state) do
    approved =
      case OriginPolicy.canonical_origin(state.config.url) do
        {:ok, ^origin} ->
          [origin]

        {:ok, server_origin} ->
          if loopback_origin?(server_origin) and loopback_origin?(origin),
            do: [origin],
            else: []

        _ ->
          []
      end

    %{allowed_origins: [origin], approved_private_origins: approved}
  end

  defp loopback_origin?(origin),
    do: LemonCore.LoopbackListener.literal_loopback?(URI.parse(origin).host)

  defp oauth_http_request(method, url, headers, body, state) do
    with {:ok, pin} <- oauth_pin(url, state) do
      Transport.request(method, url, headers, body, state.config, pin)
    end
  end

  defp fetch_metadata_json(url, state) do
    headers = Transport.headers([{"accept", "application/json"}])

    case oauth_http_request(:get, url, headers, nil, state) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
        case Jason.decode(to_string(body)) do
          {:ok, metadata} when is_map(metadata) ->
            {:ok, metadata}

          _ ->
            if is_nil(state.config.origin_policy),
              do: {:error, %{"metadata_error" => "invalid_json"}},
              else: {:error, :invalid_metadata}
        end

      {:ok, {{_version, status, reason}, _headers, _body}} ->
        if is_nil(state.config.origin_policy),
          do:
            {:error,
             %{"metadata_error" => "http_#{status}", "metadata_error_reason" => to_string(reason)}},
          else: {:error, :metadata_http_error}

      {:error, {:http_request_failed, reason}} ->
        {:error, %{"metadata_error" => inspect(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp challenge_param(header, name) do
    Regex.run(~r/(?:^|[, ])#{Regex.escape(name)}="([^"]+)"/, header, capture: :all_but_first)
    |> case do
      [value] -> value
      _ -> nil
    end
  end

  # Credentials obtained from one issuer are never sent to another: once a
  # token is held, an issuer change fails before refresh or client secrets
  # are used, and requires the operator to re-authorize (clear the cache).
  defp require_bound_issuer(_target, %{oauth_issuer: nil}), do: :ok
  defp require_bound_issuer(%{issuer: issuer}, %{oauth_issuer: issuer}), do: :ok
  defp require_bound_issuer(_target, _state), do: {:error, :oauth_issuer_changed}

  # Operator-supplied credentials go only to an issuer the operator chose: the
  # configured `oauth.issuer` exactly, or, without one, an issuer on the
  # configured server's own origin (client secrets only; a configured refresh
  # token always requires `oauth.issuer`, enforced at startup).
  defp require_operator_issuer(%{issuer: discovered}, oauth, state) do
    case Keyword.get(oauth, :issuer) do
      issuer when is_binary(issuer) ->
        if discovered === issuer, do: :ok, else: {:error, :oauth_issuer_mismatch}

      _ ->
        if bearer_token?(Keyword.get(oauth, :client_secret)) and
             OriginPolicy.canonical_origin(discovered) !=
               OriginPolicy.canonical_origin(state.config.url),
           do: {:error, :oauth_issuer_required},
           else: :ok
    end
  end

  defp validate_oauth_config(oauth) do
    case oauth_options(oauth) do
      {:ok, oauth} ->
        case Keyword.get(oauth, :issuer) do
          nil ->
            if bearer_token?(Keyword.get(oauth, :refresh_token)),
              do: {:error, :oauth_issuer_required},
              else: :ok

          issuer when is_binary(issuer) ->
            case authorization_server_metadata_url(issuer) do
              {:ok, _url} -> :ok
              _ -> {:error, :invalid_oauth_issuer}
            end

          _ ->
            {:error, :invalid_oauth_issuer}
        end

      :error ->
        :ok
    end
  end

  # Re-validates metadata at use, so cached metadata is held to the same
  # binding as freshly discovered metadata. Endpoints come only from an
  # issuer's authorization-server metadata, never the protected resource.
  defp oauth_target(%{"resource" => _} = metadata, state) do
    with :ok <- validate_resource(metadata, state),
         %{"issuer" => issuer, "token_endpoint" => token_endpoint} = server <-
           first_authorization_server(metadata),
         :ok <- validate_oauth_endpoint(token_endpoint, issuer, state),
         :ok <- validate_optional_endpoint(server, "authorization_endpoint", issuer, state) do
      {:ok,
       %{
         issuer: issuer,
         token_endpoint: token_endpoint,
         authorization_endpoint: Map.get(server, "authorization_endpoint"),
         resource: state.config.url
       }}
    else
      nil -> :error
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_oauth_metadata}
    end
  end

  defp oauth_target(_metadata, _state), do: :error

  defp first_authorization_server(%{"authorization_server_metadata" => servers})
       when is_list(servers) do
    Enum.find(servers, &(is_map(&1) and Map.has_key?(&1, "token_endpoint")))
  end

  defp first_authorization_server(_metadata), do: nil

  defp fetch_new_token(target, metadata, oauth, state, interactive?) do
    cond do
      authorization_code_provider?(oauth) and not interactive? ->
        :interactive_required

      authorization_code_provider?(oauth) ->
        case fetch_authorization_code_token(target, oauth, state) do
          {:ok, token} -> {:ok, put_oauth_token(state, metadata, target, token)}
          {:error, reason} -> {:error, reason}
          :error -> :error
        end

      client_credentials_oauth?(oauth) ->
        case fetch_client_credentials_token(target, oauth, state) do
          {:ok, token} -> {:ok, put_oauth_token(state, metadata, target, token)}
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
  defp normalize_oauth_key("issuer"), do: :issuer
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

  defp fetch_client_credentials_token(target, oauth, state) do
    params = %{
      "grant_type" => "client_credentials",
      "client_id" => Keyword.fetch!(oauth, :client_id)
    }

    case put_client_auth(params, oauth) do
      {:ok, params, auth_headers} ->
        body =
          params
          |> maybe_put_scope(oauth)
          |> maybe_put_resource(target)
          |> URI.encode_query()

        headers =
          Transport.headers(
            [
              {"accept", "application/json"},
              {"content-type", "application/x-www-form-urlencoded"}
            ] ++ auth_headers
          )

        case oauth_token_request(target.token_endpoint, headers, body, state) do
          {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
            decode_oauth_token(response_body)

          {:error, reason} ->
            {:error, reason}

          _ ->
            :error
        end

      :error ->
        :error
    end
  end

  defp fetch_authorization_code_token(target, oauth, state) do
    with {:ok, authorization_request} <- build_authorization_request(target, oauth),
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
            |> maybe_put_resource(target)
            |> URI.encode_query()

          headers =
            Transport.headers(
              [
                {"accept", "application/json"},
                {"content-type", "application/x-www-form-urlencoded"}
              ] ++ auth_headers
            )

          case oauth_token_request(target.token_endpoint, headers, body, state) do
            {:ok, {{_version, status, _reason}, _headers, response_body}}
            when status in 200..299 ->
              decode_oauth_token(response_body)

            {:error, reason} ->
              {:error, reason}

            _ ->
              :error
          end

        :error ->
          :error
      end
    else
      :error -> :error
    end
  end

  defp build_authorization_request(target, oauth) do
    with endpoint when is_binary(endpoint) <- target.authorization_endpoint,
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
        |> maybe_put_resource(target)

      {:ok,
       %{
         authorization_url: endpoint <> "?" <> URI.encode_query(params),
         authorization_endpoint: endpoint,
         client_id: Keyword.fetch!(oauth, :client_id),
         code_challenge: challenge,
         code_challenge_method: "S256",
         code_verifier: verifier,
         redirect_uri: Keyword.get(oauth, :redirect_uri),
         resource: target.resource,
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

  # The provider must echo the request state: a bare code is never accepted.
  defp normalize_authorization_code_result({:ok, %{code: code, state: state}}, expected_state),
    do: matched_authorization_code(code, state, expected_state)

  defp normalize_authorization_code_result(
         {:ok, %{"code" => code, "state" => state}},
         expected_state
       ),
       do: matched_authorization_code(code, state, expected_state)

  defp normalize_authorization_code_result(_result, _state), do: :error

  defp matched_authorization_code(code, state, expected_state)
       when is_binary(code) and code != "" and is_binary(state) and is_binary(expected_state) and
              byte_size(state) == byte_size(expected_state) do
    if :crypto.hash_equals(state, expected_state), do: {:ok, code}, else: :error
  end

  defp matched_authorization_code(_code, _state, _expected_state), do: :error

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

  defp maybe_fetch_refresh_token(target, oauth, state) do
    refresh_token =
      cond do
        bearer_token?(state.oauth_refresh_token) -> state.oauth_refresh_token
        bearer_token?(Keyword.get(oauth, :refresh_token)) -> Keyword.get(oauth, :refresh_token)
        true -> nil
      end

    if bearer_token?(refresh_token) do
      fetch_refresh_token(target, oauth, refresh_token, state)
    else
      :error
    end
  end

  defp fetch_refresh_token(target, oauth, refresh_token, state) do
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
          |> maybe_put_resource(target)
          |> URI.encode_query()

        headers =
          Transport.headers(
            [
              {"accept", "application/json"},
              {"content-type", "application/x-www-form-urlencoded"}
            ] ++ auth_headers
          )

        case oauth_token_request(target.token_endpoint, headers, body, state) do
          {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
            decode_oauth_token(response_body)

          {:error, reason} ->
            {:error, reason}

          _ ->
            :error
        end

      :error ->
        :error
    end
  end

  # The endpoint was validated against its issuer; this connection is pinned
  # before any client credential is written. Pin and policy errors surface.
  defp oauth_token_request(url, headers, body, state) do
    case oauth_http_request(
           :post,
           url,
           headers,
           {~c"application/x-www-form-urlencoded", to_charlist(body)},
           state
         ) do
      {:error, {:http_request_failed, _reason}} -> :error
      response -> response
    end
  end

  defp put_oauth_token(state, metadata, target, token) do
    refresh_token =
      case Map.get(token, :refresh_token) do
        value when is_binary(value) and value != "" -> value
        _ -> state.oauth_refresh_token
      end

    state = %{
      state
      | oauth_access_token: token.access_token,
        oauth_refresh_token: refresh_token,
        oauth_metadata: metadata,
        oauth_issuer: target.issuer
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
    issuer = Map.get(token, :issuer) || Map.get(token, "issuer")
    client_id = Map.get(token, :client_id) || Map.get(token, "client_id")

    if bearer_token?(access_token) or bearer_token?(refresh_token) do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         metadata: if(is_map(metadata), do: metadata, else: nil),
         issuer: issuer,
         client_id: client_id
       }}
    else
      :error
    end
  end

  defp normalize_cached_oauth_token(_token), do: :error

  # A cached grant is usable only with the issuer and client that issued it.
  # An entry recorded for another client is ignored. One without a recorded
  # issuer and client keeps only its access token (sent to the MCP server,
  # never an issuer); its refresh token and metadata are not trusted.
  defp apply_cached_oauth_token(state, token) do
    client_id = configured_client_id(state)

    cond do
      not is_nil(token.client_id) and token.client_id != client_id ->
        state

      is_binary(client_id) and token.client_id == client_id and is_binary(token.issuer) and
          token.issuer != "" ->
        %{
          state
          | oauth_access_token: token.access_token,
            oauth_refresh_token: token.refresh_token,
            oauth_metadata: token.metadata,
            oauth_issuer: token.issuer
        }

      true ->
        %{state | oauth_access_token: token.access_token}
    end
  end

  defp configured_client_id(state) do
    case oauth_options(state.config.oauth) do
      {:ok, oauth} -> Keyword.get(oauth, :client_id)
      _ -> nil
    end
  end

  defp persist_oauth_token_cache(%{config: %{oauth_token_cache: nil}}), do: :ok

  defp persist_oauth_token_cache(state) do
    payload = %{
      access_token: state.oauth_access_token,
      refresh_token: state.oauth_refresh_token,
      metadata: state.oauth_metadata,
      issuer: state.oauth_issuer,
      client_id: configured_client_id(state)
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

  defp maybe_put_resource(params, %{resource: resource}),
    do: Map.put(params, "resource", resource)

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
end
