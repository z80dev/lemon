defmodule LemonCore.StoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store

  defp unique_token do
    System.unique_integer([:positive, :monotonic])
  end

  defp scope(token, name), do: {:store_test, token, name}
  defp run_id(token, name), do: "run_#{token}_#{name}"
  defp session_key(token), do: "agent:store_test_#{token}:main"

  describe "chat state TTL semantics" do
    test "put_chat_state persists expires_at using configured TTL" do
      token = unique_token()
      chat_scope = scope(token, :ttl)
      ttl_ms = :sys.get_state(Store).chat_state_ttl_ms

      before_put = System.system_time(:millisecond)
      :ok = Store.put_chat_state(chat_scope, %{phase: :active})
      stored = Store.get(:chat, chat_scope)
      after_put = System.system_time(:millisecond)

      assert %{phase: :active, expires_at: expires_at} = stored
      assert expires_at >= before_put + ttl_ms
      assert expires_at <= after_put + ttl_ms
      assert %{phase: :active} = Store.get_chat_state(chat_scope)
    end

    test "get_chat_state lazily evicts expired state" do
      token = unique_token()
      chat_scope = scope(token, :lazy_expiry)

      :ok =
        Store.put(:chat, chat_scope, %{
          phase: :stale,
          expires_at: System.system_time(:millisecond) - 1
        })

      assert Store.get_chat_state(chat_scope) == nil
      assert Store.get(:chat, chat_scope) == nil
    end

    test "periodic sweep removes expired entries and keeps live entries" do
      token = unique_token()
      expired_scope = scope(token, :sweep_expired)
      live_scope = scope(token, :sweep_live)
      now = System.system_time(:millisecond)

      :ok = Store.put(:chat, expired_scope, %{phase: :expired, expires_at: now - 1})
      :ok = Store.put(:chat, live_scope, %{phase: :live, expires_at: now + 60_000})

      send(Store, :sweep_expired_chat_states)

      # `get/2` is a call, so it acts as a barrier after the sweep message.
      assert Store.get(:chat, expired_scope) == nil
      assert %{phase: :live} = Store.get(:chat, live_scope)
    end
  end

  describe "run history ordering/backfill" do
    test "get_run_history orders finalized runs by newest started_at first" do
      token = unique_token()
      scope = scope(token, :history)
      session_key = session_key(token)

      oldest = run_id(token, :oldest)
      middle = run_id(token, :middle)
      newest = run_id(token, :newest)

      :ok = Store.put(:runs, oldest, %{events: [%{step: 1}], summary: nil, started_at: 1_000})
      :ok = Store.put(:runs, middle, %{events: [%{step: 2}], summary: nil, started_at: 2_000})
      :ok = Store.put(:runs, newest, %{events: [%{step: 3}], summary: nil, started_at: 3_000})

      :ok = Store.finalize_run(oldest, %{scope: scope, session_key: session_key})
      :ok = Store.finalize_run(middle, %{scope: scope, session_key: session_key})
      :ok = Store.finalize_run(newest, %{scope: scope, session_key: session_key})

      history = Store.get_run_history(session_key, limit: 10)

      assert Enum.map(history, &elem(&1, 0)) == [newest, middle, oldest]
      assert Enum.map(history, fn {_run_id, data} -> data.started_at end) == [3_000, 2_000, 1_000]
    end

    test "supports backfilled run_history rows and applies ordering/limit consistently" do
      token = unique_token()
      scope = scope(token, :backfill)
      session_key = session_key(token)

      tuple_run = run_id(token, :tuple)
      backfilled_run = run_id(token, :backfilled)
      legacy_scope_run = run_id(token, :legacy_scope)

      :ok =
        Store.put(
          :run_history,
          {session_key, 2_000, tuple_run},
          %{
            events: [%{kind: :tuple}],
            summary: %{scope: scope, session_key: session_key},
            session_key: session_key,
            scope: scope,
            run_id: tuple_run,
            started_at: 2_000
          }
        )

      :ok =
        Store.put(
          :run_history,
          "backfill_row_#{token}",
          %{
            events: [%{kind: :backfill}],
            summary: %{scope: scope, session_key: session_key},
            session_key: session_key,
            scope: scope,
            run_id: backfilled_run,
            started_at: 1_500
          }
        )

      :ok =
        Store.put(
          :run_history,
          {scope, 1_000, legacy_scope_run},
          %{
            events: [%{kind: :legacy_scope}],
            summary: %{scope: scope},
            scope: scope,
            started_at: 1_000
          }
        )

      scoped_history = Store.get_run_history(scope, limit: 10)

      assert Enum.map(scoped_history, &elem(&1, 0)) == [
               tuple_run,
               backfilled_run,
               legacy_scope_run
             ]

      scoped_limited = Store.get_run_history(scope, limit: 2)
      assert Enum.map(scoped_limited, &elem(&1, 0)) == [tuple_run, backfilled_run]

      session_history = Store.get_run_history(session_key, limit: 10)
      assert Enum.map(session_history, &elem(&1, 0)) == [tuple_run, backfilled_run]
    end
  end

  describe "progress mapping put/get/delete" do
    test "stores, overwrites, isolates by scope, and deletes mappings" do
      token = unique_token()
      scope_a = scope(token, :progress_a)
      scope_b = scope(token, :progress_b)
      progress_msg_id = 42_001

      assert Store.get_run_by_progress(scope_a, progress_msg_id) == nil

      :ok = Store.put_progress_mapping(scope_a, progress_msg_id, "run_a_v1")
      :ok = Store.put_progress_mapping(scope_b, progress_msg_id, "run_b_v1")

      assert Store.get_run_by_progress(scope_a, progress_msg_id) == "run_a_v1"
      assert Store.get_run_by_progress(scope_b, progress_msg_id) == "run_b_v1"

      :ok = Store.put_progress_mapping(scope_a, progress_msg_id, "run_a_v2")
      assert Store.get_run_by_progress(scope_a, progress_msg_id) == "run_a_v2"

      :ok = Store.delete_progress_mapping(scope_a, progress_msg_id)

      assert Store.get_run_by_progress(scope_a, progress_msg_id) == nil
      assert Store.get(:progress, {scope_a, progress_msg_id}) == nil
      assert Store.get_run_by_progress(scope_b, progress_msg_id) == "run_b_v1"
    end
  end
end
