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

  ## Accounts and rate limits

  `api_keys/3` lists every broker account for the provider so Lemon can rotate
  between them. When a provider rate-limits one, `report_block/4` tells the
  broker (`POST /v1/credential/:id/block`, catch-all scope) so every client
  moves to the next account; Lemon retries the same turn on the next account
  instead of failing over to another provider.
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
  and a refresh that returns the rejected key again fails. Pass `id: id` to
  recover exactly that broker credential instead of the selected one.
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
          refresh_opts =
            broker_opts |> Keyword.delete(:id) |> Keyword.put(:reason, "auth-recovery")

          with {:ok, refreshed} <- OmpAuthBroker.refresh(endpoint, entry.id, refresh_opts),
               {:ok, fresh} <- shape(provider, refreshed) do
            if fresh == previous_key, do: {:error, :refresh_rejected}, else: {:ok, fresh}
          end
      end
    end
  end

  @doc """
  Every broker credential for `provider` as `{id, key}`, in the broker's
  selection order (`OmpAuthBroker.credentials/3`: OAuth before API keys,
  unblocked before rate-limit-blocked, then id), honouring `omp_account`.

  Each is freshened and shaped like `api_key/3`. A credential that cannot be
  freshened or shaped (for example an unsupported OAuth type) is skipped;
  when none succeed the last error is returned.
  """
  @spec api_keys(atom() | String.t(), map() | nil, keyword()) ::
          {:ok, [{integer(), String.t()}]} | {:error, atom()}
  def api_keys(provider, provider_cfg, opts \\ []) do
    broker_opts = broker_opts(provider_cfg, opts)

    with {:ok, omp_provider} <- require_omp_provider(provider, provider_cfg),
         {:ok, endpoint} <- endpoint(),
         {:ok, entries} <- OmpAuthBroker.credentials(endpoint, omp_provider, broker_opts) do
      {keys, errors} =
        Enum.reduce(entries, {[], []}, fn entry, {keys, errors} ->
          with {:ok, fresh} <-
                 OmpAuthBroker.credential(
                   endpoint,
                   omp_provider,
                   Keyword.put(broker_opts, :id, entry.id)
                 ),
               {:ok, key} <- shape(provider, fresh) do
            {[{entry.id, key} | keys], errors}
          else
            {:error, reason} -> {keys, [reason | errors]}
          end
        end)

      case {Enum.reverse(keys), errors} do
        {[], []} -> {:error, :no_credential}
        {[], [reason | _]} -> {:error, reason}
        {keys, _} -> {:ok, keys}
      end
    end
  end

  @doc """
  Reports to the broker that credential `id` is rate-limited until the
  wall-clock `blocked_until_ms` (epoch milliseconds), so the broker steers
  every client to its next account.

  Asynchronous: returns `:ok` immediately so failover never waits on the
  broker. A failure logs a credential-free warning.
  """
  @spec report_block(atom() | String.t(), map() | nil, integer(), integer()) :: :ok
  def report_block(provider, provider_cfg, id, blocked_until_ms)
      when is_integer(id) and is_integer(blocked_until_ms) do
    start = fn ->
      Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
        case block(provider, provider_cfg, id, blocked_until_ms) do
          :ok -> :ok
          {:error, reason} -> log_block_failure(provider, reason)
        end
      end)
    end

    try do
      start.()
    catch
      :exit, _ -> log_block_failure(provider, :broker_unreachable)
    end

    :ok
  end

  defp block(provider, provider_cfg, id, blocked_until_ms) do
    broker_opts = broker_opts(provider_cfg, [])

    with {:ok, omp_provider} <- require_omp_provider(provider, provider_cfg),
         {:ok, endpoint} <- endpoint(),
         {:ok, entries} <- OmpAuthBroker.credentials(endpoint, omp_provider, broker_opts),
         %{} = entry <- Enum.find(entries, &(&1.id == id)) || {:error, :no_credential} do
      OmpAuthBroker.block(
        endpoint,
        id,
        OmpAuthBroker.provider_key(entry),
        blocked_until_ms,
        broker_opts
      )
    end
  end

  defp log_block_failure(provider, reason) do
    Logger.warning(
      "omp auth broker rate-limit block for #{ProviderNames.canonical_name(provider) || to_string(provider)} " <>
        "not reported: " <> error_message(reason)
    )
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
