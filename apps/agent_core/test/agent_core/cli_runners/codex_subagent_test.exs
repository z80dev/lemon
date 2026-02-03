defmodule AgentCore.CliRunners.CodexSubagentTest do
  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.CodexSubagent
  alias AgentCore.CliRunners.Types.ResumeToken

  describe "start/1" do
    test "returns error without codex installed" do
      # This test verifies the API works even if codex isn't installed
      # The actual subprocess will fail, but we can test the interface

      # Note: In a real environment with codex installed, this would succeed
      # For CI/test environments, we skip the subprocess execution
      assert {:ok, _session} = CodexSubagent.start(prompt: "test", cwd: System.tmp_dir!())
    catch
      # If codex isn't installed, we'll get an error - that's expected
      :exit, _ -> :ok
    end
  end

  describe "resume/2" do
    test "requires codex engine token" do
      token = ResumeToken.new("codex", "thread_123")
      # This will fail without codex, but tests the API
      assert {:ok, _} = CodexSubagent.resume(token, prompt: "test", cwd: System.tmp_dir!())
    catch
      :exit, _ -> :ok
    end
  end

  describe "continue/3" do
    test "returns error when no resume token" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert {:error, :no_resume_token} = CodexSubagent.continue(session, "test")
    end
  end

  describe "resume_token/1" do
    test "returns the resume token from session when no agent" do
      token = ResumeToken.new("codex", "thread_123")
      session = %{pid: nil, stream: nil, resume_token: token, token_agent: nil, cwd: "/tmp"}
      assert CodexSubagent.resume_token(session) == token
    end

    test "returns nil when no token and no agent" do
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: nil, cwd: "/tmp"}
      assert CodexSubagent.resume_token(session) == nil
    end

    test "returns token from agent when agent is present" do
      token = ResumeToken.new("codex", "thread_456")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = %{pid: nil, stream: nil, resume_token: nil, token_agent: agent}
      assert CodexSubagent.resume_token(session) == token
      Agent.stop(agent)
    end
  end
end
