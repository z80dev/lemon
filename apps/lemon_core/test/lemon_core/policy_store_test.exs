defmodule LemonCore.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.{PolicyStore, Store}

  # Policies are durable: these pin the tables and keys existing stores hold
  # them under, so a user's persisted policies keep loading.

  test "agent policies live in :agent_policies keyed by agent id" do
    agent_id = "agent_#{System.unique_integer([:positive])}"
    policy = %{approvals: %{"bash" => :always}}

    :ok = PolicyStore.put_agent(agent_id, policy)

    assert PolicyStore.get_agent(agent_id) == policy
    assert Store.get(:agent_policies, agent_id) == policy

    :ok = Store.delete(:agent_policies, agent_id)
    assert PolicyStore.get_agent(agent_id) == nil
  end

  test "channel policies live in :channel_policies keyed by channel id" do
    channel_id = "channel_#{System.unique_integer([:positive])}"
    policy = %{blocked_tools: ["exec_raw"]}

    :ok = PolicyStore.put_channel(channel_id, policy)

    assert PolicyStore.get_channel(channel_id) == policy
    assert Store.get(:channel_policies, channel_id) == policy

    :ok = Store.delete(:channel_policies, channel_id)
    assert PolicyStore.get_channel(channel_id) == nil
  end

  test "session policies live in :session_policies keyed by session key" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    policy = %{model: "gpt-test", thinking_level: :high}

    :ok = PolicyStore.put_session(session_key, policy)

    assert PolicyStore.get_session(session_key) == policy
    assert Store.get(:session_policies, session_key) == policy

    :ok = PolicyStore.delete_session(session_key)
    assert PolicyStore.get_session(session_key) == nil
    assert Store.get(:session_policies, session_key) == nil
  end

  test "the runtime policy lives under :global in :runtime_policy" do
    previous = PolicyStore.get_runtime()

    on_exit(fn ->
      if previous, do: PolicyStore.put_runtime(previous), else: PolicyStore.delete_runtime()
    end)

    policy = %{deny: ["bash"]}
    :ok = PolicyStore.put_runtime(policy)

    assert PolicyStore.get_runtime() == policy
    assert Store.get(:runtime_policy, :global) == policy

    :ok = PolicyStore.delete_runtime()
    assert PolicyStore.get_runtime() == nil
    assert Store.get(:runtime_policy, :global) == nil
  end
end
