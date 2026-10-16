defmodule LemonChannels.VoiceReplyDeliveryTest do
  use ExUnit.Case, async: true

  alias LemonChannels.{OutboundPayload, VoiceReplyDelivery}
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  setup do
    server = start_supervised!({VoiceReplyDelivery, name: nil})
    supervisor = start_supervised!({Task.Supervisor, name: nil})
    owner = self()

    opts = [
      server: server,
      task_supervisor: supervisor,
      config: %{enabled: true},
      supported?: true,
      synthesize: fn text, _, context ->
        send(owner, {:synthesized, text, context})
        {:ok, %{audio_bytes: "fake", mime_type: "audio/ogg", filename: "reply.ogg"}}
      end,
      enqueue: fn payload -> send(owner, {:enqueued, payload}) end
    ]

    %{opts: opts}
  end

  defp intent do
    %DeliveryIntent{
      intent_id: "original-final",
      run_id: "run-voice",
      session_key: "agent:test:main",
      route: %DeliveryRoute{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "1",
        thread_id: "2"
      },
      kind: :stream_finalize,
      body: %{text: "The complete transcript"},
      meta: %{inbound_voice: true}
    }
  end

  defp receipt(intent, content, result, token, opts, kind \\ :text) do
    payload = %OutboundPayload{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "1"},
      kind: kind,
      content: content,
      meta: %{intent_meta: intent.meta}
    }

    VoiceReplyDelivery.receipt(payload, result, token, opts)
  end

  test "waits for every transcript chunk and ignores repeated notifications", %{opts: opts} do
    prepared = VoiceReplyDelivery.prepare(intent(), opts)
    VoiceReplyDelivery.expect(prepared, ["same", "same"], opts)
    refute_receive {:synthesized, _, _}
    receipt(prepared, "same", {:ok, 1}, :first, opts)
    receipt(prepared, "same", {:ok, 1}, :first, opts)
    refute_receive {:synthesized, _, _}
    receipt(prepared, "same", {:ok, 2}, :second, opts)
    assert_receive {:synthesized, "The complete transcript", %{delivery_id: id}}
    assert id == prepared.intent_id
    assert_receive {:enqueued, %OutboundPayload{kind: :voice, content: %{audio_bytes: "fake"}}}
  end

  test "normalizes edit text and ignores attachment receipts", %{opts: opts} do
    prepared = VoiceReplyDelivery.prepare(intent(), opts)
    VoiceReplyDelivery.expect(prepared, ["same", "same"], opts)

    receipt(prepared, "same", {:ok, 1}, :first, opts, :file)
    receipt(prepared, %{text: "same"}, {:error, :rejected}, :first, opts, :file)
    refute_receive {:synthesized, _, _}

    receipt(prepared, %{message_id: "1", text: "same"}, {:ok, 1}, :first, opts, :edit)
    refute_receive {:synthesized, _, _}
    receipt(prepared, %{"message_id" => "2", "text" => "same"}, {:ok, 2}, :second, opts, :edit)

    assert_receive {:synthesized, "The complete transcript", _}
    assert_receive {:enqueued, %OutboundPayload{kind: :voice}}
    refute_receive {:synthesized, _, _}
    refute_receive {:enqueued, _}
  end

  test "a rejected final edit or later chunk withholds audio", %{opts: opts} do
    for failure_position <- [:first, :last] do
      message = %{intent() | run_id: "failed-#{failure_position}"}
      prepared = VoiceReplyDelivery.prepare(message, opts)
      VoiceReplyDelivery.expect(prepared, ["first", "last"], opts)
      first = if failure_position == :first, do: {:error, :deleted}, else: {:ok, 1}
      last = if failure_position == :last, do: {:error, :rejected}, else: {:ok, 2}
      receipt(prepared, %{message_id: "1", text: "first"}, first, :first, opts, :edit)
      receipt(prepared, "last", last, :last, opts)
    end

    refute_receive {:synthesized, _, _}
    refute_receive {:enqueued, _}
  end

  test "fallback and coalescer final identities share one asynchronous synthesis", %{opts: opts} do
    owner = self()

    opts =
      Keyword.put(opts, :synthesize, fn _, _, _ ->
        send(owner, {:provider_waiting, self()})

        receive do
          :release -> {:ok, %{audio_bytes: "fake", mime_type: "audio/ogg", filename: "reply.ogg"}}
        end
      end)

    original = VoiceReplyDelivery.prepare(intent(), opts)
    VoiceReplyDelivery.expect(original, ["transcript"], opts)
    receipt(original, "transcript", {:ok, 1}, :original, opts)
    assert_receive {:provider_waiting, provider}

    fallback =
      VoiceReplyDelivery.prepare(%{intent() | intent_id: "fallback", kind: :final_text}, opts)

    assert fallback.intent_id == original.intent_id
    VoiceReplyDelivery.expect(fallback, ["transcript"], opts)
    receipt(fallback, "transcript", {:ok, 2}, :fallback, opts)
    send(provider, :release)
    assert_receive {:enqueued, %OutboundPayload{kind: :voice}}
    refute_receive {:provider_waiting, _}
    refute_receive {:enqueued, _}
  end

  test "intermediate stream and final text do not claim the terminal answer identity", %{
    opts: opts
  } do
    for kind <- [:stream_finalize, :final_text] do
      intermediate = %{
        intent()
        | kind: kind,
          run_id: "intermediate-#{kind}",
          body: %{text: "Still working"},
          meta: %{inbound_voice: true, terminal_answer: false}
      }

      assert VoiceReplyDelivery.prepare(intermediate, opts) == intermediate
      VoiceReplyDelivery.expect(intermediate, ["Still working"], opts)
      receipt(intermediate, "Still working", {:ok, 1}, :intermediate, opts)
      refute_receive {:synthesized, _, _}

      terminal = %{
        intermediate
        | body: %{text: "The terminal answer"},
          meta: %{inbound_voice: true, terminal_answer: true}
      }

      prepared = VoiceReplyDelivery.prepare(terminal, opts)
      VoiceReplyDelivery.expect(prepared, ["The terminal answer"], opts)
      receipt(prepared, "The terminal answer", {:ok, 2}, :terminal, opts)
      assert_receive {:synthesized, "The terminal answer", _}
      assert_receive {:enqueued, %OutboundPayload{kind: :voice}}
      refute_receive {:synthesized, _, _}
    end
  end

  test "never synthesizes text inbound, disabled channels, unsupported channels, or snapshots", %{
    opts: opts
  } do
    for {message, options} <- [
          {%{intent() | meta: %{}}, opts},
          {intent(), Keyword.put(opts, :config, %{enabled: false})},
          {intent(), Keyword.put(opts, :supported?, false)},
          {%{intent() | kind: :stream_snapshot}, opts}
        ] do
      assert VoiceReplyDelivery.prepare(message, options) == message
    end

    refute_receive {:synthesized, _, _}
  end

  test "synthesis failures retain text-only delivery", %{opts: opts} do
    opts = Keyword.put(opts, :synthesize, fn _, _, _ -> {:error, :audio_too_large} end)
    prepared = VoiceReplyDelivery.prepare(intent(), opts)
    VoiceReplyDelivery.expect(prepared, ["transcript"], opts)
    receipt(prepared, "transcript", {:ok, 1}, :final, opts)
    refute_receive {:enqueued, _}
  end
end
