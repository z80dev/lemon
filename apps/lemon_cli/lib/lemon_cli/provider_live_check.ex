defmodule LemonCli.ProviderLiveCheck do
  @moduledoc "Shared, non-generating provider connectivity check for setup and doctor."

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAi.Auth.KimiCodeOAuth
  alias LemonAi.Providers.RequestHeaders
  alias LemonCore.Doctor.Connectivity

  @openai_apis [:openai_completions, :openai_responses]
  # Codex discovery lists an account's models; the wire contract bounds the list.
  @max_model_ids 64

  @doc """
  Runs one non-generating provider check.

  Codex ChatGPT providers use authenticated model discovery (`:codex_discover`
  injects it); every other supported API uses its models endpoint. The check
  never sends a message and never returns credential material.
  """
  @spec check(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:skip, term()}
  def check(input, opts \\ [])

  def check(%{api: :openai_codex_responses} = input, opts) do
    discover_fn =
      Keyword.get(opts, :codex_discover) ||
        (&LemonAi.Models.OpenAICodexDiscovery.discover/1)

    timeout_ms = if Keyword.get(opts, :extended, false), do: 10_000, else: 5_000

    discover_opts = [
      access_token: input[:api_key],
      base_url: input[:base_url],
      timeout_ms: timeout_ms,
      force_refresh: true
    ]

    case discover_fn.(discover_opts) do
      {:ok, models} ->
        ids =
          models
          |> Enum.map(& &1.id)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.take(@max_model_ids)

        target_model = input[:model_id]

        if input[:probe?] == true or is_nil(target_model) or target_model in ids do
          {:ok, %{check: :codex_discovery, model_ids: ids}}
        else
          {:error, {:model_unavailable, ids}}
        end

      {:error, {:authentication_rejected, _}} ->
        {:error, {:unauthorized, :openai_codex}}

      {:error, :transport_failure} ->
        {:error, :unreachable}

      {:error, reason}
      when reason in [:invalid_chatgpt_access_token, :missing_chatgpt_credentials] ->
        {:error, :credential_not_usable}

      {:error, reason} ->
        {:error, {:check_failed, reason}}
    end
  end

  def check(input, opts) do
    with {:ok, url, auth} <- endpoint(input, Keyword.get(opts, :extended, false)),
         {:ok, info} <- Connectivity.get(url, RequestHeaders.merge(auth, input.headers), opts) do
      {:ok, Map.take(info, [:http_status]) |> Map.put(:check, :models_endpoint)}
    else
      {:error, :timeout} ->
        if Keyword.get(opts, :extended, false),
          do: {:error, :timeout},
          else: {:error, :unreachable}

      result ->
        result
    end
  end

  defp endpoint(%{api: api} = input, _) when api in @openai_apis do
    auth = if input.api_key, do: %{"authorization" => "Bearer " <> input.api_key}, else: %{}
    {:ok, models_url(input.base_url), auth}
  end

  defp endpoint(%{api: :anthropic_messages} = input, true) do
    base = String.trim_trailing(input.base_url, "/")
    base = if String.ends_with?(base, "/v1"), do: base, else: base <> "/v1"
    {:ok, models_url(base), anthropic_auth(input)}
  end

  defp endpoint(%{api: :google_generative_ai} = input, true) do
    {:ok, models_url(input.base_url), %{"x-goog-api-key" => input.api_key}}
  end

  defp endpoint(%{api: api}, _), do: {:skip, {:unsupported_api, api}}

  # Kimi Code authenticates as model requests do: a subscription token (JWT)
  # as a bearer, an API key as x-api-key, and always the Kimi CLI fingerprint.
  defp anthropic_auth(input) do
    cond do
      ProviderNames.canonical_name(Map.get(input, :provider)) != "kimi_coding" ->
        %{"x-api-key" => input.api_key, "anthropic-version" => "2023-06-01"}

      KimiCodeOAuth.oauth_token?(input.api_key) ->
        RequestHeaders.merge(
          %{"authorization" => "Bearer " <> input.api_key},
          KimiCodeOAuth.request_headers()
        )

      true ->
        RequestHeaders.merge(
          %{"x-api-key" => input.api_key, "anthropic-version" => "2023-06-01"},
          KimiCodeOAuth.request_headers()
        )
    end
  end

  defp models_url(base_url), do: String.trim_trailing(base_url, "/") <> "/models"

  @doc "Setup recovery text shared with doctor; arbitrary provider errors are never interpolated."
  @spec failure_message(term()) :: String.t()
  def failure_message({:unauthorized, :openai_codex}) do
    "Your ChatGPT login was rejected. Run `lemon setup model` to sign in again."
  end

  def failure_message(:unauthorized) do
    "The provider rejected the credential (HTTP 401/403). Re-run `lemon setup provider` " <>
      "to store a valid credential, or use --skip-verify to defer this check."
  end

  def failure_message({:unauthorized, _}) do
    "The provider rejected the credential (HTTP 401/403). Re-run `lemon setup provider` " <>
      "to store a valid credential, or use --skip-verify to defer this check."
  end

  def failure_message({:model_unavailable, ids}) do
    "Your ChatGPT account doesn't offer the configured model. Available: #{available(ids)}. " <>
      "Run `lemon setup model` to pick one."
  end

  def failure_message({:check_failed, reason}) do
    "Provider verification failed: check failed (#{format_reason(reason)}). " <>
      "Re-run `lemon setup provider` to fix the configuration, or use --skip-verify to defer."
  end

  def failure_message(:credential_not_usable) do
    "Provider verification failed: the provider credential is not usable. " <>
      "Re-run `lemon setup provider` to fix the configuration, or use --skip-verify to defer."
  end

  def failure_message(:unreachable) do
    "Could not reach the provider's models endpoint. Check your network and retry, " <>
      "or re-run with --skip-verify when offline."
  end

  def failure_message(:timeout),
    do: "The provider's models endpoint timed out. Check your network and retry."

  def failure_message({:http_status, status}) do
    "The provider's models endpoint returned HTTP #{status}. Check the provider status " <>
      "and your credential, or re-run with --skip-verify to defer this check."
  end

  def failure_message(reason) do
    "Provider verification failed: #{format_reason(reason)}. " <>
      "Re-run `lemon setup provider` to fix the configuration, or use --skip-verify to defer."
  end

  @doc "Doctor recovery text for the same failure kinds as setup."
  @spec doctor_failure_message(term()) :: String.t()
  def doctor_failure_message({:unauthorized, :openai_codex}),
    do: "Your ChatGPT login was rejected. Run `lemon setup model` to sign in again."

  def doctor_failure_message(:unauthorized),
    do: "The provider rejected the credential (HTTP 401/403). Re-run `lemon setup provider`."

  def doctor_failure_message({:unauthorized, _}),
    do: "The provider rejected the credential (HTTP 401/403). Re-run `lemon setup provider`."

  def doctor_failure_message({:model_unavailable, ids}),
    do:
      "Your ChatGPT account doesn't offer the configured model. Available: #{available(ids)}. " <>
        "Run `lemon setup model` to pick one."

  def doctor_failure_message({:check_failed, reason}),
    do: "Provider check failed (#{format_reason(reason)}). Re-run `lemon setup provider`."

  def doctor_failure_message(:credential_not_usable),
    do:
      "Provider verification failed: the provider credential is not usable. " <>
        "Re-run `lemon setup provider`."

  def doctor_failure_message(:unreachable),
    do: "Could not reach the provider's models endpoint. Check your network and retry."

  def doctor_failure_message(:timeout), do: failure_message(:timeout)

  def doctor_failure_message({:http_status, status}),
    do:
      "The provider's models endpoint returned HTTP #{status}. Check provider status and credentials."

  def doctor_failure_message(_),
    do: "Provider verification failed. Re-run `lemon setup provider`."

  @doc false
  @spec format_reason(term()) :: String.t()
  def format_reason({:model_unavailable, _}), do: "the model is not available for this account"
  def format_reason({:unauthorized, :openai_codex}), do: "ChatGPT login was rejected"
  def format_reason({:unauthorized, _}), do: "the provider rejected the credential"
  def format_reason({:check_failed, reason}), do: "check failed: #{format_reason(reason)}"
  def format_reason(:credential_not_usable), do: "the provider credential is not usable"
  def format_reason(:unreachable), do: "the provider is unreachable"
  def format_reason(:timeout), do: "the request timed out"
  def format_reason({:http_error, status}), do: "HTTP #{status}"
  def format_reason(:invalid_discovery_response), do: "an invalid discovery response"
  def format_reason(:no_discovery_endpoint), do: "no discovery endpoint"
  def format_reason(:discovery_cache_unavailable), do: "the discovery cache is unavailable"
  def format_reason(:invalid_chatgpt_access_token), do: "an invalid ChatGPT access token"
  def format_reason(:missing_chatgpt_credentials), do: "missing ChatGPT credentials"
  def format_reason(:transport_failure), do: "a transport failure"
  def format_reason(:unknown_model), do: "the configured model could not be resolved"
  def format_reason(:offline), do: "the provider is offline"
  def format_reason(:no_reference), do: "no saved key is configured for this provider"
  def format_reason({:credential_unavailable, _}), do: "the provider credential is unavailable"

  def format_reason({:unsupported_api, _}),
    do: "this provider does not support a lightweight live check"

  def format_reason(_), do: "the live check is unavailable"

  defp available([_ | _] = ids), do: Enum.join(ids, ", ")
  defp available(_), do: "none"
end
