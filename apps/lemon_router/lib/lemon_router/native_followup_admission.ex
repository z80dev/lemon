defmodule LemonRouter.NativeFollowupAdmission do
  @moduledoc """
  Private per-profile issuer configuration and bounded native follow-up admission.

  `configure/3` accepts an existing profile, an explicitly allowed callback URL,
  and a bearer credential. Configuration lives in an owner-only Store table,
  outside profile/config/history projections; credentials use encrypted Secrets.
  There is no management getter. `fetch_config/1` is an execution-owner API.

  Callback origins are exact scheme/host/effective-port matches from
  `LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS` (when set), otherwise
  `:lemon_router, :native_followup_allowed_origins`. HTTPS is required except
  explicitly allowlisted HTTP on the literal loopback IPs 127.0.0.1 and ::1.
  URLs forbid userinfo, queries and fragments. Redirects and retries are disabled.

  The request body is only the reserved immutable lineage's `run_id`. A response
  approves with an exact private invocation object, never principal claims or
  factory-attestation flags. The lineage owner must intersect source policy; the
  authenticated issuer authorizes the sealed fresh target against current ACLs.
  The target's current operator-authored `ProfileStore.mcpServers` is the transport
  ceiling, never response-owned origins or source credentials. Destination-local
  DNS pinning must run before resolving any execution secret.
  """

  alias LemonCore.{InvocationProof, ProfileStore, RunRequest, Secrets, ToolPolicy}
  alias LemonRouter.NativeFollowupAdmissionStore
  alias LemonMCP.HTTP.OriginPolicy

  @max_url_bytes 2048
  @max_token_bytes 4096
  @max_response_bytes 16_777_216
  @request_timeout_ms 5000
  @invocation_fields ~w(invocationContextKey memoryContextKey invocationToolPolicy invocationMcpServers invocationProof sharedMemoryGrant)
  @mcp_fields ~w(name url headers enabledTools allowedOrigins approvedPrivateOrigins)
  @transport_headers ~w(host content-length connection transfer-encoding upgrade proxy-authorization mcp-session-id)

  @type config :: %{profile_id: String.t(), url: String.t(), token_secret: String.t()}
  @type outcome :: {:ok, map()} | {:error, :denied | :admission_unavailable}

  @doc "Provision write-only private admission configuration for an existing profile."
  @spec configure(term(), term(), term()) :: {:ok, String.t()} | {:error, atom()}
  def configure(profile_id, url, token) do
    with true <- valid_token?(token),
         {:ok, _uri} <- allowed_callback(url),
         {:ok, _profile} <- ProfileStore.get(profile_id) do
      # Each configuration names its own encrypted credential, so a failed or
      # concurrent update cannot switch the token beneath an older callback URL.
      name =
        "native_followup/" <>
          profile_id <> "/" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      with {:ok, _metadata} <- Secrets.set(name, token),
           :ok <-
             NativeFollowupAdmissionStore.put(%{
               profile_id: profile_id,
               url: url,
               token_secret: name
             }) do
        {:ok, name}
      else
        _ -> {:error, :admission_unavailable}
      end
    else
      {:error, :not_found} -> {:error, :profile_not_found}
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  @doc "Fetch current private execution configuration, never a profile fallback."
  @spec fetch_config(term()) :: {:ok, config()} | {:error, :admission_unavailable}
  def fetch_config(profile_id) do
    with {:ok, _profile} <- ProfileStore.get(profile_id),
         {:ok, config} <- NativeFollowupAdmissionStore.fetch(profile_id),
         true <- valid_config?(config, profile_id),
         {:ok, _uri} <- allowed_callback(config.url) do
      {:ok, config}
    else
      _ -> {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  @doc "Capture the actual current target profile and its transport-template rotation fence."
  def capture_target(profile_id) do
    with {:ok, profile} <- ProfileStore.get_for_execution(profile_id),
         {:ok, templates} <- normalize_templates(profile["mcpServers"]) do
      profile = Map.put(profile, "mcpServers", templates)
      {:ok, profile, target_version(profile)}
    else
      _ -> {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  @doc "Fail closed unless the current target transport templates still match the captured version."
  def ensure_current_target(profile_id, version) when is_binary(version) do
    case capture_target(profile_id) do
      {:ok, _profile, ^version} -> :ok
      _ -> {:error, :admission_unavailable}
    end
  end

  def ensure_current_target(_, _), do: {:error, :admission_unavailable}

  defp target_version(profile) do
    binding = {profile["id"], profile["updatedAt"], profile["mcpServers"]}
    :crypto.hash(:sha256, :erlang.term_to_binary(binding, [:deterministic]))
  end

  @doc """
  Check a reserved immutable native lineage. Only `:plug` is accepted in opts for
  a process-local Req fixture; it cannot change URLs, credentials or HTTP bounds.
  Returned JSON is data, not an attestation; only the owner may stamp trust flags.
  """
  @spec check(config(), map(), keyword()) :: outcome()
  def check(config, lineage, opts \\ []) do
    with true <- valid_transport_opts?(opts),
         %{profile_id: profile_id} <- config,
         %{run_id: run_id, source_profile_id: ^profile_id, target_profile_id: target_profile_id} <-
           lineage,
         :ok <- RunRequest.validate_invocation_context_key(run_id),
         {:ok, ^config} <- fetch_config(profile_id),
         {:ok, target_profile, target_version} <- capture_target(target_profile_id),
         true <- target_profile["mcpServers"] != [],
         {:ok, token} <- Secrets.get(config.token_secret),
         true <- valid_token?(token),
         {:ok, response} <- request(config.url, token, run_id, opts),
         {:ok, ^config} <- fetch_config(profile_id),
         :ok <- ensure_current_target(target_profile_id, target_version) do
      receipt(response, run_id, target_profile)
    else
      _ -> {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  @doc "Validate the exact JSON invocation projection and its fixed-run proof binding."
  @spec validate_invocation(term(), term()) :: outcome()
  def validate_invocation(projection, run_id) when is_map(projection) do
    with true <- exact_fields?(projection, @invocation_fields),
         true <- safe_json?(projection, 0),
         :ok <- RunRequest.validate_invocation_context_key(projection["invocationContextKey"]),
         :ok <- RunRequest.validate_invocation_context_key(projection["memoryContextKey"]),
         false <- projection["sharedMemoryGrant"],
         policy when is_map(policy) <- projection["invocationToolPolicy"],
         {:ok, _policy} <- ToolPolicy.normalize(policy),
         servers = projection["invocationMcpServers"],
         true <- valid_servers?(servers),
         {:ok, servers} <- ProfileStore.normalize_mcp_servers(servers),
         true <- Enum.all?(servers, &valid_server_transport?/1),
         {:ok, _proof} <- InvocationProof.validate(projection["invocationProof"], run_id, servers),
         true <- byte_size(Jason.encode!(projection)) <= @max_response_bytes do
      {:ok, Map.put(projection, "invocationMcpServers", servers)}
    else
      _ -> {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  def validate_invocation(_, _), do: {:error, :admission_unavailable}

  @doc "Validate an invocation against the actual current target profile transport ceiling."
  @spec validate_invocation(term(), term(), map() | String.t()) :: outcome()
  def validate_invocation(projection, run_id, target_id) when is_binary(target_id) do
    with {:ok, profile, _version} <- capture_target(target_id) do
      validate_invocation(projection, run_id, profile)
    end
  end

  def validate_invocation(projection, run_id, %{"id" => target_id} = target_profile) do
    with {:ok, ^target_profile, _version} <- capture_target(target_id),
         templates when templates != [] <- target_profile["mcpServers"],
         {:ok, projection} <- validate_invocation(projection, run_id),
         true <- Enum.all?(projection["invocationMcpServers"], &within_template?(&1, templates)) do
      {:ok, projection}
    else
      _ -> {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  def validate_invocation(_, _, _), do: {:error, :admission_unavailable}

  defp normalize_templates(templates) when is_list(templates) and length(templates) <= 32 do
    with true <-
           Enum.all?(templates, fn template ->
             is_map(template) and Enum.all?(Map.keys(template), &(&1 in @mcp_fields)) and
               Map.get(template, "headers", %{}) == %{} and
               valid_server_url?(template["url"]) and
               canonical_origins?(template["allowedOrigins"]) and
               canonical_origins?(Map.get(template, "approvedPrivateOrigins", []))
           end),
         {:ok, normalized} <- ProfileStore.normalize_mcp_servers(templates),
         true <- Enum.all?(normalized, &valid_server_transport?/1) do
      {:ok, normalized}
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp normalize_templates(_), do: {:error, :admission_unavailable}

  defp canonical_origins?(origins) when is_list(origins) do
    Enum.all?(origins, fn origin -> OriginPolicy.canonical_origin(origin) == {:ok, origin} end)
  end

  defp canonical_origins?(_), do: false

  defp canonical_url(url) do
    with {:ok, origin} <- OriginPolicy.canonical_origin(url),
         {:ok, uri} <- URI.new(url) do
      {:ok, origin <> (uri.path || "/")}
    end
  end

  defp within_template?(server, templates) do
    Enum.any?(templates, fn template ->
      server["name"] == template["name"] and
        canonical_url(server["url"]) == canonical_url(template["url"]) and
        subset?(server["allowedOrigins"], template["allowedOrigins"]) and
        subset?(
          Map.get(server, "approvedPrivateOrigins", []),
          Map.get(template, "approvedPrivateOrigins", [])
        ) and
        tools_within_template?(server, template)
    end)
  end

  defp subset?(values, ceiling), do: Enum.all?(values, &(&1 in ceiling))

  defp tools_within_template?(server, template) do
    case Map.fetch(template, "enabledTools") do
      :error ->
        true

      {:ok, ceiling} ->
        case Map.fetch(server, "enabledTools") do
          {:ok, tools} -> subset?(tools, ceiling)
          :error -> false
        end
    end
  end

  defp request(url, token, run_id, opts) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout_ms

    Req.post(url,
      json: %{"runId" => run_id},
      headers: [{"authorization", "Bearer " <> token}, {"accept", "application/json"}],
      redirect: false,
      retry: false,
      raw: true,
      compressed: false,
      receive_timeout: @request_timeout_ms,
      pool_timeout: 1000,
      connect_options: [timeout: 2000],
      plugins: [],
      adapter: &Req.Steps.run_finch/1,
      plug: Keyword.get(opts, :plug),
      into: fn {:data, data}, {req, resp} ->
        size = Map.get(resp.private, :native_admission_body_bytes, 0) + byte_size(data)

        if size <= @max_response_bytes and System.monotonic_time(:millisecond) < deadline do
          private =
            resp.private
            |> Map.put(:native_admission_body_bytes, size)
            |> Map.update(:native_admission_body_chunks, [data], &[data | &1])

          {:cont, {req, %{resp | private: private}}}
        else
          {:halt, {req, %{resp | private: %{native_admission_body_invalid: true}}}}
        end
      end
    )
  end

  defp receipt(%Req.Response{status: 200, private: private}, run_id, target_config) do
    with false <- Map.get(private, :native_admission_body_invalid, false),
         body =
           private
           |> Map.get(:native_admission_body_chunks, [])
           |> Enum.reverse()
           |> IO.iodata_to_binary(),
         {:ok, decoded} <- Jason.decode(body, objects: :ordered_objects),
         {:ok, decoded} <- unique_json(decoded, 0) do
      case decoded do
        %{"allow" => false} when map_size(decoded) == 1 ->
          {:error, :denied}

        %{"allow" => true, "invocation" => invocation} when map_size(decoded) == 2 ->
          validate_invocation(invocation, run_id, target_config)

        _ ->
          {:error, :admission_unavailable}
      end
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp receipt(_, _, _), do: {:error, :admission_unavailable}

  # Decode ordered objects first: Jason's default map decoder would erase a
  # duplicate authority-bearing key before shape validation could reject it.
  defp unique_json(_, depth) when depth > 16, do: {:error, :invalid_json}

  defp unique_json(%Jason.OrderedObject{values: values}, depth) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with false <- Map.has_key?(acc, key),
           {:ok, value} <- unique_json(value, depth + 1) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, {:error, :invalid_json}}
      end
    end)
  end

  defp unique_json(values, depth) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case unique_json(value, depth + 1) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, {:error, :invalid_json}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp unique_json(value, depth) do
    if safe_json?(value, depth), do: {:ok, value}, else: {:error, :invalid_json}
  end

  defp safe_json?(_, depth) when depth > 16, do: false
  defp safe_json?(value, _) when is_binary(value), do: String.valid?(value)
  defp safe_json?(value, _) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp safe_json?(values, depth) when is_list(values),
    do: Enum.all?(values, &safe_json?(&1, depth + 1))

  defp safe_json?(%{__struct__: _}, _), do: false

  defp safe_json?(value, depth) when is_map(value) do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and String.valid?(key) and safe_json?(item, depth + 1)
    end)
  end

  defp safe_json?(_, _), do: false

  defp valid_servers?(servers) when is_list(servers) and length(servers) <= 32 do
    Enum.all?(servers, fn server ->
      is_map(server) and Enum.all?(Map.keys(server), &(&1 in @mcp_fields)) and
        valid_server_url?(server["url"]) and valid_headers?(Map.get(server, "headers", %{})) and
        canonical_origins?(server["allowedOrigins"]) and
        canonical_origins?(Map.get(server, "approvedPrivateOrigins", []))
    end)
  end

  defp valid_servers?(_), do: false

  defp valid_server_url?(url) do
    with true <- valid_string?(url, @max_url_bytes),
         false <- Regex.match?(~r/[\s\\\x00-\x1F\x7F]|%(?![0-9a-fA-F]{2})|\$\{/, url),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"] and valid_host?(uri.host),
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment) and is_nil(uri.query),
         false <- Regex.match?(~r/\Ahttps?:\/\/[^\/?#]*:(?:[\/?#]|\z)/i, url) do
      true
    else
      _ -> false
    end
  end

  defp valid_server_transport?(server) do
    uri = URI.new!(server["url"])
    allowed = Map.get(server, "allowedOrigins")
    private = Map.get(server, "approvedPrivateOrigins", [])

    with {:ok, origin} <- OriginPolicy.canonical_origin(server["url"]),
         true <- is_list(allowed) and allowed != [] and origin in allowed,
         true <- is_list(private) and Enum.all?(private, &(&1 in allowed)),
         true <-
           uri.scheme == "https" or
             (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"] and origin in private) do
      # Only literal addresses can be validated on the controller. Hostname DNS
      # pinning belongs to the actual executing destination, never this process.
      case :inet.parse_strict_address(String.to_charlist(uri.host)) do
        {:ok, _address} ->
          policy = %{"allowedOrigins" => allowed, "approvedPrivateOrigins" => private}
          match?({:ok, _pin}, OriginPolicy.pin(server["url"], policy))

        {:error, _} ->
          true
      end
    else
      _ -> false
    end
  end

  defp valid_headers?(headers) when is_map(headers) and map_size(headers) <= 64 do
    names = Map.keys(headers)

    Enum.all?(headers, fn {name, value} ->
      if is_binary(name) and is_binary(value) do
        downcase = String.downcase(name)

        value =
          if downcase == "authorization",
            do: String.replace_prefix(value, "Bearer ", ""),
            else: value

        byte_size(name) in 1..128 and Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, name) and
          downcase not in @transport_headers and secret_reference?(value)
      else
        false
      end
    end) and MapSet.size(MapSet.new(names, &String.downcase/1)) == length(names)
  end

  defp valid_headers?(_), do: false

  defp secret_reference?(value) do
    case Regex.run(~r/\A\$\{LEMON_SECRET:([^{}]+)\}\z/, value) do
      [_, name] ->
        valid_string?(name, 512) and name == String.trim(name) and
          not Regex.match?(~r/[\x00-\x1F\x7F]/, name)

      _ ->
        false
    end
  end

  defp valid_config?(%{profile_id: profile_id, url: url, token_secret: name} = config, profile_id) do
    map_size(config) == 3 and valid_string?(url, @max_url_bytes) and
      is_binary(name) and String.starts_with?(name, "native_followup/" <> profile_id <> "/") and
      valid_string?(name, 256)
  end

  defp valid_config?(_, _), do: false

  defp exact_fields?(map, fields),
    do: map_size(map) == length(fields) and Enum.all?(fields, &Map.has_key?(map, &1))

  defp valid_transport_opts?(opts) do
    Keyword.keyword?(opts) and (opts == [] or match?([plug: _], opts))
  end

  defp valid_token?(token) do
    valid_string?(token, @max_token_bytes) and not Regex.match?(~r/[\x00-\x1F\x7F]/, token)
  end

  defp valid_string?(value, max) when is_binary(value) do
    byte_size(value) in 1..max and String.valid?(value) and String.trim(value) != ""
  end

  defp valid_string?(_, _), do: false

  defp allowed_callback(url) do
    with {:ok, uri} <- callback_uri(url),
         origins when is_list(origins) <- allowed_origins(),
         true <-
           Enum.any?(origins, fn origin ->
             case callback_uri(origin) do
               {:ok, configured} ->
                 is_nil(configured.path) and configured.scheme == uri.scheme and
                   configured.host == uri.host and configured.port == uri.port

               _ ->
                 false
             end
           end) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp allowed_origins do
    case System.get_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS") do
      nil -> Application.get_env(:lemon_router, :native_followup_allowed_origins, [])
      value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp callback_uri(url) do
    with true <- valid_string?(url, @max_url_bytes),
         false <- Regex.match?(~r/[\s\\\x00-\x1F\x7F]|%(?![0-9a-fA-F]{2})/, url),
         {:ok, %URI{host: host, port: port} = uri} <- URI.new(url),
         true <- valid_host?(host),
         true <- uri.scheme == "https" or (uri.scheme == "http" and host in ["127.0.0.1", "::1"]),
         true <- is_integer(port) and port in 1..65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment) and is_nil(uri.query),
         false <- Regex.match?(~r/\Ahttps?:\/\/[^\/?#]*:(?:[\/?#]|\z)/i, url) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp valid_host?(host) when is_binary(host) do
    if String.contains?(host, ":") do
      match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
    else
      byte_size(host) <= 253 and
        Enum.all?(String.split(host, "."), fn label ->
          byte_size(label) in 1..63 and
            Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/, label)
        end)
    end
  end

  defp valid_host?(_), do: false
end
