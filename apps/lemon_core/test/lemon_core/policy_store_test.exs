defmodule LemonCore.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.{PolicyStore, Store}

  # Policies are durable: these pin the tables and keys existing stores hold
  # them under, so a user's persisted policies keep loading.

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

  test "only the session policy scope exists" do
    Code.ensure_loaded!(PolicyStore)

    for {fun, arity} <- [
          fetch_agent: 1,
          put_agent: 2,
          fetch_channel: 1,
          put_channel: 2,
          fetch_runtime: 0,
          put_runtime: 1,
          delete_runtime: 0
        ] do
      refute function_exported?(PolicyStore, fun, arity),
             "PolicyStore.#{fun}/#{arity} is an unwritten policy scope"
    end
  end
end
