defmodule LemonChannels.Adapters.Discord.Supervisor do
  @moduledoc """
  Supervisor for Discord adapter processes.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    base = LemonChannels.GatewayConfig.get(:discord, %{}) || %{}

    config =
      base
      |> merge_config(Application.get_env(:lemon_channels, :discord))
      |> merge_config(Keyword.get(opts, :config))

    token = config[:bot_token] || config["bot_token"] || System.get_env("DISCORD_BOT_TOKEN")

    children =
      if is_binary(token) and String.trim(token) != "" do
        [{LemonChannels.Adapters.Discord.Transport, [config: config]}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp merge_config(config, nil), do: config
  defp merge_config(config, opts) when is_map(opts), do: Map.merge(config, opts)

  defp merge_config(config, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Map.merge(config, Enum.into(opts, %{}))
    else
      config
    end
  end

  defp merge_config(config, _opts), do: config
end
