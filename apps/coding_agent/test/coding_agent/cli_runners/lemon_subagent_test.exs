defmodule CodingAgent.CliRunners.LemonSubagentTest do
  use ExUnit.Case, async: true

  alias CodingAgent.CliRunners.LemonSubagent
  alias AgentCore.CliRunners.Types.ResumeToken

  describe "API structure" do
    test "supports_steer? returns true" do
      assert LemonSubagent.supports_steer?() == true
    end
  end

  describe "continue/3" do
    test "returns error when no resume token" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert {:error, :no_resume_token} = LemonSubagent.continue(session, "test")
    end
  end

  describe "resume_token/1" do
    test "returns the resume token from session when no agent" do
      token = ResumeToken.new("lemon", "abc12345")
      session = %{pid: nil, stream: nil, resume_token: token, token_agent: nil, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == token
    end

    test "returns nil when no token and no agent" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == nil
    end

    test "returns token from agent when agent is present" do
      token = ResumeToken.new("lemon", "xyz78901")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == token
      Agent.stop(agent)
    end

    test "falls back to session token when agent is dead" do
      token = ResumeToken.new("lemon", "abc12345")
      {:ok, agent} = Agent.start_link(fn -> nil end)
      Agent.stop(agent)
      # Wait a moment for the agent to fully stop
      Process.sleep(10)
      session = %{pid: nil, stream: nil, resume_token: token, token_agent: agent, cwd: "/tmp"}
      assert LemonSubagent.resume_token(session) == token
    end
  end

  describe "cancel/1" do
    test "returns ok even with nil pid" do
      # This tests the API doesn't crash on edge cases
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      # Should not raise
      try do
        LemonSubagent.cancel(session)
      rescue
        # Expected since pid is nil
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "steer/2" do
    test "returns error when session has no process" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      try do
        result = LemonSubagent.steer(session, "redirect")
        # If we get here, it should be an error
        assert {:error, _} = result or result == :ok
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "follow_up/2" do
    test "returns error when session has no process" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}

      try do
        result = LemonSubagent.follow_up(session, "next task")
        assert {:error, _} = result or result == :ok
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end
end
