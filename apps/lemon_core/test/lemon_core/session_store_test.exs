defmodule LemonCore.SessionStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.SessionStore
  alias LemonCore.Store

  defp unique_token, do: System.unique_integer([:positive, :monotonic])
  defp scope(token, name), do: {:session_store_test, token, name}
  defp session_key(token), do: "agent:session_store_test_#{token}:main"

  def handle_telemetry(event_name, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = "session-store-test-#{unique_token()}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "put_chat_state/2" do
    test "persists chat state through Store" do
      token = unique_token()
      chat_scope = scope(token, :put)

      :ok = SessionStore.put_chat_state(chat_scope, %{phase: :active})

      # Use generic get as barrier (put_chat_state is cast-based)
      stored = Store.get(:chat, chat_scope)
      assert %{phase: :active} = stored
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :put_chat_state, :start],
        [:lemon_core, :store, :put_chat_state, :stop]
      ])

      token = unique_token()
      chat_scope = scope(token, :telem_put)

      SessionStore.put_chat_state(chat_scope, %{phase: :active})

      assert_receive {:telemetry_event, [:lemon_core, :store, :put_chat_state, :start],
                       %{system_time: _}, %{table: :chat, session_key: ^chat_scope}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :put_chat_state, :stop],
                       %{duration: duration}, %{table: :chat, session_key: ^chat_scope}}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "get_chat_state/1" do
    test "returns chat state from Store" do
      token = unique_token()
      chat_scope = scope(token, :get)

      :ok = Store.put_chat_state(chat_scope, %{phase: :active})

      result = SessionStore.get_chat_state(chat_scope)
      assert %{phase: :active} = result
    end

    test "returns nil for missing key" do
      token = unique_token()
      chat_scope = scope(token, :missing)

      assert SessionStore.get_chat_state(chat_scope) == nil
    end

    test "returns nil for expired chat state" do
      token = unique_token()
      chat_scope = scope(token, :expired)

      :ok =
        Store.put(:chat, chat_scope, %{
          phase: :stale,
          expires_at: System.system_time(:millisecond) - 1
        })

      assert SessionStore.get_chat_state(chat_scope) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :get_chat_state, :start],
        [:lemon_core, :store, :get_chat_state, :stop]
      ])

      token = unique_token()
      chat_scope = scope(token, :telem_get)

      SessionStore.get_chat_state(chat_scope)

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_chat_state, :start],
                       %{system_time: _}, %{table: :chat, session_key: ^chat_scope}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_chat_state, :stop],
                       %{duration: _}, %{table: :chat, session_key: ^chat_scope}}
    end
  end

  describe "delete_chat_state/1" do
    test "removes chat state through Store" do
      token = unique_token()
      chat_scope = scope(token, :delete)

      :ok = Store.put_chat_state(chat_scope, %{phase: :active})
      assert Store.get_chat_state(chat_scope) != nil

      :ok = SessionStore.delete_chat_state(chat_scope)

      # Use generic get as barrier
      assert Store.get(:chat, chat_scope) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :delete_chat_state, :start],
        [:lemon_core, :store, :delete_chat_state, :stop]
      ])

      token = unique_token()
      chat_scope = scope(token, :telem_delete)

      SessionStore.delete_chat_state(chat_scope)

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_chat_state, :start],
                       %{system_time: _}, %{table: :chat, session_key: ^chat_scope}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_chat_state, :stop],
                       %{duration: _}, %{table: :chat, session_key: ^chat_scope}}
    end
  end

  describe "get_session/1" do
    test "returns session entry from sessions_index" do
      token = unique_token()
      key = session_key(token)
      entry = %{agent_id: "agent_#{token}", updated_at_ms: System.system_time(:millisecond)}

      :ok = Store.put(:sessions_index, key, entry)

      result = SessionStore.get_session(key)
      assert result == entry
    end

    test "returns nil for missing session" do
      token = unique_token()
      key = session_key(token)

      assert SessionStore.get_session(key) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :get_session, :start],
        [:lemon_core, :store, :get_session, :stop]
      ])

      token = unique_token()
      key = session_key(token)

      SessionStore.get_session(key)

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_session, :start],
                       %{system_time: _}, %{table: :sessions_index, session_key: ^key}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_session, :stop],
                       %{duration: _}, %{table: :sessions_index, session_key: ^key}}
    end
  end

  describe "list_sessions/0" do
    test "returns all sessions from sessions_index" do
      token = unique_token()
      key = session_key(token)
      entry = %{agent_id: "agent_#{token}", updated_at_ms: System.system_time(:millisecond)}

      :ok = Store.put(:sessions_index, key, entry)

      sessions = SessionStore.list_sessions()
      assert {key, entry} in sessions
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :list_sessions, :start],
        [:lemon_core, :store, :list_sessions, :stop]
      ])

      SessionStore.list_sessions()

      assert_receive {:telemetry_event, [:lemon_core, :store, :list_sessions, :start],
                       %{system_time: _}, %{table: :sessions_index}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :list_sessions, :stop],
                       %{duration: _}, %{table: :sessions_index}}
    end
  end

  describe "delete_session/1" do
    test "removes session from sessions_index" do
      token = unique_token()
      key = session_key(token)
      entry = %{agent_id: "agent_#{token}", updated_at_ms: System.system_time(:millisecond)}

      :ok = Store.put(:sessions_index, key, entry)
      assert Store.get(:sessions_index, key) == entry

      :ok = SessionStore.delete_session(key)
      assert Store.get(:sessions_index, key) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :delete_session, :start],
        [:lemon_core, :store, :delete_session, :stop]
      ])

      token = unique_token()
      key = session_key(token)

      SessionStore.delete_session(key)

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_session, :start],
                       %{system_time: _}, %{table: :sessions_index, session_key: ^key}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_session, :stop],
                       %{duration: _}, %{table: :sessions_index, session_key: ^key}}
    end
  end
end
