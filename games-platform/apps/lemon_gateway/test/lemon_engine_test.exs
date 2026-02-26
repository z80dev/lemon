defmodule LemonGateway.LemonEngineTest do
  use ExUnit.Case

  alias LemonGateway.Engines.Lemon
  alias LemonCore.ResumeToken

  describe "id/0" do
    test "returns lemon" do
      assert Lemon.id() == "lemon"
    end
  end

  describe "format_resume/1" do
    test "formats resume token" do
      token = %ResumeToken{engine: "lemon", value: "session_abc123"}
      assert Lemon.format_resume(token) == "lemon resume session_abc123"
    end
  end

  describe "extract_resume/1" do
    test "extracts token from plain text" do
      text = "lemon resume abc123"
      assert %ResumeToken{engine: "lemon", value: "abc123"} = Lemon.extract_resume(text)
    end

    test "extracts token from backticks" do
      text = "`lemon resume session_xyz`"
      assert %ResumeToken{engine: "lemon", value: "session_xyz"} = Lemon.extract_resume(text)
    end

    test "extracts token case-insensitively" do
      text = "LEMON RESUME MySession123"
      assert %ResumeToken{engine: "lemon", value: "MySession123"} = Lemon.extract_resume(text)
    end

    test "returns nil for non-matching text" do
      assert Lemon.extract_resume("no resume here") == nil
    end

    test "returns nil for other engine tokens" do
      assert Lemon.extract_resume("codex resume abc") == nil
      assert Lemon.extract_resume("claude --resume xyz") == nil
    end
  end

  describe "is_resume_line/1" do
    test "returns true for exact resume line" do
      assert Lemon.is_resume_line("lemon resume abc123")
    end

    test "returns true for backtick-wrapped line" do
      assert Lemon.is_resume_line("`lemon resume abc123`")
    end

    test "returns true for line with whitespace" do
      assert Lemon.is_resume_line("  lemon resume abc123  ")
    end

    test "returns false for line with extra text" do
      refute Lemon.is_resume_line("Please run lemon resume abc123")
    end

    test "returns false for other engines" do
      refute Lemon.is_resume_line("codex resume abc123")
    end
  end

  describe "supports_steer?/0" do
    test "returns true" do
      assert Lemon.supports_steer?() == true
    end
  end

  describe "steer/2" do
    test "returns error for nil runner" do
      ctx = %{runner_pid: nil, task_pid: nil, runner_module: CodingAgent.CliRunners.LemonRunner}
      assert Lemon.steer(ctx, "test") == {:error, :no_runner}
    end

    test "returns error for missing runner_pid" do
      ctx = %{task_pid: self(), runner_module: CodingAgent.CliRunners.LemonRunner}
      assert Lemon.steer(ctx, "test") == {:error, :no_runner}
    end
  end
end
