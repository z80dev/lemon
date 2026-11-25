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

  describe "chat rows" do
    setup do
      chat = "-#{System.unique_integer([:positive])}"

      routes = [
        {"telegram", nil, nil, nil},
        {"telegram", "default", chat, nil},
        {"telegram", "default", chat, "9"}
      ]

      on_exit(fn -> Enum.each(routes, &PolicyStore.delete_chat/1) end)
      %{chat: chat}
    end

    test "a channel session key names its chat route; other sessions have none", %{chat: chat} do
      key =
        LemonCore.SessionKey.channel_peer(%{
          agent_id: "a",
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :group,
          peer_id: chat,
          thread_id: "9",
          sub_id: "user"
        })

      assert PolicyStore.chat_route(key) == {"telegram", "default", chat, "9"}
      assert PolicyStore.chat_route("agent:a:main") == nil

      assert PolicyStore.resolve_chat("agent:a:main") ==
               {:ok, %{model: nil, model_route: nil, thinking_level: nil, thinking_route: nil}}
    end

    test "only narrowing routes are valid", %{chat: chat} do
      assert PolicyStore.chat_route?({"telegram", nil, nil, nil})
      assert PolicyStore.chat_route?({"telegram", "default", chat, "9"})
      refute PolicyStore.chat_route?({"telegram", nil, chat, nil})
      refute PolicyStore.chat_route?({"telegram", "default", nil, "9"})

      assert PolicyStore.update_chat({"telegram", nil, chat, nil}, fn _ -> %{model: "m"} end) ==
               {:error, :invalid_chat_route}
    end

    test "resolution takes each field from the most specific row that sets it", %{chat: chat} do
      thread = {"telegram", "default", chat, "9"}
      peer = {"telegram", "default", chat, nil}
      channel = {"telegram", nil, nil, nil}

      {:ok, _} =
        PolicyStore.update_chat(channel, fn _ ->
          %{model: "channel-model", thinking_level: "low"}
        end)

      {:ok, _} = PolicyStore.update_chat(peer, fn _ -> %{model: "chat-model"} end)
      {:ok, _} = PolicyStore.update_chat(thread, fn _ -> %{thinking_level: "high"} end)

      assert PolicyStore.resolve_chat(thread) ==
               {:ok,
                %{
                  model: "chat-model",
                  model_route: peer,
                  thinking_level: "high",
                  thinking_route: thread
                }}

      assert {:ok, nil} = PolicyStore.update_chat(thread, fn _ -> nil end)
      assert PolicyStore.fetch_chat(thread) == {:ok, nil}

      assert {:ok, %{thinking_level: "low", thinking_route: ^channel}} =
               PolicyStore.resolve_chat(thread)

      assert {:ok, rows} = PolicyStore.fetch_chats()
      assert {peer, %{model: "chat-model"}} in rows
    end
  end
end
