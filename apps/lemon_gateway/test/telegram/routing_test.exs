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

  describe "parse_routing/1" do
    test "returns nil resume and nil engine_hint for plain text" do
      assert {nil, nil} = Transport.parse_routing("hello world")
    end

    test "extracts engine_hint from /codex command" do
      assert {nil, "codex"} = Transport.parse_routing("/codex do something")
    end

    test "extracts engine_hint from /claude command" do
      assert {nil, "claude"} = Transport.parse_routing("/claude help me")
    end

    test "extracts engine_hint from /lemon command" do
      assert {nil, "lemon"} = Transport.parse_routing("/lemon test")
    end

    test "extracts engine_hint from /echo command" do
      assert {nil, "echo"} = Transport.parse_routing("/echo test")
    end

    test "returns nil engine_hint for unknown command" do
      assert {nil, nil} = Transport.parse_routing("/unknown do something")
    end

    test "extracts lemon engine resume token" do
      {resume, engine_hint} = Transport.parse_routing("lemon resume abc123")

      assert %ResumeToken{engine: "lemon", value: "abc123"} = resume
      assert engine_hint == "lemon"
    end

    test "extracts echo engine resume token" do
      {resume, engine_hint} = Transport.parse_routing("echo resume abc123")

      assert %ResumeToken{engine: "echo", value: "abc123"} = resume
      assert engine_hint == "echo"
    end

    test "extracts codex resume token" do
      {resume, engine_hint} = Transport.parse_routing("codex resume session-456")

      assert %ResumeToken{engine: "codex", value: "session-456"} = resume
      assert engine_hint == "codex"
    end

    test "extracts claude resume token" do
      {resume, engine_hint} = Transport.parse_routing("claude --resume session-789")

      assert %ResumeToken{engine: "claude", value: "session-789"} = resume
      assert engine_hint == "claude"
    end

    test "resume engine takes precedence over command prefix" do
      # Even if /codex is used, if the text contains a claude resume token,
      # the claude engine should be used
      {resume, engine_hint} = Transport.parse_routing("/codex claude --resume xyz")

      assert %ResumeToken{engine: "claude", value: "xyz"} = resume
      assert engine_hint == "claude"
    end

    test "command prefix without resume uses command engine" do
      {resume, engine_hint} = Transport.parse_routing("/claude write some code")

      assert resume == nil
      assert engine_hint == "claude"
    end

    test "handles whitespace in command" do
      assert {nil, "codex"} = Transport.parse_routing("  /codex   something")
    end

    test "command at start of line only" do
      # Commands must be at the start (after optional whitespace)
      assert {nil, nil} = Transport.parse_routing("hello /codex")
    end

    test "case-insensitive command matching" do
      assert {nil, "codex"} = Transport.parse_routing("/Codex test")
      assert {nil, "claude"} = Transport.parse_routing("/CLAUDE test")
    end

    test "resume token in message body is extracted" do
      text = "Please continue: codex resume my-session"
      {resume, engine_hint} = Transport.parse_routing(text)

      assert %ResumeToken{engine: "codex", value: "my-session"} = resume
      assert engine_hint == "codex"
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
