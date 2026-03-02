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

  # ---------------------------------------------------------------
  # render_prompt_actions/2 — channel-specific action rendering
  # ---------------------------------------------------------------

  describe "render_prompt_actions/2" do
    test "returns nil for nil actions" do
      assert Dispatcher.render_prompt_actions("telegram", nil) == nil
      assert Dispatcher.render_prompt_actions("discord", nil) == nil
    end

    test "returns nil for empty actions list" do
      assert Dispatcher.render_prompt_actions("telegram", []) == nil
      assert Dispatcher.render_prompt_actions("discord", []) == nil
    end

    test "renders Telegram inline keyboard from actions" do
      actions = [
        %{id: "lemon:idle:c:run_1", label: "Keep Waiting"},
        %{id: "lemon:idle:k:run_1", label: "Stop Run"}
      ]

      result = Dispatcher.render_prompt_actions("telegram", actions)

      assert %{"inline_keyboard" => [buttons]} = result
      assert length(buttons) == 2

      [keep_btn, stop_btn] = buttons
      assert keep_btn == %{"text" => "Keep Waiting", "callback_data" => "lemon:idle:c:run_1"}
      assert stop_btn == %{"text" => "Stop Run", "callback_data" => "lemon:idle:k:run_1"}
    end

    test "renders Telegram inline keyboard with string keys" do
      actions = [
        %{"id" => "cb_1", "label" => "Button 1"}
      ]

      result = Dispatcher.render_prompt_actions("telegram", actions)

      assert %{"inline_keyboard" => [[btn]]} = result
      assert btn == %{"text" => "Button 1", "callback_data" => "cb_1"}
    end

    test "renders structured actions for non-Telegram channels" do
      actions = [
        %{id: "action_1", label: "Do Thing"},
        %{id: "action_2", label: "Other Thing"}
      ]

      result = Dispatcher.render_prompt_actions("discord", actions)
      assert result == %{"actions" => actions}
    end

    test "renders structured actions for generic channels" do
      actions = [%{id: "a1", label: "OK"}]

      result = Dispatcher.render_prompt_actions("xmtp", actions)
      assert result == %{"actions" => actions}
    end
  end

  # ---------------------------------------------------------------
  # intent_to_payload_with_actions/1 — keepalive prompt payloads
  # ---------------------------------------------------------------

  describe "intent_to_payload_with_actions/1" do
    test "includes Telegram inline keyboard in payload meta" do
      actions = [
        %{id: "lemon:idle:c:run_abc", label: "Keep Waiting"},
        %{id: "lemon:idle:k:run_abc", label: "Stop Run"}
      ]

      intent = %OutputIntent{
        route: @route,
        op: :keepalive_prompt,
        body: %{text: "Still running...", actions: actions},
        meta: %{
          idempotency_key: "run_abc:watchdog:prompt:120000",
          run_id: "run_abc"
        }
      }

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      assert %OutboundPayload{} = payload
      assert payload.kind == :text
      assert payload.content == "Still running..."
      assert payload.channel_id == "telegram"

      # The Telegram inline keyboard should be in meta.reply_markup
      assert %{"inline_keyboard" => [buttons]} = payload.meta[:reply_markup]
      assert length(buttons) == 2
    end

    test "includes structured actions for non-Telegram channels" do
      actions = [%{id: "act_1", label: "Continue"}]

      intent = %OutputIntent{
        route: @route_with_thread,
        op: :keepalive_prompt,
        body: %{text: "Prompt text", actions: actions},
        meta: %{idempotency_key: "test:actions:1"}
      }

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      assert payload.channel_id == "discord"
      assert payload.meta[:reply_markup] == %{"actions" => actions}
    end

    test "omits reply_markup when no actions provided" do
      intent = %OutputIntent{
        route: @route,
        op: :keepalive_prompt,
        body: %{text: "No actions here"},
        meta: %{idempotency_key: "test:no-actions:1"}
      }

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      refute Map.has_key?(payload.meta, :reply_markup)
    end

    test "maps route and meta fields correctly" do
      pid = self()
      ref = make_ref()

      intent = %OutputIntent{
        route: @route_with_thread,
        op: :keepalive_prompt,
        body: %{text: "test", actions: [%{id: "a", label: "A"}]},
        meta: %{
          idempotency_key: "ik_actions",
          reply_to: "msg_1",
          notify_pid: pid,
          notify_ref: ref,
          run_id: "r_1"
        }
      }

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      assert payload.idempotency_key == "ik_actions"
      assert payload.reply_to == "msg_1"
      assert payload.notify_pid == pid
      assert payload.notify_ref == ref
      assert payload.meta[:run_id] == "r_1"

      # Reserved keys should not be in meta
      refute Map.has_key?(payload.meta, :idempotency_key)
      refute Map.has_key?(payload.meta, :reply_to)
      refute Map.has_key?(payload.meta, :notify_pid)
      refute Map.has_key?(payload.meta, :notify_ref)
    end
  end

  # ---------------------------------------------------------------
  # dispatch_with_actions/1 — delivery with action rendering
  # ---------------------------------------------------------------

  describe "dispatch_with_actions/1" do
    test "returns :ok when Outbox is running" do
      actions = [
        %{id: "lemon:idle:c:run_x", label: "Keep Waiting"},
        %{id: "lemon:idle:k:run_x", label: "Stop Run"}
      ]

      intent = %OutputIntent{
        route: @route,
        op: :keepalive_prompt,
        body: %{text: "Watchdog prompt", actions: actions},
        meta: %{idempotency_key: "dispatch-actions-#{System.unique_integer([:positive])}"}
      }

      assert :ok = Dispatcher.dispatch_with_actions(intent)
    end
  end
end
