defmodule LemonChannels.Dispatcher do
  @moduledoc """
  Router-facing semantic delivery entrypoint.

  Every dispatch is observable. After the renderer returns, the dispatcher emits:

  - a `[:lemon, :channels, :dispatch]` telemetry event with `%{count: 1, duration: native}`
    measurements and `%{channel_id, account_id, kind, intent_id, run_id, session_key, ok}`
    metadata, and
  - a typed `LemonCore.Events.ChannelDelivery` on the `"channels"` bus topic, which the
    control plane's `EventBridge` forwards to WS clients as `channel.delivery`.

  Emission happens strictly after the dispatch result is known and is wrapped defensively:
  an observability failure (crashed bus backend, serialization issue) is logged and
  swallowed, never surfaced to the caller — it must not break a real send.
  """

  require Logger

  alias LemonChannels.Adapters.Discord.Renderer, as: DiscordRenderer
  alias LemonChannels.Adapters.Generic.Renderer, as: GenericRenderer
  alias LemonChannels.Adapters.Telegram.Renderer, as: TelegramRenderer
  alias LemonCore.Bus
  alias LemonCore.DeliveryIntent
  alias LemonCore.Events.ChannelDelivery

  @channels_topic "channels"
  @preview_limit 200
  @error_inspect_opts [limit: 10, printable_limit: 200]

  @spec dispatch(DeliveryIntent.t()) :: :ok | {:error, term()}
  def dispatch(%DeliveryIntent{} = intent) do
    started_at = System.monotonic_time()

    result =
      renderer_for(intent)
      |> dispatch_with(intent)

    observe(intent, result, System.monotonic_time() - started_at)
    result
  end

  defp renderer_for(%DeliveryIntent{route: %{channel_id: "telegram"}}), do: TelegramRenderer
  defp renderer_for(%DeliveryIntent{route: %{channel_id: "discord"}}), do: DiscordRenderer
  defp renderer_for(_intent), do: GenericRenderer

  defp dispatch_with(renderer, %DeliveryIntent{} = intent) do
    renderer.dispatch(intent)
  rescue
    error -> {:error, {:dispatch_failed, renderer, Exception.message(error)}}
  end

  # -- Observability ----------------------------------------------------------
  #
  # Runs after the dispatch result is known; must never raise into the caller.

  defp observe(%DeliveryIntent{} = intent, result, duration) do
    ok? = delivery_ok?(result)
    route = intent.route || %{}

    :telemetry.execute(
      [:lemon, :channels, :dispatch],
      %{count: 1, duration: duration},
      %{
        channel_id: route_field(route, :channel_id),
        account_id: route_field(route, :account_id),
        kind: intent.kind,
        intent_id: intent.intent_id,
        run_id: intent.run_id,
        session_key: intent.session_key,
        ok: ok?
      }
    )

    broadcast_delivery(intent, route, result, ok?, duration)
    :ok
  rescue
    error ->
      Logger.debug("Dispatcher observability emission failed: #{Exception.message(error)}")

      :ok
  catch
    kind, reason ->
      Logger.debug("Dispatcher observability emission failed: #{inspect({kind, reason})}")
      :ok
  end

  defp broadcast_delivery(%DeliveryIntent{} = intent, route, result, ok?, duration) do
    if Bus.running?() do
      payload =
        ChannelDelivery.new(%{
          intent_id: intent.intent_id,
          run_id: intent.run_id,
          session_key: intent.session_key,
          channel_id: route_field(route, :channel_id),
          account_id: route_field(route, :account_id),
          peer_kind: route_field(route, :peer_kind),
          peer_id: route_field(route, :peer_id),
          thread_id: route_field(route, :thread_id),
          kind: intent.kind,
          text_preview: text_preview(intent),
          ok: ok?,
          error: error_reason(result),
          duration_ms: System.convert_time_unit(duration, :native, :millisecond),
          ts_ms: LemonCore.Event.now_ms()
        })

      Bus.broadcast_event(@channels_topic, :channel_delivery, payload, %{
        run_id: intent.run_id,
        session_key: intent.session_key,
        origin: :dispatcher
      })
    end

    :ok
  end

  defp delivery_ok?(:ok), do: true
  defp delivery_ok?({:ok, _}), do: true
  defp delivery_ok?(_result), do: false

  defp error_reason(:ok), do: nil
  defp error_reason({:ok, _}), do: nil
  defp error_reason({:error, reason}), do: inspect(reason, @error_inspect_opts)
  defp error_reason(other), do: inspect(other, @error_inspect_opts)

  defp route_field(route, key) when is_map(route), do: Map.get(route, key)
  defp route_field(_route, _key), do: nil

  defp text_preview(%DeliveryIntent{body: body}) when is_map(body) do
    case Map.get(body, :text) || Map.get(body, "text") do
      text when is_binary(text) -> truncate(text)
      _ -> nil
    end
  end

  defp text_preview(_intent), do: nil

  defp truncate(text) do
    if String.length(text) <= @preview_limit do
      text
    else
      String.slice(text, 0, @preview_limit) <> "…"
    end
  end
end
