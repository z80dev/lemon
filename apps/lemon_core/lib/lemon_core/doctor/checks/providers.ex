defmodule LemonCore.Doctor.Checks.Providers do
  @moduledoc "Checks that at least one AI provider is configured."

  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Check

  @doc """
  Returns a list of Check results covering provider configuration.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(_opts \\ []) do
    config = Modular.load()

    [
      check_default_provider(config),
      check_provider_credentials(config)
    ]
  end

  defp check_default_provider(config) do
    case config.agent.default_provider do
      nil ->
        Check.warn(
          "providers.default",
          "No default provider is set.",
          "Run `mix lemon.setup provider` or set defaults.provider in config.toml."
        )

      provider ->
        Check.pass("providers.default", "Default provider: #{provider}")
    end
  end

  defp check_provider_credentials(config) do
    providers =
      if config.providers && config.providers.providers do
        config.providers.providers
      else
        %{}
      end

    if map_size(providers) == 0 do
      Check.warn(
        "providers.credentials",
        "No providers are configured.",
        "Run `mix lemon.setup provider` or `mix lemon.onboard` to onboard a provider."
      )
    else
      configured = Enum.filter(providers, fn {_, p} -> provider_has_credential?(p) end)

      if Enum.empty?(configured) do
        Check.warn(
          "providers.credentials",
          "Providers are listed in config but none have credentials (api_key or api_key_secret).",
          "Run `mix lemon.setup provider` to onboard a provider."
        )
      else
        names = configured |> Enum.map(fn {name, _} -> name end) |> Enum.join(", ")
        Check.pass("providers.credentials", "Providers with credentials: #{names}")
      end
    end
  end

  defp provider_has_credential?(provider) do
    not is_nil(provider.api_key) or not is_nil(provider.api_key_secret)
  end
end
