defmodule LemonCore.OutputIntentTest do
  use ExUnit.Case, async: true

  alias LemonCore.{ChannelRoute, OutputIntent}

  @valid_route %ChannelRoute{
    channel_id: "telegram",
    account_id: "bot_123",
    peer_kind: :dm,
    peer_id: "456"
  }

  describe "struct creation" do
    test "creates intent with required fields and defaults" do
      intent = %OutputIntent{
        route: @valid_route,
        op: :final_text
      }

      assert intent.route == @valid_route
      assert intent.op == :final_text
      assert intent.body == %{}
      assert intent.meta == %{}
    end

    test "creates intent with body and meta" do
      intent = %OutputIntent{
        route: @valid_route,
        op: :stream_append,
        body: %{text: "hello world"},
        meta: %{run_id: "run_1", seq: 5}
      }

      assert intent.body == %{text: "hello world"}
      assert intent.meta == %{run_id: "run_1", seq: 5}
    end
  end

  describe "all op types" do
    test "accepts :stream_append" do
      intent = %OutputIntent{route: @valid_route, op: :stream_append}
      assert intent.op == :stream_append
    end

    test "accepts :stream_replace" do
      intent = %OutputIntent{route: @valid_route, op: :stream_replace}
      assert intent.op == :stream_replace
    end

    test "accepts :tool_status" do
      intent = %OutputIntent{route: @valid_route, op: :tool_status}
      assert intent.op == :tool_status
    end

    test "accepts :keepalive_prompt" do
      intent = %OutputIntent{route: @valid_route, op: :keepalive_prompt}
      assert intent.op == :keepalive_prompt
    end

    test "accepts :final_text" do
      intent = %OutputIntent{route: @valid_route, op: :final_text}
      assert intent.op == :final_text
    end

    test "accepts :fanout_text" do
      intent = %OutputIntent{route: @valid_route, op: :fanout_text}
      assert intent.op == :fanout_text
    end

    test "accepts :send_files" do
      intent = %OutputIntent{route: @valid_route, op: :send_files}
      assert intent.op == :send_files
    end
  end

  describe "enforce_keys" do
    test "raises when route is missing" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(OutputIntent, %{op: :final_text})
      end
    end

    test "raises when op is missing" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(OutputIntent, %{route: @valid_route})
      end
    end
  end

  describe "struct!/2" do
    test "creates intent from keyword list via struct!" do
      intent =
        struct!(OutputIntent,
          route: @valid_route,
          op: :send_files,
          body: %{files: [%{path: "/tmp/a.png"}]},
          meta: %{run_id: "r1"}
        )

      assert %OutputIntent{} = intent
      assert intent.op == :send_files
      assert intent.body == %{files: [%{path: "/tmp/a.png"}]}
    end
  end

  describe "body defaults" do
    test "body defaults to empty map" do
      intent = %OutputIntent{route: @valid_route, op: :final_text}
      assert intent.body == %{}
    end

    test "meta defaults to empty map" do
      intent = %OutputIntent{route: @valid_route, op: :final_text}
      assert intent.meta == %{}
    end
  end
end
