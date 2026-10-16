defmodule LemonRouter.VoiceReplyTerminalStreamTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{OutboundPayload, PresentationState, VoiceReplyDelivery}
  alias LemonChannels.Registry, as: ChannelRegistry
  alias LemonCore.{DeliveryIntent, DeliveryRoute, Event, ExecutionCommand, SessionKey}
  alias LemonRouter.{StreamCoalescer, SurfaceManager, ToolStatusCoalescer}

  defmodule TelegramPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "telegram"

    @impl true
    def meta do
      %{
        label: "Terminal voice stream regression",
        capabilities: %{edit_support: true, chunk_limit: 4096},
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def gateway_methods, do: []

    @impl true
    def deliver(payload) do
      owner = :persistent_term.get({__MODULE__, :owner})

      with :ok <- confirm_terminal_transcript(payload, owner) do
        send(owner, {:delivered, payload})
        {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
      end
    end

    defp confirm_terminal_transcript(payload, owner) do
      if get_in(payload.meta || %{}, [:intent_meta, :terminal_answer]) == true do
        send(owner, {:terminal_transcript_waiting, self(), payload})

        receive do
          :confirm_transcript -> :ok
        after
          5_000 -> {:error, :transcript_ack_timeout}
        end
      else
        :ok
      end
    end
  end

  defmodule Dispatcher do
    # Inject only the existing speech-provider seam. Rendering, presentation,
    # enqueueing, transcript receipts, and audio delivery use the real channels path.
    def dispatch(%DeliveryIntent{} = intent) do
      {owner, opts} = :persistent_term.get({__MODULE__, :options})
      prepared = VoiceReplyDelivery.prepare(intent, opts)
      result = LemonChannels.Dispatcher.dispatch(prepared)
      send(owner, {:dispatched_intent, intent, prepared.intent_id})
      result
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, name: nil})

    opts = [
      config: %{enabled: true},
      supported?: true,
      task_supervisor: supervisor,
      synthesize: fn text, _, context ->
        send(owner, {:synthesized, text, context.delivery_id})
        {:ok, %{audio_bytes: "opus", mime_type: "audio/ogg", filename: "reply.ogg"}}
      end
    ]

    previous_dispatcher = Application.get_env(:lemon_router, :dispatcher)
    previous_coalescer = Application.get_env(:lemon_router, :stream_coalescer)
    previous_plugin = ChannelRegistry.get_plugin("telegram")
    Application.put_env(:lemon_router, :dispatcher, Dispatcher)
    Application.delete_env(:lemon_router, :stream_coalescer)
    :persistent_term.put({Dispatcher, :options}, {owner, opts})
    :persistent_term.put({TelegramPlugin, :owner}, owner)
    ChannelRegistry.unregister("telegram")
    :ok = ChannelRegistry.register(TelegramPlugin)

    on_exit(fn ->
      :persistent_term.erase({Dispatcher, :options})
      :persistent_term.erase({TelegramPlugin, :owner})
      restore(:dispatcher, previous_dispatcher)
      restore(:stream_coalescer, previous_coalescer)

      if Process.whereis(ChannelRegistry) do
        ChannelRegistry.unregister("telegram")
        if previous_plugin, do: ChannelRegistry.register(previous_plugin)
      end
    end)

    suffix = System.unique_integer([:positive])
    account_id = "terminal-voice-#{suffix}"
    peer_id = "recipient-#{suffix}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "terminal-voice",
        channel_id: "telegram",
        account_id: account_id,
        peer_kind: :dm,
        peer_id: peer_id
      })

    start_supervised!(
      {StreamCoalescer,
       session_key: session_key,
       channel_id: "telegram",
       min_chars: 1,
       idle_ms: 10_000,
       max_latency_ms: 10_000}
    )

    start_supervised!(
      {ToolStatusCoalescer, session_key: session_key, channel_id: "telegram", idle_ms: 10_000}
    )

    %{
      run_id: "terminal-voice-run-#{suffix}",
      session_key: session_key,
      route: %DeliveryRoute{
        channel_id: "telegram",
        account_id: account_id,
        peer_kind: :dm,
        peer_id: peer_id
      }
    }
  end

  test "surface completion delivers the final transcript and voices only the completed answer",
       ctx do
    complete_after_tool_handoff(ctx, :surface)
  end

  test "coalescer completion delivers the final transcript and voices only the completed answer",
       ctx do
    complete_after_tool_handoff(ctx, :coalescer)
  end

  defp complete_after_tool_handoff(ctx, completion) do
    state = %{
      run_id: ctx.run_id,
      session_key: ctx.session_key,
      saw_delta: true,
      execution_request: %ExecutionCommand{
        run_id: ctx.run_id,
        session_key: ctx.session_key,
        prompt: "voice request",
        meta: %{inbound_voice: true, user_msg_id: 42}
      }
    }

    assert :ok = SurfaceManager.ingest_answer_delta(state, %{seq: 1, text: "Let me check."})
    assert_receive {:delivered, %OutboundPayload{kind: :text, content: "Let me check."}}, 1_000
    assert eventually(fn -> settled_answer?(ctx) end)

    action_event = %{
      action: %{id: "inspect", kind: "tool", title: "Inspect result", detail: %{name: "bash"}},
      phase: :started
    }

    {state, surface, capture?} = SurfaceManager.prepare_status_action(state, action_event)
    assert capture?
    assert surface == :status
    assert :ok = SurfaceManager.handoff_answer_to_status(state, surface)
    assert :ok = SurfaceManager.ingest_status_action(state, action_event, surface)

    assert_receive {:dispatched_intent,
                    %DeliveryIntent{
                      kind: :stream_finalize,
                      body: %{text: "Let me check."},
                      meta: %{inbound_voice: true, terminal_answer: false}
                    }, intermediate_id},
                   1_000

    # Telegram already displayed this exact snapshot, so its renderer may
    # suppress the redundant handoff edit. The delivered text remains visible.
    refute String.starts_with?(intermediate_id, "voice-final:")

    refute_receive {:synthesized, _, _}, 100

    event =
      Event.new(
        :run_completed,
        %{completed: %{ok: true, answer: "The result is 42."}},
        %{run_id: ctx.run_id, session_key: ctx.session_key}
      )

    assert :ok = SurfaceManager.finalize_status(state, event)
    assert :ok = SurfaceManager.ingest_answer_delta(state, %{seq: 2, text: "The result is"})
    assert_receive {:delivered, %OutboundPayload{kind: :text, content: "The result is"}}, 1_000
    assert eventually(fn -> settled_answer?(ctx) end)

    result =
      case completion do
        :surface ->
          SurfaceManager.finalize_answer(state, event, %{})

        :coalescer ->
          StreamCoalescer.finalize_run(ctx.session_key, "telegram", ctx.run_id,
            final_text: "The result is 42."
          )
      end

    assert :ok = result

    assert_receive {:dispatched_intent,
                    %DeliveryIntent{
                      kind: :stream_finalize,
                      body: %{text: "The result is 42."},
                      meta: %{inbound_voice: true, terminal_answer: true}
                    }, terminal_id},
                   1_000

    refute terminal_id == intermediate_id

    assert_receive {:terminal_transcript_waiting, worker,
                    %OutboundPayload{
                      kind: :edit,
                      content: %{text: "The result is 42."},
                      idempotency_key: ^terminal_id
                    }},
                   1_000

    refute_receive {:synthesized, _, _}, 100
    refute_receive {:delivered, %OutboundPayload{kind: :voice}}, 100
    send(worker, :confirm_transcript)

    assert_receive {:delivered,
                    %OutboundPayload{kind: :edit, content: %{text: "The result is 42."}}},
                   1_000

    assert_receive {:synthesized, "The result is 42.", ^terminal_id}, 1_000
    voice_key = terminal_id <> ":voice"

    assert_receive {:delivered, %OutboundPayload{kind: :voice, idempotency_key: ^voice_key}},
                   1_000

    refute_receive {:synthesized, _, _}, 100
    refute_receive {:delivered, %OutboundPayload{kind: :voice}}, 100
  end

  defp settled_answer?(ctx) do
    entry = PresentationState.get(ctx.route, ctx.run_id, :answer)

    not is_nil(entry.platform_message_id) and is_nil(entry.pending_create_ref) and
      is_nil(entry.pending_edit_ref)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:lemon_router, key)
  defp restore(key, value), do: Application.put_env(:lemon_router, key, value)
end
