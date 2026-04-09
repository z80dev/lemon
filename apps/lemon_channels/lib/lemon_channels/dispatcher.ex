defmodule LemonChannels.Dispatcher do
  @moduledoc """
  Router-facing semantic delivery entrypoint.
  """

  alias LemonChannels.Adapters.Discord.Renderer, as: DiscordRenderer
  alias LemonChannels.Adapters.Generic.Renderer, as: GenericRenderer
  alias LemonChannels.Adapters.Telegram.Renderer, as: TelegramRenderer
  alias LemonCore.DeliveryIntent

  @spec dispatch(DeliveryIntent.t()) :: :ok | {:error, term()}
  def dispatch(%DeliveryIntent{} = intent) do
    renderer_for(intent)
    |> dispatch_with(intent)
  end

  defp renderer_for(%DeliveryIntent{route: %{channel_id: "telegram"}}), do: TelegramRenderer
  defp renderer_for(%DeliveryIntent{route: %{channel_id: "discord"}}), do: DiscordRenderer
  defp renderer_for(_intent), do: GenericRenderer

  defp dispatch_with(renderer, %DeliveryIntent{} = intent) do
    renderer.dispatch(intent)
  rescue
    error -> {:error, {:dispatch_failed, renderer, Exception.message(error)}}
  end
end
