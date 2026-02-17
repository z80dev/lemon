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
      session_key = session_key(token)

      oldest = run_id(token, :oldest)
      middle = run_id(token, :middle)
      newest = run_id(token, :newest)

      :ok = Store.put(:runs, oldest, %{events: [%{step: 1}], summary: nil, started_at: 1_000})
      :ok = Store.put(:runs, middle, %{events: [%{step: 2}], summary: nil, started_at: 2_000})
      :ok = Store.put(:runs, newest, %{events: [%{step: 3}], summary: nil, started_at: 3_000})

      :ok = Store.finalize_run(oldest, %{session_key: session_key})
      :ok = Store.finalize_run(middle, %{session_key: session_key})
      :ok = Store.finalize_run(newest, %{session_key: session_key})

      history = Store.get_run_history(session_key, limit: 10)

      assert Enum.map(history, &elem(&1, 0)) == [newest, middle, oldest]
      assert Enum.map(history, fn {_run_id, data} -> data.started_at end) == [3_000, 2_000, 1_000]
    end

    test "applies ordering/limit consistently for canonical run_history rows" do
      token = unique_token()
      session_key = session_key(token)

      older_run = run_id(token, :older)
      newer_run = run_id(token, :newer)

      :ok =
        Store.put(
          :run_history,
          {session_key, 2_000, older_run},
          %{
            events: [%{kind: :older}],
            summary: %{session_key: session_key},
            session_key: session_key,
            run_id: older_run,
            started_at: 2_000
          }
        )

      :ok =
        Store.put(
          :run_history,
          {session_key, 3_000, newer_run},
          %{
            events: [%{kind: :newer}],
            summary: %{session_key: session_key},
            session_key: session_key,
            run_id: newer_run,
            started_at: 3_000
          }
        )

      session_history = Store.get_run_history(session_key, limit: 10)
      assert Enum.map(session_history, &elem(&1, 0)) == [newer_run, older_run]

      session_limited = Store.get_run_history(session_key, limit: 1)
      assert Enum.map(session_limited, &elem(&1, 0)) == [newer_run]
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

  describe "policy wrapper API" do
    test "agent policy wrappers preserve table/key compatibility" do
      token = unique_token()
      agent_id = "agent_#{token}"
      policy = %{approvals: %{"bash" => :always}}

      :ok = Store.put_agent_policy(agent_id, policy)

      assert Store.get_agent_policy(agent_id) == policy
      assert Store.get(:agent_policies, agent_id) == policy
      assert {agent_id, policy} in Store.list_agent_policies()

      :ok = Store.delete_agent_policy(agent_id)
      assert Store.get_agent_policy(agent_id) == nil
      assert Store.get(:agent_policies, agent_id) == nil
    end

    test "channel policy wrappers preserve table/key compatibility" do
      token = unique_token()
      channel_id = "channel_#{token}"
      policy = %{blocked_tools: ["exec_raw"]}

      :ok = Store.put_channel_policy(channel_id, policy)

      assert Store.get_channel_policy(channel_id) == policy
      assert Store.get(:channel_policies, channel_id) == policy
      assert {channel_id, policy} in Store.list_channel_policies()

      :ok = Store.delete_channel_policy(channel_id)
      assert Store.get_channel_policy(channel_id) == nil
      assert Store.get(:channel_policies, channel_id) == nil
    end

    test "session policy wrappers preserve table/key compatibility" do
      token = unique_token()
      key = session_key(token)
      policy = %{thinking_level: "high"}

      :ok = Store.put_session_policy(key, policy)

      assert Store.get_session_policy(key) == policy
      assert Store.get(:session_policies, key) == policy
      assert {key, policy} in Store.list_session_policies()

      :ok = Store.delete_session_policy(key)
      assert Store.get_session_policy(key) == nil
      assert Store.get(:session_policies, key) == nil
    end

    test "runtime policy wrappers preserve :global key compatibility" do
      policy = %{sandbox: true}

      :ok = Store.put_runtime_policy(policy)

      assert Store.get_runtime_policy() == policy
      assert Store.get(:runtime_policy, :global) == policy
      assert {:global, policy} in Store.list_runtime_policies()

      :ok = Store.delete_runtime_policy()
      assert Store.get_runtime_policy() == nil
      assert Store.get(:runtime_policy, :global) == nil
    end
  end
end
