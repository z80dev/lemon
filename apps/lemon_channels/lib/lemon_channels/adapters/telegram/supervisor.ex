defmodule LemonChannels.Adapters.Telegram.Supervisor do
  @moduledoc """
  Supervisor for Telegram adapter processes.

  Starts both the inbound transport (polling) and manages outbound delivery.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Check if Telegram is configured (allow running without lemon_gateway started).
    base = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}

    config =
      base
      |> merge_config(Application.get_env(:lemon_gateway, :telegram))
      |> merge_config(Keyword.get(opts, :config))

    token = config[:bot_token] || config["bot_token"]

    children =
      if is_binary(token) and token != "" do
        [
          # Start the inbound transport (polling)
          {LemonChannels.Adapters.Telegram.Transport, [config: config]}
        ]
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
