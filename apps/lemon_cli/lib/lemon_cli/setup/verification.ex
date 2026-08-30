defmodule LemonCli.Setup.Verification do
  @moduledoc """
  Setup state derivation and provider verification for the setup wizard.

  Two responsibilities:

  1. `setup_state/1` derives which setup steps (`:config`, `:secrets`,
     `:provider`) are complete by reading the same files and stores setup
     writes. It is read-only; the wizard re-derives state after every
     mutation, which is what makes rerunning setup idempotent.
  2. `verify_provider/1` validates the configured default provider, model,
     and credential with the strongest runtime-safe checks available:

       - the config resolves a default provider and a default model
       - the referenced credential source is usable — an inline `api_key`, or
         a secret reference that is actually decryptable from the encrypted
         store (falling back to a same-named environment variable, matching
         `LemonCore.Secrets.resolve/2`)
       - optionally a lightweight live request against the provider's
         OpenAI-compatible `GET {base_url}/models` endpoint

     Live checks are opt-in and injectable (`:verifier`), so tests run
     without network and offline users can pass `--skip-verify`.

  This module is deliberately Mix-free: the packaged `lemon setup` command
  and `LemonCli.CLI`'s first-run readiness gate reuse the same derivation
  instead of a second implementation.
  """

  alias LemonAi.Models
  alias LemonCore.Httpc
  alias LemonCore.Secrets
  alias LemonCore.Setup.Readiness

  @live_timeout_ms 5_000

  # Registry APIs that expose a lightweight, unauthenticated-cheap
  # `GET {base_url}/models` endpoint suitable for a setup smoke test.
  @live_check_apis [:openai_completions, :openai_responses]

  @type step :: Readiness.step()
  @type provider_state :: Readiness.provider_state()
  @type setup_state :: Readiness.setup_state()

  @type verify_ok :: %{
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:live) => :ok | :skipped | :disabled,
          optional(:live_note) => String.t()
        }

  @type verify_failure :: %{
          required(:step) => :provider | :live,
          required(:reason) => term(),
          required(:message) => String.t()
        }

  # ──────────────────────────────────────────────────────────────────────────
  # State derivation
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Derives the completed/pending state of the three core setup steps.

  ## Options

    * `:config_path` - config file to inspect (default: the global config)
  """
  @spec setup_state(keyword()) :: setup_state()
  def setup_state(opts \\ []), do: Readiness.status(opts)

  @doc """
  Returns the steps of `state` that are not complete yet.
  """
  @spec pending_steps(setup_state()) :: [step()]
  def pending_steps(state), do: Readiness.pending_steps(state)

  # ──────────────────────────────────────────────────────────────────────────
  # Provider verification
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Verifies the configured default provider, model, and credential.

  Runs the offline strong checks always; runs the live check (when the
  provider exposes a lightweight models endpoint) unless `:skip_verify` is
  set. A failed check returns `{:error, failure}` whose `:message` is
  actionable user-facing recovery text — callers must not report setup
  complete when this returns an error.

  ## Options

    * `:config_path` - config file to inspect (default: the global config)
    * `:verifier` - injectable live-check function of one map argument
      (`%{provider:, model:, base_url:, api_key:}`) returning `{:ok, map}`,
      `{:error, reason}`, or `{:skip, reason}`. Defaults to the built-in
      `GET {base_url}/models` request.
    * `:skip_verify` - skip the live check entirely (offline use)
  """
  @spec verify_provider(keyword()) :: {:ok, verify_ok()} | {:error, verify_failure()}
  def verify_provider(opts \\ []) do
    state = setup_state(opts)
    provider_state = state.provider

    with :ok <- assert_provider_complete(provider_state) do
      run_live_check(provider_state, opts)
    end
  end

  defp assert_provider_complete(%{complete: true}), do: :ok

  defp assert_provider_complete(%{provider: provider, reason: reason}) do
    {:error,
     %{
       step: :provider,
       reason: reason,
       message: provider_failure_message(provider, reason)
     }}
  end

  defp provider_failure_message(_provider, :missing_default_provider),
    do: "No default provider is configured. Run `lemon setup provider --set-default` to set one."

  defp provider_failure_message(_provider, :missing_default_model),
    do: "No default model is configured. Run `lemon setup provider --set-default` to set one."

  defp provider_failure_message(provider, :credential_not_usable),
    do:
      "The credentials referenced for #{provider || "the default provider"} are not usable " <>
        "(missing or undecryptable secret). Re-run `lemon setup provider` to store a fresh credential."

  defp provider_failure_message(_provider, :model_provider_mismatch),
    do:
      "The configured default model does not belong to the default provider. " <>
        "Run `lemon setup provider --set-default` to align them."

  defp provider_failure_message(provider, reason),
    do:
      "Provider configuration for #{provider || "the default provider"} is incomplete (#{inspect(reason)})."

  defp run_live_check(%{provider: provider, model: model}, opts) do
    skip_verify? = Keyword.get(opts, :skip_verify, false)

    if skip_verify? do
      {:ok, %{provider: provider, model: model, live: :disabled}}
    else
      verifier = Keyword.get(opts, :verifier) || (&default_live_check/1)

      case build_live_input(opts, provider, model) do
        {:ok, live_input} ->
          case verifier.(live_input) do
            {:ok, info} ->
              {:ok, %{provider: provider, model: model, live: :ok, live_note: live_note(info)}}

            {:skip, reason} ->
              {:ok,
               %{
                 provider: provider,
                 model: model,
                 live: :skipped,
                 live_note: "live check not available (#{format_live_reason(reason)})"
               }}

            {:error, reason} ->
              {:error,
               %{
                 step: :live,
                 reason: reason,
                 message: live_failure_message(live_input, reason)
               }}
          end

        {:skip, reason} ->
          {:ok,
           %{
             provider: provider,
             model: model,
             live: :skipped,
             live_note: "live check not available (#{format_live_reason(reason)})"
           }}
      end
    end
  end

  defp live_note(info) when is_map(info) do
    case Map.get(info, :http_status) do
      nil -> "live check passed"
      status -> "live check passed (HTTP #{status})"
    end
  end

  defp live_note(_), do: "live check passed"

  defp build_live_input(opts, provider, model) do
    settings = opts |> config_path() |> read_settings()
    provider_cfg = get_in(settings, ["providers", provider]) || %{}

    with {:ok, api_key} <- fetch_live_credential(provider_cfg),
         {:ok, registry_model} <- fetch_registry_model(provider, model) do
      {:ok,
       %{
         provider: provider,
         model: model,
         api: registry_model.api,
         base_url: registry_model.base_url,
         api_key: api_key
       }}
    end
  end

  defp fetch_live_credential(provider_cfg) when is_map(provider_cfg) do
    cond do
      inline = normalize_optional_string(provider_cfg["api_key"]) ->
        {:ok, inline}

      name =
          normalize_optional_string(
            provider_cfg["oauth_secret"] || provider_cfg["api_key_secret"]
          ) ->
        case Secrets.resolve(name, prefer_env: false) do
          {:ok, value, _source} -> {:ok, value}
          {:error, reason} -> {:skip, {:credential_unavailable, reason}}
        end

      true ->
        {:skip, {:credential_unavailable, :no_reference}}
    end
  end

  defp fetch_registry_model(provider, model) do
    model_id = model |> String.split(":", parts: 2) |> List.last()

    case registry_provider_atom(provider) do
      nil ->
        {:skip, {:unknown_provider, provider}}

      provider_atom ->
        case Models.get_model(provider_atom, model_id) do
          nil -> {:skip, {:unknown_model, model_id}}
          registry_model -> {:ok, registry_model}
        end
    end
  end

  defp registry_provider_atom(provider) do
    normalized = normalize_provider_name(provider)

    Models.get_providers()
    |> Enum.find(fn registry_provider ->
      registry_provider |> Atom.to_string() |> normalize_provider_name() == normalized
    end)
  end

  # Default live verifier: one lightweight GET against the provider's
  # OpenAI-compatible models endpoint. 2xx proves the credential is accepted;
  # 401/403 proves it is not; anything else is reported, never guessed.
  defp default_live_check(%{api: api, base_url: base_url, api_key: api_key}) do
    if api in @live_check_apis do
      url = String.trim_trailing(base_url, "/") <> "/models"

      request = {String.to_charlist(url), [{~c"authorization", ~c"Bearer #{api_key}"}]}
      ssl_opts = [verify: :verify_peer] |> maybe_put_cacerts()

      case Httpc.request(:get, request, [{:ssl, ssl_opts}, {:timeout, @live_timeout_ms}], []) do
        {:ok, {{_vsn, status, _phrase}, _headers, _body}} when status in 200..299 ->
          {:ok, %{http_status: status}}

        {:ok, {{_vsn, status, _phrase}, _headers, _body}} when status in [401, 403] ->
          {:error, :unauthorized}

        {:ok, {{_vsn, status, _phrase}, _headers, _body}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, {:unreachable, reason}}
      end
    else
      {:skip, {:unsupported_api, api}}
    end
  end

  # Same TLS posture as the gateway smoke tests: verify peers whenever the
  # runtime can provide CA certificates.
  defp maybe_put_cacerts(ssl_opts) do
    if function_exported?(:public_key, :cacerts_get, 0) do
      case apply(:public_key, :cacerts_get, []) do
        cacerts when is_list(cacerts) and cacerts != [] ->
          Keyword.put(ssl_opts, :cacerts, cacerts)

        _ ->
          ssl_opts
      end
    else
      ssl_opts
    end
  end

  defp live_failure_message(_live_input, :unauthorized) do
    "The provider rejected the credential (HTTP 401/403). Re-run `lemon setup provider` " <>
      "to store a valid credential, or use --skip-verify to defer this check."
  end

  defp live_failure_message(_live_input, {:unreachable, _reason}) do
    "Could not reach the provider's models endpoint. Check your network and retry, " <>
      "or re-run with --skip-verify when offline."
  end

  defp live_failure_message(_live_input, {:http_status, status}) do
    "The provider's models endpoint returned HTTP #{status}. Check the provider status " <>
      "and your credential, or re-run with --skip-verify to defer this check."
  end

  defp live_failure_message(_live_input, reason) do
    "Provider verification failed: #{format_live_reason(reason)}. " <>
      "Re-run `lemon setup provider` to fix the configuration, or use --skip-verify to defer."
  end

  defp format_live_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_live_reason({tag, detail}), do: "#{tag}: #{inspect(detail)}"
  defp format_live_reason(reason), do: inspect(reason)

  # ──────────────────────────────────────────────────────────────────────────
  # Shared helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp config_path(opts),
    do: Keyword.get(opts, :config_path) || LemonCore.Config.Modular.global_path()

  defp read_settings(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Toml.decode(content) do
      decoded
    else
      _ -> %{}
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_provider_name(value) when is_binary(value) do
    value |> String.downcase() |> String.replace("_", "-")
  end
end
