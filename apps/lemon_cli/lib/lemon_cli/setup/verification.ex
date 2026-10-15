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
       - live credentials resolve through the native credential owner, including
         selected-login authority and credential-pool/default policy
       - optionally a lightweight live request against the provider's
         OpenAI-compatible `GET {base_url}/models` endpoint

     Live checks are opt-in and injectable (`:verifier`), so tests run
     without network and offline users can pass `--skip-verify`.

  This module is deliberately Mix-free: the packaged `lemon setup` command
  and `LemonCli.CLI`'s first-run readiness gate reuse the same derivation
  instead of a second implementation.
  """

  alias LemonAgent.ModelRuntime.{Credentials, CustomProviders, ProviderNames}
  alias LemonAi.Models
  alias LemonAi.Providers.RequestHeaders
  alias LemonCore.Config
  alias LemonCore.Config.{Agent, LegacyAgentMigration, Modular, Providers}
  alias LemonCore.Setup.Readiness

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
    * `:config` - full effective runtime config (including credential routing);
      otherwise loaded from the selected file with canonical environment overrides
    * `:verification_model` - resolved model for that config and default identity
    * `:verifier` - injectable live-check function of one map argument
      (`%{provider:, model:, base_url:, api_key:}`) returning `{:ok, map}`,
      `{:error, reason}`, or `{:skip, reason}`. Defaults to the built-in
      `GET {base_url}/models` request.
    * `:skip_verify` - skip the live check entirely (offline use)
  """
  @spec verify_provider(keyword()) :: {:ok, verify_ok()} | {:error, verify_failure()}
  def verify_provider(opts \\ []) do
    config = Keyword.get(opts, :config) || effective_config(opts)
    provider_state = effective_provider_state(setup_state(opts).provider, config)
    opts = bind_verification_options(opts, config, provider_state)

    with :ok <- assert_provider_complete(provider_state, opts) do
      run_live_check(provider_state, opts)
    end
  end

  @doc """
  Binds setup verification to the effective config and concrete default model.

  Setup callers use this after onboarding has written its config. A custom
  `:config_path` selects that file; the global path uses the normal global/project
  merge. Both paths apply the canonical environment overrides. This does not
  discover models or resolve credentials for an explicitly skipped live check.
  """
  @spec verification_options(keyword()) :: keyword()
  def verification_options(opts \\ []) do
    config = Keyword.get(opts, :config) || effective_config(opts)
    provider_state = effective_provider_state(setup_state(opts).provider, config)
    bind_verification_options(opts, config, provider_state)
  end

  defp bind_verification_options(opts, config, provider_state) do
    model =
      unless Keyword.get(opts, :skip_verify, false) do
        Keyword.get(opts, :verification_model) ||
          effective_model(config, provider_state.provider, provider_state.model)
      end

    opts
    |> Keyword.put(:config, config)
    |> Keyword.put(:verification_model, model)
  end

  # Local readiness only proves storage availability. Live verification must
  # resolve the selected credential even when local readiness has no usable ref.
  defp assert_provider_complete(%{provider: provider, reason: :credential_not_usable}, opts) do
    config = Keyword.fetch!(opts, :config)
    keyless? = Readiness.keyless_provider?(provider, provider_config(config, provider))

    if Keyword.get(opts, :skip_verify, false) and not keyless?,
      do: provider_failure(provider, :credential_not_usable),
      else: :ok
  end

  defp assert_provider_complete(%{complete: true}, _opts), do: :ok

  defp assert_provider_complete(%{provider: provider, reason: reason}, _opts) do
    provider_failure(provider, reason)
  end

  defp provider_failure(provider, reason) do
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

  defp provider_failure_message(provider, _reason),
    do:
      "Provider configuration for #{provider || "the default provider"} is incomplete. " <>
        "Run `lemon setup provider --set-default` to configure it."

  defp run_live_check(%{provider: provider, model: model}, opts) do
    skip_verify? = Keyword.get(opts, :skip_verify, false)

    if skip_verify? do
      {:ok, %{provider: provider, model: model, live: :disabled}}
    else
      verifier = Keyword.get(opts, :verifier) || (&LemonCli.ProviderLiveCheck.check/1)

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
                 message: LemonCli.ProviderLiveCheck.failure_message(reason)
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

        {:error, reason} ->
          provider_failure(provider, reason)
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

  @doc "Builds the default provider probe using setup's canonical credential and model resolution."
  @spec live_input(keyword()) :: {:ok, map()} | {:skip, term()} | {:error, term()}
  def live_input(opts \\ []) do
    config = Keyword.get(opts, :config) || effective_config(opts)
    provider = config.agent[:default_provider]
    model = config.agent[:default_model]

    resolved = Keyword.get(opts, :verification_model) || effective_model(config, provider, model)
    provider_cfg = provider_config(config, provider)

    cond do
      is_nil(provider) or is_nil(model) or is_nil(resolved) ->
        {:skip, :unknown_model}

      Keyword.get(opts, :non_generating, false) and
          (Credentials.oauth_selected?(provider_cfg) or
             resolved.api not in [
               :openai_completions,
               :openai_responses,
               :anthropic_messages,
               :google_generative_ai
             ]) ->
        {:skip, {:unsupported_api, resolved.api}}

      true ->
        opts = opts |> Keyword.put(:config, config) |> Keyword.put(:verification_model, resolved)
        build_live_input(opts, provider, model)
    end
  end

  defp build_live_input(opts, provider, model) do
    config = Keyword.fetch!(opts, :config)
    provider_cfg = provider_config(config, provider)
    resolved_model = Keyword.get(opts, :verification_model)

    with {:ok, api_key} <- fetch_live_credential(config, provider, provider_cfg),
         {:ok, resolved_model} <- fetch_effective_model(resolved_model, provider, model) do
      keyless? =
        Readiness.keyless_provider?(provider, provider_cfg) ||
          Map.get(resolved_model.compat || %{}, :allow_missing_api_key, false)

      if is_nil(api_key) and not keyless? do
        {:error, :credential_not_usable}
      else
        {:ok,
         %{
           provider: provider,
           model: model,
           api: resolved_model.api,
           base_url: resolved_model.base_url,
           api_key: api_key,
           headers: resolved_model.headers || %{}
         }}
      end
    end
  end

  defp fetch_live_credential(config, provider, provider_cfg) do
    key = Credentials.build_get_api_key(config).(provider)

    cond do
      normalize_optional_string(key) -> {:ok, key}
      Credentials.oauth_selected?(provider_cfg) -> {:error, :credential_not_usable}
      true -> {:ok, nil}
    end
  end

  defp fetch_effective_model(nil, _provider, _model), do: {:skip, :unknown_model}

  defp fetch_effective_model(resolved_model, provider, model) do
    model_id = model |> String.split(":", parts: 2) |> List.last()

    if normalize_provider_name(to_string(resolved_model.provider)) ==
         normalize_provider_name(provider) and resolved_model.id == model_id,
       do: {:ok, resolved_model},
       else: {:error, :model_provider_mismatch}
  end

  defp effective_model(_config, nil, _model), do: nil
  defp effective_model(_config, _provider, nil), do: nil

  defp effective_model(config, provider, model) do
    model_id = model |> String.split(":", parts: 2) |> List.last()
    registry_provider = registry_provider_atom(provider)

    resolved_model =
      CustomProviders.lookup(config, provider, model_id) ||
        (registry_provider && Models.get_model(registry_provider, model_id))

    if resolved_model do
      provider_cfg = provider_config(config, provider)

      %{
        resolved_model
        | base_url: CustomProviders.base_url(provider_cfg) || resolved_model.base_url,
          headers:
            CustomProviders.headers(provider_cfg)
            |> RequestHeaders.merge(resolved_model.headers)
      }
    end
  end

  defp provider_config(config, provider) do
    ProviderNames.provider_config(config, provider) ||
      CustomProviders.config_for(config, provider) || %{}
  end

  defp registry_provider_atom(provider) do
    ProviderNames.provider_atom(provider) ||
      Enum.find(Models.get_providers(), fn registry_provider ->
        normalize_provider_name(Atom.to_string(registry_provider)) ==
          normalize_provider_name(provider)
      end)
  end

  defp format_live_reason(reason), do: LemonCli.ProviderLiveCheck.format_reason(reason)

  # ──────────────────────────────────────────────────────────────────────────
  # Shared helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp config_path(opts),
    do: Keyword.get(opts, :config_path) || Modular.global_path()

  defp read_settings(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Toml.decode(content) do
      decoded
    else
      _ -> %{}
    end
  end

  defp effective_config(opts) do
    path = config_path(opts)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    if Path.expand(path) == Path.expand(Modular.global_path()) do
      Config.load(cwd, cache: false)
    else
      settings = path |> read_settings() |> LegacyAgentMigration.migrate_settings()

      %{
        providers: Providers.resolve(settings).providers,
        agent: settings |> Agent.resolve() |> Map.from_struct()
      }
    end
  end

  defp effective_provider_state(state, config) do
    agent = Map.get(config, :agent) || %{}

    # Do not turn implicit runtime defaults into newly completed setup steps.
    provider =
      state.provider && (normalize_optional_string(agent[:default_provider]) || state.provider)

    model = state.model && (normalize_optional_string(agent[:default_model]) || state.model)

    mismatch? =
      case provider && model && String.split(model, ":", parts: 2) do
        [prefix, _id] -> normalize_provider_name(prefix) != normalize_provider_name(provider)
        _ -> false
      end

    reason =
      cond do
        is_nil(provider) -> :missing_default_provider
        is_nil(model) -> :missing_default_model
        mismatch? -> :model_provider_mismatch
        not state.credential_ready -> :credential_not_usable
        true -> nil
      end

    %{state | provider: provider, model: model, reason: reason, complete: is_nil(reason)}
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_provider_name(value) when is_binary(value) do
    (ProviderNames.config_name(value) || value)
    |> String.downcase()
    |> String.replace("_", "-")
  end
end
