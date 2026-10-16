defmodule LemonChannels.VoiceReplyOutboxTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Renderer

  alias LemonChannels.{
    OutboundPayload,
    Outbox,
    PresentationState,
    Registry,
    VoiceReply,
    VoiceReplyDelivery
  }

  alias LemonChannels.Outbox.{Dedupe, RateLimiter}
  alias LemonChannels.Telegram.Truncate
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  defmodule TranscriptPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "voice-reply-outbox-regression"
    @impl true
    def meta,
      do: %{label: "Voice transcript regression", capabilities: %{chunk_limit: 4096}, docs: nil}

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}
    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}
    @impl true
    def gateway_methods, do: []

    @impl true
    def deliver(payload) do
      send(payload.notify_pid, {:transcript_attempt, payload.kind, payload.content})

      case payload.kind do
        :edit -> {:error, {:http_error, 400, "deleted"}}
        :text -> {:ok, :transcript_delivered}
      end
    end
  end

  defmodule RendererPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "telegram"

    @impl true
    def meta,
      do: %{label: "Voice renderer regression", capabilities: %{chunk_limit: 4096}, docs: nil}

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def gateway_methods, do: []

    @impl true
    def deliver(payload) do
      send(payload.meta.intent_meta.test_pid, {:renderer_attempt, self(), payload})

      receive do
        {:complete, result} -> result
      end
    end
  end

  defmodule OversizedProvider do
    @behaviour LemonChannels.VoiceProvider

    @impl true
    def synthesize(_text, _config, _context) do
      {:ok,
       %{
         audio_bytes: :binary.copy(<<0>>, VoiceReply.max_audio_bytes() + 1),
         mime_type: "audio/ogg",
         filename: "reply.ogg"
       }}
    end
  end

  defmodule TranscriptAPI do
    def send_message(_token, _chat_id, text, _opts, _parse_mode) do
      attempt({:create, text})
    end

    def edit_message_text(_token, _chat_id, message_id, text, _opts) do
      attempt({:edit, message_id, text})
    end

    defp attempt(operation) do
      owner = Agent.get(__MODULE__, & &1)
      send(owner, {:telegram_attempt, self(), operation})

      receive do
        {:complete, result} -> result
      end
    end
  end

  setup do
    for module <- [Registry, RateLimiter, Dedupe, Outbox, PresentationState, VoiceReplyDelivery] do
      if is_nil(Process.whereis(module)), do: start_supervised!(module)
    end

    if is_nil(Process.whereis(LemonChannels.VoiceReplyTaskSupervisor)) do
      start_supervised!({Task.Supervisor, name: LemonChannels.VoiceReplyTaskSupervisor})
    end

    Registry.register(TranscriptPlugin)

    on_exit(fn ->
      if Process.whereis(Registry), do: Registry.unregister(TranscriptPlugin.id())
    end)

    %{account: "voice-outbox-#{System.unique_integer([:positive])}"}
  end

  defp intent(account) do
    %DeliveryIntent{
      intent_id: "final-#{account}",
      run_id: "run-#{account}",
      session_key: "agent:test:#{account}",
      route: %DeliveryRoute{
        channel_id: TranscriptPlugin.id(),
        account_id: account,
        peer_kind: :dm,
        peer_id: "recipient"
      },
      kind: :stream_finalize,
      body: %{text: "The complete transcript"},
      meta: %{inbound_voice: true}
    }
  end

  defp enqueue_transcript(prepared, kind) do
    ref = make_ref()

    payload = %OutboundPayload{
      channel_id: prepared.route.channel_id,
      account_id: prepared.route.account_id,
      peer: %{kind: :dm, id: prepared.route.peer_id},
      kind: kind,
      content:
        if(kind == :edit,
          do: %{message_id: "3101", text: prepared.body.text},
          else: prepared.body.text
        ),
      idempotency_key: "#{prepared.intent_id}:transcript",
      meta: %{intent_meta: prepared.meta},
      notify_pid: self(),
      notify_ref: ref
    }

    assert {:ok, _} = Outbox.enqueue(payload)
    ref
  end

  test "a rejected final transcript edit through the real outbox withholds audio", ctx do
    owner = self()

    opts = [
      config: %{enabled: true},
      supported?: true,
      synthesize: fn _, _, _ ->
        send(owner, :synthesis_started)
        {:ok, %{audio_bytes: "opus", mime_type: "audio/ogg", filename: "reply.ogg"}}
      end,
      enqueue: fn payload -> send(owner, {:voice_enqueued, payload}) end
    ]

    prepared = VoiceReplyDelivery.prepare(intent(ctx.account), opts)
    VoiceReplyDelivery.expect(prepared, [prepared.body.text])
    ref = enqueue_transcript(prepared, :edit)

    assert_receive {:transcript_attempt, :edit,
                    %{message_id: "3101", text: "The complete transcript"}},
                   1_000

    assert_receive {:outbox_delivered, ^ref, {:error, {:http_error, 400, "deleted"}}}, 1_000
    refute_receive :synthesis_started, 200
    refute_receive {:voice_enqueued, _}
  end

  test "renderer final edits synthesize once after all chunks, including deferred creates and edits",
       ctx do
    existing = Registry.get_plugin("telegram")
    _ = Registry.unregister("telegram")
    :ok = Registry.register(RendererPlugin)

    on_exit(fn ->
      if Process.whereis(Registry) do
        _ = Registry.unregister("telegram")
        if existing, do: Registry.register(existing)
      end
    end)

    owner = self()
    text = String.duplicate("The terminal answer. ", 500)
    [first | rest] = chunks = Truncate.split_messages(text)
    assert rest != []

    opts = [
      config: %{enabled: true},
      supported?: true,
      synthesize: fn transcript, _, context ->
        send(owner, {:synthesis_started, transcript, context.delivery_id})
        {:ok, %{audio_bytes: "opus", mime_type: "audio/ogg", filename: "reply.ogg"}}
      end,
      enqueue: fn payload -> send(owner, {:voice_enqueued, payload}) end
    ]

    for pending <- [:none, :create, :edit] do
      message = intent("#{ctx.account}-#{pending}")
      route = %{message.route | channel_id: "telegram", peer_id: "3100"}

      snapshot = %{
        message
        | route: route,
          kind: :stream_snapshot,
          body: %{text: "Starting", seq: 1},
          meta: %{inbound_voice: true, test_pid: owner}
      }

      assert :ok = Renderer.dispatch(snapshot)
      assert_receive {:renderer_attempt, create_worker, %OutboundPayload{kind: :text}}, 1_000

      pending_worker =
        if pending == :create do
          create_worker
        else
          send(create_worker, {:complete, {:ok, %{message_id: 3101}}})
          await_presentation(route, message.run_id)

          if pending == :edit do
            assert :ok =
                     Renderer.dispatch(%{
                       snapshot
                       | intent_id: "#{snapshot.intent_id}:working",
                         body: %{text: "Still working", seq: 2}
                     })

            assert_receive {:renderer_attempt, edit_worker,
                            %OutboundPayload{kind: :edit, content: %{text: "Still working"}}},
                           1_000

            edit_worker
          end
        end

      terminal = %{
        snapshot
        | kind: :stream_finalize,
          body: %{text: text, seq: 3},
          meta: %{inbound_voice: true, terminal_answer: true, test_pid: owner}
      }

      prepared = VoiceReplyDelivery.prepare(terminal, opts)
      assert :ok = Renderer.dispatch(prepared)

      if pending_worker do
        assert PresentationState.get(route, message.run_id, :answer).deferred_chunks == chunks
        refute_receive {:renderer_attempt, _, _}
        refute_receive {:synthesis_started, _, _}
        send(pending_worker, {:complete, {:ok, %{message_id: 3101}}})
      end

      assert_receive {:renderer_attempt, final_worker,
                      %OutboundPayload{kind: :edit, content: %{message_id: "3101", text: ^first}}},
                     1_000

      refute_receive {:synthesis_started, _, _}
      send(final_worker, {:complete, {:ok, %{message_id: 3101}}})

      for chunk <- rest do
        assert_receive {:renderer_attempt, chunk_worker,
                        %OutboundPayload{kind: :text, content: ^chunk}},
                       1_000

        refute_receive {:synthesis_started, _, _}
        send(chunk_worker, {:complete, {:ok, %{message_id: 3102}}})
      end

      id = prepared.intent_id
      assert_receive {:synthesis_started, ^text, ^id}, 1_000
      assert_receive {:voice_enqueued, %OutboundPayload{kind: :voice}}, 1_000
      refute_receive {:synthesis_started, _, _}
      refute_receive {:voice_enqueued, _}
    end
  end

  for scenario <- [:identical_snapshot, :lost_acknowledgement] do
    @scenario scenario
    test "real Telegram outbound confirms transcript before synthesis: #{scenario}", ctx do
      owner = self()

      start_supervised!(%{
        id: TranscriptAPI,
        start: {Agent, :start_link, [fn -> owner end, [name: TranscriptAPI]]}
      })

      existing = Registry.get_plugin("telegram")
      _ = Registry.unregister("telegram")
      :ok = Registry.register(LemonChannels.Adapters.Telegram)
      config_key = :"Elixir.LemonGateway.Config"
      old_config = Application.get_env(:lemon_gateway, config_key)

      Application.put_env(:lemon_gateway, config_key, %{
        telegram: %{
          account_id: ctx.account,
          bot_token: "test-token",
          api_mod: TranscriptAPI,
          use_markdown: false
        }
      })

      on_exit(fn ->
        if old_config,
          do: Application.put_env(:lemon_gateway, config_key, old_config),
          else: Application.delete_env(:lemon_gateway, config_key)

        if Process.whereis(Registry) do
          Registry.unregister("telegram")
          if existing, do: Registry.register(existing)
        end
      end)

      message = intent(ctx.account)
      route = %{message.route | channel_id: "telegram", peer_id: "3100"}
      text = message.body.text

      snapshot = %{
        message
        | route: route,
          intent_id: "#{message.intent_id}:snapshot",
          kind: :stream_snapshot,
          body: %{text: if(@scenario == :identical_snapshot, do: text, else: "Working"), seq: 1}
      }

      assert :ok = Renderer.dispatch(snapshot)
      assert_receive {:telegram_attempt, create_worker, {:create, _}}, 1_000
      send(create_worker, {:complete, {:ok, %{"message_id" => 3101}}})
      await_presentation(route, message.run_id)

      opts = [
        config: %{enabled: true},
        supported?: true,
        synthesize: fn transcript, _, _ ->
          send(owner, {:synthesis_started, transcript})
          {:ok, %{audio_bytes: "opus", mime_type: "audio/ogg", filename: "reply.ogg"}}
        end,
        enqueue: fn payload -> send(owner, {:voice_enqueued, payload}) end
      ]

      terminal = %{
        snapshot
        | intent_id: message.intent_id,
          kind: :stream_finalize,
          body: %{text: text, seq: 2},
          meta: %{inbound_voice: true, terminal_answer: true}
      }

      prepared = VoiceReplyDelivery.prepare(terminal, opts)
      assert :ok = Renderer.dispatch(prepared)
      assert_receive {:telegram_attempt, edit_worker, {:edit, 3101, ^text}}, 1_000
      refute_receive {:synthesis_started, _}

      if @scenario == :lost_acknowledgement do
        # Telegram accepted the final text, but the outbox must retry the
        # unknown acknowledgement with the same edit.
        send(edit_worker, {:complete, {:error, :timeout}})
        assert_receive {:telegram_attempt, retry_worker, {:edit, 3101, ^text}}, 5_000
        refute_receive {:synthesis_started, _}
        send(retry_worker, {:complete, not_modified()})
      else
        send(edit_worker, {:complete, not_modified()})
      end

      assert_receive {:synthesis_started, ^text}, 1_000
      assert_receive {:voice_enqueued, %OutboundPayload{kind: :voice}}, 1_000
      assert PresentationState.get(route, message.run_id, :answer).platform_message_id == 3101
      refute_receive {:synthesis_started, _}
      refute_receive {:voice_enqueued, _}
      refute_receive {:telegram_attempt, _, _}
    end
  end

  defp not_modified do
    {:error,
     {:http_error, 400,
      Jason.encode!(%{
        "ok" => false,
        "description" =>
          "Bad Request: message is not modified: specified new message content and reply markup are exactly the same as a current content and reply markup of the message"
      })}}
  end

  defp await_presentation(route, run_id, attempts \\ 100) do
    state = PresentationState.get(route, run_id, :answer)

    if state.platform_message_id == 3101 and is_nil(state.pending_create_ref) do
      :ok
    else
      assert attempts > 0, "snapshot delivery did not reach presentation state"
      Process.sleep(10)
      await_presentation(route, run_id, attempts - 1)
    end
  end

  test "oversized provider audio leaves a confirmed real outbox transcript text-only", ctx do
    owner = self()

    opts = [
      config: %{enabled: true, provider: "openai", api_key: "test-key"},
      supported?: true,
      synthesize: fn text, config, context ->
        result =
          VoiceReply.synthesize(
            text,
            config,
            Map.merge(context, %{
              provider_module: OversizedProvider,
              usage_recorder: fn _ ->
                send(owner, :usage_recorded)
                :ok
              end
            })
          )

        send(owner, {:synthesis_finished, result})
        result
      end,
      enqueue: fn payload -> send(owner, {:voice_enqueued, payload}) end
    ]

    prepared = VoiceReplyDelivery.prepare(intent(ctx.account), opts)
    VoiceReplyDelivery.expect(prepared, [prepared.body.text])
    ref = enqueue_transcript(prepared, :text)

    assert_receive {:transcript_attempt, :text, "The complete transcript"}, 1_000
    assert_receive {:outbox_delivered, ^ref, {:ok, :transcript_delivered}}, 1_000
    assert_receive {:synthesis_finished, {:error, :audio_too_large}}, 1_000
    refute_receive {:voice_enqueued, _}
    refute_receive :usage_recorded
  end
end
