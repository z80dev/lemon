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
    # Allow running lemon_channels without any Telegram token configured.
    base = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}

    config =
      base
      |> merge_config(Keyword.get(opts, :config))

    token = config[:bot_token] || config["bot_token"] || resolve_bot_token_secret(config)

    children =
      if is_binary(token) and token != "" do
        [
          {Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor},
          # Start the inbound transport (polling)
          {LemonChannels.Adapters.Telegram.Transport, [config: config]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp merge_config(base, opts), do: LemonCore.MapHelpers.merge_config(base, opts)

  defp resolve_bot_token_secret(config) do
    secret_name = config[:bot_token_secret] || config["bot_token_secret"]

    if is_binary(secret_name) and secret_name != "" do
      LemonCore.Secrets.fetch_value(secret_name)
    else
      nil
    end
  end
end
