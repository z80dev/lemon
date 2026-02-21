defmodule LemonGateway.Telegram.RoutingTest do
  use ExUnit.Case

  alias LemonGateway.EngineDirective
  alias LemonGateway.Types.ResumeToken

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      LemonGateway.Engines.Lemon,
      LemonGateway.Engines.Codex,
      LemonGateway.Engines.Claude
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  describe "EngineDirective.strip/1" do
    test "strips /claude directive and returns engine hint" do
      assert {"claude", "What is the weather?"} =
               EngineDirective.strip("/claude\nWhat is the weather?")
    end

    test "strips /codex directive and returns engine hint" do
      assert {"codex", "Do something"} =
               EngineDirective.strip("/codex\nDo something")
    end

    test "strips /lemon directive and returns engine hint" do
      assert {"lemon", "Run a task"} =
               EngineDirective.strip("/lemon\nRun a task")
    end

    test "returns nil engine_hint for text without directive" do
      assert {nil, "What is the weather?"} =
               EngineDirective.strip("What is the weather?")
    end

    test "returns empty string when only directive present" do
      assert {"codex", ""} = EngineDirective.strip("/codex")
    end

    test "handles directive with trailing whitespace only" do
      assert {"claude", ""} = EngineDirective.strip("/claude   ")
    end

    test "preserves multiline content after directive" do
      input = "/claude\nLine 1\nLine 2\nLine 3"
      assert {"claude", "Line 1\nLine 2\nLine 3"} = EngineDirective.strip(input)
    end

    test "handles leading whitespace before directive" do
      assert {"codex", "Task here"} =
               EngineDirective.strip("  /codex\nTask here")
    end

    test "is case-insensitive for directive" do
      assert {"claude", "Test"} = EngineDirective.strip("/Claude\nTest")
      assert {"codex", "Test"} = EngineDirective.strip("/CODEX\nTest")
      assert {"lemon", "Test"} = EngineDirective.strip("/LEMON\nTest")
    end

    test "does not strip non-engine directives" do
      assert {nil, "/other\nSome text"} =
               EngineDirective.strip("/other\nSome text")
    end

    test "handles directive with content on same line" do
      # When there's content after the directive on the same line, preserve it
      assert {"claude", "inline content"} =
               EngineDirective.strip("/claude inline content")
    end

    test "handles nil input" do
      assert {nil, ""} = EngineDirective.strip(nil)
    end

    test "handles Windows-style line endings" do
      assert {"claude", "Content"} =
               EngineDirective.strip("/claude\r\nContent")
    end
  end

  describe "EngineRegistry.extract_resume/1" do
    test "returns :none when no engine matches" do
      assert :none = LemonGateway.EngineRegistry.extract_resume("just plain text")
    end

    test "returns {:ok, token} when lemon engine matches" do
      assert {:ok, %ResumeToken{engine: "lemon", value: "test123"}} =
               LemonGateway.EngineRegistry.extract_resume("lemon resume test123")
    end

    test "returns {:ok, token} when codex engine matches" do
      assert {:ok, %ResumeToken{engine: "codex", value: "sess-1"}} =
               LemonGateway.EngineRegistry.extract_resume("codex resume sess-1")
    end

    test "returns {:ok, token} when claude engine matches" do
      assert {:ok, %ResumeToken{engine: "claude", value: "sess-2"}} =
               LemonGateway.EngineRegistry.extract_resume("claude --resume sess-2")
    end
  end
end
