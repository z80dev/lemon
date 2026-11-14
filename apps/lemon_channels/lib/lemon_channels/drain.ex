defmodule LemonChannels.Drain do
  @moduledoc """
  Channel ingress participant of `LemonCore.Drain`.

  In the `:ingress` phase the Telegram transport submits every debounced
  message and media group to the router, then stops polling. Updates it has not
  fetched stay unconfirmed at Telegram and reach the next runtime from the
  persisted offset. Inbound HTTP answers 503 while the runtime drains (see
  `LemonChannels.InboundHttp.Router`). Push transports keep delivering into the
  router until it seals admission.
  """

  @behaviour LemonCore.Drain

  alias LemonChannels.Adapters.Telegram.Transport, as: TelegramTransport

  @impl true
  def drain(:ingress, ctx), do: {:ok, %{telegram: pause(TelegramTransport, ctx)}}
  def drain(:work, _ctx), do: :ok

  defp pause(name, ctx) do
    case Process.whereis(name) do
      nil ->
        :not_running

      pid ->
        timeout = max(ctx.deadline_ms - System.monotonic_time(:millisecond), 1_000)

        try do
          :ok = GenServer.call(pid, :drain_pause, timeout)
          :paused
        catch
          :exit, _ -> :failed
        end
    end
  end
end
