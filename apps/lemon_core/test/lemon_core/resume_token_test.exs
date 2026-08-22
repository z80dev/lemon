defmodule LemonCore.ResumeTokenTest do
  use ExUnit.Case, async: true

  alias LemonCore.ResumeToken

  doctest LemonCore.ResumeToken

  describe "new/2 and format/1" do
    test "creates a token while retaining the historical engine field" do
      token = ResumeToken.new("codex", "thread_123")

      assert token.engine == "codex"
      assert token.value == "thread_123"
    end

    test "implements Jason.Encoder for persisted history compatibility" do
      token = ResumeToken.new("codex", "thread_123")

      assert Jason.encode!(token) |> Jason.decode!() == %{
               "engine" => "codex",
               "value" => "thread_123"
             }
    end

    test "wraps the plain command in backticks" do
      assert ResumeToken.format(ResumeToken.new("lemon", "abc12345")) == "`lemon resume abc12345`"
    end
  end

  describe "format_plain/1" do
    test "renders a native Lemon token" do
      assert ResumeToken.format_plain(%ResumeToken{engine: "lemon", value: "abc123"}) ==
               "lemon resume abc123"
    end

    test "renders historical non-Lemon tokens generically" do
      assert ResumeToken.format_plain(%ResumeToken{engine: "custom", value: "token"}) ==
               "custom resume token"
    end
  end

  describe "extract_resume/1" do
    test "extracts a native Lemon token, bare or backticked" do
      assert ResumeToken.extract_resume("lemon resume abc12345") ==
               %ResumeToken{engine: "lemon", value: "abc12345"}

      assert ResumeToken.extract_resume("Continue with `LEMON RESUME abc12345`") ==
               %ResumeToken{engine: "lemon", value: "abc12345"}
    end

    test "rejects non-native resume commands" do
      assert ResumeToken.extract_resume("codex resume abc") == nil
      assert ResumeToken.extract_resume("stub --continue <s1>") == nil
      assert ResumeToken.extract_resume("No token here") == nil
      assert ResumeToken.extract_resume(:not_text) == nil
    end
  end

  describe "extract_resume/2" do
    test "extracts only the native Lemon engine" do
      assert ResumeToken.extract_resume("lemon resume abc123", "lemon") ==
               %ResumeToken{engine: "lemon", value: "abc123"}

      assert ResumeToken.extract_resume("lemon resume abc123", "codex") == nil
    end
  end

  describe "is_resume_line" do
    test "accepts only a complete native Lemon resume line" do
      assert ResumeToken.is_resume_line("lemon resume abc12345")
      assert ResumeToken.is_resume_line("`lemon resume abc12345`")
      assert ResumeToken.is_resume_line("  LEMON RESUME abc  ")
      assert ResumeToken.is_resume_line("lemon resume abc", "lemon")
    end

    test "rejects prose, non-native commands, and non-Lemon engines" do
      refute ResumeToken.is_resume_line("Please run lemon resume abc")
      refute ResumeToken.is_resume_line("codex resume abc")
      refute ResumeToken.is_resume_line("lemon resume abc", "codex")
      refute ResumeToken.is_resume_line(nil)
    end
  end
end
