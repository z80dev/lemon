defmodule LemonCore.Setup.Readiness do
  @moduledoc """
  Derives the local first-run readiness state shared by every Lemon client.

  Readiness inspects the resolved global config, secrets backend and configured
  default provider/model without starting a runtime or making a model request.
  Credential readiness is the runtime's single presence-mode predicate
  (`LemonCore.CredentialReadiness`), shared with doctor, provider status and the
  CLI: it never decrypts a value, refreshes a login or runs external commands.

  This module reports three stable steps:

    * `:config` - the global config file exists
    * `:secrets` - a master key is configured, or external auth needs no local secret
    * `:provider` - a matching default provider/model has a usable credential

  Provider live verification remains the responsibility of `lemon setup` and
  `lemon doctor`; readiness never sends a model request.
  """

  alias LemonCore.Config.{LegacyAgentMigration, Modular, Providers}
  alias LemonCore.CredentialReadiness
  alias LemonCore.Config.Providers.AuthExtension
  alias LemonCore.Secrets

  @type step :: :config | :secrets | :provider

  @type provider_state :: %{
          required(:complete) => boolean(),
          required(:provider) => String.t() | nil,
          required(:model) => String.t() | nil,
          required(:credential_ready) => boolean(),
          required(:reason) =>
            nil
            | :missing_default_provider
            | :missing_default_model
            | :model_provider_mismatch
            | :credential_not_usable
        }

  @type setup_state :: %{
          required(:config) => %{required(:complete) => boolean(), required(:path) => String.t()},
          required(:secrets) => %{
            required(:complete) => boolean(),
            required(:source) => atom() | nil
          },
          required(:provider) => provider_state()
        }

  @doc """
  Derives the completed/pending state of the three core setup steps.

  ## Options

    * `:config_path` - config file to inspect (default: the global config)
  """
  @spec status(keyword()) :: setup_state()
  def status(opts \\ []) do
    config_path = Keyword.get(opts, :config_path) || Modular.global_path()
    expanded = Path.expand(config_path)
    settings = expanded |> read_settings() |> LegacyAgentMigration.migrate_settings()
    secrets_status = Secrets.status()
    provider = derive_provider(settings)
    external? = external_default?(settings)

    %{
      config: %{complete: File.exists?(expanded), path: expanded},
      secrets: %{
        complete: external? or secrets_status.configured == true,
        source: if(external?, do: :not_required, else: secrets_status.source)
      },
      provider: provider
    }
  end

  @doc "Returns the readiness steps that are not complete yet."
  @spec pending_steps(setup_state()) :: [step()]
  def pending_steps(state) do
    Enum.reject([:config, :secrets, :provider], &Map.fetch!(state, &1).complete)
  end

  @doc "Returns whether every first-run readiness step is complete."
  @spec ready?(setup_state()) :: boolean()
  def ready?(state), do: pending_steps(state) == []

  @doc """
  Whether a provider may run without credentials.

  Explicit `auth = "none"` endpoints and the keyless local presets qualify.
  The preset ids are kept here so core remains usable without lemon_ai.
  """
  @spec keyless_provider?(term(), map()) :: boolean()
  def keyless_provider?(provider, config) do
    auth = Map.get(config, :auth) || Map.get(config, "auth")

    Providers.canonical_auth(auth) == "none" or
      (is_binary(provider) and
         normalize_provider_name(provider) in ~w(ollama lm-studio lmstudio llama-cpp llama.cpp llamacpp vllm litellm lite-llm))
  end

  defp derive_provider(settings) do
    defaults = settings["defaults"] || %{}

    provider = normalize_optional_string(defaults["provider"])
    model = normalize_optional_string(defaults["model"])

    provider_cfg =
      provider &&
        Enum.find_value(settings["providers"] || %{}, fn {name, cfg} ->
          if normalize_provider_name(name) == normalize_provider_name(provider), do: cfg
        end)

    provider_cfg = if is_map(provider_cfg), do: provider_cfg, else: %{}

    {credential_ready?, credential_reason} = credential_state(provider, settings)

    reason =
      cond do
        is_nil(provider) ->
          :missing_default_provider

        is_nil(model) ->
          :missing_default_model

        not credential_ready? ->
          credential_reason || :credential_not_usable

        model_provider_mismatch?(provider, model, settings, provider_cfg) ->
          :model_provider_mismatch

        true ->
          nil
      end

    %{
      complete: is_nil(reason),
      provider: provider,
      model: model,
      credential_ready: credential_ready?,
      reason: reason
    }
  end

  defp credential_state(nil, _settings), do: {false, :missing_default_provider}

  defp credential_state(provider, settings) do
    routing = get_in(settings, ["runtime", "provider_routing"]) || %{}

    if CredentialReadiness.ready?(provider, settings["providers"] || %{},
         provider_routing: routing
       ),
       do: {true, nil},
       else: {false, :credential_not_usable}
  end

  defp external_default?(settings) do
    provider = get_in(settings, ["defaults", "provider"])

    settings
    |> Map.get("providers", %{})
    |> Enum.any?(fn {name, cfg} ->
      normalize_provider_name(name) == normalize_provider_name(provider || "") and
        AuthExtension.call(:external?, [name, cfg], false)
    end)
  end

  # Core has no provider catalog: local readiness recognizes configured provider
  # keys, while live setup verification also checks runtime providers/aliases.
  # Unknown prefixes remain literal native ids, as do explicitly declared ids.
  defp model_provider_mismatch?(provider, model, settings, provider_cfg) do
    declared? =
      Enum.any?(provider_cfg["models"] || [], fn entry -> entry["id"] == model end)

    case String.split(model, ":", parts: 2) do
      [prefix, id] when prefix != "" and id != "" ->
        configured? =
          Enum.any?(Map.keys(settings["providers"] || %{}), fn name ->
            normalize_provider_name(name) == normalize_provider_name(prefix)
          end)

        configured? and not declared? and
          normalize_provider_name(prefix) != normalize_provider_name(provider)

      _ ->
        false
    end
  end

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
