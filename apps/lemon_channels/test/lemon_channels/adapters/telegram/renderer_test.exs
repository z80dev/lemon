defmodule LemonChannels.Adapters.Telegram.RendererTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Renderer
  alias LemonChannels.{PresentationState, Registry}
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  defmodule TelegramRendererPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "telegram"

    @impl true
    def meta do
      %{
        label: "Telegram Renderer Test",
        capabilities: %{
          edit_support: true,
          chunk_limit: 4096
        },
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}

    @impl true
    def deliver(payload) do
      if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        send(pid, {:delivered, payload})
      end

      maybe_block_edit(payload)
      {:ok, %{"ok" => true, "result" => %{"message_id" => 3101}}}
    end

    @impl true
    def gateway_methods, do: []

    defp maybe_block_edit(%LemonChannels.OutboundPayload{kind: :edit} = payload) do
      if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        send(pid, {:edit_started, self(), payload})
      end

      if :persistent_term.get({__MODULE__, :block_edit}, false) do
        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end
      end
    end

    defp maybe_block_edit(_payload), do: :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)
    :persistent_term.put({TelegramRendererPlugin, :notify_pid}, self())
    :persistent_term.put({TelegramRendererPlugin, :block_edit}, false)

    existing = Registry.get_plugin("telegram")
    _ = Registry.unregister("telegram")
    :ok = Registry.register(TelegramRendererPlugin)

    on_exit(fn ->
      :persistent_term.erase({TelegramRendererPlugin, :notify_pid})
      :persistent_term.erase({TelegramRendererPlugin, :block_edit})

      if is_pid(Process.whereis(Registry)) do
        _ = Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = Registry.register(existing)
        end
      end
    end)

    :ok
  end

  test "dispatch/1 truncates long telegram text before delivery" do
    route = route("321")
    run_id = "run-#{System.unique_integer([:positive])}"
    long_text = String.duplicate("a", 5_500)

    assert :ok = Renderer.dispatch(intent(run_id, route, :final_text, %{text: long_text}))

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      content: delivered_text
                    }},
                   1_000

    assert is_binary(delivered_text)
    assert String.length(delivered_text) <= 4_096
  end

  test "dispatch/1 sends then edits answer text using channels-owned presentation state" do
    route = route("654")
    run_id = "run-#{System.unique_integer([:positive])}"

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :stream_snapshot, %{text: "hello", seq: 1}))

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      content: "hello",
                      peer: %{id: "654"}
                    }},
                   1_000

    assert eventually(fn ->
             PresentationState.get(route, run_id, :answer).platform_message_id == 3101
           end)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :stream_snapshot, %{text: "hello world", seq: 2})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      content: %{message_id: "3101", text: text}
                    }},
                   1_000

    assert String.contains?(text, "hello world")
  end

  test "dispatch/1 coalesces new telegram text while an edit is still in flight" do
    route = route("777")
    run_id = "run-#{System.unique_integer([:positive])}"

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :stream_snapshot, %{text: "hello", seq: 1}))

    assert_receive {:delivered, %LemonChannels.OutboundPayload{kind: :text}}, 1_000

    assert eventually(fn ->
             PresentationState.get(route, run_id, :answer).platform_message_id == 3101
           end)

    :persistent_term.put({TelegramRendererPlugin, :block_edit}, true)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :stream_snapshot, %{text: "hello world", seq: 2})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: "hello world"}
                    }},
                   1_000

    assert_receive {:edit_started, worker, _payload}, 1_000

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :stream_snapshot, %{text: "hello newest", seq: 3})
             )

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{text: "hello newest"}
                    }},
                   150

    send(worker, :release)
    :persistent_term.put({TelegramRendererPlugin, :block_edit}, false)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: "hello newest"}
                    }},
                   1_000
  end

  test "dispatch/1 waits for the final edit ack before sending long-message tail chunks" do
    route = route("887")
    run_id = "run-#{System.unique_integer([:positive])}"
    long_text = String.duplicate("x", 5_500)

    :ok = PresentationState.mark_sent(route, run_id, :answer, 1, 111, 3101)
    :persistent_term.put({TelegramRendererPlugin, :block_edit}, true)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :final_text, %{text: long_text, seq: 2}, %{user_msg_id: "55"})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: first_chunk}
                    }},
                   1_000

    assert_receive {:edit_started, worker, _payload}, 1_000

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text
                    }},
                   150

    send(worker, :release)
    :persistent_term.put({TelegramRendererPlugin, :block_edit}, false)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: second_chunk,
                      reply_to: "55"
                    }},
                   1_000

    assert String.length(first_chunk) <= 4_096
    assert String.length(second_chunk) <= 4_096
    assert first_chunk <> second_chunk == long_text
  end

  test "stage_followups/5 sends tails immediately when the first chunk was already acked" do
    route = route("887-late-stage")
    run_id = "run-#{System.unique_integer([:positive])}"

    :ok = PresentationState.mark_sent(route, run_id, :answer, 1, 111, 3101)

    assert :ok =
             PresentationState.stage_followups(
               route,
               run_id,
               :answer,
               ["tail-1", "tail-2"],
               %{followup_reply_to: "55"}
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: "tail-1",
                      reply_to: "55"
                    }},
                   1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: "tail-2",
                      reply_to: "55"
                    }},
                   1_000

    assert eventually(fn ->
             entry = PresentationState.get(route, run_id, :answer)
             is_nil(entry.pending_followup_chunks)
           end)
  end

  test "defer_chunks/7 flushes immediately when the first chunk was already acked" do
    route = route("887-late-defer")
    run_id = "run-#{System.unique_integer([:positive])}"

    :ok = PresentationState.mark_sent(route, run_id, :answer, 1, 111, 3101)

    assert :ok =
             PresentationState.defer_chunks(
               route,
               run_id,
               :answer,
               ["first-final", "tail-final"],
               2,
               222,
               %{followup_reply_to: "55", intent_kind: :stream_finalize}
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: "first-final"}
                    }},
                   1_000

    assert eventually(fn ->
             entry = PresentationState.get(route, run_id, :answer)
             is_nil(entry.deferred_chunks) and is_nil(entry.deferred_text) and
               entry.last_text_hash == 222
           end)
  end

  test "dispatch/1 waits for the initial create ack before sending long-message tail chunks" do
    route = route("887-create")
    run_id = "run-#{System.unique_integer([:positive])}"
    long_text = String.duplicate("z", 5_500)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :final_text, %{text: long_text, seq: 1}, %{user_msg_id: "55"})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: first_chunk,
                      reply_to: "55"
                    }},
                   1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: second_chunk,
                      reply_to: "55"
                    }},
                   1_000

    assert String.length(first_chunk) <= 4_096
    assert String.length(second_chunk) <= 4_096
    assert first_chunk <> second_chunk == long_text
  end

  test "dispatch/1 flushes deferred long text as edit plus follow-up chunks after create ack" do
    route = route("888")
    run_id = "run-#{System.unique_integer([:positive])}"
    create_ref = make_ref()
    long_text = String.duplicate("a", 5_500)

    :ok = PresentationState.register_pending_create(route, run_id, :answer, create_ref, 1, 111)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :final_text, %{text: long_text, seq: 2}, %{user_msg_id: "42"})
             )

    refute_receive {:delivered, _payload}, 150

    :persistent_term.put({TelegramRendererPlugin, :block_edit}, true)

    send(
      PresentationState,
      {:presentation_delivery, create_ref, {:ok, %{"result" => %{"message_id" => 3101}}}}
    )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: first_chunk}
                    }},
                   1_000

    assert_receive {:edit_started, worker, _payload}, 1_000

    flushed_ref = PresentationState.get(route, run_id, :answer).pending_edit_ref
    assert is_reference(flushed_ref)

    send(worker, :release)
    :persistent_term.put({TelegramRendererPlugin, :block_edit}, false)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: second_chunk,
                      reply_to: "42"
                    }},
                   1_000

    assert String.length(first_chunk) <= 4_096
    assert String.length(second_chunk) <= 4_096
    assert first_chunk <> second_chunk == long_text

    assert eventually(fn ->
             is_nil(PresentationState.get(route, run_id, :answer).pending_edit_ref)
           end)
  end

  test "dispatch/1 defers all chunks while an edit is in flight" do
    route = route("889")
    run_id = "run-#{System.unique_integer([:positive])}"
    in_flight_ref = make_ref()
    long_text = String.duplicate("b", 5_500)

    :ok = PresentationState.mark_sent(route, run_id, :answer, 1, 111, 3101)

    :ok =
      PresentationState.register_pending_edit(route, run_id, :answer, in_flight_ref, 2, 222, 3101)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :final_text, %{text: long_text, seq: 3}, %{user_msg_id: "77"})
             )

    refute_receive {:delivered, _payload}, 150

    send(PresentationState, {:presentation_delivery, in_flight_ref, {:ok, %{"ok" => true}}})

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: first_chunk}
                    }},
                   1_000

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: second_chunk,
                      reply_to: "77"
                    }},
                   1_000

    assert String.length(first_chunk) <= 4_096
    assert String.length(second_chunk) <= 4_096
    assert first_chunk <> second_chunk == long_text
  end

  test "dispatch/1 drops superseded long-message tail chunks" do
    route = route("892")
    run_id = "run-#{System.unique_integer([:positive])}"
    create_ref = make_ref()
    long_text_a = String.duplicate("a", 5_500)
    long_text_b = String.duplicate("c", 5_500)
    second_chunk_a = String.duplicate("a", 1_404)

    :ok = PresentationState.register_pending_create(route, run_id, :answer, create_ref, 1, 111)

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :final_text, %{text: long_text_a, seq: 2}))

    :persistent_term.put({TelegramRendererPlugin, :block_edit}, true)

    send(
      PresentationState,
      {:presentation_delivery, create_ref, {:ok, %{"result" => %{"message_id" => 3101}}}}
    )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: delivered_first_chunk_a}
                    }},
                   1_000

    assert String.starts_with?(delivered_first_chunk_a, "a")

    assert_receive {:edit_started, first_worker, _payload}, 1_000

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :final_text, %{text: long_text_b, seq: 3}))

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: ^second_chunk_a
                    }},
                   150

    send(first_worker, :release)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: delivered_first_chunk_b}
                    }},
                   1_000

    assert String.starts_with?(delivered_first_chunk_b, "c")

    assert_receive {:edit_started, second_worker, _payload}, 1_000

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: ^second_chunk_a
                    }},
                   150

    :persistent_term.put({TelegramRendererPlugin, :block_edit}, false)
    send(second_worker, :release)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: delivered_second_chunk_b
                    }},
                   1_000

    assert String.starts_with?(delivered_second_chunk_b, "c")
  end

  test "dispatch/1 clears duplicate create refs so later sends are not blocked" do
    route = route("890")
    run_id = "run-#{System.unique_integer([:positive])}"
    duplicate_intent_id = "#{run_id}:duplicate-create"

    LemonChannels.Outbox.Dedupe.mark("telegram", duplicate_intent_id)

    assert :ok =
             Renderer.dispatch(%DeliveryIntent{
               intent(run_id, route, :stream_snapshot, %{text: "hello", seq: 1})
               | intent_id: duplicate_intent_id
             })

    assert eventually(fn ->
             entry = PresentationState.get(route, run_id, :answer)
             is_nil(entry.pending_create_ref)
           end)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :stream_snapshot, %{text: "hello later", seq: 2})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: "hello later"
                    }},
                   1_000
  end

  test "dispatch/1 clears duplicate edit refs so later edits are not blocked" do
    route = route("891")
    run_id = "run-#{System.unique_integer([:positive])}"
    duplicate_intent_id = "#{run_id}:duplicate-edit"

    :ok = PresentationState.mark_sent(route, run_id, :answer, 1, 111, 3101)
    LemonChannels.Outbox.Dedupe.mark("telegram", duplicate_intent_id)

    assert :ok =
             Renderer.dispatch(%DeliveryIntent{
               intent(run_id, route, :stream_snapshot, %{text: "hello duplicate", seq: 2})
               | intent_id: duplicate_intent_id
             })

    assert eventually(fn ->
             entry = PresentationState.get(route, run_id, :answer)
             is_nil(entry.pending_edit_ref) and entry.platform_message_id == 3101
           end)

    assert :ok =
             Renderer.dispatch(
               intent(run_id, route, :stream_snapshot, %{text: "hello newest", seq: 3})
             )

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "3101", text: "hello newest"}
                   }},
                   1_000
  end

  test "dispatch/1 suppresses repeated identical final text even when seq increases" do
    route = route("893")
    run_id = "run-#{System.unique_integer([:positive])}"

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :final_text, %{text: "stable final", seq: 2}))

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: "stable final"
                    }},
                   1_000

    assert eventually(fn ->
             PresentationState.get(route, run_id, :answer).platform_message_id == 3101
           end)

    assert :ok =
             Renderer.dispatch(intent(run_id, route, :final_text, %{text: "stable final", seq: 3}))

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :edit
                    }},
                   150

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      kind: :text,
                      content: "stable final"
                    }},
                   150
  end

  defp route(peer_id) do
    %DeliveryRoute{
      channel_id: "telegram",
      account_id: "default",
      peer_kind: :dm,
      peer_id: peer_id
    }
  end

  defp intent(run_id, route, kind, body, meta \\ %{}) do
    %DeliveryIntent{
      intent_id: "#{run_id}:#{kind}:#{System.unique_integer([:positive])}",
      run_id: run_id,
      session_key: "agent:test:main",
      route: route,
      kind: kind,
      body: body,
      meta: meta
    }
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, attempts) when attempts <= 0, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
