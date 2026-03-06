defmodule LemonCore.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.PolicyStore

  test "stores and fetches session policy through the typed wrapper" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    policy = %{model: "gpt-test", thinking_level: :high}

    assert :ok = PolicyStore.put_session(session_key, policy)
    assert PolicyStore.get_session(session_key) == policy
  end
end
