defmodule LemonChannels.Adapters.Telegram.Transport.PollerTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.Poller

  # ---------------------------------------------------------------------------
  # Mock API modules (pre-defined to avoid dynamic module creation issues)
  # ---------------------------------------------------------------------------

  defmodule EmptyAPI do
    def get_updates(_token, _offset, _timeout_ms) do
      {:ok, %{"ok" => true, "result" => []}}
    end

    def send_message(_token, _chat_id, _text, _opts \\ nil, _parse \\ nil),
      do: {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}

    def delete_webhook(_token, _opts \\ []), do: {:ok, %{"ok" => true}}
    def set_message_reaction(_token, _chat_id, _msg_id, _emoji, _opts \\ %{}), do: {:ok, %{"ok" => true}}
  end

  defmodule TwoUpdatesAPI do
    def get_updates(_token, _offset, _timeout_ms) do
      {:ok, %{"ok" => true, "result" => [
        %{"update_id" => 10, "message" => %{"text" => "hello", "chat" => %{"id" => 1}, "from" => %{"id" => 99}, "message_id" => 1, "date" => 1}},
        %{"update_id" => 11, "message" => %{"text" => "world", "chat" => %{"id" => 1}, "from" => %{"id" => 99}, "message_id" => 2, "date" => 1}}
      ]}}
    end

    def send_message(_token, _chat_id, _text, _opts \\ nil, _parse \\ nil),
      do: {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}

    def delete_webhook(_token, _opts \\ []), do: {:ok, %{"ok" => true}}
    def set_message_reaction(_token, _chat_id, _msg_id, _emoji, _opts \\ %{}), do: {:ok, %{"ok" => true}}
  end

  defmodule PendingUpdatesAPI do
    def get_updates(_token, _offset, _timeout_ms) do
      {:ok, %{"ok" => true, "result" => [
        %{"update_id" => 100, "message" => %{"text" => "old", "chat" => %{"id" => 1}, "from" => %{"id" => 99}, "message_id" => 1, "date" => 1}},
        %{"update_id" => 101, "message" => %{"text" => "old2", "chat" => %{"id" => 1}, "from" => %{"id" => 99}, "message_id" => 2, "date" => 1}}
      ]}}
    end

    def send_message(_token, _chat_id, _text, _opts \\ nil, _parse \\ nil),
      do: {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}

    def delete_webhook(_token, _opts \\ []), do: {:ok, %{"ok" => true}}
    def set_message_reaction(_token, _chat_id, _msg_id, _emoji, _opts \\ %{}), do: {:ok, %{"ok" => true}}
  end

  defmodule ErrorAPI do
    def get_updates(_token, _offset, _timeout_ms), do: {:error, :timeout}
    def delete_webhook(_token, _opts \\ []), do: {:ok, %{"ok" => true}}
  end

  # ---------------------------------------------------------------------------
  # initial_offset/2
  # ---------------------------------------------------------------------------

  describe "initial_offset/2" do
    test "returns config offset when it is an integer" do
      assert Poller.initial_offset(42, 100) == 42
    end

    test "returns stored offset when config offset is nil" do
      assert Poller.initial_offset(nil, 100) == 100
    end

    test "returns 0 when both config and stored offsets are nil" do
      assert Poller.initial_offset(nil, nil) == 0
    end

    test "prefers config offset over stored offset" do
      assert Poller.initial_offset(5, 99) == 5
    end

    test "returns 0 when config is a non-integer and stored is nil" do
      assert Poller.initial_offset("not_an_int", nil) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # max_update_id/2
  # ---------------------------------------------------------------------------

  describe "max_update_id/2" do
    test "returns offset - 1 for empty list" do
      assert Poller.max_update_id([], 10) == 9
    end

    test "returns the maximum update_id from updates" do
      updates = [
        %{"update_id" => 5},
        %{"update_id" => 12},
        %{"update_id" => 8}
      ]

      assert Poller.max_update_id(updates, 1) == 12
    end

    test "ignores updates without integer update_id" do
      updates = [
        %{"update_id" => 5},
        %{"update_id" => nil},
        %{"other" => "data"}
      ]

      assert Poller.max_update_id(updates, 1) == 5
    end

    test "uses offset - 1 as baseline when all update_ids are below it" do
      updates = [%{"update_id" => 3}]
      assert Poller.max_update_id(updates, 100) == 99
    end

    test "handles single update" do
      updates = [%{"update_id" => 42}]
      assert Poller.max_update_id(updates, 1) == 42
    end
  end

  # ---------------------------------------------------------------------------
  # poll_updates/2
  # ---------------------------------------------------------------------------

  describe "poll_updates/2" do
    test "processes updates and advances offset" do
      state = base_state(offset: 10, api_mod: TwoUpdatesAPI)
      process_fn = fn acc_state, _update, _id -> acc_state end

      result = Poller.poll_updates(state, process_fn)
      assert result.offset == 12
    end

    test "does not advance offset on empty updates" do
      state = base_state(offset: 10, api_mod: EmptyAPI)

      result = Poller.poll_updates(state, fn s, _u, _id -> s end)
      assert result.offset == 10
    end

    test "handles API error gracefully" do
      state = base_state(offset: 10, api_mod: ErrorAPI)

      result = Poller.poll_updates(state, fn s, _u, _id -> s end)
      # poll_updates pattern-matches {:error, reason}, so :timeout is stored
      assert result.last_poll_error == :timeout
    end

    test "drops pending updates when configured" do
      state =
        base_state(offset: 0, api_mod: PendingUpdatesAPI)
        |> Map.put(:drop_pending_updates?, true)
        |> Map.put(:drop_pending_done?, false)

      process_fn = fn _s, _u, _id -> raise "should not be called" end
      result = Poller.poll_updates(state, process_fn)
      assert result.offset == 102
      assert result.drop_pending_done? == false
    end

    test "marks drop_pending_done when empty batch received during drop" do
      state =
        base_state(offset: 100, api_mod: EmptyAPI)
        |> Map.put(:drop_pending_updates?, true)
        |> Map.put(:drop_pending_done?, false)

      result = Poller.poll_updates(state, fn s, _u, _id -> s end)
      assert result.drop_pending_done? == true
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_state(opts) do
    api_mod = Keyword.get(opts, :api_mod, EmptyAPI)
    offset = Keyword.get(opts, :offset, 0)

    %{
      token: "test_token",
      api_mod: api_mod,
      offset: offset,
      poll_interval_ms: 1000,
      account_id: "test",
      drop_pending_updates?: false,
      drop_pending_done?: true,
      last_poll_error: nil,
      last_poll_error_log_ts: nil,
      last_webhook_clear_ts: nil
    }
  end
end
