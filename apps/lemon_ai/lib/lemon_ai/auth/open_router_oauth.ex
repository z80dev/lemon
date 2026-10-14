defmodule LemonAi.Auth.OpenRouterOAuth do
  @moduledoc """
  OpenRouter browser sign-in (OAuth PKCE) that yields a durable API key.

  OpenRouter has no client registration: the S256 code verifier is the only
  proof of identity, and it never echoes `state`. `login_device_flow/1` opens
  `https://openrouter.ai/auth` with a loopback `callback_url`
  (`http://localhost:54549/callback`), captures the redirect through
  `:local_callback_listener` when that port is free, and otherwise asks for the
  redirect URL or code through `:on_prompt`. The prompt also accepts an existing
  `sk-or-` key, which is checked against `/api/v1/auth/key`.

  The code is exchanged at `/api/v1/auth/keys` for a user API key. The result
  is that plain key, not a refreshable payload: callers store it like a pasted
  API key and no refresh applies. Tests and local fakes may override
  `:authorize_url`, `:keys_url` and `:key_info_url`, and pass `:req_options`.
  """

  alias LemonAi.Auth.{OAuthFlow, OAuthPKCE}

  @authorize_url "https://openrouter.ai/auth"
  @keys_url "https://openrouter.ai/api/v1/auth/keys"
  @key_info_url "https://openrouter.ai/api/v1/auth/key"
  @redirect_uri "http://localhost:54549/callback"
  @key_prefix "sk-or-"
  @default_callback_timeout_ms 120_000

  @doc "Build the authorization URL with a fresh PKCE verifier."
  @spec build_authorize_url(keyword()) :: {:ok, map()}
  def build_authorize_url(opts \\ []) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @redirect_uri)
    %{verifier: verifier, challenge: challenge} = OAuthPKCE.generate()

    query =
      URI.encode_query(
        [
          {"callback_url", redirect_uri},
          {"code_challenge", challenge},
          {"code_challenge_method", "S256"}
        ],
        :rfc3986
      )

    {:ok,
     %{
       authorize_url: "#{Keyword.get(opts, :authorize_url, @authorize_url)}?#{query}",
       code_verifier: verifier,
       redirect_uri: redirect_uri
     }}
  end

  @doc """
  Sign in through the browser and return `{:ok, api_key}`.

  Requires `:on_auth` and `:on_prompt`; pass `:local_callback_listener` to
  capture the loopback redirect automatically.
  """
  @spec login_device_flow(keyword()) :: {:ok, String.t()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    {:ok, auth} = build_authorize_url(opts)
    listener = start_listener(auth.redirect_uri, opts)

    try do
      with :ok <- OAuthFlow.notify_auth(opts, auth.authorize_url, instructions(listener)),
           {:ok, input} <- await_input(listener, auth.redirect_uri, opts) do
        complete(input, auth, opts)
      end
    after
      stop_listener(listener)
    end
  end

  @doc """
  Parse a pasted redirect URL, `code=` query string, or bare code.
  Malformed full URLs return a credential-free `:invalid_authorization_input` error.
  """
  @spec parse_authorization_input(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_authorization_input(input) when is_binary(input) do
    value = String.trim(input)

    result =
      cond do
        String.contains?(value, "://") ->
          with {:ok, uri} <- OAuthFlow.parse_authorization_uri(value) do
            {:ok, if(is_binary(uri.query), do: URI.decode_query(uri.query)["code"])}
          end

        String.contains?(value, "code=") ->
          {:ok, URI.decode_query(value)["code"]}

        true ->
          {:ok, value}
      end

    with {:ok, code} <- result do
      case OAuthFlow.non_empty_binary(code) do
        nil -> {:error, :missing_authorization_code}
        code -> {:ok, code}
      end
    end
  rescue
    _ -> {:error, :invalid_authorization_input}
  end

  @doc "Exchange an authorization code and its PKCE verifier for an API key."
  @spec exchange_code(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def exchange_code(code, code_verifier, opts \\ []) do
    body = %{
      "code" => code,
      "code_verifier" => code_verifier,
      "code_challenge_method" => "S256"
    }

    case OAuthFlow.request(Keyword.get(opts, :keys_url, @keys_url), [json: body], opts) do
      {:ok, %{status: status, body: %{"key" => key}}}
      when status in 200..299 and is_binary(key) ->
        case OAuthFlow.non_empty_binary(key) do
          nil -> {:error, :missing_api_key}
          key -> {:ok, key}
        end

      {:ok, %{status: status}} when status in 200..299 ->
        {:error, :missing_api_key}

      {:ok, %{status: status, body: body}} ->
        {:error, OAuthFlow.http_error(status, body)}

      {:error, _} = error ->
        error
    end
  end

  @doc "Check a pasted OpenRouter key against the key-info endpoint."
  @spec validate_api_key(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_api_key(api_key, opts \\ []) do
    headers = [{"authorization", "Bearer #{api_key}"}, {"accept", "application/json"}]
    url = Keyword.get(opts, :key_info_url, @key_info_url)

    case OAuthFlow.request(url, [method: :get, headers: headers], opts) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} when status in [401, 403] -> {:error, :invalid_api_key}
      {:ok, %{status: status, body: body}} -> {:error, OAuthFlow.http_error(status, body)}
      {:error, _} = error -> error
    end
  end

  # ── Flow ───────────────────────────────────────────────────────────────────

  defp complete(input, auth, opts) do
    if String.starts_with?(input, @key_prefix) and not String.contains?(input, ["://", "="]) do
      with :ok <- validate_api_key(input, opts), do: {:ok, input}
    else
      with :ok <- OAuthFlow.validate_redirect_input(input, auth.redirect_uri),
           {:ok, code} <- parse_authorization_input(input) do
        OAuthFlow.notify_progress(opts, "Exchanging the authorization code for an API key...")
        exchange_code(code, auth.code_verifier, opts)
      end
    end
  end

  defp start_listener(redirect_uri, opts) do
    module = Keyword.get(opts, :local_callback_listener)

    if module && Keyword.get(opts, :listen_for_callback, true) &&
         module.local_redirect_uri?(redirect_uri) do
      case module.start(redirect_uri) do
        {:ok, listener} ->
          {module, listener}

        {:error, _reason} ->
          OAuthFlow.notify_progress(
            opts,
            "Could not listen on #{redirect_uri}; paste the redirect URL instead."
          )

          nil
      end
    end
  end

  defp stop_listener(nil), do: :ok
  defp stop_listener({module, listener}), do: module.stop(listener)

  defp instructions(nil),
    do: "Sign in to OpenRouter, then paste the URL the browser is redirected to."

  defp instructions(_listener),
    do: "Sign in to OpenRouter. Lemon captures the browser redirect automatically."

  defp await_input(nil, _redirect_uri, opts), do: prompt(opts)

  defp await_input({module, listener}, redirect_uri, opts) do
    OAuthFlow.notify_progress(opts, "Waiting for the browser redirect to #{redirect_uri} ...")
    timeout_ms = Keyword.get(opts, :callback_timeout_ms, @default_callback_timeout_ms)

    case module.wait(listener, timeout_ms) do
      {:ok, callback_url} ->
        {:ok, callback_url}

      {:error, _reason} ->
        OAuthFlow.notify_progress(opts, "The browser redirect did not arrive.")
        prompt(opts)
    end
  end

  defp prompt(opts) do
    case Keyword.get(opts, :on_prompt) do
      prompt when is_function(prompt, 1) ->
        message = "Paste the redirect URL (or code), or an existing OpenRouter API key:"

        case prompt.(%{message: message, placeholder: "http://localhost:54549/callback?code=..."})
             |> OAuthFlow.normalize_prompt_input() do
          "" -> {:error, :login_cancelled}
          value -> {:ok, value}
        end

      _ ->
        {:error, :prompt_callback_required}
    end
  end
end
