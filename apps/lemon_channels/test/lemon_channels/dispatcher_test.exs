defmodule LemonChannels.DispatcherTest do
  use ExUnit.Case, async: true

  alias LemonCore.{ChannelRoute, OutputIntent}
  alias LemonChannels.{Dispatcher, OutboundPayload}

  @route %ChannelRoute{
    channel_id: "telegram",
    account_id: "bot_42",
    peer_kind: :dm,
    peer_id: "100",
    thread_id: nil
  }

  @route_with_thread %ChannelRoute{
    channel_id: "discord",
    account_id: "acc_d",
    peer_kind: :group,
    peer_id: "guild_1",
    thread_id: "thread_99"
  }

  # ---------------------------------------------------------------
  # intent_to_payload/1 — op translation
  # ---------------------------------------------------------------

  describe "intent_to_payload/1 :stream_append" do
    test "translates to :text payload with body text" do
      intent = %OutputIntent{
        route: @route,
        op: :stream_append,
        body: %{text: "streaming chunk"}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert %OutboundPayload{} = payload
      assert payload.kind == :text
      assert payload.content == "streaming chunk"
    end

    test "defaults to empty string when body has no text" do
      intent = %OutputIntent{route: @route, op: :stream_append, body: %{}}
      payload = Dispatcher.intent_to_payload(intent)

      assert payload.content == ""
    end
  end

  describe "intent_to_payload/1 :stream_replace" do
    test "translates to :edit payload with message_id and text" do
      intent = %OutputIntent{
        route: @route,
        op: :stream_replace,
        body: %{message_id: 42, text: "updated text"}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.kind == :edit
      assert payload.content == %{message_id: 42, text: "updated text"}
    end
  end

  describe "intent_to_payload/1 :tool_status" do
    test "translates to :text payload" do
      intent = %OutputIntent{
        route: @route,
        op: :tool_status,
        body: %{text: "Running bash..."}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.kind == :text
      assert payload.content == "Running bash..."
    end
  end

  describe "intent_to_payload/1 :keepalive_prompt" do
    test "translates to :text payload" do
      intent = %OutputIntent{
        route: @route,
        op: :keepalive_prompt,
        body: %{text: "Still working..."}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.kind == :text
      assert payload.content == "Still working..."
    end
  end

  describe "intent_to_payload/1 :final_text" do
    test "translates to :text payload" do
      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "Done!"}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.kind == :text
      assert payload.content == "Done!"
    end
  end

  describe "intent_to_payload/1 :fanout_text" do
    test "translates to :text payload" do
      intent = %OutputIntent{
        route: @route,
        op: :fanout_text,
        body: %{text: "Broadcast message"}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.kind == :text
      assert payload.content == "Broadcast message"
    end
  end

  describe "intent_to_payload/1 :send_files" do
    test "translates to :file payload with file list" do
      files = [%{path: "/tmp/img.png", filename: "img.png"}]

      intent = %OutputIntent{
        route: @route,
        op: :send_files,
        body: %{files: files}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.kind == :file
      assert payload.content == files
    end

    test "defaults to empty list when body has no files" do
      intent = %OutputIntent{route: @route, op: :send_files, body: %{}}
      payload = Dispatcher.intent_to_payload(intent)

      assert payload.content == []
    end
  end

  # ---------------------------------------------------------------
  # intent_to_payload/1 — route fields mapping
  # ---------------------------------------------------------------

  describe "intent_to_payload/1 route mapping" do
    test "maps channel_id and account_id from route" do
      intent = %OutputIntent{route: @route, op: :final_text, body: %{text: "hi"}}
      payload = Dispatcher.intent_to_payload(intent)

      assert payload.channel_id == "telegram"
      assert payload.account_id == "bot_42"
    end

    test "maps peer from route" do
      intent = %OutputIntent{route: @route, op: :final_text, body: %{text: "hi"}}
      payload = Dispatcher.intent_to_payload(intent)

      assert payload.peer == %{kind: :dm, id: "100", thread_id: nil}
    end

    test "maps peer with thread_id from route" do
      intent = %OutputIntent{route: @route_with_thread, op: :final_text, body: %{text: "hi"}}
      payload = Dispatcher.intent_to_payload(intent)

      assert payload.peer == %{kind: :group, id: "guild_1", thread_id: "thread_99"}
    end
  end

  # ---------------------------------------------------------------
  # intent_to_payload/1 — meta fields
  # ---------------------------------------------------------------

  describe "intent_to_payload/1 meta handling" do
    test "maps idempotency_key from meta" do
      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "x"},
        meta: %{idempotency_key: "run1:42"}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.idempotency_key == "run1:42"
    end

    test "maps reply_to from meta" do
      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "x"},
        meta: %{reply_to: "msg_99"}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.reply_to == "msg_99"
    end

    test "maps notify_pid and notify_ref from meta" do
      pid = self()
      ref = make_ref()

      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "x"},
        meta: %{notify_pid: pid, notify_ref: ref}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.notify_pid == pid
      assert payload.notify_ref == ref
    end

    test "extra meta fields pass through to payload meta (excluding reserved keys)" do
      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "x"},
        meta: %{
          run_id: "run_abc",
          session_key: "agent:test:main",
          idempotency_key: "ik",
          reply_to: "rt",
          notify_pid: self(),
          notify_ref: make_ref()
        }
      }

      payload = Dispatcher.intent_to_payload(intent)

      # Reserved keys are extracted to top-level payload fields
      assert payload.idempotency_key == "ik"
      assert payload.reply_to == "rt"
      assert payload.notify_pid == self()

      # Non-reserved keys go into meta
      assert payload.meta[:run_id] == "run_abc"
      assert payload.meta[:session_key] == "agent:test:main"

      # Reserved keys should not be duplicated in meta
      refute Map.has_key?(payload.meta, :idempotency_key)
      refute Map.has_key?(payload.meta, :reply_to)
      refute Map.has_key?(payload.meta, :notify_pid)
      refute Map.has_key?(payload.meta, :notify_ref)
    end

    test "nil meta values result in nil payload fields" do
      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "x"},
        meta: %{}
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.idempotency_key == nil
      assert payload.reply_to == nil
      assert payload.notify_pid == nil
      assert payload.notify_ref == nil
    end
  end

  # ---------------------------------------------------------------
  # dispatch/1 — delivery
  # ---------------------------------------------------------------

  describe "dispatch/1" do
    test "returns :ok when Outbox is running and accepts the payload" do
      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "test delivery"},
        meta: %{idempotency_key: "dispatch-test-#{System.unique_integer([:positive])}"}
      }

      # The Outbox is running in the lemon_channels test env (started by test_helper).
      # The payload will be accepted even if the channel adapter is unknown.
      assert :ok = Dispatcher.dispatch(intent)
    end

    test "returns :ok for duplicate idempotency key" do
      idem_key = "dispatch-dup-#{System.unique_integer([:positive])}"

      intent = %OutputIntent{
        route: @route,
        op: :final_text,
        body: %{text: "first"},
        meta: %{idempotency_key: idem_key}
      }

      # First dispatch succeeds
      assert :ok = Dispatcher.dispatch(intent)

      # Second dispatch with same idempotency key is treated as duplicate (still :ok)
      assert :ok = Dispatcher.dispatch(intent)
    end

    test "constructs correct payload for dispatch" do
      intent = %OutputIntent{
        route: @route_with_thread,
        op: :stream_append,
        body: %{text: "hello"},
        meta: %{
          idempotency_key: "dispatch-payload-#{System.unique_integer([:positive])}",
          run_id: "r_test"
        }
      }

      # Verify the payload translation is correct even in a dispatch context
      payload = Dispatcher.intent_to_payload(intent)
      assert payload.channel_id == "discord"
      assert payload.peer == %{kind: :group, id: "guild_1", thread_id: "thread_99"}
      assert payload.kind == :text
      assert payload.content == "hello"
    end
  end
end
