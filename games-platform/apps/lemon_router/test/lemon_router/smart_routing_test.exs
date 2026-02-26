defmodule LemonRouter.SmartRoutingTest do
  use ExUnit.Case, async: true

  alias LemonRouter.SmartRouting
  alias LemonRouter.SmartRouting.Config

  # --- classify_message/1 ---

  describe "classify_message/1" do
    test "nil and empty are :simple" do
      assert SmartRouting.classify_message(nil) == :simple
      assert SmartRouting.classify_message("") == :simple
      assert SmartRouting.classify_message("   ") == :simple
    end

    test "short messages (<= 10 chars) are :simple" do
      assert SmartRouting.classify_message("ok") == :simple
      assert SmartRouting.classify_message("hey") == :simple
      assert SmartRouting.classify_message("1234567890") == :simple
    end

    test "simple keywords with short length are :simple" do
      assert SmartRouting.classify_message("show status") == :simple
      assert SmartRouting.classify_message("help") == :simple
      assert SmartRouting.classify_message("what is this") == :simple
      assert SmartRouting.classify_message("yes") == :simple
      assert SmartRouting.classify_message("hello") == :simple
      assert SmartRouting.classify_message("version") == :simple
    end

    test "code blocks are :complex" do
      message = "Here is some code:\n```elixir\ndef foo, do: :bar\n```"
      assert SmartRouting.classify_message(message) == :complex
    end

    test "complex keywords are :complex" do
      assert SmartRouting.classify_message("please implement a new feature") == :complex
      assert SmartRouting.classify_message("refactor this module") == :complex
      assert SmartRouting.classify_message("analyze the performance") == :complex
      assert SmartRouting.classify_message("debug this issue") == :complex
      assert SmartRouting.classify_message("design a new API") == :complex
      assert SmartRouting.classify_message("optimize the query") == :complex
      assert SmartRouting.classify_message("migrate the database") == :complex
      assert SmartRouting.classify_message("architect the system") == :complex
    end

    test "long messages (>= 1000 chars) are :complex" do
      long_message = String.duplicate("a", 1000)
      assert SmartRouting.classify_message(long_message) == :complex
    end

    test "moderate messages fall through" do
      # Not short, no keywords, no code blocks
      assert SmartRouting.classify_message("tell me about the weather today please") == :moderate
      assert SmartRouting.classify_message("can you summarize my recent activity for me") == :moderate
    end
  end

  # --- route/4 ---

  describe "route/4" do
    @primary "claude-opus"
    @cheap "claude-haiku"

    test "simple messages route to cheap model" do
      assert {:ok, @cheap, :simple} = SmartRouting.route("hi", @primary, @cheap)
    end

    test "complex messages route to primary model" do
      assert {:ok, @primary, :complex} =
               SmartRouting.route("implement a new authentication system", @primary, @cheap)
    end

    test "moderate messages route to cheap model (caller handles cascade)" do
      assert {:ok, @cheap, :moderate} =
               SmartRouting.route("tell me about the weather today please", @primary, @cheap)
    end

    test "messages with tool calls always route to primary" do
      tool_msg = "process this <tool_call>some_tool</tool_call>"
      assert {:ok, @primary, :complex} = SmartRouting.route(tool_msg, @primary, @cheap)
    end

    test "messages with JSON tool_calls always route to primary" do
      json_msg = ~s({"tool_calls": [{"name": "search"}]})
      assert {:ok, @primary, :complex} = SmartRouting.route(json_msg, @primary, @cheap)
    end

    test "accepts custom config" do
      config = %Config{cascade_enabled: false, simple_max_chars: 100, complex_min_chars: 500}
      assert {:ok, @cheap, :simple} = SmartRouting.route("hi", @primary, @cheap, config)
    end
  end

  # --- uncertain_response?/1 ---

  describe "uncertain_response?/1" do
    test "nil and empty are uncertain" do
      assert SmartRouting.uncertain_response?(nil) == true
      assert SmartRouting.uncertain_response?("") == true
    end

    test "detects uncertainty patterns" do
      assert SmartRouting.uncertain_response?("I'm not sure about that") == true
      assert SmartRouting.uncertain_response?("I cannot do that") == true
      assert SmartRouting.uncertain_response?("That's beyond my capabilities") == true
      assert SmartRouting.uncertain_response?("I need more context to answer") == true
      assert SmartRouting.uncertain_response?("I need more information") == true
      assert SmartRouting.uncertain_response?("I'm not confident in this answer") == true
    end

    test "case insensitive matching" do
      assert SmartRouting.uncertain_response?("I'M NOT SURE") == true
      assert SmartRouting.uncertain_response?("I CANNOT do this") == true
    end

    test "confident responses return false" do
      assert SmartRouting.uncertain_response?("The answer is 42.") == false
      assert SmartRouting.uncertain_response?("Here is the implementation.") == false
    end
  end

  # --- Stats tracking ---

  describe "stats tracking" do
    test "start_stats creates agent with zeroed counters" do
      {:ok, pid} = SmartRouting.start_stats()
      stats = SmartRouting.get_stats(pid)
      assert stats == %{cheap: 0, primary: 0, cascade_escalation: 0}
      Agent.stop(pid)
    end

    test "record_request increments counters" do
      {:ok, pid} = SmartRouting.start_stats()

      SmartRouting.record_request(pid, :cheap)
      SmartRouting.record_request(pid, :cheap)
      SmartRouting.record_request(pid, :primary)
      SmartRouting.record_request(pid, :cascade_escalation)

      stats = SmartRouting.get_stats(pid)
      assert stats.cheap == 2
      assert stats.primary == 1
      assert stats.cascade_escalation == 1
      Agent.stop(pid)
    end
  end
end
