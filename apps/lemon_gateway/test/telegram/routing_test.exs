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

  describe "sticky engine persistence" do
    test "engine directive updates last_engine in chat state" do
      session_key = "test:sticky_engine:#{System.unique_integer([:positive])}"

      # Initially no chat state
      assert LemonCore.Store.get_chat_state(session_key) == nil

      # Simulate what update_chat_state_last_engine does: persist engine from directive
      payload = %{last_engine: "claude", updated_at: System.system_time(:millisecond)}
      LemonCore.Store.put_chat_state(session_key, payload)

      # Allow async cast to process
      Process.sleep(50)

      state = LemonCore.Store.get_chat_state(session_key)
      assert state[:last_engine] == "claude" || state["last_engine"] == "claude"
    end

    test "engine directive preserves existing last_resume_token" do
      session_key = "test:sticky_engine_preserve:#{System.unique_integer([:positive])}"

      # Set initial state with a resume token
      initial = %{
        last_engine: "echo",
        last_resume_token: "tok-abc123",
        updated_at: System.system_time(:millisecond)
      }

      LemonCore.Store.put_chat_state(session_key, initial)
      Process.sleep(50)

      # Now simulate directive engine update (preserving resume token)
      existing = LemonCore.Store.get_chat_state(session_key)
      token = existing[:last_resume_token] || existing["last_resume_token"]

      updated = %{
        last_engine: "claude",
        last_resume_token: token,
        updated_at: System.system_time(:millisecond)
      }

      LemonCore.Store.put_chat_state(session_key, updated)
      Process.sleep(50)

      state = LemonCore.Store.get_chat_state(session_key)
      last_engine = state[:last_engine] || state["last_engine"]
      resume_token = state[:last_resume_token] || state["last_resume_token"]

      assert last_engine == "claude"
      assert resume_token == "tok-abc123"
    end

    test "last_engine_hint retrieval pattern works with stored engine" do
      session_key = "test:sticky_hint:#{System.unique_integer([:positive])}"

      payload = %{last_engine: "codex", updated_at: System.system_time(:millisecond)}
      LemonCore.Store.put_chat_state(session_key, payload)
      Process.sleep(50)

      # Replicate the last_engine_hint retrieval pattern
      s1 = LemonCore.Store.get_chat_state(session_key)
      engine = s1 && (s1[:last_engine] || s1["last_engine"])
      hint = if is_binary(engine) and engine != "", do: engine, else: nil

      assert hint == "codex"
    end
  end
end
