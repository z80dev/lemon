defmodule LemonCore.Setup.Readiness do
  @moduledoc """
  Derives the local first-run readiness state shared by every Lemon client.

  Readiness is deliberately read-only. It inspects the resolved global config,
  the secrets backend, and the configured default provider/model without
  starting a runtime or making a network request. The setup wizard, TUI, Web
  UI, and launchers can therefore agree on whether a prompt can run and on the
  exact recovery steps when it cannot.

  This module reports three stable steps:

    * `:config` - the global config file exists
    * `:secrets` - a secrets master key is configured
    * `:provider` - a matching default provider/model has a usable credential

  Provider live verification remains the responsibility of `lemon setup` and
  `lemon doctor`; readiness never sends credentials over the network.
  """

  alias LemonCore.Config.Modular
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
    settings = read_settings(expanded)
    secrets_status = Secrets.status()

    %{
      config: %{complete: File.exists?(expanded), path: expanded},
      secrets: %{
        complete: secrets_status.configured == true,
        source: secrets_status.source
      },
      provider: derive_provider(settings)
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

  defp derive_provider(settings) do
    defaults = settings["defaults"] || %{}
    legacy_agent = settings["agent"] || %{}

    provider = normalize_optional_string(defaults["provider"] || legacy_agent["provider"])
    model = normalize_optional_string(defaults["model"] || legacy_agent["model"])

    provider_cfg =
      provider &&
        get_in(settings, ["providers", provider])

    provider_cfg = if is_map(provider_cfg), do: provider_cfg, else: %{}

    {credential_ready?, credential_reason} = credential_state(provider, provider_cfg)

    reason =
      cond do
        is_nil(provider) -> :missing_default_provider
        is_nil(model) -> :missing_default_model
        not credential_ready? -> credential_reason || :credential_not_usable
        model_provider_mismatch?(provider, model) -> :model_provider_mismatch
        true -> nil
      end

    %{
      complete: is_nil(reason),
      provider: provider,
      model: model,
      credential_ready: credential_ready?,
      reason: reason
    }
  end

  defp credential_state(nil, _provider_cfg), do: {false, :missing_default_provider}

  defp credential_state(_provider, provider_cfg) do
    refs =
      provider_cfg
      |> Map.take(["oauth_secret", "api_key_secret"])
      |> Map.values()

    inline_key = normalize_optional_string(provider_cfg["api_key"])

    cond do
      inline_key != nil -> {true, nil}
      Enum.any?(refs, &secret_usable?/1) -> {true, nil}
      true -> {false, :credential_not_usable}
    end
  end

  # A referenced credential is usable when the encrypted store can decrypt it,
  # or when a same-named environment variable carries it. This matches the
  # runtime resolution order in `LemonCore.Secrets.resolve/2`.
  defp secret_usable?(name) when is_binary(name) and name != "" do
    match?({:ok, _}, Secrets.get(name, prefer_env: false, env_fallback: false)) or
      match?({:ok, _, _}, Secrets.resolve(name, prefer_env: false))
  end

  defp secret_usable?(_), do: false

  defp model_provider_mismatch?(provider, model) do
    case String.split(model, ":", parts: 2) do
      [prefix, _model_id] -> normalize_provider_name(prefix) != normalize_provider_name(provider)
      [_only] -> false
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
