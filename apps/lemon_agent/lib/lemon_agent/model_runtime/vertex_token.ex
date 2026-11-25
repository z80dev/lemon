defmodule LemonAgent.ModelRuntime.VertexToken do
  @moduledoc """
  Google Vertex AI access tokens. `LemonAi.Providers.GoogleVertex` accepts only
  an explicit token; Lemon mints it here, per request through the credential
  callback (`LemonAgent.ModelRuntime.Credentials`), never in the stream worker.

  Sources, in order:

    1. the resolved service-account JSON (`providers.google_vertex`
       `service_account_json_secret`/`service_account_json`, or
       `GOOGLE_APPLICATION_CREDENTIALS_JSON`; see
       `LemonAgent.ModelRuntime.StreamOptions.ProviderSettings`);
    2. the service-account file named by `GOOGLE_APPLICATION_CREDENTIALS`;
    3. `gcloud auth print-access-token`.

  A configured service account that could not be read (`credential_error`)
  refuses every source. Tokens are cached in `LemonAi.Auth.Cache` per source: a
  service-account token until a minute before its `expires_in`, a gcloud token
  (whose expiry gcloud does not report) for two minutes. Minting is
  single-flight per source and bounded: the JWT exchange and the gcloud process
  each have a 15 second deadline, and waiters give up at the same deadline.
  gcloud runs argv-only with closed stdin and a 64 KiB output limit. Errors are
  credential-free atoms.
  """

  alias LemonAi.Auth.Cache

  @default_token_uri "https://oauth2.googleapis.com/token"
  @scope "https://www.googleapis.com/auth/cloud-platform"
  @timeout_ms 15_000
  @expiry_margin_s 60
  @gcloud_ttl_s 120
  @default_ttl_s 3_600
  @max_output_bytes 65_536
  @max_file_bytes 1_048_576

  @type error ::
          :service_account_unavailable
          | :invalid_service_account
          | :token_exchange_failed
          | :credentials_file_unreadable
          | :gcloud_not_found
          | :gcloud_failed
          | :gcloud_timeout
          | :gcloud_output_too_large
          | :mint_timeout

  @doc """
  An access token for the resolved `google_vertex` settings.

  Options: `:req_options` (merged into the token exchange request) and
  `:gcloud` (absolute path of the gcloud executable), for tests.
  """
  @spec access_token(map(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def access_token(resolved, opts \\ []) when is_map(resolved) do
    cond do
      not is_nil(Map.get(resolved, :credential_error)) ->
        {:error, :service_account_unavailable}

      json = present(Map.get(resolved, :service_account_json)) ->
        service_account_token(json, opts)

      path = credentials_file() ->
        with {:ok, json} <- read_credentials_file(path), do: service_account_token(json, opts)

      true ->
        gcloud_token(opts)
    end
  end

  @doc "Credential-free operator guidance for an error from `access_token/2`."
  @spec error_message(error() | term()) :: String.t()
  def error_message(:service_account_unavailable),
    do:
      "the configured service account secret could not be read; refusing GOOGLE_APPLICATION_CREDENTIALS and gcloud."

  def error_message(:invalid_service_account),
    do: "the service account JSON has no usable client_email and private_key."

  def error_message(:token_exchange_failed),
    do: "Google rejected or did not answer the service account token exchange."

  def error_message(:credentials_file_unreadable),
    do: "the GOOGLE_APPLICATION_CREDENTIALS file could not be read."

  def error_message(:gcloud_not_found),
    do:
      "gcloud was not found; configure a service account or install gcloud and run `gcloud auth login`."

  def error_message(:gcloud_failed),
    do: "gcloud could not print an access token; run `gcloud auth login` and retry."

  def error_message(:gcloud_timeout), do: "gcloud did not print an access token in time."
  def error_message(:gcloud_output_too_large), do: "gcloud output exceeded the limit."
  def error_message(:mint_timeout), do: "another Vertex AI token request did not finish in time."
  def error_message(_reason), do: "Vertex AI credentials are unavailable."

  # ── Service account ────────────────────────────────────────────────────────

  defp service_account_token(json, opts) do
    with {:ok, email, private_key, token_uri} <- service_account(json) do
      key = {__MODULE__, :service_account, email, :crypto.hash(:sha256, private_key), token_uri}

      cached(key, fn ->
        with {:ok, jwt} <- sign_jwt(email, private_key, token_uri) do
          exchange(jwt, token_uri, opts)
        end
      end)
    end
  end

  defp service_account(json) do
    with {:ok, %{} = credentials} <- Jason.decode(json),
         email when is_binary(email) and email != "" <- credentials["client_email"],
         key when is_binary(key) and key != "" <- credentials["private_key"] do
      {:ok, email, key, present(credentials["token_uri"]) || @default_token_uri}
    else
      _ -> {:error, :invalid_service_account}
    end
  end

  defp sign_jwt(email, private_key, token_uri) do
    now = System.system_time(:second)

    claims = %{
      "iss" => email,
      "sub" => email,
      "scope" => @scope,
      "aud" => token_uri,
      "iat" => now,
      "exp" => now + @default_ttl_s
    }

    signing_input =
      Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    case :public_key.pem_decode(private_key) do
      [entry | _] ->
        signature = :public_key.sign(signing_input, :sha256, :public_key.pem_entry_decode(entry))
        {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}

      _ ->
        {:error, :invalid_service_account}
    end
  rescue
    _ -> {:error, :invalid_service_account}
  end

  defp exchange(jwt, token_uri, opts) do
    request =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        method: :post,
        url: token_uri,
        form: %{"grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion" => jwt},
        connect_options: [timeout: @timeout_ms],
        receive_timeout: @timeout_ms,
        retry: false,
        redirect: false
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}}
      when is_binary(token) and token != "" ->
        {:ok, token, ttl(body["expires_in"]) - @expiry_margin_s}

      _ ->
        {:error, :token_exchange_failed}
    end
  rescue
    _ -> {:error, :token_exchange_failed}
  end

  defp ttl(seconds) when is_integer(seconds) and seconds > @expiry_margin_s, do: seconds
  defp ttl(_seconds), do: @default_ttl_s

  defp credentials_file do
    case present(System.get_env("GOOGLE_APPLICATION_CREDENTIALS")) do
      nil -> nil
      path -> if File.exists?(path), do: path
    end
  end

  defp read_credentials_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        case File.read(path) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, :credentials_file_unreadable}
        end

      _ ->
        {:error, :credentials_file_unreadable}
    end
  end

  # ── gcloud ─────────────────────────────────────────────────────────────────

  defp gcloud_token(opts) do
    with {:ok, executable} <- gcloud_executable(opts) do
      # gcloud's account follows the user's home directory.
      cached({__MODULE__, :gcloud, executable, System.get_env("HOME")}, fn ->
        with {:ok, output} <- run(executable, ["auth", "print-access-token"]),
             token when is_binary(token) <- last_line(output) do
          {:ok, token, @gcloud_ttl_s}
        else
          {:error, _} = error -> error
          _ -> {:error, :gcloud_failed}
        end
      end)
    end
  end

  defp gcloud_executable(opts) do
    case Keyword.get(opts, :gcloud) || System.find_executable("gcloud") do
      path when is_binary(path) ->
        if Path.type(path) == :absolute and File.regular?(path),
          do: {:ok, path},
          else: {:error, :gcloud_not_found}

      _ ->
        {:error, :gcloud_not_found}
    end
  end

  defp last_line(output) do
    if String.valid?(output) do
      output
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()
      |> case do
        nil -> nil
        line -> if String.contains?(line, [" ", "\t"]), do: nil, else: line
      end
    end
  end

  defp run(executable, args) do
    caller = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(caller, {ref, execute(executable, args)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :gcloud_failed}
    after
      @timeout_ms + 1_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :gcloud_timeout}
    end
  end

  defp execute(executable, args) do
    # `:in` opens only the child's stdout pipe; its stdin is /dev/null.
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :in,
        :exit_status,
        :use_stdio,
        {:args, Enum.map(args, &String.to_charlist/1)}
      ])

    try do
      collect(port, System.monotonic_time(:millisecond) + @timeout_ms, [], 0)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> {:error, :gcloud_not_found}
  end

  defp collect(port, deadline, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > @max_output_bytes,
          do: {:error, :gcloud_output_too_large},
          else: collect(port, deadline, [data | chunks], size + byte_size(data))

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :gcloud_failed}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :gcloud_timeout}
    end
  end

  # ── Cache ──────────────────────────────────────────────────────────────────

  defp cached(key, mint) do
    case fresh(Cache.get(key)) do
      {:ok, token} -> {:ok, token}
      :miss -> locked(key, mint, System.monotonic_time(:millisecond) + @timeout_ms)
    end
  end

  # Hold the per-source lock through publication; a waiter re-reads the cache
  # the winner filled instead of minting again.
  defp locked(key, mint, deadline) do
    case :global.trans({key, self()}, fn -> mint_once(key, mint) end, [node()], 0) do
      :aborted ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(25, remaining))
          locked(key, mint, deadline)
        else
          {:error, :mint_timeout}
        end

      result ->
        result
    end
  end

  defp mint_once(key, mint) do
    case fresh(Cache.get(key)) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        with {:ok, token, ttl_s} <- mint.() do
          Cache.put(key, {token, System.monotonic_time(:second) + ttl_s})
          {:ok, token}
        end
    end
  end

  defp fresh({token, expires_at}) when is_binary(token) and is_integer(expires_at) do
    if expires_at > System.monotonic_time(:second), do: {:ok, token}, else: :miss
  end

  defp fresh(_entry), do: :miss

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil
end
