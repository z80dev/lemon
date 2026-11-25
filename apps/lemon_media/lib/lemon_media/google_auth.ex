defmodule LemonMedia.GoogleAuth do
  @moduledoc """
  Google service-account access tokens for media providers, cached until
  shortly before expiry.

  The cache is an ETS table owned by this process (started by
  `LemonMedia.Application`) and keyed by service account, private key and
  token endpoint, so a second job with the same credentials reuses the token
  instead of signing and exchanging a new JWT. Errors are labelled with the
  calling provider (`label`, e.g. `:vertex_imagen`), never raw responses.
  """

  use GenServer

  alias LemonMedia.Providers.Http

  @table __MODULE__
  @scope "https://www.googleapis.com/auth/cloud-platform"
  @default_token_uri "https://oauth2.googleapis.com/token"
  @default_ttl_seconds 3600
  @refresh_margin_seconds 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Returns an access token for `runtime`: its explicit `:access_token`, or one
  exchanged for its `:service_account_json` through `runtime.token_http_post`.
  """
  @spec access_token(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  def access_token(%{access_token: token}, _label) when is_binary(token) and token != "",
    do: {:ok, token}

  def access_token(%{service_account_json: json} = runtime, label)
      when is_binary(json) and json != "" do
    with {:ok, credentials} <- decode_credentials(json, label),
         {:ok, client_email, private_key, token_uri} <- credential_fields(credentials, label) do
      key = {client_email, :crypto.hash(:sha256, private_key), token_uri}

      case cached(key) do
        {:ok, token} -> {:ok, token}
        :miss -> fetch(key, client_email, private_key, token_uri, runtime, label)
      end
    end
  end

  def access_token(_runtime, label), do: {:error, :"missing_#{label}_credentials"}

  @doc "Drops every cached token."
  @spec clear() :: :ok
  def clear do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  defp decode_credentials(json, label) do
    case Jason.decode(json) do
      {:ok, credentials} when is_map(credentials) -> {:ok, credentials}
      _ -> {:error, :"invalid_#{label}_service_account_json"}
    end
  end

  defp credential_fields(credentials, label) do
    client_email = credentials["client_email"]
    private_key = credentials["private_key"]

    if is_binary(client_email) and client_email != "" and is_binary(private_key) and
         private_key != "" do
      {:ok, client_email, private_key, credentials["token_uri"] || @default_token_uri}
    else
      {:error, :"invalid_#{label}_service_account_json"}
    end
  end

  defp cached(key) do
    now = System.system_time(:second)

    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, key) do
      [{^key, token, expires_at}] when expires_at - @refresh_margin_seconds > now -> {:ok, token}
      _ -> :miss
    end
  end

  defp fetch(key, client_email, private_key, token_uri, runtime, label) do
    with {:ok, jwt} <- sign_jwt(client_email, private_key, token_uri, label),
         {:ok, token, ttl} <- exchange(jwt, token_uri, runtime, label) do
      if :ets.whereis(@table) != :undefined do
        :ets.insert(@table, {key, token, System.system_time(:second) + ttl})
      end

      {:ok, token}
    end
  end

  defp sign_jwt(client_email, private_key, token_uri, label) do
    now = System.system_time(:second)
    header = %{"alg" => "RS256", "typ" => "JWT"}

    claims = %{
      "iss" => client_email,
      "sub" => client_email,
      "scope" => @scope,
      "aud" => token_uri,
      "iat" => now,
      "exp" => now + @default_ttl_seconds
    }

    signing_input =
      Base.url_encode64(Jason.encode!(header), padding: false) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    with [pem_entry | _] <- :public_key.pem_decode(private_key),
         decoded_key <- :public_key.pem_entry_decode(pem_entry) do
      signature = :public_key.sign(signing_input, :sha256, decoded_key)
      {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}
    else
      _ -> {:error, :"invalid_#{label}_service_account_private_key"}
    end
  end

  defp exchange(jwt, token_uri, runtime, label) do
    request_opts = [
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body:
        URI.encode_query(%{
          "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
          "assertion" => jwt
        }),
      receive_timeout: 60_000
    ]

    token_http_post = Map.get(runtime, :token_http_post) || (&Req.post/2)

    case token_http_post.(token_uri, request_opts) do
      {:ok, %{status: status, body: %{"access_token" => token} = body}}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, token, ttl(body["expires_in"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:"#{label}_token_http_error", status, Http.provider_error_kind(body)}}

      {:error, reason} ->
        {:error, {:"#{label}_token_request_failed", Http.provider_error_kind(reason)}}
    end
  end

  defp ttl(seconds) when is_integer(seconds) and seconds > 0, do: seconds
  defp ttl(_seconds), do: @default_ttl_seconds
end
