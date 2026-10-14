defmodule LemonAutomation.CronAdmission do
  @moduledoc """
  Validates private per-job admission configuration and checks an external receipt
  before a cron agent run is submitted. Jobs without admission remain unchanged.

  Callback origins must be explicitly configured with the comma-separated
  `LEMON_CRON_ADMISSION_ALLOWED_ORIGINS` environment declaration or, when unset,
  `:lemon_automation, :cron_admission_allowed_origins`. Both validation and dispatch
  enforce that allowlist. HTTPS is required except for explicitly allowlisted
  HTTP origins on the literal loopback IPs `127.0.0.1` and `::1`. Tokens are read
  only from encrypted `LemonCore.Secrets`; neither configuration validation nor
  receipts accept a plaintext token.
  Origins compare exact scheme, host and effective port; an explicit default
  port is equivalent to an omitted one. Origin entries have no path (including
  trailing `/`), query, userinfo or fragment; callback URLs also forbid queries.

  A bound approving receipt may additionally contain a private `invocation`
  object with exactly `invocationContextKey`, `invocationMcpServers`, and
  `invocationToolPolicy`. Its canonical projection is returned to the caller,
  never persisted here. MCP headers contain destination-local encrypted secret
  references only; this module does not resolve invocation credentials.
  """

  alias LemonCore.{Env, ProfileStore, RunRequest, Secrets, ToolPolicy}

  @fields [:url, :token_secret, :routine_id, :creator_id, :workspace_id]
  @string_fields Enum.map(@fields, &Atom.to_string/1)
  @max_id_bytes 256
  @max_url_bytes 2048
  @max_token_bytes 4096
  @max_response_bytes 16_384
  @request_timeout_ms 5000
  @invocation_fields ~w(invocationContextKey invocationMcpServers invocationToolPolicy)
  @mcp_fields ~w(name url headers enabledTools allowedOrigins approvedPrivateOrigins)
  @transport_headers ~w(host content-length connection transfer-encoding upgrade proxy-authorization mcp-session-id)

  @type admission :: %{
          url: String.t(),
          token_secret: String.t(),
          routine_id: String.t(),
          creator_id: String.t(),
          workspace_id: String.t()
        }
  @type invocation :: %{
          context_key: String.t(),
          mcp_servers: [map()],
          tool_policy: map()
        }
  @type outcome :: :ok | {:ok, invocation()} | {:error, :denied | :admission_unavailable}

  @doc """
  Canonicalizes an atom- or string-keyed admission map, rejecting unknown fields,
  ambiguous duplicate keys, invalid identities, and callbacks outside the exact
  HTTPS or literal-loopback HTTP origin allowlist. `nil` means no external hook.
  Errors are bounded classifications without caller-controlled values.
  """
  @spec validate(term(), term()) :: {:ok, nil | admission()} | {:error, String.t()}
  def validate(nil, _profile_id), do: {:ok, nil}

  def validate(admission, profile_id) when is_map(admission) do
    with true <- valid_id?(profile_id),
         true <- valid_fields?(admission),
         canonical = Map.new(@fields, &{&1, field(admission, &1)}),
         true <- Enum.all?(@fields -- [:url], &valid_id?(canonical[&1])),
         {:ok, _uri} <- allowed_callback(canonical.url) do
      {:ok, canonical}
    else
      false -> {:error, "invalid_admission"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, "invalid_admission"}
  catch
    _, _ -> {:error, "invalid_admission"}
  end

  def validate(_, _), do: {:error, "invalid_admission"}

  @doc """
  Validates the exact string-keyed invocation object from an approving receipt.
  Uses the shared context-key, MCP and sparse tool-policy normalizers. Unknown
  invocation/server fields, credential-bearing URLs, and literal header values
  fail closed. Header values must be `${LEMON_SECRET:NAME}` (optionally prefixed
  with `Bearer ` for Authorization); resolution belongs solely to the executing
  host. HTTPS is required except for literal-loopback HTTP whose exact origin is
  in both `allowedOrigins` and `approvedPrivateOrigins`. `[]` is an explicit
  complete MCP replacement, not profile inheritance.
  """
  @spec validate_invocation(term()) ::
          {:ok, invocation()} | {:error, :admission_unavailable}
  def validate_invocation(projection) when is_map(projection) do
    with true <- map_size(projection) == length(@invocation_fields),
         true <- Enum.all?(Map.keys(projection), &(&1 in @invocation_fields)),
         key = projection["invocationContextKey"],
         :ok <- RunRequest.validate_invocation_context_key(key),
         servers = projection["invocationMcpServers"],
         true <- valid_invocation_servers?(servers),
         {:ok, servers} <- ProfileStore.normalize_mcp_servers(servers),
         true <- Enum.all?(servers, &valid_invocation_transport?/1),
         {:ok, policy} <- ToolPolicy.normalize(projection["invocationToolPolicy"]) do
      {:ok, %{context_key: key, mcp_servers: servers, tool_policy: policy}}
    else
      _ -> {:error, :admission_unavailable}
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  def validate_invocation(_), do: {:error, :admission_unavailable}

  defp valid_invocation_servers?(servers) when is_list(servers) and length(servers) <= 32 do
    Enum.all?(servers, fn server ->
      is_map(server) and
        Enum.all?(Map.keys(server), &(&1 in @mcp_fields)) and
        valid_invocation_url?(server["url"]) and
        valid_invocation_headers?(Map.get(server, "headers", %{}))
    end)
  end

  defp valid_invocation_servers?(_), do: false

  defp valid_invocation_url?(url) do
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

  defp valid_invocation_transport?(server) do
    uri = URI.new!(server["url"])
    origin = URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})

    uri.scheme == "https" or
      (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"] and
         origin in Map.get(server, "allowedOrigins", []) and
         origin in Map.get(server, "approvedPrivateOrigins", []))
  end

  defp valid_invocation_headers?(headers) when is_map(headers) and map_size(headers) <= 64 do
    names = Map.keys(headers)

    Enum.all?(headers, fn {name, value} ->
      if is_binary(name) and is_binary(value) do
        name = String.downcase(name)
        value = if name == "authorization", do: String.replace_prefix(value, "Bearer ", ""), else: value
        name not in @transport_headers and secret_reference?(value)
      else
        false
      end
    end) and
      MapSet.size(MapSet.new(names, &String.downcase/1)) == length(names)
  end

  defp valid_invocation_headers?(_), do: false

  defp secret_reference?(value) when is_binary(value) do
    case Regex.run(~r/\A\$\{LEMON_SECRET:([^{}]+)\}\z/, value) do
      [_, name] ->
        valid_string?(name, 512) and name == String.trim(name) and
          not String.contains?(name, ["\r", "\n", <<0>>])

      _ ->
        false
    end
  end

  defp secret_reference?(_), do: false

  @doc """
  Provisions a routine's private bearer token in the encrypted default-owner
  secret store. The returned deterministic name, not the token, belongs in the
  admission map. Tokens must be nonempty, at most 4096 bytes, and contain no CR/LF.
  """
  @spec set_token(term(), term()) ::
          {:ok, String.t()} | {:error, :invalid_request | :secret_unavailable}
  def set_token(routine_id, token) do
    if valid_id?(routine_id) and valid_token?(token) do
      name = "cron_admission_" <> Base.encode16(:crypto.hash(:sha256, routine_id), case: :lower)

      case Secrets.set(name, token) do
        {:ok, _metadata} -> {:ok, name}
        _ -> {:error, :secret_unavailable}
      end
    else
      {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :secret_unavailable}
  catch
    _, _ -> {:error, :secret_unavailable}
  end

  @doc """
  Checks the exact invocation context against the external admission service.
  Returns `:ok` for a legacy approval, `{:ok, projection}` for a bound private
  invocation approval, or a bounded denial/unavailability classification.
  """
  @spec check(map(), map()) :: outcome()
  def check(job, run), do: check(job, run, [])

  @doc """
  Checks admission with an optional process-local Req `:plug` transport fixture.
  No other request options are accepted: fixtures cannot override origin checks,
  secrets, the request context, redirects, retries, timeouts, or response bounds.
  Production callers use `check/2`.
  """
  @spec check(map(), map(), keyword()) :: outcome()
  def check(job, run, opts) do
    case Map.get(job, :admission) do
      nil -> :ok
      admission -> check_admission(job, run, admission, opts)
    end
  rescue
    _ -> {:error, :admission_unavailable}
  catch
    _, _ -> {:error, :admission_unavailable}
  end

  defp check_admission(job, run, admission, opts) do
    with true <- valid_transport_opts?(opts),
         true <- LemonAutomation.CronJob.execution_mode(job) == :agent,
         {:ok, canonical} <- validate(admission, Map.get(job, :profile_id)),
         {:ok, token} <- Secrets.get(canonical.token_secret),
         true <- valid_token?(token),
         context = request_context(job, run, canonical),
         {:ok, response} <- request(canonical.url, token, context, opts) do
      receipt(response, context)
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp request_context(job, run, admission) do
    %{
      "jobId" => job.id,
      "profileId" => job.profile_id,
      "routineId" => admission.routine_id,
      "creatorId" => admission.creator_id,
      "workspaceId" => admission.workspace_id,
      "cronRunId" => run.id,
      "routerRunId" => run.run_id,
      "triggeredBy" => Atom.to_string(run.triggered_by),
      "scheduledForMs" => scheduled_for_ms(Map.get(run, :meta))
    }
  end

  defp scheduled_for_ms(meta) when is_map(meta) do
    case Map.fetch(meta, :scheduled_for_ms) do
      {:ok, value} -> value
      :error -> Map.get(meta, "scheduled_for_ms")
    end
  end

  defp scheduled_for_ms(_), do: nil

  defp request(url, token, context, opts) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout_ms

    Req.post(url,
      json: context,
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
        size = Map.get(resp.private, :admission_body_bytes, 0) + byte_size(data)

        if size <= @max_response_bytes and System.monotonic_time(:millisecond) < deadline do
          private =
            resp.private
            |> Map.put(:admission_body_bytes, size)
            |> Map.update(:admission_body_chunks, [data], &[data | &1])

          {:cont, {req, %{resp | private: private}}}
        else
          private = %{admission_body_invalid: true}
          {:halt, {req, %{resp | private: private}}}
        end
      end
    )
  end

  defp receipt(%Req.Response{status: 200, private: private}, context) do
    with false <- Map.get(private, :admission_body_invalid, false),
         body = private |> Map.get(:admission_body_chunks, []) |> Enum.reverse() |> IO.iodata_to_binary(),
         {:ok, %{"allow" => allow, "context" => echoed} = decoded} <- Jason.decode(body),
         true <- is_boolean(allow) and echoed === context,
         true <- Enum.all?(Map.keys(decoded), &(&1 in ["allow", "context", "invocation"])) do
      case {allow, Map.fetch(decoded, "invocation")} do
        {true, :error} -> :ok
        {false, :error} -> {:error, :denied}
        {true, {:ok, projection}} -> validate_invocation(projection)
        {false, {:ok, _}} -> {:error, :admission_unavailable}
      end
    else
      _ -> {:error, :admission_unavailable}
    end
  end

  defp receipt(_, _), do: {:error, :admission_unavailable}

  defp valid_transport_opts?(opts) do
    Keyword.keyword?(opts) and Enum.all?(opts, fn {key, _value} -> key == :plug end)
  end

  defp valid_fields?(admission) do
    map_size(admission) == length(@fields) and
      Enum.all?(Map.keys(admission), &(&1 in @fields or &1 in @string_fields)) and
      Enum.all?(@fields, fn key ->
        Map.has_key?(admission, key) != Map.has_key?(admission, Atom.to_string(key))
      end)
  end

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp valid_id?(value), do: valid_string?(value, @max_id_bytes)

  defp valid_token?(value) do
    valid_string?(value, @max_token_bytes) and not String.contains?(value, ["\r", "\n"])
  end

  defp valid_string?(value, max_bytes) when is_binary(value) do
    byte_size(value) in 1..max_bytes and String.valid?(value) and String.trim(value) != ""
  end

  defp valid_string?(_, _), do: false

  defp allowed_callback(url) do
    with {:ok, uri} <- callback_uri(url),
         origins when is_list(origins) <- allowed_origins(),
         true <- Enum.any?(origins, &allowed_origin?(&1, uri)) do
      {:ok, uri}
    else
      _ -> {:error, "admission_origin_not_allowed"}
    end
  end

  defp allowed_origins do
    case Env.get(:lemon_cron_admission_allowed_origins) do
      nil ->
        case System.get_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS") do
          nil -> Application.get_env(:lemon_automation, :cron_admission_allowed_origins, [])
          _ -> []
        end

      value when is_binary(value) -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  defp allowed_origin?(origin, callback) do
    case callback_uri(origin) do
      {:ok, uri} ->
        is_nil(uri.path) and is_nil(uri.query) and
          uri.scheme == callback.scheme and uri.host == callback.host and uri.port == callback.port

      _ ->
        false
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
         # URI.new/1 leaves the deprecated authority field nil. Check the
         # original authority syntax instead, preserving rejection of empty ports.
         false <- Regex.match?(~r/\Ahttps?:\/\/[^\/?#]*:(?:[\/?#]|\z)/i, url) do
      {:ok, uri}
    else
      _ -> {:error, "invalid_admission_url"}
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
