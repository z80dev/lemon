defmodule LemonCli.ProviderLiveCheck do
  @moduledoc "Shared, non-generating provider connectivity check for setup and doctor."

  alias LemonAi.Providers.RequestHeaders
  alias LemonCore.Doctor.Connectivity

  @openai_apis [:openai_completions, :openai_responses]

  @spec check(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:skip, term()}
  def check(input, opts \\ []) do
    with {:ok, url, auth} <- endpoint(input, Keyword.get(opts, :extended, false)),
         {:ok, info} <- Connectivity.get(url, RequestHeaders.merge(auth, input.headers), opts) do
      {:ok, Map.take(info, [:http_status])}
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
    {:ok, models_url(base), %{"x-api-key" => input.api_key, "anthropic-version" => "2023-06-01"}}
  end

  defp endpoint(%{api: :google_generative_ai} = input, true) do
    {:ok, models_url(input.base_url), %{"x-goog-api-key" => input.api_key}}
  end

  defp endpoint(%{api: api}, _), do: {:skip, {:unsupported_api, api}}

  defp models_url(base_url), do: String.trim_trailing(base_url, "/") <> "/models"

  @doc "Setup recovery text shared with doctor; arbitrary provider errors are never interpolated."
  @spec failure_message(term()) :: String.t()
  def failure_message(:unauthorized) do
    "The provider rejected the credential (HTTP 401/403). Re-run `lemon setup provider` " <>
      "to store a valid credential, or use --skip-verify to defer this check."
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
  def doctor_failure_message(:unauthorized),
    do: "The provider rejected the credential (HTTP 401/403). Re-run `lemon setup provider`."

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
  def format_reason(:unknown_model), do: "the configured model could not be resolved"
  def format_reason(:offline), do: "the provider is offline"
  def format_reason(:no_reference), do: "no saved key is configured for this provider"
  def format_reason({:credential_unavailable, _}), do: "the provider credential is unavailable"

  def format_reason({:unsupported_api, _}),
    do: "this provider does not support a lightweight live check"

  def format_reason(_), do: "the live check is unavailable"
end
