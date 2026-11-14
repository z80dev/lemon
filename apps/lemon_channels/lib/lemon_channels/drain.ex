defmodule LemonChannels.Drain do
  @moduledoc """
  Channel participant of `LemonCore.Drain`, registered to run after the router.

  `:ingress`: the Telegram transport submits every debounced message and media
  group to the router, then stops polling. Updates it has not fetched stay
  unconfirmed at Telegram and reach the next runtime from the persisted offset.
  Inbound HTTP answers 503 while the runtime drains (see
  `LemonChannels.InboundHttp.Router`). Push transports keep delivering into the
  router until it seals admission.

  `:work`: once the router has suspended its runs, wait for the outbox to stay
  empty briefly so their final "paused" notices and answers are delivered
  before the VM stops.
  """

  @behaviour LemonCore.Drain

  alias LemonChannels.Adapters.Telegram.Transport, as: TelegramTransport

  @poll_ms 100
  @idle_ms 500

  @impl true
  def drain(:ingress, ctx), do: {:ok, %{telegram: pause(TelegramTransport, ctx)}}
  def drain(:work, ctx), do: {:ok, %{outbox: await_outbox_idle(ctx.deadline_ms, nil)}}

  defp pause(name, ctx) do
    case Process.whereis(name) do
      nil ->
        :not_running

      pid ->
        timeout = max(ctx.deadline_ms - now(), 1_000)

        try do
          :ok = GenServer.call(pid, :drain_pause, timeout)
          :paused
        catch
          :exit, _ -> :failed
        end
    end
  end

  defp await_outbox_idle(deadline_ms, idle_since) do
    now = now()

    cond do
      not idle?() ->
        if now >= deadline_ms, do: :timeout, else: sleep_then(deadline_ms, nil)

      is_integer(idle_since) and now - idle_since >= @idle_ms ->
        :flushed

      now >= deadline_ms ->
        :flushed

      true ->
        sleep_then(deadline_ms, idle_since || now)
    end
  end

  defp sleep_then(deadline_ms, idle_since) do
    Process.sleep(@poll_ms)
    await_outbox_idle(deadline_ms, idle_since)
  end

  defp idle? do
    %{queue_length: queued, processing_count: processing} = LemonChannels.Outbox.stats()
    queued == 0 and processing == 0
  catch
    :exit, _ -> true
  end

  defp now, do: System.monotonic_time(:millisecond)
end
