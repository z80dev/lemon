defmodule LemonGateway.ChatStateTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{ChatState, Store}
  alias LemonGateway.Types.ChatScope

  setup do
    # Stop the app to reset state
    _ = Application.stop(:lemon_gateway)

    # Clean up any existing config
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :config_path)

    on_exit(fn ->
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_gateway, :config_path)
    end)

    :ok
  end

  describe "new/0 default value verification" do
    test "creates new ChatState with all nil defaults" do
      state = ChatState.new()

      assert state.last_engine == nil
      assert state.last_resume_token == nil
      assert state.updated_at == nil
      assert state.expires_at == nil
    end

    test "returns a proper ChatState struct" do
      state = ChatState.new()
      assert %ChatState{} = state
    end

    test "struct has exactly four fields" do
      state = ChatState.new()
      # Map.from_struct returns all fields defined in defstruct
      fields = Map.from_struct(state)
      assert map_size(fields) == 4

      assert Map.keys(fields) |> Enum.sort() == [
               :expires_at,
               :last_engine,
               :last_resume_token,
               :updated_at
             ]
    end
  end

  describe "new/1 with atom keys" do
    test "creates ChatState with all atom key values" do
      state =
        ChatState.new(%{
          last_engine: "claude",
          last_resume_token: "abc123",
          updated_at: 1_234_567_890,
          expires_at: 1_234_569_999
        })

      assert state.last_engine == "claude"
      assert state.last_resume_token == "abc123"
      assert state.updated_at == 1_234_567_890
      assert state.expires_at == 1_234_569_999
    end

    test "creates ChatState with partial atom keys" do
      state = ChatState.new(%{last_engine: "codex"})

      assert state.last_engine == "codex"
      assert state.last_resume_token == nil
      assert state.updated_at == nil
      assert state.expires_at == nil
    end

    test "creates ChatState with empty map" do
      state = ChatState.new(%{})

      assert state.last_engine == nil
      assert state.last_resume_token == nil
      assert state.updated_at == nil
      assert state.expires_at == nil
    end
  end

  describe "new/1 with string keys" do
    test "creates ChatState with all string key values" do
      state =
        ChatState.new(%{
          "last_engine" => "gemini",
          "last_resume_token" => "xyz789",
          "updated_at" => 9_876_543_210,
          "expires_at" => 9_876_549_999
        })

      assert state.last_engine == "gemini"
      assert state.last_resume_token == "xyz789"
      assert state.updated_at == 9_876_543_210
      assert state.expires_at == 9_876_549_999
    end

    test "creates ChatState with partial string keys" do
      state = ChatState.new(%{"last_resume_token" => "partial_token"})

      assert state.last_engine == nil
      assert state.last_resume_token == "partial_token"
      assert state.updated_at == nil
      assert state.expires_at == nil
    end
  end

  describe "new/1 with mixed atom/string keys edge cases" do
    test "atom keys take precedence over string keys" do
      # The implementation uses || which means atom key is checked first
      # Must use arrow syntax for all keys when mixing atom and string keys
      state =
        ChatState.new(%{
          :last_engine => "atom_engine",
          "last_engine" => "string_engine"
        })

      # atom key value is truthy, so it should be used
      assert state.last_engine == "atom_engine"
    end

    test "string key used when atom key is nil" do
      state =
        ChatState.new(%{
          :last_engine => nil,
          "last_engine" => "fallback_engine"
        })

      # nil || "fallback_engine" => "fallback_engine"
      assert state.last_engine == "fallback_engine"
    end

    test "string key used when atom key is missing" do
      state =
        ChatState.new(%{
          "last_engine" => "only_string"
        })

      assert state.last_engine == "only_string"
    end

    test "mixed keys for different fields" do
      state =
        ChatState.new(%{
          :last_engine => "atom_engine",
          "last_resume_token" => "string_token",
          :updated_at => 12345
        })

      assert state.last_engine == "atom_engine"
      assert state.last_resume_token == "string_token"
      assert state.updated_at == 12345
    end

    test "false atom key value still uses atom key (falsy but not nil)" do
      # Note: false is falsy in || but the implementation uses attrs[:key] || attrs["key"]
      # false || "string" => "string" because false is falsy
      state =
        ChatState.new(%{
          :last_engine => false,
          "last_engine" => "fallback"
        })

      # false || "fallback" => "fallback"
      assert state.last_engine == "fallback"
    end

    test "empty string atom key is truthy" do
      state =
        ChatState.new(%{
          :last_engine => "",
          "last_engine" => "fallback"
        })

      # "" is truthy in Elixir (only nil and false are falsy)
      assert state.last_engine == ""
    end

    test "zero value is truthy" do
      state =
        ChatState.new(%{
          :updated_at => 0,
          "updated_at" => 999
        })

      # 0 is truthy in Elixir
      assert state.updated_at == 0
    end

    test "ignores extra keys not in struct" do
      state =
        ChatState.new(%{
          :last_engine => "valid",
          :extra_key => "ignored",
          "another_extra" => "also_ignored"
        })

      assert state.last_engine == "valid"
      # Extra keys don't raise errors, they're simply not used
      refute Map.has_key?(Map.from_struct(state), :extra_key)
    end
  end

  describe "struct enforcement validation" do
    test "ChatState is a struct (not a plain map)" do
      state = ChatState.new()
      assert is_struct(state)
      assert is_struct(state, ChatState)
    end

    test "struct has __struct__ key" do
      state = ChatState.new()
      assert state.__struct__ == ChatState
    end

    test "pattern matching works with struct" do
      state = ChatState.new(%{last_engine: "test"})
      assert %ChatState{last_engine: "test"} = state
    end

    test "pattern matching extracts values correctly" do
      state =
        ChatState.new(%{
          last_engine: "engine1",
          last_resume_token: "token1",
          updated_at: 1000
        })

      %ChatState{
        last_engine: engine,
        last_resume_token: token,
        updated_at: time
      } = state

      assert engine == "engine1"
      assert token == "token1"
      assert time == 1000
    end

    test "struct can be created directly" do
      state = %ChatState{
        last_engine: "direct",
        last_resume_token: "direct_token",
        updated_at: 2000
      }

      assert state.last_engine == "direct"
    end

    test "direct struct creation with partial fields" do
      state = %ChatState{last_engine: "partial"}

      assert state.last_engine == "partial"
      assert state.last_resume_token == nil
      assert state.updated_at == nil
    end
  end

  describe "type contract validation" do
    test "last_engine accepts string values" do
      state = ChatState.new(%{last_engine: "claude"})
      assert is_binary(state.last_engine)
    end

    test "last_engine accepts nil" do
      state = ChatState.new(%{last_engine: nil})
      assert state.last_engine == nil
    end

    test "last_resume_token accepts string values" do
      state = ChatState.new(%{last_resume_token: "abc123"})
      assert is_binary(state.last_resume_token)
    end

    test "last_resume_token accepts nil" do
      state = ChatState.new(%{last_resume_token: nil})
      assert state.last_resume_token == nil
    end

    test "updated_at accepts integer values" do
      state = ChatState.new(%{updated_at: 1_234_567_890})
      assert is_integer(state.updated_at)
    end

    test "updated_at accepts nil" do
      state = ChatState.new(%{updated_at: nil})
      assert state.updated_at == nil
    end

    test "updated_at works with System.system_time values" do
      timestamp = System.system_time(:millisecond)
      state = ChatState.new(%{updated_at: timestamp})
      assert state.updated_at == timestamp
      assert is_integer(state.updated_at)
    end

    # Note: Elixir structs don't enforce types at runtime
    # These tests document behavior when non-standard types are used
    test "struct accepts any value type (no runtime type enforcement)" do
      # This documents that Elixir structs don't enforce @type at runtime
      state = ChatState.new(%{last_engine: 12345})
      assert state.last_engine == 12345

      state2 = ChatState.new(%{updated_at: "not_an_integer"})
      assert state2.updated_at == "not_an_integer"
    end
  end

  describe "all field access patterns" do
    setup do
      state =
        ChatState.new(%{
          last_engine: "test_engine",
          last_resume_token: "test_token",
          updated_at: 1_609_459_200_000
        })

      {:ok, state: state}
    end

    test "dot notation access", %{state: state} do
      assert state.last_engine == "test_engine"
      assert state.last_resume_token == "test_token"
      assert state.updated_at == 1_609_459_200_000
    end

    test "Map.get/2 access", %{state: state} do
      assert Map.get(state, :last_engine) == "test_engine"
      assert Map.get(state, :last_resume_token) == "test_token"
      assert Map.get(state, :updated_at) == 1_609_459_200_000
    end

    test "Map.get/3 with default", %{state: state} do
      assert Map.get(state, :last_engine, "default") == "test_engine"
      assert Map.get(state, :nonexistent, "default") == "default"
    end

    test "Map.fetch/2 access", %{state: state} do
      assert Map.fetch(state, :last_engine) == {:ok, "test_engine"}
      assert Map.fetch(state, :last_resume_token) == {:ok, "test_token"}
      assert Map.fetch(state, :updated_at) == {:ok, 1_609_459_200_000}
    end

    test "Map.fetch!/2 access", %{state: state} do
      assert Map.fetch!(state, :last_engine) == "test_engine"
    end

    test "bracket notation requires Access behaviour (not implemented)" do
      state = ChatState.new(%{last_engine: "test_engine"})

      # ChatState does not implement Access behaviour, so bracket notation fails
      # Use Map.get/2 or dot notation instead
      assert_raise UndefinedFunctionError, fn ->
        _ = state[:last_engine]
      end
    end

    test "Map.from_struct/1 conversion", %{state: state} do
      map = Map.from_struct(state)

      assert map == %{
               expires_at: nil,
               last_engine: "test_engine",
               last_resume_token: "test_token",
               updated_at: 1_609_459_200_000
             }
    end

    test "Map.keys/1 returns all field names", %{state: state} do
      keys = Map.keys(state) |> Enum.reject(&(&1 == :__struct__)) |> Enum.sort()
      assert keys == [:expires_at, :last_engine, :last_resume_token, :updated_at]
    end

    test "Map.values/1 returns all values plus struct module" do
      state = ChatState.new()
      values = Map.values(state)
      # Values include __struct__ module and all field values
      assert ChatState in values
      assert nil in values
    end

    test "Kernel.struct/2 update", %{state: state} do
      updated = struct(state, last_engine: "new_engine")

      assert updated.last_engine == "new_engine"
      assert updated.last_resume_token == "test_token"
      assert updated.updated_at == 1_609_459_200_000
    end

    test "Map.put/3 update", %{state: state} do
      updated = Map.put(state, :last_engine, "updated_engine")

      assert updated.last_engine == "updated_engine"
      assert updated.last_resume_token == "test_token"
    end

    test "Map.merge/2 update", %{state: state} do
      updated = Map.merge(state, %{last_engine: "merged", updated_at: 9999})

      assert updated.last_engine == "merged"
      assert updated.last_resume_token == "test_token"
      assert updated.updated_at == 9999
    end

    test "update syntax with |>", %{state: state} do
      updated = %{state | last_engine: "pipe_updated"}

      assert updated.last_engine == "pipe_updated"
      assert updated.last_resume_token == "test_token"
    end
  end

  describe "invalid field handling" do
    test "accessing undefined field via dot notation raises KeyError" do
      state = ChatState.new()

      assert_raise KeyError, fn ->
        # Avoid compile-time "unknown key" warnings for struct dot access.
        Code.eval_string("state.nonexistent_field", state: state)
      end
    end

    test "bracket notation fails because Access behaviour not implemented" do
      state = ChatState.new()
      # Bracket notation requires Access behaviour which ChatState doesn't implement
      # Use Map.get/2 instead for dynamic access
      assert_raise UndefinedFunctionError, fn ->
        _ = state[:nonexistent_field]
      end
    end

    test "Map.fetch/2 returns error for undefined fields" do
      state = ChatState.new()
      assert Map.fetch(state, :nonexistent_field) == :error
    end

    test "Map.fetch!/2 raises for undefined fields" do
      state = ChatState.new()

      assert_raise KeyError, fn ->
        Map.fetch!(state, :nonexistent_field)
      end
    end

    test "Map.get/3 returns default for undefined fields" do
      state = ChatState.new()
      assert Map.get(state, :nonexistent_field, "default_value") == "default_value"
    end

    test "Map.has_key?/2 returns false for undefined fields" do
      state = ChatState.new()
      refute Map.has_key?(state, :nonexistent_field)
      assert Map.has_key?(state, :last_engine)
    end

    test "update syntax raises for undefined fields" do
      state = ChatState.new()

      assert_raise KeyError, fn ->
        # Avoid compile-time warnings for invalid struct update syntax.
        Code.eval_string("%{state | nonexistent_field: \"value\"}", state: state)
      end
    end

    test "Kernel.struct/2 ignores unknown keys" do
      state = ChatState.new()
      # struct/2 silently ignores unknown keys
      updated = struct(state, unknown_key: "ignored", last_engine: "valid")

      assert updated.last_engine == "valid"
      refute Map.has_key?(Map.from_struct(updated), :unknown_key)
    end

    test "direct struct creation with invalid keys raises at compile time" do
      # Invalid struct keys are caught at compile time, not runtime.
      # This test verifies the behavior using Code.eval_string which
      # compiles and runs the code at runtime.
      assert_raise KeyError, fn ->
        Code.eval_string("""
        alias LemonGateway.ChatState
        %ChatState{invalid_key: "value"}
        """)
      end
    end

    test "new/1 with non-map argument raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        ChatState.new("not a map")
      end

      assert_raise FunctionClauseError, fn ->
        ChatState.new([:list, :of, :values])
      end

      assert_raise FunctionClauseError, fn ->
        ChatState.new(123)
      end
    end

    test "new/1 with keyword list raises FunctionClauseError" do
      # Keyword lists are not maps
      assert_raise FunctionClauseError, fn ->
        ChatState.new(last_engine: "test")
      end
    end
  end

  describe "equality and comparison" do
    test "two structs with same values are equal" do
      state1 = ChatState.new(%{last_engine: "test", last_resume_token: "token", updated_at: 1000})
      state2 = ChatState.new(%{last_engine: "test", last_resume_token: "token", updated_at: 1000})

      assert state1 == state2
    end

    test "structs with different values are not equal" do
      state1 = ChatState.new(%{last_engine: "test1"})
      state2 = ChatState.new(%{last_engine: "test2"})

      refute state1 == state2
    end

    test "struct is not equal to equivalent map" do
      state = ChatState.new(%{last_engine: "test", last_resume_token: nil, updated_at: nil})
      map = %{last_engine: "test", last_resume_token: nil, updated_at: nil}

      refute state == map
    end

    test "default structs are equal" do
      state1 = ChatState.new()
      state2 = ChatState.new()

      assert state1 == state2
    end
  end

  describe "Store ChatState round-trip" do
    test "stores and retrieves ChatState" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      original = %ChatState{
        last_engine: "codex",
        last_resume_token: "token123",
        updated_at: System.system_time(:millisecond)
      }

      # Store the chat state
      Store.put_chat_state(scope, original)

      # Give the async cast time to complete
      Process.sleep(50)

      # Retrieve and verify
      retrieved = Store.get_chat_state(scope)

      # The Store may return either the struct or a map depending on backend
      case retrieved do
        %ChatState{} = chat_state ->
          assert chat_state.last_engine == original.last_engine
          assert chat_state.last_resume_token == original.last_resume_token
          assert chat_state.updated_at == original.updated_at

        %{} = map ->
          # ETS backend stores maps directly
          assert map.last_engine == original.last_engine ||
                   map[:last_engine] == original.last_engine
      end
    end

    test "returns nil for missing chat state" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = %ChatScope{transport: :telegram, chat_id: 99999}

      assert Store.get_chat_state(scope) == nil
    end

    test "overwrites existing chat state" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope = %ChatScope{transport: :telegram, chat_id: 12345}

      first = %ChatState{last_engine: "first", last_resume_token: "token1", updated_at: 1000}
      second = %ChatState{last_engine: "second", last_resume_token: "token2", updated_at: 2000}

      Store.put_chat_state(scope, first)
      Process.sleep(50)
      Store.put_chat_state(scope, second)
      Process.sleep(50)

      retrieved = Store.get_chat_state(scope)

      case retrieved do
        %ChatState{} = chat_state ->
          assert chat_state.last_engine == "second"
          assert chat_state.last_resume_token == "token2"

        %{} = map ->
          last_engine = map.last_engine || map[:last_engine]
          assert last_engine == "second"
      end
    end

    test "different scopes have separate chat states" do
      Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      scope1 = %ChatScope{transport: :telegram, chat_id: 11111}
      scope2 = %ChatScope{transport: :telegram, chat_id: 22222}

      state1 = %ChatState{last_engine: "engine1", last_resume_token: "t1", updated_at: 1000}
      state2 = %ChatState{last_engine: "engine2", last_resume_token: "t2", updated_at: 2000}

      Store.put_chat_state(scope1, state1)
      Store.put_chat_state(scope2, state2)
      Process.sleep(50)

      retrieved1 = Store.get_chat_state(scope1)
      retrieved2 = Store.get_chat_state(scope2)

      # Get last_engine from either struct or map
      get_engine = fn
        %ChatState{last_engine: e} -> e
        %{last_engine: e} -> e
        %{} = m -> m[:last_engine]
      end

      assert get_engine.(retrieved1) == "engine1"
      assert get_engine.(retrieved2) == "engine2"
    end
  end
end
