defmodule CodingAgent.UI.HeadlessTest do
  # Uses `capture_log/1`, which is global. Run synchronously to avoid
  # cross-test log interference in umbrella `mix test`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.UI.Headless

  # ============================================================================
  # Dialog Methods
  # ============================================================================

  describe "select/3" do
    test "returns {:ok, nil} with empty options" do
      assert Headless.select("Title", []) == {:ok, nil}
    end

    test "returns {:ok, nil} with valid options" do
      options = [
        %{label: "Option A", value: "a", description: "First option"},
        %{label: "Option B", value: "b", description: nil}
      ]

      assert Headless.select("Choose", options) == {:ok, nil}
    end

    test "returns {:ok, nil} with custom opts" do
      options = [%{label: "X", value: "x", description: "test"}]
      assert Headless.select("Title", options, timeout: 5000) == {:ok, nil}
    end

    test "handles nil title" do
      assert Headless.select(nil, []) == {:ok, nil}
    end

    test "handles empty string title" do
      assert Headless.select("", []) == {:ok, nil}
    end

    test "handles large option list" do
      options =
        Enum.map(1..1000, fn i ->
          %{label: "Option #{i}", value: "opt_#{i}", description: "Description #{i}"}
        end)

      assert Headless.select("Many options", options) == {:ok, nil}
    end

    test "handles special characters in options" do
      options = [
        %{label: "Emoji: \u{1F600}", value: "emoji", description: nil},
        %{label: "Unicode: \u00E9\u00E0\u00FC", value: "unicode", description: nil},
        %{label: "Newline:\ntest", value: "newline", description: "Has\nnewlines"}
      ]

      assert Headless.select("Special", options) == {:ok, nil}
    end
  end

  describe "confirm/3" do
    test "returns {:ok, false} for basic confirmation" do
      assert Headless.confirm("Confirm?", "Are you sure?") == {:ok, false}
    end

    test "returns {:ok, false} with empty strings" do
      assert Headless.confirm("", "") == {:ok, false}
    end

    test "returns {:ok, false} with nil values" do
      assert Headless.confirm(nil, nil) == {:ok, false}
    end

    test "returns {:ok, false} with custom opts" do
      assert Headless.confirm("Title", "Message", default: true) == {:ok, false}
    end

    test "handles long messages" do
      long_message = String.duplicate("This is a test message. ", 1000)
      assert Headless.confirm("Long message", long_message) == {:ok, false}
    end

    test "handles special characters" do
      assert Headless.confirm("Title with \u00E9", "Message with \n newlines") == {:ok, false}
    end
  end

  describe "input/3" do
    test "returns {:ok, nil} for basic input" do
      assert Headless.input("Enter name") == {:ok, nil}
    end

    test "returns {:ok, nil} with placeholder" do
      assert Headless.input("Enter value", "placeholder text") == {:ok, nil}
    end

    test "returns {:ok, nil} with nil placeholder" do
      assert Headless.input("Title", nil) == {:ok, nil}
    end

    test "returns {:ok, nil} with opts" do
      assert Headless.input("Title", "placeholder", required: true) == {:ok, nil}
    end

    test "handles empty strings" do
      assert Headless.input("", "") == {:ok, nil}
    end

    test "handles nil title" do
      assert Headless.input(nil) == {:ok, nil}
    end

    test "handles special characters in placeholder" do
      assert Headless.input("Title", "Type here... \u{1F4DD}") == {:ok, nil}
    end
  end

  describe "notify/2" do
    test "logs :info type messages" do
      log =
        capture_log(fn ->
          assert Headless.notify("Info message", :info) == :ok
        end)

      assert log =~ "Info message"
    end

    test "logs :warning type messages" do
      log =
        capture_log(fn ->
          assert Headless.notify("Warning message", :warning) == :ok
        end)

      assert log =~ "Warning message"
    end

    test "logs :error type messages" do
      log =
        capture_log(fn ->
          assert Headless.notify("Error message", :error) == :ok
        end)

      assert log =~ "Error message"
    end

    test "logs :success type messages with prefix" do
      log =
        capture_log(fn ->
          assert Headless.notify("Success message", :success) == :ok
        end)

      assert log =~ "[SUCCESS]"
      assert log =~ "Success message"
    end

    test "handles empty message" do
      log =
        capture_log(fn ->
          assert Headless.notify("", :info) == :ok
        end)

      # Should not crash, log might be empty or contain minimal output
      assert is_binary(log)
    end

    test "handles special characters in message" do
      log =
        capture_log(fn ->
          assert Headless.notify("Message with \u00E9moticons \u{1F389}", :info) == :ok
        end)

      assert log =~ "moticons"
    end

    test "handles multiline messages" do
      log =
        capture_log(fn ->
          assert Headless.notify("Line 1\nLine 2\nLine 3", :info) == :ok
        end)

      assert log =~ "Line 1"
    end
  end

  # ============================================================================
  # Status/Widget Methods
  # ============================================================================

  describe "set_status/2" do
    test "returns :ok with valid key and text" do
      assert Headless.set_status("mode", "Running") == :ok
    end

    test "returns :ok with nil text (clearing status)" do
      assert Headless.set_status("mode", nil) == :ok
    end

    test "returns :ok with empty strings" do
      assert Headless.set_status("", "") == :ok
    end

    test "returns :ok with nil key" do
      assert Headless.set_status(nil, "text") == :ok
    end

    test "handles special characters" do
      assert Headless.set_status("key-with-\u00E9", "value \u{1F680}") == :ok
    end
  end

  describe "set_widget/3" do
    test "returns :ok with string content" do
      assert Headless.set_widget("files", "file1.txt") == :ok
    end

    test "returns :ok with list content" do
      assert Headless.set_widget("files", ["a.txt", "b.txt", "c.txt"]) == :ok
    end

    test "returns :ok with nil content" do
      assert Headless.set_widget("files", nil) == :ok
    end

    test "returns :ok with empty list" do
      assert Headless.set_widget("files", []) == :ok
    end

    test "returns :ok with opts" do
      assert Headless.set_widget("files", ["a.txt"], collapsed: true) == :ok
    end

    test "handles empty key" do
      assert Headless.set_widget("", "content") == :ok
    end

    test "handles nil key" do
      assert Headless.set_widget(nil, "content") == :ok
    end

    test "handles large content list" do
      large_list = Enum.map(1..1000, &"file_#{&1}.txt")
      assert Headless.set_widget("files", large_list) == :ok
    end
  end

  describe "set_working_message/1" do
    test "returns :ok with nil (clears message)" do
      assert Headless.set_working_message(nil) == :ok
    end

    test "logs debug with valid message" do
      log =
        capture_log([level: :debug], fn ->
          assert Headless.set_working_message("Processing...") == :ok
        end)

      assert log =~ "[WORKING]"
      assert log =~ "Processing..."
    end

    test "returns :ok with empty string" do
      log =
        capture_log([level: :debug], fn ->
          assert Headless.set_working_message("") == :ok
        end)

      assert log =~ "[WORKING]"
    end

    test "handles special characters" do
      log =
        capture_log([level: :debug], fn ->
          assert Headless.set_working_message("Loading \u{1F504}") == :ok
        end)

      assert log =~ "[WORKING]"
    end
  end

  # ============================================================================
  # Layout Methods
  # ============================================================================

  describe "set_title/1" do
    test "returns :ok with valid title" do
      assert Headless.set_title("My Application") == :ok
    end

    test "returns :ok with empty string" do
      assert Headless.set_title("") == :ok
    end

    test "returns :ok with nil" do
      assert Headless.set_title(nil) == :ok
    end

    test "handles special characters" do
      assert Headless.set_title("Title with \u00E9 and \u{1F3C6}") == :ok
    end

    test "handles long title" do
      long_title = String.duplicate("A", 1000)
      assert Headless.set_title(long_title) == :ok
    end
  end

  # ============================================================================
  # Editor Methods
  # ============================================================================

  describe "set_editor_text/1" do
    test "returns :ok with valid text" do
      assert Headless.set_editor_text("Hello World") == :ok
    end

    test "returns :ok with empty string" do
      assert Headless.set_editor_text("") == :ok
    end

    test "returns :ok with nil" do
      assert Headless.set_editor_text(nil) == :ok
    end

    test "handles multiline text" do
      text = """
      Line 1
      Line 2
      Line 3
      """

      assert Headless.set_editor_text(text) == :ok
    end

    test "handles special characters" do
      assert Headless.set_editor_text("Code: fn -> \u{1F4BB} end") == :ok
    end

    test "handles large text" do
      large_text = String.duplicate("x", 100_000)
      assert Headless.set_editor_text(large_text) == :ok
    end
  end

  describe "get_editor_text/0" do
    test "returns empty string" do
      assert Headless.get_editor_text() == ""
    end

    test "consistently returns empty string on multiple calls" do
      assert Headless.get_editor_text() == ""
      assert Headless.get_editor_text() == ""
      assert Headless.get_editor_text() == ""
    end
  end

  describe "editor/3" do
    test "returns {:ok, nil} for basic editor" do
      assert Headless.editor("Edit message") == {:ok, nil}
    end

    test "returns {:ok, nil} with prefill" do
      assert Headless.editor("Edit", "initial content") == {:ok, nil}
    end

    test "returns {:ok, nil} with nil prefill" do
      assert Headless.editor("Edit", nil) == {:ok, nil}
    end

    test "returns {:ok, nil} with opts" do
      assert Headless.editor("Edit", "content", language: "elixir") == {:ok, nil}
    end

    test "handles empty strings" do
      assert Headless.editor("", "") == {:ok, nil}
    end

    test "handles nil title" do
      assert Headless.editor(nil) == {:ok, nil}
    end

    test "handles large prefill" do
      large_prefill = String.duplicate("code\n", 10_000)
      assert Headless.editor("Edit", large_prefill) == {:ok, nil}
    end

    test "handles special characters in prefill" do
      prefill = """
      defmodule Test do
        def hello, do: "world \u{1F30D}"
      end
      """

      assert Headless.editor("Edit code", prefill) == {:ok, nil}
    end
  end

  # ============================================================================
  # Capability Check
  # ============================================================================

  describe "has_ui?/0" do
    test "returns false" do
      assert Headless.has_ui?() == false
    end

    test "consistently returns false on multiple calls" do
      assert Headless.has_ui?() == false
      assert Headless.has_ui?() == false
      assert Headless.has_ui?() == false
    end
  end

  # ============================================================================
  # Behaviour Compliance
  # ============================================================================

  describe "behaviour compliance" do
    test "module implements CodingAgent.UI behaviour" do
      behaviours = Headless.__info__(:attributes)[:behaviour] || []
      assert CodingAgent.UI in behaviours
    end

    test "all callbacks are implemented" do
      # Verify the module exports all expected functions
      exports = Headless.__info__(:functions)

      assert {:select, 2} in exports or {:select, 3} in exports
      assert {:confirm, 2} in exports or {:confirm, 3} in exports
      assert {:input, 1} in exports or {:input, 2} in exports or {:input, 3} in exports
      assert {:notify, 2} in exports
      assert {:set_status, 2} in exports
      assert {:set_widget, 2} in exports or {:set_widget, 3} in exports
      assert {:set_working_message, 1} in exports
      assert {:set_title, 1} in exports
      assert {:set_editor_text, 1} in exports
      assert {:get_editor_text, 0} in exports
      assert {:editor, 1} in exports or {:editor, 2} in exports or {:editor, 3} in exports
      assert {:has_ui?, 0} in exports
    end
  end

  # ============================================================================
  # Edge Cases and Stress Tests
  # ============================================================================

  describe "edge cases" do
    test "all functions handle atoms as string arguments" do
      # These should not crash - atoms are not the expected type but
      # the functions should be resilient
      assert Headless.select(:title, []) == {:ok, nil}
      assert Headless.confirm(:title, :message) == {:ok, false}
      assert Headless.input(:title) == {:ok, nil}
      assert Headless.set_status(:key, :text) == :ok
      assert Headless.set_widget(:key, :content) == :ok
      assert Headless.set_title(:title) == :ok
      assert Headless.set_editor_text(:text) == :ok
      assert Headless.editor(:title) == {:ok, nil}
    end

    test "all functions handle integer arguments" do
      assert Headless.select(123, []) == {:ok, nil}
      assert Headless.confirm(123, 456) == {:ok, false}
      assert Headless.input(123) == {:ok, nil}
      assert Headless.set_status(123, 456) == :ok
      assert Headless.set_widget(123, 456) == :ok
      assert Headless.set_title(123) == :ok
      assert Headless.set_editor_text(123) == :ok
      assert Headless.editor(123) == {:ok, nil}
    end

    test "rapid successive calls do not cause issues" do
      for _ <- 1..100 do
        Headless.set_status("key", "value")
        Headless.set_widget("key", ["item"])
        Headless.set_title("title")
        Headless.get_editor_text()
        Headless.has_ui?()
      end

      # If we get here without crashing, the test passes
      assert true
    end

    test "concurrent calls from multiple processes" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Headless.set_status("key_#{i}", "value_#{i}")
            Headless.select("Title #{i}", [])
            Headless.confirm("Confirm #{i}", "Message #{i}")
            Headless.has_ui?()
          end)
        end

      results = Task.await_many(tasks)

      # All should return false from has_ui?
      assert Enum.all?(results, &(&1 == false))
    end
  end

  # ============================================================================
  # Notify Type Coverage
  # ============================================================================

  describe "notify type coverage" do
    test "handles all four notification types" do
      types = [:info, :warning, :error, :success]

      for type <- types do
        log =
          capture_log(fn ->
            result = Headless.notify("Test message for #{type}", type)
            assert result == :ok
          end)

        assert log =~ "Test message for #{type}"
      end
    end
  end
end
