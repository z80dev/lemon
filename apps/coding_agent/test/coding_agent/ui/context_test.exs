defmodule CodingAgent.UI.ContextTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.Context
  alias CodingAgent.Test.MockUI

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    # Create a unique tracker for each test (enables async: true)
    tracker_name = :"ui_context_test_#{:erlang.unique_integer([:positive])}"
    tracker = MockUI.start_tracker(tracker_name)
    MockUI.set_global_tracker(tracker)

    on_exit(fn ->
      MockUI.clear_global_tracker()
      MockUI.stop_tracker(tracker)
    end)

    {:ok, tracker: tracker}
  end

  # ============================================================================
  # Struct Tests
  # ============================================================================

  describe "struct" do
    test "has module and state fields" do
      ctx = %Context{}

      assert Map.has_key?(ctx, :module)
      assert Map.has_key?(ctx, :state)
    end

    test "defaults to nil values" do
      ctx = %Context{}

      assert ctx.module == nil
      assert ctx.state == nil
    end
  end

  # ============================================================================
  # new/2 Tests
  # ============================================================================

  describe "new/1" do
    test "creates context with module" do
      ctx = Context.new(MockUI)

      assert ctx.module == MockUI
      assert ctx.state == nil
    end
  end

  describe "new/2" do
    test "creates context with module and state" do
      state = %{custom: "state"}
      ctx = Context.new(MockUI, state)

      assert ctx.module == MockUI
      assert ctx.state == state
    end

    test "accepts any term as state" do
      # Nil state
      ctx1 = Context.new(MockUI, nil)
      assert ctx1.state == nil

      # Map state
      ctx2 = Context.new(MockUI, %{key: "value"})
      assert ctx2.state == %{key: "value"}

      # List state
      ctx3 = Context.new(MockUI, [1, 2, 3])
      assert ctx3.state == [1, 2, 3]

      # Tuple state
      ctx4 = Context.new(MockUI, {:some, :tuple})
      assert ctx4.state == {:some, :tuple}

      # PID state
      ctx5 = Context.new(MockUI, self())
      assert ctx5.state == self()
    end
  end

  # ============================================================================
  # Dialog Method Tests
  # ============================================================================

  describe "select/4" do
    test "delegates to module.select/3", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      options = [
        %{label: "Option A", value: "a", description: nil},
        %{label: "Option B", value: "b", description: "With description"}
      ]

      result = Context.select(ctx, "Choose an option", options)

      assert result == {:ok, nil}

      calls = MockUI.get_calls(tracker)
      assert {:select, ["Choose an option", ^options, []]} = List.last(calls)
    end

    test "passes options through", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      options = [%{label: "Only", value: "only", description: nil}]
      opts = [default: "only", multiple: true]

      Context.select(ctx, "Select", options, opts)

      calls = MockUI.get_calls(tracker)
      assert {:select, ["Select", ^options, ^opts]} = List.last(calls)
    end

    test "works with empty options list", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.select(ctx, "No options", [])

      assert result == {:ok, nil}

      calls = MockUI.get_calls(tracker)
      assert {:select, ["No options", [], []]} = List.last(calls)
    end
  end

  describe "confirm/4" do
    test "delegates to module.confirm/3", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.confirm(ctx, "Confirm", "Are you sure?")

      assert result == {:ok, false}

      calls = MockUI.get_calls(tracker)
      assert {:confirm, ["Confirm", "Are you sure?", []]} = List.last(calls)
    end

    test "passes options through", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      opts = [default: true, destructive: true]

      Context.confirm(ctx, "Delete?", "This cannot be undone", opts)

      calls = MockUI.get_calls(tracker)
      assert {:confirm, ["Delete?", "This cannot be undone", ^opts]} = List.last(calls)
    end
  end

  describe "input/4" do
    test "delegates to module.input/3", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.input(ctx, "Enter name")

      assert result == {:ok, nil}

      calls = MockUI.get_calls(tracker)
      assert {:input, ["Enter name", nil, []]} = List.last(calls)
    end

    test "passes placeholder through", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.input(ctx, "Enter email", "user@example.com")

      calls = MockUI.get_calls(tracker)
      assert {:input, ["Enter email", "user@example.com", []]} = List.last(calls)
    end

    test "passes options through", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      opts = [multiline: true, max_length: 100]

      Context.input(ctx, "Description", "Enter description...", opts)

      calls = MockUI.get_calls(tracker)
      assert {:input, ["Description", "Enter description...", ^opts]} = List.last(calls)
    end
  end

  describe "notify/3" do
    test "delegates to module.notify/2", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.notify(ctx, "Operation complete", :info)

      assert result == :ok

      calls = MockUI.get_calls(tracker)
      assert {:notify, ["Operation complete", :info]} = List.last(calls)
    end

    test "works with all notify types", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.notify(ctx, "Info message", :info)
      Context.notify(ctx, "Warning message", :warning)
      Context.notify(ctx, "Error message", :error)
      Context.notify(ctx, "Success message", :success)

      calls = MockUI.get_calls(tracker)

      assert {:notify, ["Info message", :info]} in calls
      assert {:notify, ["Warning message", :warning]} in calls
      assert {:notify, ["Error message", :error]} in calls
      assert {:notify, ["Success message", :success]} in calls
    end
  end

  # ============================================================================
  # Status/Widget Method Tests
  # ============================================================================

  describe "set_status/3" do
    test "delegates to module.set_status/2", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.set_status(ctx, "connection", "Connected")

      assert result == :ok

      calls = MockUI.get_calls(tracker)
      assert {:set_status, ["connection", "Connected"]} = List.last(calls)
    end

    test "handles nil text (clears status)", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.set_status(ctx, "connection", nil)

      calls = MockUI.get_calls(tracker)
      assert {:set_status, ["connection", nil]} = List.last(calls)
    end
  end

  describe "set_widget/4" do
    test "delegates to module.set_widget/3", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.set_widget(ctx, "sidebar", "Widget content")

      assert result == :ok

      calls = MockUI.get_calls(tracker)
      assert {:set_widget, ["sidebar", "Widget content", []]} = List.last(calls)
    end

    test "works with list content", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      content = ["Line 1", "Line 2", "Line 3"]

      Context.set_widget(ctx, "list", content)

      calls = MockUI.get_calls(tracker)
      assert {:set_widget, ["list", ^content, []]} = List.last(calls)
    end

    test "works with nil content (clears widget)", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.set_widget(ctx, "panel", nil)

      calls = MockUI.get_calls(tracker)
      assert {:set_widget, ["panel", nil, []]} = List.last(calls)
    end

    test "passes options through", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      opts = [position: :left, width: 200]

      Context.set_widget(ctx, "panel", "Content", opts)

      calls = MockUI.get_calls(tracker)
      assert {:set_widget, ["panel", "Content", ^opts]} = List.last(calls)
    end
  end

  describe "set_working_message/2" do
    test "delegates to module.set_working_message/1", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.set_working_message(ctx, "Processing...")

      assert result == :ok

      calls = MockUI.get_calls(tracker)
      assert {:set_working_message, ["Processing..."]} = List.last(calls)
    end

    test "handles nil message (clears working message)", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.set_working_message(ctx, nil)

      calls = MockUI.get_calls(tracker)
      assert {:set_working_message, [nil]} = List.last(calls)
    end
  end

  # ============================================================================
  # Layout Method Tests
  # ============================================================================

  describe "set_title/2" do
    test "delegates to module.set_title/1", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.set_title(ctx, "My Application")

      assert result == :ok

      calls = MockUI.get_calls(tracker)
      assert {:set_title, ["My Application"]} = List.last(calls)
    end

    test "works with empty string", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.set_title(ctx, "")

      calls = MockUI.get_calls(tracker)
      assert {:set_title, [""]} = List.last(calls)
    end
  end

  # ============================================================================
  # Editor Method Tests
  # ============================================================================

  describe "set_editor_text/2" do
    test "delegates to module.set_editor_text/1", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.set_editor_text(ctx, "Some text content")

      assert result == :ok

      calls = MockUI.get_calls(tracker)
      assert {:set_editor_text, ["Some text content"]} = List.last(calls)
    end

    test "works with empty string", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.set_editor_text(ctx, "")

      calls = MockUI.get_calls(tracker)
      assert {:set_editor_text, [""]} = List.last(calls)
    end

    test "works with multiline text", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      multiline = "Line 1\nLine 2\nLine 3"

      Context.set_editor_text(ctx, multiline)

      calls = MockUI.get_calls(tracker)
      assert {:set_editor_text, [^multiline]} = List.last(calls)
    end
  end

  describe "get_editor_text/1" do
    test "delegates to module.get_editor_text/0", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.get_editor_text(ctx)

      # MockUI returns empty string
      assert result == ""

      calls = MockUI.get_calls(tracker)
      assert {:get_editor_text, []} = List.last(calls)
    end
  end

  describe "editor/4" do
    test "delegates to module.editor/3", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.editor(ctx, "Edit content")

      assert result == {:ok, nil}

      calls = MockUI.get_calls(tracker)
      assert {:editor, ["Edit content", nil, []]} = List.last(calls)
    end

    test "passes prefill through", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      prefill = "Default text"

      Context.editor(ctx, "Edit", prefill)

      calls = MockUI.get_calls(tracker)
      assert {:editor, ["Edit", ^prefill, []]} = List.last(calls)
    end

    test "passes options through", %{tracker: tracker} do
      ctx = Context.new(MockUI)
      opts = [syntax: "elixir", line_numbers: true]

      Context.editor(ctx, "Code Editor", "def foo, do: :ok", opts)

      calls = MockUI.get_calls(tracker)
      assert {:editor, ["Code Editor", "def foo, do: :ok", ^opts]} = List.last(calls)
    end
  end

  # ============================================================================
  # Capability Check Tests
  # ============================================================================

  describe "has_ui?/1" do
    test "delegates to module.has_ui?/0", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      result = Context.has_ui?(ctx)

      # MockUI returns true
      assert result == true

      calls = MockUI.get_calls(tracker)
      assert {:has_ui?, []} = List.last(calls)
    end
  end

  # ============================================================================
  # Integration/Edge Case Tests
  # ============================================================================

  describe "context state is not passed to module" do
    test "state is held but not used in delegation", %{tracker: tracker} do
      # The state field exists for the context owner's use,
      # but isn't passed to the underlying module methods
      state = %{session_id: "abc123", custom_data: [1, 2, 3]}
      ctx = Context.new(MockUI, state)

      # All methods should work regardless of state
      Context.select(ctx, "Title", [])
      Context.confirm(ctx, "Title", "Message")
      Context.input(ctx, "Title")
      Context.notify(ctx, "Message", :info)
      Context.set_status(ctx, "key", "value")
      Context.set_widget(ctx, "key", "content")
      Context.set_working_message(ctx, "Working...")
      Context.set_title(ctx, "Title")
      Context.set_editor_text(ctx, "Text")
      Context.get_editor_text(ctx)
      Context.editor(ctx, "Title")
      Context.has_ui?(ctx)

      calls = MockUI.get_calls(tracker)

      # All 12 calls should have been made
      assert length(calls) == 12
    end
  end

  describe "pattern matching on context struct" do
    test "functions pattern match on %Context{}" do
      # These should work with Context struct
      ctx = Context.new(MockUI)

      # Verify we can pattern match the module out
      %Context{module: mod} = ctx
      assert mod == MockUI
    end

    test "functions fail gracefully with wrong struct" do
      # Passing a map that looks like Context but isn't the struct
      # should raise a FunctionClauseError
      fake_ctx = %{module: MockUI, state: nil}

      assert_raise FunctionClauseError, fn ->
        Context.select(fake_ctx, "Title", [])
      end
    end
  end

  describe "multiple sequential operations" do
    test "context can be reused for multiple operations", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      # Perform sequence of operations
      Context.set_working_message(ctx, "Starting...")
      Context.set_status(ctx, "step", "1 of 3")
      Context.set_status(ctx, "step", "2 of 3")
      Context.set_status(ctx, "step", "3 of 3")
      Context.set_working_message(ctx, nil)
      Context.notify(ctx, "Complete!", :success)

      calls = MockUI.get_calls(tracker)

      assert length(calls) == 6
      assert {:set_working_message, ["Starting..."]} = Enum.at(calls, 0)
      assert {:set_status, ["step", "1 of 3"]} = Enum.at(calls, 1)
      assert {:set_status, ["step", "2 of 3"]} = Enum.at(calls, 2)
      assert {:set_status, ["step", "3 of 3"]} = Enum.at(calls, 3)
      assert {:set_working_message, [nil]} = Enum.at(calls, 4)
      assert {:notify, ["Complete!", :success]} = Enum.at(calls, 5)
    end
  end

  describe "unicode and special characters" do
    test "handles unicode in strings", %{tracker: tracker} do
      ctx = Context.new(MockUI)

      Context.set_title(ctx, "日本語タイトル")
      Context.notify(ctx, "Émojis work! 🎉", :info)
      Context.set_editor_text(ctx, "中文内容\nМикс языков")

      calls = MockUI.get_calls(tracker)

      assert {:set_title, ["日本語タイトル"]} in calls
      assert {:notify, ["Émojis work! 🎉", :info]} in calls
      assert {:set_editor_text, ["中文内容\nМикс языков"]} in calls
    end
  end
end
