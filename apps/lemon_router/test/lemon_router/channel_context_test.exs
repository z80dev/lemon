defmodule LemonRouter.ChannelContextTest do
  use ExUnit.Case, async: true

  alias LemonRouter.ChannelContext

  describe "parse_session_key/1" do
    test "parses canonical channel session keys" do
      parsed = ChannelContext.parse_session_key("agent:a1:telegram:bot:group:123:thread:77")

      assert parsed.kind == :channel_peer
      assert parsed.channel_id == "telegram"
      assert parsed.account_id == "bot"
      assert parsed.peer_kind == :group
      assert parsed.peer_id == "123"
      assert parsed.thread_id == "77"
    end

    test "falls back to :unknown peer kind for invalid values" do
      parsed = ChannelContext.parse_session_key("agent:a1:telegram:bot:not_real:123")

      assert parsed.kind == :channel_peer
      assert parsed.channel_id == "telegram"
      assert parsed.peer_kind == :unknown
      assert parsed.peer_id == "123"
    end

    test "parses legacy telegram format" do
      parsed = ChannelContext.parse_session_key("channel:telegram:bot:12345:thread:9")

      assert parsed.kind == :channel_peer
      assert parsed.channel_id == "telegram"
      assert parsed.account_id == "bot"
      assert parsed.peer_kind == :dm
      assert parsed.peer_id == "12345"
      assert parsed.thread_id == "9"
    end
  end

  describe "helpers" do
    test "channel_id/1 returns channel only for channel peer sessions" do
      assert ChannelContext.channel_id("agent:a1:telegram:bot:dm:42") == {:ok, "telegram"}
      assert ChannelContext.channel_id("agent:a1:main") == :error
    end

    test "compact_meta/1 removes nil values" do
      assert ChannelContext.compact_meta(%{"c" => "x", a: 1, b: nil}) == %{"c" => "x", a: 1}
      assert ChannelContext.compact_meta(nil) == %{}
    end

    test "coalescer_meta_from_job/1 returns expected ids" do
      job = %{meta: %{progress_msg_id: 10, status_msg_id: 11, user_msg_id: 12, ignore: "x"}}

      assert ChannelContext.coalescer_meta_from_job(job) == %{
               progress_msg_id: 10,
               status_msg_id: 11,
               user_msg_id: 12
             }
    end

    test "parse_int/1 parses integer strings safely" do
      assert ChannelContext.parse_int("42") == 42
      assert ChannelContext.parse_int(99) == 99
      assert ChannelContext.parse_int("x") == nil
      assert ChannelContext.parse_int(nil) == nil
    end
  end
end
