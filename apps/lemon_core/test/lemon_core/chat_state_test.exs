defmodule LemonCore.ChatStateTest do
  use ExUnit.Case, async: false

  alias LemonCore.ChatState
  alias LemonCore.{ChatScope, ChatStateStore}

  describe "new/0 default value verification" do
    test "creates new ChatState with all nil defaults" do
      state = ChatState.new()

      assert state.last_engine == nil
      assert state.last_resume_token == nil
      assert state.updated_at == nil
      assert state.expires_at == nil
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
          :updated_at => 12_345
        })

      assert state.last_engine == "atom_engine"
      assert state.last_resume_token == "string_token"
      assert state.updated_at == 12_345
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
      state = ChatState.new(%{last_engine: 12_345})
      assert state.last_engine == 12_345

      state2 = ChatState.new(%{updated_at: "not_an_integer"})
      assert state2.updated_at == "not_an_integer"
    end
  end

  describe "invalid field handling" do
    @tag invalid_attrs: ["not a map", [:list, :of, :values], 123, [last_engine: "test"]]
    test "new/1 rejects non-map attributes", %{invalid_attrs: invalid_attrs} do
      for attrs <- invalid_attrs do
        assert_raise FunctionClauseError, fn ->
          ChatState.new(attrs)
        end
      end
    end
  end

  describe "ChatStateStore round-trip" do
    test "stores and retrieves ChatState" do
      scope = %ChatScope{transport: :demo, chat_id: 12_345}

      original = %ChatState{
        last_engine: "codex",
        last_resume_token: "token123",
        updated_at: System.system_time(:millisecond)
      }

      :ok = ChatStateStore.put(scope, original)

      # Retrieve and verify
      retrieved = ChatStateStore.get(scope)

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
      scope = %ChatScope{transport: :demo, chat_id: 99_999}

      assert ChatStateStore.get(scope) == nil
    end

    test "overwrites existing chat state" do
      scope = %ChatScope{transport: :demo, chat_id: 12_345}

      first = %ChatState{last_engine: "first", last_resume_token: "token1", updated_at: 1000}
      second = %ChatState{last_engine: "second", last_resume_token: "token2", updated_at: 2000}

      :ok = ChatStateStore.put(scope, first)
      :ok = ChatStateStore.put(scope, second)

      retrieved = ChatStateStore.get(scope)

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
      scope1 = %ChatScope{transport: :demo, chat_id: 11_111}
      scope2 = %ChatScope{transport: :demo, chat_id: 22_222}

      state1 = %ChatState{last_engine: "engine1", last_resume_token: "t1", updated_at: 1000}
      state2 = %ChatState{last_engine: "engine2", last_resume_token: "t2", updated_at: 2000}

      :ok = ChatStateStore.put(scope1, state1)
      :ok = ChatStateStore.put(scope2, state2)

      retrieved1 = ChatStateStore.get(scope1)
      retrieved2 = ChatStateStore.get(scope2)

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
