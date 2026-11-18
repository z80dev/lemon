defmodule LemonAi.Auth.GoogleGeminiCliOAuth do
  @moduledoc """
  Google Gemini CLI OAuth helpers.

  Supports PKCE authorization URL generation, localhost callback/manual paste
  parsing, token exchange + refresh, Code Assist project setup, encoded
  secret payloads, and API-key resolution for the `google_gemini_cli` provider.
  """

  import LemonAi.Auth.OAuthFlow, only: [non_empty_binary: 1, notify_auth: 3, notify_progress: 2]

  alias LemonAi.Auth.{OAuthFlow, OAuthPKCE, OAuthSecret}

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @userinfo_url "https://www.googleapis.com/oauth2/v1/userinfo?alt=json"
  @code_assist_base_url "https://cloudcode-pa.googleapis.com/v1internal"
  @default_redirect_uri "http://localhost:8085/oauth2callback"
  @default_client_id System.get_env("GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID", "")
  @default_client_secret System.get_env("GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET", "")
  @client_id_secret_names [
    "google_gemini_cli_oauth_client_id",
    "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID"
  ]
  @client_secret_secret_names [
    "google_gemini_cli_oauth_client_secret",
    "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET"
  ]
  @scopes [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile"
  ]
  @secret_type "google_gemini_cli_oauth"
  @near_expiry_ms 5 * 60 * 1000
  @free_tier_id "free-tier"
  @legacy_tier_id "legacy-tier"
  @default_onboard_attempts 10
  @default_onboard_delay_ms 5_000
  @code_assist_headers %{
    "User-Agent" => "google-cloud-sdk vscode_cloudshelleditor/0.1",
    "X-Goog-Api-Client" => "gl-node/22.17.0",
    "Client-Metadata" => "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI"
  }

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}
  @type login_opt ::
          {:on_auth, (String.t(), String.t() | nil -> any())}
          | {:on_progress, (String.t() -> any())}
          | {:on_prompt, (map() -> String.t() | charlist())}
          | {:redirect_uri, String.t()}
          | {:state, String.t()}
          | {:project_id, String.t()}
          | {:callback_timeout_ms, pos_integer()}
          | {:listen_for_callback, boolean()}
          | {:local_callback_listener, module()}
          | {:persist_secret,
             (String.t(), String.t(), term() -> :ok | {:ok, term()} | {:error, term()})}

  @doc false
  @spec oauth_client_id() :: String.t()
  def oauth_client_id do
    resolve_client_credential(
      @client_id_secret_names,
      "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID",
      @default_client_id
    )
  end

  @doc false
  @spec oauth_client_secret() :: String.t()
  def oauth_client_secret do
    resolve_client_credential(
      @client_secret_secret_names,
      "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET",
      @default_client_secret
    )
  end

  @doc """
  Build an OAuth authorization URL + PKCE verifier.
  """
  @spec authorize_url(keyword()) :: {:ok, map()}
  def authorize_url(opts \\ []), do: build_authorize_url(opts)

  @doc """
  Run the Gemini CLI OAuth flow.

  When the redirect URI is local (`http://localhost:8085/oauth2callback` by default),
  A local listener can capture the browser callback automatically and fall back to manual
  paste only if the listener cannot complete the flow.
  """
  @spec login_device_flow([login_opt()]) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    with {:ok, auth} <- build_authorize_url(opts) do
      listener = OAuthFlow.start_callback_listener(auth.redirect_uri, auth.state, opts)

      try do
        with :ok <-
               notify_auth(
                 opts,
                 auth.authorize_url,
                 auth_instructions(auth.redirect_uri, listener)
               ),
             {:ok, input} <-
               OAuthFlow.await_authorization_input(opts, auth.redirect_uri, listener, %{
                 message: "Paste the callback URL from the browser address bar:",
                 placeholder: "http://localhost:8085/oauth2callback?code=...&state=..."
               }),
             {:ok, %{code: code, state: state}} <- OAuthFlow.parse_authorization_input(input),
             :ok <- OAuthFlow.ensure_state_matches(auth.state, state),
             :ok <- notify_progress(opts, "Exchanging authorization code for Gemini tokens..."),
             {:ok, secret} <-
               exchange_code_for_secret(code, auth.code_verifier,
                 redirect_uri: auth.redirect_uri,
                 project_id: resolve_configured_project_id(opts)
               ) do
          {:ok, secret}
        end
      after
        OAuthFlow.stop_callback_listener(listener)
      end
    end
  end

  @doc """
  Build an OAuth authorization URL + PKCE verifier.
  """
  @spec build_authorize_url(keyword()) :: {:ok, map()}
  def build_authorize_url(opts \\ []) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)
    %{verifier: verifier, challenge: challenge} = OAuthPKCE.generate()
    state = Keyword.get(opts, :state, OAuthPKCE.random_state())

    params =
      URI.encode_query(%{
        "client_id" => oauth_client_id(),
        "response_type" => "code",
        "redirect_uri" => redirect_uri,
        "scope" => Enum.join(@scopes, " "),
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "access_type" => "offline",
        "prompt" => "consent"
      })

    {:ok,
     %{
       authorize_url: "#{@authorize_url}?#{params}#lemon",
       code_verifier: verifier,
       state: state,
       redirect_uri: redirect_uri,
       created_at_ms: System.system_time(:millisecond)
     }}
  end

  @doc """
  Exchange authorization code + PKCE verifier for an OAuth secret payload.
  """
  @spec exchange_code_for_secret(String.t(), String.t(), keyword()) ::
          {:ok, oauth_secret()} | {:error, term()}
  def exchange_code_for_secret(code, code_verifier, opts \\ [])

  def exchange_code_for_secret(code, code_verifier, opts)
      when is_binary(code) and is_binary(code_verifier) do
    redirect_uri = Keyword.get(opts, :redirect_uri, @default_redirect_uri)
    configured_project_id = resolve_configured_project_id(opts)

    body = %{
      "client_id" => oauth_client_id(),
      "client_secret" => oauth_client_secret(),
      "code" => code,
      "grant_type" => "authorization_code",
      "redirect_uri" => redirect_uri,
      "code_verifier" => code_verifier
    }

    with {:ok, data} <- OAuthFlow.post_form(@token_url, body),
         {:ok, token_data} <- OAuthSecret.parse_token_response(data, @near_expiry_ms, true),
         {:ok, email} <- fetch_user_email(token_data.access_token),
         {:ok, secret} <-
           build_oauth_secret(token_data, email, redirect_uri, configured_project_id),
         {:ok, hydrated_secret, _changed?} <- ensure_project_context(secret) do
      {:ok, hydrated_secret}
    end
  end

  def exchange_code_for_secret(_, _, _), do: {:error, :invalid_authorization_input}

  @doc """
  Encode OAuth secret payload for storage by the caller.
  """
  @spec encode_secret(oauth_secret()) :: String.t()
  defdelegate encode_secret(secret), to: OAuthSecret, as: :encode

  @doc """
  Decode OAuth secret payload.
  """
  @spec decode_secret(String.t()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(value), do: OAuthSecret.decode(value, [@secret_type])

  @doc """
  Resolve a usable Gemini CLI credential JSON string (`{"token","projectId"}`)
  from a secret value.

  Returns `:ignore` for non-Gemini-CLI OAuth payloads.
  """
  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value, opts \\ []) do
    OAuthSecret.resolve(__MODULE__, secret_name, secret_value, opts, %{
      refresh: &refresh_secret/1,
      skew_ms: @near_expiry_ms,
      always_reload: true,
      refresh_replaced: true,
      usable: &OAuthSecret.usable/1,
      prepare: &maybe_ensure_project_context(&1, project_id_from_secret(&1)),
      resolve: &OAuthSecret.project_key(&1, project_id_from_secret(&1), :missing_gemini_project)
    })
  end

  defp refresh_secret(secret) do
    refresh_token = non_empty_binary(secret["refresh_token"])

    body = %{
      "client_id" => oauth_client_id(),
      "client_secret" => oauth_client_secret(),
      "refresh_token" => refresh_token,
      "grant_type" => "refresh_token"
    }

    with {:ok, data} <- OAuthFlow.post_form(@token_url, body),
         {:ok, token} <- OAuthSecret.parse_token_response(data, @near_expiry_ms, true) do
      {:ok,
       secret
       |> Map.put("access_token", token.access_token)
       |> Map.put("refresh_token", token.refresh_token || refresh_token)
       |> Map.put("expires_at_ms", token.expires_at_ms)
       |> Map.put("updated_at_ms", System.system_time(:millisecond))}
    end
  end

  defp maybe_ensure_project_context(secret, project_id)
       when is_binary(project_id) and project_id != "" do
    {:ok, secret, false}
  end

  defp maybe_ensure_project_context(secret, _project_id), do: ensure_project_context(secret)

  defp ensure_project_context(secret) when is_map(secret) do
    access_token = non_empty_binary(secret["access_token"])
    configured_project_id = configured_project_id_from_secret(secret)
    managed_project_id = managed_project_id_from_secret(secret)
    existing_project_id = project_id_from_secret(secret)

    cond do
      is_binary(existing_project_id) and existing_project_id != "" and
          (is_nil(configured_project_id) or not is_nil(managed_project_id)) ->
        {:ok, secret, false}

      is_nil(access_token) ->
        {:error, :missing_access_token}

      true ->
        with {:ok, payload} <- load_code_assist(access_token, configured_project_id),
             {:ok, updated_secret, changed?} <- apply_project_payload(secret, payload) do
          {:ok, updated_secret, changed?}
        end
    end
  end

  defp apply_project_payload(secret, payload) when is_map(payload) do
    configured_project_id = configured_project_id_from_secret(secret)

    case normalize_project_id(payload["cloudaicompanionProject"]) do
      managed_project_id when is_binary(managed_project_id) and managed_project_id != "" ->
        updated =
          secret
          |> put_project_fields(configured_project_id, managed_project_id, managed_project_id)

        {:ok, updated, project_fields_changed?(secret, updated)}

      _ ->
        current_tier_id = get_in(payload, ["currentTier", "id"]) |> normalize_project_id()

        cond do
          is_binary(current_tier_id) and current_tier_id != "" and
            is_binary(configured_project_id) and configured_project_id != "" ->
            updated =
              secret
              |> put_project_fields(configured_project_id, nil, configured_project_id)

            {:ok, updated, project_fields_changed?(secret, updated)}

          is_binary(current_tier_id) and current_tier_id != "" ->
            {:error, project_required_message()}

          true ->
            with :ok <- maybe_raise_validation_error(payload["ineligibleTiers"]),
                 {:ok, tier_id} <- pick_onboard_tier_id(payload["allowedTiers"]),
                 :ok <- ensure_project_allowed_for_tier(tier_id, configured_project_id),
                 {:ok, managed_project_id} <-
                   onboard_user(access_token_from_secret(secret), tier_id, configured_project_id) do
              updated =
                secret
                |> put_project_fields(
                  configured_project_id,
                  managed_project_id,
                  managed_project_id
                )

              {:ok, updated, project_fields_changed?(secret, updated)}
            end
        end
    end
  end

  defp load_code_assist(access_token, project_id)
       when is_binary(access_token) and access_token != "" do
    body =
      %{"metadata" => code_assist_metadata(project_id)}
      |> maybe_put("cloudaicompanionProject", project_id)

    case post_code_assist("#{@code_assist_base_url}:loadCodeAssist", access_token, body) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:ok, payload} ->
        case decode_json_body(payload) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :invalid_code_assist_payload}
        end

      {:error, {:http_error, status, response_body}} ->
        if vpc_sc_error?(response_body) do
          {:ok, %{"currentTier" => %{"id" => "standard-tier"}}}
        else
          {:error, {:http_error, status, response_body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_code_assist(_, _), do: {:error, :missing_access_token}

  defp onboard_user(access_token, tier_id, project_id)
       when is_binary(access_token) and access_token != "" and is_binary(tier_id) and
              tier_id != "" do
    body =
      %{
        "tierId" => tier_id,
        "metadata" => code_assist_metadata(project_id, tier_id != @free_tier_id)
      }
      |> maybe_put(
        "cloudaicompanionProject",
        if(tier_id == @free_tier_id, do: nil, else: project_id)
      )

    with {:ok, payload} <-
           post_code_assist("#{@code_assist_base_url}:onboardUser", access_token, body),
         {:ok, decoded_payload} <- decode_json_body(payload),
         {:ok, done_payload} <- wait_for_operation(access_token, decoded_payload) do
      managed_project_id =
        done_payload
        |> get_in(["response", "cloudaicompanionProject"])
        |> normalize_project_id()

      cond do
        is_binary(managed_project_id) and managed_project_id != "" ->
          {:ok, managed_project_id}

        is_binary(project_id) and project_id != "" ->
          {:ok, project_id}

        true ->
          {:error, project_required_message()}
      end
    end
  end

  defp onboard_user(_, _, _), do: {:error, :missing_access_token}

  defp wait_for_operation(_access_token, %{"done" => true} = payload), do: {:ok, payload}

  defp wait_for_operation(access_token, %{"name" => operation_name} = _payload)
       when is_binary(operation_name) and operation_name != "" do
    Enum.reduce_while(1..@default_onboard_attempts, {:error, :operation_timeout}, fn _attempt,
                                                                                     _acc ->
      Process.sleep(@default_onboard_delay_ms)

      case get_code_assist("#{@code_assist_base_url}/#{operation_name}", access_token) do
        {:ok, %{"done" => true} = operation_payload} ->
          {:halt, {:ok, operation_payload}}

        {:ok, %{} = _operation_payload} ->
          {:cont, {:error, :operation_timeout}}

        {:ok, payload} ->
          case decode_json_body(payload) do
            {:ok, %{"done" => true} = operation_payload} ->
              {:halt, {:ok, operation_payload}}

            {:ok, %{} = _operation_payload} ->
              {:cont, {:error, :operation_timeout}}

            _ ->
              {:halt, {:error, :invalid_onboard_response}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp wait_for_operation(_, payload) when is_map(payload), do: {:ok, payload}

  defp build_oauth_secret(token_data, email, redirect_uri, configured_project_id) do
    {:ok,
     OAuthSecret.build(@secret_type, token_data, %{
       "configured_project_id" => configured_project_id,
       "email" => non_empty_binary(email),
       "redirect_uri" => non_empty_binary(redirect_uri)
     })}
  end

  defp fetch_user_email(access_token) when is_binary(access_token) and access_token != "" do
    headers = %{"authorization" => "Bearer #{access_token}"}

    case Req.get(@userinfo_url, headers: headers) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, non_empty_binary(body["email"])}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case decode_json_body(body) do
          {:ok, decoded} -> {:ok, non_empty_binary(decoded["email"])}
          :error -> {:ok, nil}
        end

      {:ok, %Req.Response{}} ->
        {:ok, nil}

      {:error, _reason} ->
        {:ok, nil}
    end
  end

  defp fetch_user_email(_), do: {:ok, nil}

  defp post_code_assist(url, access_token, body) when is_binary(url) and is_map(body) do
    headers =
      @code_assist_headers
      |> Map.put("Authorization", "Bearer #{access_token}")
      |> Map.put("Content-Type", "application/json")

    case Req.post(url, headers: headers, json: body) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_code_assist(url, access_token) when is_binary(url) do
    headers =
      @code_assist_headers
      |> Map.put("Authorization", "Bearer #{access_token}")

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp code_assist_metadata(project_id, include_project? \\ true) do
    %{
      "ideType" => "IDE_UNSPECIFIED",
      "platform" => "PLATFORM_UNSPECIFIED",
      "pluginType" => "GEMINI"
    }
    |> maybe_put("duetProject", if(include_project?, do: project_id, else: nil))
  end

  defp pick_onboard_tier_id(allowed_tiers) when is_list(allowed_tiers) do
    tier =
      Enum.find(allowed_tiers, fn tier ->
        truthy?(Map.get(tier, "isDefault") || Map.get(tier, :isDefault))
      end) || List.first(allowed_tiers)

    tier_id =
      tier &&
        (Map.get(tier, "id") || Map.get(tier, :id))
        |> normalize_project_id()

    {:ok, tier_id || @legacy_tier_id}
  end

  defp pick_onboard_tier_id(_), do: {:ok, @legacy_tier_id}

  defp ensure_project_allowed_for_tier(@free_tier_id, _project_id), do: :ok

  defp ensure_project_allowed_for_tier(_tier_id, project_id)
       when is_binary(project_id) and project_id != "",
       do: :ok

  defp ensure_project_allowed_for_tier(_tier_id, _project_id),
    do: {:error, project_required_message()}

  defp maybe_raise_validation_error(ineligible_tiers) when is_list(ineligible_tiers) do
    validation_tier =
      Enum.find(ineligible_tiers, fn tier ->
        try do
          reason_code =
            tier
            |> Map.get("reasonCode", Map.get(tier, :reasonCode))
            |> to_string()
            |> String.upcase()

          reason_code == "VALIDATION_REQUIRED" and
            is_binary(Map.get(tier, "validationUrl") || Map.get(tier, :validationUrl))
        rescue
          _ -> false
        end
      end)

    case validation_tier do
      nil ->
        :ok

      tier ->
        message =
          [
            normalize_project_id(Map.get(tier, "reasonMessage") || Map.get(tier, :reasonMessage)),
            normalize_project_id(Map.get(tier, "validationUrl") || Map.get(tier, :validationUrl))
            |> then(fn
              nil -> nil
              url -> "Complete validation: #{url}"
            end),
            normalize_project_id(
              Map.get(tier, "validationLearnMoreUrl") || Map.get(tier, :validationLearnMoreUrl)
            )
            |> then(fn
              nil -> nil
              url -> "Learn more: #{url}"
            end)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {:error, if(message == "", do: "Google account validation is required.", else: message)}
    end
  end

  defp maybe_raise_validation_error(_), do: :ok

  defp vpc_sc_error?(payload) when is_map(payload) do
    payload
    |> get_in(["error", "details"])
    |> case do
      details when is_list(details) ->
        Enum.any?(details, fn
          %{"reason" => "SECURITY_POLICY_VIOLATED"} -> true
          %{reason: "SECURITY_POLICY_VIOLATED"} -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp vpc_sc_error?(_), do: false

  defp put_project_fields(secret, configured_project_id, managed_project_id, effective_project_id) do
    secret
    |> maybe_put("configured_project_id", configured_project_id)
    |> maybe_put("managed_project_id", managed_project_id)
    |> maybe_put("project_id", effective_project_id)
    |> maybe_put("projectId", effective_project_id)
    |> Map.put("updated_at_ms", System.system_time(:millisecond))
  end

  defp project_fields_changed?(before, updated) do
    keys = ["configured_project_id", "managed_project_id", "project_id", "projectId"]
    Enum.any?(keys, &(Map.get(before, &1) != Map.get(updated, &1)))
  end

  defp access_token_from_secret(secret), do: non_empty_binary(secret["access_token"])

  defp configured_project_id_from_secret(secret) when is_map(secret) do
    non_empty_binary(secret["configured_project_id"]) ||
      non_empty_binary(secret["configuredProjectId"])
  end

  defp managed_project_id_from_secret(secret) when is_map(secret) do
    non_empty_binary(secret["managed_project_id"]) ||
      non_empty_binary(secret["managedProjectId"])
  end

  defp project_id_from_secret(secret) when is_map(secret) do
    non_empty_binary(secret["project_id"]) ||
      non_empty_binary(secret["projectId"]) ||
      managed_project_id_from_secret(secret) ||
      configured_project_id_from_secret(secret)
  end

  defp resolve_configured_project_id(opts) when is_list(opts) do
    opts[:project_id] ||
      System.get_env("LEMON_GEMINI_PROJECT_ID") ||
      System.get_env("GOOGLE_CLOUD_PROJECT") ||
      System.get_env("GOOGLE_CLOUD_PROJECT_ID") ||
      System.get_env("GCLOUD_PROJECT")
      |> normalize_project_id()
  end

  defp normalize_project_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_project_id(%{"id" => id}), do: normalize_project_id(id)
  defp normalize_project_id(%{id: id}), do: normalize_project_id(id)
  defp normalize_project_id(_), do: nil

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> :error
    end
  end

  defp decode_json_body(%{} = body), do: {:ok, body}
  defp decode_json_body(_), do: :error

  defp resolve_client_credential(secret_names, env_name, default_value)
       when is_list(secret_names) do
    Enum.find_value(secret_names, &non_empty_binary(System.get_env(&1))) ||
      non_empty_binary(System.get_env(env_name)) ||
      default_value
  end

  defp auth_instructions(_redirect_uri, nil) do
    "After browser sign-in, paste the callback URL from the address bar (it includes the state)."
  end

  defp auth_instructions(redirect_uri, _listener) do
    "After browser sign-in, the local callback listener will capture the redirect to #{redirect_uri} automatically."
  end

  defp project_required_message do
    "Google Gemini CLI requires a Google Cloud project. Enable the Gemini for Google Cloud API on a project you control, then rerun onboarding with --project-id <gcp-project-id>."
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("TRUE"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
