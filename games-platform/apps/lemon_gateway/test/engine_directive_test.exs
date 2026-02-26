defmodule LemonGateway.EngineDirectiveTest do
  use ExUnit.Case, async: true

  alias LemonGateway.EngineDirective

  # ============================================================================
  # Supported engine names
  # ============================================================================

  describe "strip/1 with supported engine directives" do
    test "strips /lemon directive with trailing text" do
      assert EngineDirective.strip("/lemon fix this bug") == {"lemon", "fix this bug"}
    end

    test "strips /codex directive with trailing text" do
      assert EngineDirective.strip("/codex fix this") == {"codex", "fix this"}
    end

    test "strips /claude directive with trailing text" do
      assert EngineDirective.strip("/claude summarize the code") == {"claude", "summarize the code"}
    end

    test "strips /opencode directive with trailing text" do
      assert EngineDirective.strip("/opencode refactor module") == {"opencode", "refactor module"}
    end

    test "strips /pi directive with trailing text" do
      assert EngineDirective.strip("/pi tell me a joke") == {"pi", "tell me a joke"}
    end

    test "strips /echo directive with trailing text" do
      assert EngineDirective.strip("/echo hello world") == {"echo", "hello world"}
    end
  end

  # ============================================================================
  # Engine directive without trailing text
  # ============================================================================

  describe "strip/1 with directive only (no trailing text)" do
    test "strips /lemon with no trailing text" do
      assert EngineDirective.strip("/lemon") == {"lemon", ""}
    end

    test "strips /codex with no trailing text" do
      assert EngineDirective.strip("/codex") == {"codex", ""}
    end

    test "strips /claude with no trailing text" do
      assert EngineDirective.strip("/claude") == {"claude", ""}
    end

    test "strips /opencode with no trailing text" do
      assert EngineDirective.strip("/opencode") == {"opencode", ""}
    end

    test "strips /pi with no trailing text" do
      assert EngineDirective.strip("/pi") == {"pi", ""}
    end

    test "strips /echo with no trailing text" do
      assert EngineDirective.strip("/echo") == {"echo", ""}
    end
  end

  # ============================================================================
  # Case insensitivity
  # ============================================================================

  describe "strip/1 case insensitivity" do
    test "handles uppercase /CLAUDE" do
      assert EngineDirective.strip("/CLAUDE hello") == {"claude", "hello"}
    end

    test "handles mixed case /Claude" do
      assert EngineDirective.strip("/Claude hello") == {"claude", "hello"}
    end

    test "handles uppercase /CODEX" do
      assert EngineDirective.strip("/CODEX do something") == {"codex", "do something"}
    end

    test "handles mixed case /Codex" do
      assert EngineDirective.strip("/Codex do something") == {"codex", "do something"}
    end

    test "handles uppercase /LEMON" do
      assert EngineDirective.strip("/LEMON help me") == {"lemon", "help me"}
    end

    test "handles mixed case /LeMoN" do
      assert EngineDirective.strip("/LeMoN help me") == {"lemon", "help me"}
    end

    test "handles uppercase /OPENCODE" do
      assert EngineDirective.strip("/OPENCODE refactor") == {"opencode", "refactor"}
    end

    test "handles uppercase /PI" do
      assert EngineDirective.strip("/PI chat") == {"pi", "chat"}
    end

    test "handles uppercase /ECHO" do
      assert EngineDirective.strip("/ECHO test") == {"echo", "test"}
    end

    test "handles uppercase directive without trailing text" do
      assert EngineDirective.strip("/CLAUDE") == {"claude", ""}
    end
  end

  # ============================================================================
  # Whitespace handling
  # ============================================================================

  describe "strip/1 whitespace handling" do
    test "trims leading whitespace before directive" do
      assert EngineDirective.strip("  /claude hello") == {"claude", "hello"}
    end

    test "trims trailing whitespace after text" do
      assert EngineDirective.strip("/claude hello  ") == {"claude", "hello"}
    end

    test "trims both leading and trailing whitespace" do
      assert EngineDirective.strip("  /claude hello  ") == {"claude", "hello"}
    end

    test "handles multiple spaces between directive and text" do
      assert EngineDirective.strip("/claude    hello world") == {"claude", "hello world"}
    end

    test "handles tab characters in leading whitespace" do
      assert EngineDirective.strip("\t/claude hello") == {"claude", "hello"}
    end

    test "handles newline in leading whitespace" do
      assert EngineDirective.strip("\n/claude hello") == {"claude", "hello"}
    end

    test "trims trailing text whitespace" do
      assert EngineDirective.strip("/codex   fix bug   ") == {"codex", "fix bug"}
    end

    test "handles directive with only whitespace after it" do
      assert EngineDirective.strip("/claude   ") == {"claude", ""}
    end

    test "trims plain text with leading/trailing whitespace" do
      assert EngineDirective.strip("  hello world  ") == {nil, "hello world"}
    end
  end

  # ============================================================================
  # Non-matching prefixes
  # ============================================================================

  describe "strip/1 with unsupported engine directives" do
    test "does not match /unknown" do
      assert EngineDirective.strip("/unknown fix this") == {nil, "/unknown fix this"}
    end

    test "does not match /invalid" do
      assert EngineDirective.strip("/invalid command") == {nil, "/invalid command"}
    end

    test "does not match /gpt" do
      assert EngineDirective.strip("/gpt hello") == {nil, "/gpt hello"}
    end

    test "does not match /gemini" do
      assert EngineDirective.strip("/gemini hello") == {nil, "/gemini hello"}
    end

    test "does not match /help" do
      assert EngineDirective.strip("/help") == {nil, "/help"}
    end

    test "does not match /start" do
      assert EngineDirective.strip("/start") == {nil, "/start"}
    end
  end

  # ============================================================================
  # Plain text without directive
  # ============================================================================

  describe "strip/1 with plain text (no directive)" do
    test "returns nil engine for plain text" do
      assert EngineDirective.strip("hello world") == {nil, "hello world"}
    end

    test "returns nil engine for text starting with a word" do
      assert EngineDirective.strip("fix this bug please") == {nil, "fix this bug please"}
    end

    test "returns nil engine for text with special characters" do
      assert EngineDirective.strip("what is 2 + 2?") == {nil, "what is 2 + 2?"}
    end

    test "returns nil engine for text starting with a number" do
      assert EngineDirective.strip("42 is the answer") == {nil, "42 is the answer"}
    end
  end

  # ============================================================================
  # Empty string
  # ============================================================================

  describe "strip/1 with empty string" do
    test "returns nil engine and empty string for empty input" do
      assert EngineDirective.strip("") == {nil, ""}
    end

    test "returns nil engine and empty string for whitespace-only input" do
      assert EngineDirective.strip("   ") == {nil, ""}
    end

    test "returns nil engine and empty string for tab-only input" do
      assert EngineDirective.strip("\t\t") == {nil, ""}
    end

    test "returns nil engine and empty string for newline-only input" do
      assert EngineDirective.strip("\n\n") == {nil, ""}
    end
  end

  # ============================================================================
  # nil input
  # ============================================================================

  describe "strip/1 with nil input" do
    test "returns nil engine and empty string for nil" do
      assert EngineDirective.strip(nil) == {nil, ""}
    end
  end

  # ============================================================================
  # Non-string input
  # ============================================================================

  describe "strip/1 with non-string input" do
    test "returns nil engine and empty string for integer" do
      assert EngineDirective.strip(42) == {nil, ""}
    end

    test "returns nil engine and empty string for atom" do
      assert EngineDirective.strip(:hello) == {nil, ""}
    end

    test "returns nil engine and empty string for list" do
      assert EngineDirective.strip([1, 2, 3]) == {nil, ""}
    end

    test "returns nil engine and empty string for map" do
      assert EngineDirective.strip(%{key: "value"}) == {nil, ""}
    end

    test "returns nil engine and empty string for boolean" do
      assert EngineDirective.strip(true) == {nil, ""}
    end

    test "returns nil engine and empty string for tuple" do
      assert EngineDirective.strip({:ok, "data"}) == {nil, ""}
    end
  end

  # ============================================================================
  # Edge cases: directive-like text not at start
  # ============================================================================

  describe "strip/1 edge cases with directive-like text not at start" do
    test "does not match directive embedded in sentence" do
      assert EngineDirective.strip("please use /claude for this") ==
               {nil, "please use /claude for this"}
    end

    test "does not match directive in the middle of text" do
      assert EngineDirective.strip("I want /codex to help") ==
               {nil, "I want /codex to help"}
    end

    test "does not match directive after other text" do
      assert EngineDirective.strip("try /echo hello") ==
               {nil, "try /echo hello"}
    end

    test "does not match directive preceded by non-whitespace characters" do
      assert EngineDirective.strip("x/claude hello") == {nil, "x/claude hello"}
    end
  end

  # ============================================================================
  # Word boundary edge cases
  # ============================================================================

  describe "strip/1 word boundary behavior" do
    test "does not match partial engine name /claud" do
      assert EngineDirective.strip("/claud hello") == {nil, "/claud hello"}
    end

    test "does not match engine name as prefix of longer word /claudeX" do
      assert EngineDirective.strip("/claudeX hello") == {nil, "/claudeX hello"}
    end

    test "does not match /echotest as engine" do
      assert EngineDirective.strip("/echotest") == {nil, "/echotest"}
    end

    test "does not match /pirate as engine" do
      assert EngineDirective.strip("/pirate hello") == {nil, "/pirate hello"}
    end

    test "does not match /lemonade as engine" do
      assert EngineDirective.strip("/lemonade hello") == {nil, "/lemonade hello"}
    end

    test "does not match /codextra as engine" do
      assert EngineDirective.strip("/codextra hello") == {nil, "/codextra hello"}
    end

    test "does not match /opencodex as engine" do
      assert EngineDirective.strip("/opencodex hello") == {nil, "/opencodex hello"}
    end
  end

  # ============================================================================
  # Additional edge cases
  # ============================================================================

  describe "strip/1 additional edge cases" do
    test "handles slash alone" do
      assert EngineDirective.strip("/") == {nil, "/"}
    end

    test "handles double slash" do
      assert EngineDirective.strip("//claude hello") == {nil, "//claude hello"}
    end

    test "handles backslash instead of forward slash" do
      assert EngineDirective.strip("\\claude hello") == {nil, "\\claude hello"}
    end

    test "preserves internal whitespace in remaining text" do
      assert EngineDirective.strip("/claude  fix   this   bug") == {"claude", "fix   this   bug"}
    end

    test "handles multiline text after directive" do
      assert EngineDirective.strip("/claude fix this\nand that") ==
               {"claude", "fix this\nand that"}
    end

    test "engine name is always returned lowercase" do
      {engine, _rest} = EngineDirective.strip("/ECHO test")
      assert engine == "echo"

      {engine2, _rest2} = EngineDirective.strip("/Claude test")
      assert engine2 == "claude"
    end

    test "handles directive with special characters in trailing text" do
      assert EngineDirective.strip("/claude what is @user's #1 priority?") ==
               {"claude", "what is @user's #1 priority?"}
    end

    test "handles directive followed by URL in trailing text" do
      assert EngineDirective.strip("/claude check https://example.com") ==
               {"claude", "check https://example.com"}
    end

    test "handles directive followed by code in trailing text" do
      assert EngineDirective.strip("/codex def foo(), do: :bar") ==
               {"codex", "def foo(), do: :bar"}
    end
  end
end
