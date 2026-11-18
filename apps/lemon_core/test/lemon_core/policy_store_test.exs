defmodule LemonCore.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.{PolicyStore, Store}

  # Policies are durable: these pin the tables and keys existing stores hold
  # them under, so a user's persisted policies keep loading.

  test "agent policies live in :agent_policies keyed by agent id" do
    agent_id = "agent_#{System.unique_integer([:positive])}"
    policy = %{approvals: %{"bash" => :always}}

    :ok = PolicyStore.put_agent(agent_id, policy)

    assert PolicyStore.fetch_agent(agent_id) == {:ok, policy}
    assert Store.get(:agent_policies, agent_id) == policy

    :ok = Store.delete(:agent_policies, agent_id)
    assert PolicyStore.fetch_agent(agent_id) == {:ok, nil}
  end

  test "channel policies live in :channel_policies keyed by channel id" do
    channel_id = "channel_#{System.unique_integer([:positive])}"
    policy = %{blocked_tools: ["exec_raw"]}

    :ok = PolicyStore.put_channel(channel_id, policy)

    assert PolicyStore.fetch_channel(channel_id) == {:ok, policy}
    assert Store.get(:channel_policies, channel_id) == policy

    :ok = Store.delete(:channel_policies, channel_id)
    assert PolicyStore.fetch_channel(channel_id) == {:ok, nil}
  end

  test "session policies live in :session_policies keyed by session key" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    policy = %{model: "gpt-test", thinking_level: :high}

    :ok = PolicyStore.put_session(session_key, policy)

    assert PolicyStore.fetch_session(session_key) == {:ok, policy}
    assert Store.get(:session_policies, session_key) == policy

    :ok = PolicyStore.delete_session(session_key)
    assert PolicyStore.fetch_session(session_key) == {:ok, nil}
    assert Store.get(:session_policies, session_key) == nil
  end

  test "update_session merges against the stored row by compare-and-swap" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    on_exit(fn -> PolicyStore.delete_session(session_key) end)

    assert {:ok, %{model: "m1"}} =
             PolicyStore.update_session(session_key, &Map.merge(&1 || %{}, %{model: "m1"}))

    :ok = PolicyStore.put_session(session_key, %{model: "m1", tool_policy: %{deny: ["bash"]}})

    assert {:ok, %{model: "m2", tool_policy: %{deny: ["bash"]}}} =
             PolicyStore.update_session(session_key, &Map.merge(&1, %{model: "m2"}))

    assert PolicyStore.fetch_session(session_key) ==
             {:ok, %{model: "m2", tool_policy: %{deny: ["bash"]}}}
  end

  test "the runtime policy lives under :global in :runtime_policy" do
    {:ok, previous} = PolicyStore.fetch_runtime()

    on_exit(fn ->
      if previous, do: PolicyStore.put_runtime(previous), else: PolicyStore.delete_runtime()
    end)

    policy = %{deny: ["bash"]}
    :ok = PolicyStore.put_runtime(policy)

    assert PolicyStore.fetch_runtime() == {:ok, policy}
    assert Store.get(:runtime_policy, :global) == policy

    :ok = PolicyStore.delete_runtime()
    assert PolicyStore.fetch_runtime() == {:ok, nil}
    assert Store.get(:runtime_policy, :global) == nil
  end
end
