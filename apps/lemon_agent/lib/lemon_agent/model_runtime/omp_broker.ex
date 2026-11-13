defmodule LemonAgent.ModelRuntime.OmpBroker do
  @moduledoc """
  Provider credentials from omp's auth broker (`auth_source = "omp_broker"`).

  The broker (`omp auth-broker serve`) holds the canonical credential vault and
  performs every OAuth refresh. Lemon reads access tokens and API keys from its
  redacted snapshot through `LemonAi.Auth.OmpAuthBroker`; refresh tokens never
  reach Lemon and nothing is written to Lemon's secret store.

  ## Endpoint

  Resolved like omp's own client, without reading omp's `config.yml`:

    * URL: `OMP_AUTH_BROKER_URL` (environment, else a Lemon secret of that name),
      default `http://127.0.0.1:8765` (`omp auth-broker serve`'s default bind).
    * Token: `OMP_AUTH_BROKER_TOKEN` (environment, else a Lemon secret of that
      name), else omp's `<config root>/auth-broker.token`
      (`LemonAi.Auth.OmpConfig`).

  ## Provider config

    * `omp_provider` - the omp provider id to read. Defaults to the Lemon
      provider name with dashes (`openai_codex` -> `openai-codex`) and a few
      renames (`kimi_coding` -> `kimi-code`, `kimi` -> `moonshot`, `opencode` ->
      `opencode-zen`). Custom providers must set it.
    * `omp_account` - an OAuth `identityKey` (as listed by
      `omp usage accounts`). Only that account is used; API keys are not.

  Credentials are shaped for Lemon's provider modules: Gemini CLI and
  Antigravity receive `{"token","projectId"}` JSON, every other provider the
  access token or API key. GitHub Copilot OAuth credentials are not supported
  (omp stores the GitHub token, Lemon's Copilot provider expects its own
  exchange) and fail closed.
  """

  require Logger

  alias LemonAi.Auth.{OmpAuthBroker, OmpConfig}
  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonCore.Secrets

  @default_url "http://127.0.0.1:8765"

  @omp_provider_overrides %{
    "kimi_coding" => "kimi-code",
    "kimi" => "moonshot",
    "opencode" => "opencode-zen"
  }

  @project_json_providers ["google_gemini_cli", "google_antigravity"]

  @doc "The broker endpoint (`%{url, token}`) from environment, secrets and omp's token file."
  @spec endpoint() :: {:ok, OmpAuthBroker.endpoint()} | {:error, atom()}
  def endpoint do
    url = secret_env("OMP_AUTH_BROKER_URL") || @default_url

    case secret_env("OMP_AUTH_BROKER_TOKEN") || OmpConfig.read_token(:broker) do
      nil -> {:error, :missing_broker_token}
      token -> {:ok, %{url: url, token: token}}
    end
  end

  @doc "The omp provider id for a Lemon provider and its config, or `nil`."
  @spec omp_provider(atom() | String.t(), map() | nil) :: String.t() | nil
  def omp_provider(provider, provider_cfg) do
    case config_value(provider_cfg, :omp_provider) do
      configured when is_binary(configured) ->
        configured

      nil ->
        case ProviderNames.canonical_name(provider) do
          nil ->
            nil

          canonical ->
            Map.get(@omp_provider_overrides, canonical, String.replace(canonical, "_", "-"))
        end
    end
  end

  @doc """
  The API key Lemon sends for `provider`, or `{:error, reason}` with a bare,
  credential-free atom.
  """
  @spec api_key(atom() | String.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def api_key(provider, provider_cfg, opts \\ []) do
    with {:ok, omp_provider} <- require_omp_provider(provider, provider_cfg),
         {:ok, endpoint} <- endpoint(),
         {:ok, entry} <-
           OmpAuthBroker.credential(endpoint, omp_provider, broker_opts(provider_cfg, opts)) do
      shape(provider, entry)
    end
  end

  @doc """
  Recovers after the provider rejected `previous_key` (for example HTTP 401).

  Re-reads a fresh snapshot first, so a token the broker already rotated is
  adopted without a refresh; otherwise asks the broker to refresh the selected
  OAuth credential with `reason=auth-recovery`. API keys are not refreshable,
  and a refresh that returns the rejected key again fails.
  """
  @spec recover(atom() | String.t(), map() | nil, String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def recover(provider, provider_cfg, previous_key, opts \\ []) do
    broker_opts = provider_cfg |> broker_opts(opts) |> Keyword.put(:fresh, true)

    with {:ok, omp_provider} <- require_omp_provider(provider, provider_cfg),
         {:ok, endpoint} <- endpoint(),
         {:ok, entry} <- OmpAuthBroker.credential(endpoint, omp_provider, broker_opts),
         {:ok, current} <- shape(provider, entry) do
      cond do
        current != previous_key ->
          {:ok, current}

        entry.credential.type != :oauth ->
          {:error, :not_refreshable}

        true ->
          refresh_opts = Keyword.put(broker_opts, :reason, "auth-recovery")

          with {:ok, refreshed} <- OmpAuthBroker.refresh(endpoint, entry.id, refresh_opts),
               {:ok, fresh} <- shape(provider, refreshed) do
            if fresh == previous_key, do: {:error, :refresh_rejected}, else: {:ok, fresh}
          end
      end
    end
  end

  @doc "Credential-free operator guidance for an error from this module."
  @spec error_message(atom()) :: String.t()
  def error_message(:missing_omp_provider),
    do: "set omp_provider to the omp provider id whose broker credential this provider uses."

  def error_message(:unsupported_credential),
    do: "omp auth broker OAuth credentials for this provider are not supported by Lemon."

  def error_message(:missing_project),
    do: "the omp auth broker credential has no Google project id; sign in again with omp."

  def error_message(:refresh_rejected),
    do: "the omp auth broker returned the rejected token again."

  def error_message(reason), do: OmpAuthBroker.error_message(reason)

  defp require_omp_provider(provider, provider_cfg) do
    case omp_provider(provider, provider_cfg) do
      nil -> {:error, :missing_omp_provider}
      omp_provider -> {:ok, omp_provider}
    end
  end

  defp broker_opts(provider_cfg, opts) do
    case config_value(provider_cfg, :omp_account) do
      nil -> opts
      account -> Keyword.put(opts, :account, account)
    end
  end

  defp shape(_provider, %{credential: %{type: :api_key, key: key}}), do: {:ok, key}

  defp shape(provider, %{credential: %{type: :oauth} = credential}) do
    case ProviderNames.canonical_name(provider) do
      canonical when canonical in @project_json_providers ->
        case credential.project_id do
          nil ->
            {:error, :missing_project}

          project_id ->
            {:ok, Jason.encode!(%{"token" => credential.access, "projectId" => project_id})}
        end

      "github_copilot" ->
        {:error, :unsupported_credential}

      _ ->
        {:ok, credential.access}
    end
  end

  # An environment variable wins, then a same-named Lemon secret.
  defp secret_env(name) do
    case Secrets.resolve(name, prefer_env: true, env_fallback: true) do
      {:ok, value, _source} when is_binary(value) -> non_empty(value)
      _ -> nil
    end
  rescue
    _ -> non_empty(System.get_env(name))
  catch
    :exit, _ -> non_empty(System.get_env(name))
  end

  defp config_value(cfg, key) when is_map(cfg),
    do: non_empty(Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key)))

  defp config_value(_, _), do: nil

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp non_empty(_), do: nil

  @doc false
  def log_failure(provider, reason) do
    Logger.warning(
      "omp auth broker credential for #{ProviderNames.canonical_name(provider) || to_string(provider)} " <>
        "unavailable: " <> error_message(reason)
    )
  end
end
