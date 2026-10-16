defmodule LemonRouter.VoiceReplyFallbackTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{OutboundPayload, VoiceReplyDelivery}
  alias LemonCore.{DeliveryIntent, DeliveryRoute, Event, SessionKey}

  defmodule Dispatcher do
    def dispatch(intent) do
      {owner, opts} = :persistent_term.get({__MODULE__, :options})
      prepared = VoiceReplyDelivery.prepare(intent, opts)
      VoiceReplyDelivery.expect(prepared, [intent.body.text], opts)

      VoiceReplyDelivery.receipt(
        %OutboundPayload{
          channel_id: "telegram",
          account_id: "default",
          peer: %{kind: :dm, id: "primary"},
          kind: :text,
          content: intent.body.text,
          meta: %{intent_meta: prepared.meta}
        },
        {:ok, 42},
        make_ref(),
        opts
      )

      send(owner, {:dispatched, intent.intent_id, prepared.intent_id})
      :ok
    end
  end

  defmodule TimedOutCoalescer do
    # Model an ambiguous finalize timeout: the original final was accepted, but
    # the caller cannot observe its acknowledgement and dispatches a fallback.
    def finalize_run(session_key, _, run_id, opts) do
      Dispatcher.dispatch(%DeliveryIntent{
        intent_id: "#{run_id}:coalescer-final",
        run_id: run_id,
        session_key: session_key,
        route: %DeliveryRoute{
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :dm,
          peer_id: "primary"
        },
        kind: :stream_finalize,
        body: %{text: opts[:final_text]},
        meta: opts[:meta]
      })

      {:error, {:finalize_call_failed, :timeout}}
    end
  end

  test "a delayed provider cannot block finalization and timeout fallback synthesizes once" do
    server = start_supervised!({VoiceReplyDelivery, name: nil})
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    owner = self()

    opts = [
      server: server,
      task_supervisor: supervisor,
      config: %{enabled: true},
      supported?: true,
      synthesize: fn _, _, context ->
        send(owner, {:provider_waiting, self(), context.delivery_id})

        receive do
          :release ->
            {:ok, %{audio_bytes: "audio", mime_type: "audio/ogg", filename: "reply.ogg"}}
        end
      end,
      enqueue: fn payload -> send(owner, {:voice, payload}) end
    ]

    previous_dispatcher = Application.get_env(:lemon_router, :dispatcher)
    previous_coalescer = Application.get_env(:lemon_router, :stream_coalescer)
    Application.put_env(:lemon_router, :dispatcher, Dispatcher)
    Application.put_env(:lemon_router, :stream_coalescer, TimedOutCoalescer)
    :persistent_term.put({Dispatcher, :options}, {owner, opts})

    on_exit(fn ->
      :persistent_term.erase({Dispatcher, :options})
      restore(:dispatcher, previous_dispatcher)
      restore(:stream_coalescer, previous_coalescer)
    end)

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "test",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "primary"
      })

    state = %{
      run_id: "voice-timeout",
      session_key: session_key,
      execution_request: %LemonCore.ExecutionCommand{
        run_id: "voice-timeout",
        session_key: session_key,
        prompt: "voice",
        meta: %{inbound_voice: true}
      }
    }

    event = Event.new(:run_completed, %{completed: %{ok: true, answer: "Transcript"}}, %{})
    assert :ok = LemonRouter.SurfaceManager.finalize_answer(state, event, %{})
    assert_receive {:dispatched, "voice-timeout:coalescer-final", stable_id}
    assert_receive {:dispatched, "voice-timeout:finalize-fallback", ^stable_id}
    assert_receive {:provider_waiting, provider, ^stable_id}
    refute_receive {:voice, _}
    send(provider, :release)
    assert_receive {:voice, %OutboundPayload{kind: :voice, idempotency_key: key}}
    assert key == stable_id <> ":voice"
    refute_receive {:provider_waiting, _, _}
    refute_receive {:voice, _}
  end

  defp restore(key, nil), do: Application.delete_env(:lemon_router, key)
  defp restore(key, value), do: Application.put_env(:lemon_router, key, value)
end
