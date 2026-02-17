defmodule LemonGateway.Telegram.RoutingTest do
  use ExUnit.Case

  alias LemonGateway.Telegram.Transport
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

  describe "strip_engine_directive/1" do
    test "strips /claude directive and returns engine hint" do
      assert {"claude", "What is the weather?"} =
               Transport.strip_engine_directive("/claude\nWhat is the weather?")
    end

    test "strips /codex directive and returns engine hint" do
      assert {"codex", "Do something"} =
               Transport.strip_engine_directive("/codex\nDo something")
    end

    test "strips /lemon directive and returns engine hint" do
      assert {"lemon", "Run a task"} =
               Transport.strip_engine_directive("/lemon\nRun a task")
    end

    test "returns nil engine_hint for text without directive" do
      assert {nil, "What is the weather?"} =
               Transport.strip_engine_directive("What is the weather?")
    end

    test "returns empty string when only directive present" do
      assert {"codex", ""} = Transport.strip_engine_directive("/codex")
    end

    test "handles directive with trailing whitespace only" do
      assert {"claude", ""} = Transport.strip_engine_directive("/claude   ")
    end

    test "preserves multiline content after directive" do
      input = "/claude\nLine 1\nLine 2\nLine 3"
      assert {"claude", "Line 1\nLine 2\nLine 3"} = Transport.strip_engine_directive(input)
    end

    test "handles leading whitespace before directive" do
      assert {"codex", "Task here"} =
               Transport.strip_engine_directive("  /codex\nTask here")
    end

    test "is case-insensitive for directive" do
      assert {"claude", "Test"} = Transport.strip_engine_directive("/Claude\nTest")
      assert {"codex", "Test"} = Transport.strip_engine_directive("/CODEX\nTest")
      assert {"lemon", "Test"} = Transport.strip_engine_directive("/LEMON\nTest")
    end

    test "does not strip non-engine directives" do
      assert {nil, "/other\nSome text"} =
               Transport.strip_engine_directive("/other\nSome text")
    end

    test "handles directive with content on same line" do
      # When there's content after the directive on the same line, preserve it
      assert {"claude", "inline content"} =
               Transport.strip_engine_directive("/claude inline content")
    end

    test "handles nil input" do
      assert {nil, ""} = Transport.strip_engine_directive(nil)
    end

    test "handles Windows-style line endings" do
      assert {"claude", "Content"} =
               Transport.strip_engine_directive("/claude\r\nContent")
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
