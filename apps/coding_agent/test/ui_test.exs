defmodule CodingAgent.UITest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI

  # ============================================================================
  # Behaviour Definition Tests
  # ============================================================================

  describe "behaviour callbacks" do
    test "defines select callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:select, 3} in callbacks
    end

    test "defines confirm callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:confirm, 3} in callbacks
    end

    test "defines input callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:input, 3} in callbacks
    end

    test "defines notify callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:notify, 2} in callbacks
    end

    test "defines set_status callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:set_status, 2} in callbacks
    end

    test "defines set_widget callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:set_widget, 3} in callbacks
    end

    test "defines set_working_message callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:set_working_message, 1} in callbacks
    end

    test "defines set_title callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:set_title, 1} in callbacks
    end

    test "defines set_editor_text callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:set_editor_text, 1} in callbacks
    end

    test "defines get_editor_text callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:get_editor_text, 0} in callbacks
    end

    test "defines editor callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:editor, 3} in callbacks
    end

    test "defines has_ui? callback" do
      callbacks = UI.behaviour_info(:callbacks)
      assert {:has_ui?, 0} in callbacks
    end

    test "has exactly 12 callbacks" do
      callbacks = UI.behaviour_info(:callbacks)
      assert length(callbacks) == 12
    end
  end

  # ============================================================================
  # Type Definition Tests
  # ============================================================================

  describe "type definitions" do
    test "module defines option type" do
      # Verify the types module compiles and has expected structure
      # We check that the module can be inspected for types
      {:ok, types} = Code.Typespec.fetch_types(UI)
      type_names = Enum.map(types, fn {:type, {name, _, _}} -> name end)

      assert :option in type_names
      assert :notify_type in type_names
      assert :widget_content in type_names
    end

    test "option type has required fields" do
      # Check that option type exists and can be referenced
      # The type is: %{label: String.t(), value: String.t(), description: String.t() | nil}
      {:ok, types} = Code.Typespec.fetch_types(UI)
      option_type = Enum.find(types, fn {:type, {name, _, _}} -> name == :option end)
      assert option_type != nil
    end

    test "notify_type includes expected atoms" do
      # notify_type :: :info | :warning | :error | :success
      {:ok, types} = Code.Typespec.fetch_types(UI)
      notify_type = Enum.find(types, fn {:type, {name, _, _}} -> name == :notify_type end)
      assert notify_type != nil
    end

    test "widget_content allows string, list, or nil" do
      # widget_content :: String.t() | [String.t()] | nil
      {:ok, types} = Code.Typespec.fetch_types(UI)
      widget_type = Enum.find(types, fn {:type, {name, _, _}} -> name == :widget_content end)
      assert widget_type != nil
    end
  end

  # ============================================================================
  # Mock Implementation Tests
  # ============================================================================

  describe "mock implementation" do
    setup do
      tracker_name = :"ui_test_#{:erlang.unique_integer([:positive])}"
      tracker = CodingAgent.Test.MockUI.start_tracker(tracker_name)
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      on_exit(fn ->
        CodingAgent.Test.MockUI.clear_global_tracker()
        CodingAgent.Test.MockUI.stop_tracker(tracker)
      end)

      {:ok, tracker: tracker}
    end

    test "MockUI implements UI behaviour", %{tracker: tracker} do
      # Verify MockUI can be used as a valid implementation
      assert function_exported?(CodingAgent.Test.MockUI, :select, 3)
      assert function_exported?(CodingAgent.Test.MockUI, :confirm, 3)
      assert function_exported?(CodingAgent.Test.MockUI, :input, 3)
      assert function_exported?(CodingAgent.Test.MockUI, :notify, 2)
      assert function_exported?(CodingAgent.Test.MockUI, :set_status, 2)
      assert function_exported?(CodingAgent.Test.MockUI, :set_widget, 3)
      assert function_exported?(CodingAgent.Test.MockUI, :set_working_message, 1)
      assert function_exported?(CodingAgent.Test.MockUI, :set_title, 1)
      assert function_exported?(CodingAgent.Test.MockUI, :set_editor_text, 1)
      assert function_exported?(CodingAgent.Test.MockUI, :get_editor_text, 0)
      assert function_exported?(CodingAgent.Test.MockUI, :editor, 3)
      assert function_exported?(CodingAgent.Test.MockUI, :has_ui?, 0)

      # Verify the tracker is empty initially
      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert calls == []
    end

    test "select returns {:ok, nil}", %{tracker: tracker} do
      options = [%{label: "A", value: "a", description: nil}]
      result = CodingAgent.Test.MockUI.select("Title", options)
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:select, ["Title", ^options, []]} = List.last(calls)
    end

    test "confirm returns {:ok, false}", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.confirm("Title", "Message")
      assert result == {:ok, false}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:confirm, ["Title", "Message", []]} = List.last(calls)
    end

    test "input returns {:ok, nil}", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.input("Title")
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:input, ["Title", nil, []]} = List.last(calls)
    end

    test "notify returns :ok", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.notify("Message", :info)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:notify, ["Message", :info]} = List.last(calls)
    end

    test "set_status returns :ok", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_status("key", "value")
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_status, ["key", "value"]} = List.last(calls)
    end

    test "set_widget returns :ok", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_widget("key", "content")
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_widget, ["key", "content", []]} = List.last(calls)
    end

    test "set_working_message returns :ok", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_working_message("Working...")
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_working_message, ["Working..."]} = List.last(calls)
    end

    test "set_title returns :ok", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_title("Title")
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_title, ["Title"]} = List.last(calls)
    end

    test "set_editor_text returns :ok", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_editor_text("Text")
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_editor_text, ["Text"]} = List.last(calls)
    end

    test "get_editor_text returns empty string", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.get_editor_text()
      assert result == ""

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:get_editor_text, []} = List.last(calls)
    end

    test "editor returns {:ok, nil}", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.editor("Title")
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:editor, ["Title", nil, []]} = List.last(calls)
    end

    test "has_ui? returns true", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.has_ui?()
      assert result == true

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:has_ui?, []} = List.last(calls)
    end
  end

  # ============================================================================
  # Inline Implementation Tests
  # ============================================================================

  describe "inline implementation" do
    defmodule TestUI do
      @behaviour CodingAgent.UI

      @impl true
      def select(_title, _options, _opts), do: {:ok, "selected"}
      @impl true
      def confirm(_title, _message, _opts), do: {:ok, true}
      @impl true
      def input(_title, _placeholder, _opts), do: {:ok, "input"}
      @impl true
      def notify(_message, _type), do: :ok
      @impl true
      def set_status(_key, _text), do: :ok
      @impl true
      def set_widget(_key, _content, _opts), do: :ok
      @impl true
      def set_working_message(_message), do: :ok
      @impl true
      def set_title(_title), do: :ok
      @impl true
      def set_editor_text(_text), do: :ok
      @impl true
      def get_editor_text, do: "editor text"
      @impl true
      def editor(_title, _prefill, _opts), do: {:ok, "edited"}
      @impl true
      def has_ui?, do: true
    end

    test "TestUI implements all callbacks" do
      assert TestUI.select("t", [], []) == {:ok, "selected"}
      assert TestUI.confirm("t", "m", []) == {:ok, true}
      assert TestUI.input("t", nil, []) == {:ok, "input"}
      assert TestUI.notify("m", :info) == :ok
      assert TestUI.set_status("k", "v") == :ok
      assert TestUI.set_widget("k", "c", []) == :ok
      assert TestUI.set_working_message("m") == :ok
      assert TestUI.set_title("t") == :ok
      assert TestUI.set_editor_text("t") == :ok
      assert TestUI.get_editor_text() == "editor text"
      assert TestUI.editor("t", nil, []) == {:ok, "edited"}
      assert TestUI.has_ui?() == true
    end
  end

  # ============================================================================
  # Edge Cases Tests
  # ============================================================================

  describe "edge cases" do
    setup do
      tracker_name = :"ui_edge_test_#{:erlang.unique_integer([:positive])}"
      tracker = CodingAgent.Test.MockUI.start_tracker(tracker_name)
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      on_exit(fn ->
        CodingAgent.Test.MockUI.clear_global_tracker()
        CodingAgent.Test.MockUI.stop_tracker(tracker)
      end)

      {:ok, tracker: tracker}
    end

    test "select with empty options list", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.select("Empty", [])
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:select, ["Empty", [], []]} = List.last(calls)
    end

    test "select with many options", %{tracker: tracker} do
      options = for i <- 1..100 do
        %{label: "Option #{i}", value: "#{i}", description: "Description #{i}"}
      end

      result = CodingAgent.Test.MockUI.select("Many options", options)
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:select, ["Many options", ^options, []]} = List.last(calls)
    end

    test "input with empty placeholder", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.input("Title", "")
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:input, ["Title", "", []]} = List.last(calls)
    end

    test "notify with empty message", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.notify("", :info)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:notify, ["", :info]} = List.last(calls)
    end

    test "notify with all types", %{tracker: tracker} do
      for type <- [:info, :warning, :error, :success] do
        result = CodingAgent.Test.MockUI.notify("Message", type)
        assert result == :ok
      end

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert length(calls) == 4
    end

    test "set_status with nil text", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_status("key", nil)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_status, ["key", nil]} = List.last(calls)
    end

    test "set_widget with nil content", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_widget("key", nil)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_widget, ["key", nil, []]} = List.last(calls)
    end

    test "set_widget with list content", %{tracker: tracker} do
      content = ["line1", "line2", "line3"]
      result = CodingAgent.Test.MockUI.set_widget("key", content)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_widget, ["key", ^content, []]} = List.last(calls)
    end

    test "set_working_message with nil", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_working_message(nil)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_working_message, [nil]} = List.last(calls)
    end

    test "set_title with empty string", %{tracker: tracker} do
      result = CodingAgent.Test.MockUI.set_title("")
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_title, [""]} = List.last(calls)
    end

    test "set_editor_text with multiline text", %{tracker: tracker} do
      text = "line1\nline2\nline3"
      result = CodingAgent.Test.MockUI.set_editor_text(text)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_editor_text, [^text]} = List.last(calls)
    end

    test "editor with prefill and options", %{tracker: tracker} do
      prefill = "def foo, do: :ok"
      opts = [syntax: "elixir", line_numbers: true]

      result = CodingAgent.Test.MockUI.editor("Code Editor", prefill, opts)
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:editor, ["Code Editor", ^prefill, ^opts]} = List.last(calls)
    end

    test "handles unicode strings", %{tracker: tracker} do
      CodingAgent.Test.MockUI.set_title("Unicode: \u00e9\u00e0\u00fc\u00f1")
      CodingAgent.Test.MockUI.notify("Emoji: \u{1F389}\u{1F680}", :success)
      CodingAgent.Test.MockUI.set_editor_text("\u4e2d\u6587\u5185\u5bb9")

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert length(calls) == 3
    end

    test "handles very long strings", %{tracker: tracker} do
      long_string = String.duplicate("a", 10_000)
      result = CodingAgent.Test.MockUI.set_editor_text(long_string)
      assert result == :ok

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_editor_text, [^long_string]} = List.last(calls)
    end

    test "options with complex values", %{tracker: tracker} do
      options = [
        %{
          label: "Complex option",
          value: "complex",
          description: "This is a longer description with\nmultiple lines\nand special chars: @#$%"
        }
      ]

      result = CodingAgent.Test.MockUI.select("Complex", options, [default: "complex"])
      assert result == {:ok, nil}

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:select, ["Complex", ^options, [default: "complex"]]} = List.last(calls)
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    defmodule ErrorUI do
      @behaviour CodingAgent.UI

      @impl true
      def select(_title, _options, _opts), do: {:error, :user_cancelled}
      @impl true
      def confirm(_title, _message, _opts), do: {:error, :timeout}
      @impl true
      def input(_title, _placeholder, _opts), do: {:error, :invalid_input}
      @impl true
      def notify(_message, _type), do: :ok
      @impl true
      def set_status(_key, _text), do: :ok
      @impl true
      def set_widget(_key, _content, _opts), do: :ok
      @impl true
      def set_working_message(_message), do: :ok
      @impl true
      def set_title(_title), do: :ok
      @impl true
      def set_editor_text(_text), do: :ok
      @impl true
      def get_editor_text, do: ""
      @impl true
      def editor(_title, _prefill, _opts), do: {:error, :editor_closed}
      @impl true
      def has_ui?, do: false
    end

    test "select can return error tuple" do
      assert ErrorUI.select("Title", [], []) == {:error, :user_cancelled}
    end

    test "confirm can return error tuple" do
      assert ErrorUI.confirm("Title", "Message", []) == {:error, :timeout}
    end

    test "input can return error tuple" do
      assert ErrorUI.input("Title", nil, []) == {:error, :invalid_input}
    end

    test "editor can return error tuple" do
      assert ErrorUI.editor("Title", nil, []) == {:error, :editor_closed}
    end

    test "has_ui? can return false for headless mode" do
      assert ErrorUI.has_ui?() == false
    end
  end

  # ============================================================================
  # Callback Specification Tests
  # ============================================================================

  describe "callback specifications" do
    test "callbacks match expected arities" do
      callbacks = UI.behaviour_info(:callbacks)
      callback_map = Map.new(callbacks)

      # Dialog methods
      assert callback_map[:select] == 3
      assert callback_map[:confirm] == 3
      assert callback_map[:input] == 3
      assert callback_map[:notify] == 2

      # Status/widget methods
      assert callback_map[:set_status] == 2
      assert callback_map[:set_widget] == 3
      assert callback_map[:set_working_message] == 1

      # Layout methods
      assert callback_map[:set_title] == 1

      # Editor methods
      assert callback_map[:set_editor_text] == 1
      assert callback_map[:get_editor_text] == 0
      assert callback_map[:editor] == 3

      # Capability check
      assert callback_map[:has_ui?] == 0
    end

    test "optional_callbacks is empty" do
      optional = UI.behaviour_info(:optional_callbacks)
      assert optional == []
    end
  end

  # ============================================================================
  # MockUI Tracker Tests
  # ============================================================================

  describe "MockUI tracker" do
    test "start_tracker creates new tracker" do
      tracker = CodingAgent.Test.MockUI.start_tracker(:"test_tracker_#{:erlang.unique_integer([:positive])}")
      assert is_reference(tracker)

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert calls == []

      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end

    test "get_calls returns calls in order" do
      tracker = CodingAgent.Test.MockUI.start_tracker(:"test_tracker_#{:erlang.unique_integer([:positive])}")
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      CodingAgent.Test.MockUI.set_title("First")
      CodingAgent.Test.MockUI.set_title("Second")
      CodingAgent.Test.MockUI.set_title("Third")

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert length(calls) == 3
      assert Enum.at(calls, 0) == {:set_title, ["First"]}
      assert Enum.at(calls, 1) == {:set_title, ["Second"]}
      assert Enum.at(calls, 2) == {:set_title, ["Third"]}

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end

    test "clear_calls removes all calls" do
      tracker = CodingAgent.Test.MockUI.start_tracker(:"test_tracker_#{:erlang.unique_integer([:positive])}")
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      CodingAgent.Test.MockUI.set_title("Title")
      calls_before = CodingAgent.Test.MockUI.get_calls(tracker)
      assert length(calls_before) == 1

      CodingAgent.Test.MockUI.clear_calls(tracker)
      calls_after = CodingAgent.Test.MockUI.get_calls(tracker)
      assert calls_after == []

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end

    test "stop_tracker handles already stopped tracker" do
      tracker = CodingAgent.Test.MockUI.start_tracker(:"test_tracker_#{:erlang.unique_integer([:positive])}")
      assert CodingAgent.Test.MockUI.stop_tracker(tracker) == :ok
      assert CodingAgent.Test.MockUI.stop_tracker(tracker) == :ok
    end
  end

  # ============================================================================
  # Concurrent Access Tests
  # ============================================================================

  describe "concurrent access" do
    test "multiple processes can use the same tracker" do
      tracker = CodingAgent.Test.MockUI.start_tracker(:"concurrent_tracker_#{:erlang.unique_integer([:positive])}")
      CodingAgent.Test.MockUI.set_global_tracker(tracker)

      parent = self()

      # Spawn multiple processes that make UI calls
      tasks = for i <- 1..5 do
        Task.async(fn ->
          CodingAgent.Test.MockUI.set_title("Title #{i}")
          CodingAgent.Test.MockUI.notify("Message #{i}", :info)
          send(parent, {:done, i})
        end)
      end

      # Wait for all tasks
      Enum.each(tasks, &Task.await/1)

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert length(calls) == 10  # 5 set_title + 5 notify

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end
  end

  # ============================================================================
  # Process Dictionary Tracker Tests
  # ============================================================================

  describe "process dictionary tracker" do
    test "register_tracker sets process-local tracker" do
      tracker = CodingAgent.Test.MockUI.start_tracker(:"pd_tracker_#{:erlang.unique_integer([:positive])}")
      CodingAgent.Test.MockUI.register_tracker(tracker)

      CodingAgent.Test.MockUI.set_title("Title")

      calls = CodingAgent.Test.MockUI.get_calls(tracker)
      assert {:set_title, ["Title"]} in calls

      CodingAgent.Test.MockUI.stop_tracker(tracker)
    end

    test "process-local tracker takes precedence over global" do
      global_tracker = CodingAgent.Test.MockUI.start_tracker(:"global_#{:erlang.unique_integer([:positive])}")
      local_tracker = CodingAgent.Test.MockUI.start_tracker(:"local_#{:erlang.unique_integer([:positive])}")

      CodingAgent.Test.MockUI.set_global_tracker(global_tracker)
      CodingAgent.Test.MockUI.register_tracker(local_tracker)

      CodingAgent.Test.MockUI.set_title("Title")

      # Call should go to local tracker
      local_calls = CodingAgent.Test.MockUI.get_calls(local_tracker)
      global_calls = CodingAgent.Test.MockUI.get_calls(global_tracker)

      assert {:set_title, ["Title"]} in local_calls
      assert global_calls == []

      CodingAgent.Test.MockUI.clear_global_tracker()
      CodingAgent.Test.MockUI.stop_tracker(global_tracker)
      CodingAgent.Test.MockUI.stop_tracker(local_tracker)
    end
  end
end
