defmodule LemonChannels.OutboxChunkingTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{Outbox, OutboundPayload, Registry}
  alias LemonChannels.Outbox.{Chunker, Dedupe, RateLimiter}

  defmodule TrackingPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "outbox-chunk-contract"

    @impl true
    def meta do
      %{label: "Chunk contract", capabilities: %{chunk_limit: 100}, docs: nil}
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> [] end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def deliver(payload) do
      send(payload.meta.test_pid, {:chunk_payload, payload})
      {:ok, make_ref()}
    end

    @impl true
    def gateway_methods, do: []
  end

  setup do
    for module <- [Registry, RateLimiter, Dedupe, Outbox] do
      if is_nil(Process.whereis(module)), do: start_supervised!(module)
    end

    :ok = Registry.register(TrackingPlugin)
    on_exit(fn -> Registry.unregister(TrackingPlugin.id()) end)

    %{account: "chunk-account-#{System.unique_integer([:positive])}"}
  end

  test "delivers every chunk with only the first carrying reply, dedupe and notification identity",
       %{
         account: account
       } do
    content = String.duplicate("0123456789 ", 22)
    chunks = Chunker.chunk(content, chunk_size: 100)
    assert length(chunks) in 2..5
    notify_ref = make_ref()
    idempotency_key = "chunk-key-#{System.unique_integer([:positive])}"

    payload = %OutboundPayload{
      channel_id: TrackingPlugin.id(),
      account_id: account,
      peer: %{kind: :dm, id: "chunk-peer", thread_id: nil},
      kind: :text,
      content: content,
      reply_to: "original-message",
      idempotency_key: idempotency_key,
      notify_pid: self(),
      notify_ref: notify_ref,
      meta: %{test_pid: self(), notify_tag: :chunk_delivered}
    }

    assert {:ok, _ref} = Outbox.enqueue(payload)

    for {content, index} <- Enum.with_index(chunks) do
      assert_receive {:chunk_payload, delivered}, 1_000
      assert delivered.content == content
      assert delivered.meta.chunk_index == index
      assert delivered.meta.chunk_count == length(chunks)
      assert delivered.meta.is_continuation == index > 0
      assert delivered.account_id == account
      assert delivered.peer == payload.peer

      if index == 0 do
        assert delivered.reply_to == payload.reply_to
        assert delivered.idempotency_key == idempotency_key
        assert delivered.notify_pid == self()
        assert delivered.notify_ref == notify_ref
      else
        assert delivered.reply_to == nil
        assert delivered.idempotency_key == nil
        assert delivered.notify_pid == nil
        assert delivered.notify_ref == nil
      end
    end

    assert_receive {:chunk_delivered, ^notify_ref, {:ok, _}}, 1_000
    assert {:error, :duplicate} = Outbox.enqueue(payload)
    refute_receive {:chunk_delivered, ^notify_ref, _}, 100
    refute_receive {:chunk_payload, _}, 0
  end

  test "delivers non-text content unchanged without continuation metadata", %{account: account} do
    notify_ref = make_ref()

    payload = %OutboundPayload{
      channel_id: TrackingPlugin.id(),
      account_id: account,
      peer: %{kind: :dm, id: "image-peer", thread_id: nil},
      kind: :image,
      content: {:file, "/test/image.png"},
      notify_pid: self(),
      notify_ref: notify_ref,
      meta: %{test_pid: self(), notify_tag: :chunk_delivered}
    }

    assert {:ok, _ref} = Outbox.enqueue(payload)
    assert_receive {:chunk_payload, ^payload}, 1_000
    assert_receive {:chunk_delivered, ^notify_ref, {:ok, _}}, 1_000
    refute_receive {:chunk_payload, _}, 100
  end
end
