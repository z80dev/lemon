defmodule LemonCore.ResumeTokenTest do
  # Registering a resume format writes application env, which is global.
  use ExUnit.Case, async: false

  alias LemonCore.ResumeFormat
  alias LemonCore.ResumeFormats
  alias LemonCore.ResumeToken

  doctest LemonCore.ResumeToken

  # Vendor syntax lives with the vendor: the round-trip for the CLI engines is
  # in lemon_cli_runners, against the formats its application registers at boot.
  # What core owns is the generic mechanism and its own `lemon` syntax.
  setup do
    ResumeFormats.register(
      ResumeFormat.new("stub",
        pattern: ~r/`?stub\s+--continue\s+<([^>]+)>`?/i,
        render: &("stub --continue <" <> &1 <> ">"),
        normalize: &String.upcase/1
      )
    )

    on_exit(fn -> ResumeFormats.unregister("stub") end)
  end

  describe "new/2 and format/1" do
    test "creates a new token" do
      token = ResumeToken.new("codex", "thread_123")
      assert token.engine == "codex"
      assert token.value == "thread_123"
    end

    test "implements Jason.Encoder" do
      token = ResumeToken.new("codex", "thread_123")

      assert Jason.encode!(token) |> Jason.decode!() == %{
               "engine" => "codex",
               "value" => "thread_123"
             }
    end

    test "format/1 wraps format_plain/1 in backticks" do
      assert ResumeToken.format(ResumeToken.new("lemon", "abc12345")) == "`lemon resume abc12345`"
    end
  end

  describe "format_plain/1" do
    test "renders the built-in lemon syntax" do
      assert ResumeToken.format_plain(%ResumeToken{engine: "lemon", value: "abc123"}) ==
               "lemon resume abc123"
    end

    test "renders a registered format with that format's own renderer" do
      assert ResumeToken.format_plain(%ResumeToken{engine: "stub", value: "s1"}) ==
               "stub --continue <s1>"
    end

    test "falls back to generic syntax for engines with no registered format" do
      assert ResumeToken.format_plain(%ResumeToken{engine: "custom", value: "token"}) ==
               "custom resume token"
    end
  end

  describe "extract_resume/1" do
    test "extracts the built-in lemon token, bare or backticked" do
      assert ResumeToken.extract_resume("lemon resume abc12345") ==
               %ResumeToken{engine: "lemon", value: "abc12345"}

      assert ResumeToken.extract_resume("Continue with `lemon resume abc12345`") ==
               %ResumeToken{engine: "lemon", value: "abc12345"}
    end

    test "extracts a registered format's token and applies its normalizer" do
      assert ResumeToken.extract_resume("run `stub --continue <s1>` next") ==
               %ResumeToken{engine: "stub", value: "S1"}
    end

    test "prefers the format registered first when several match" do
      assert %ResumeToken{engine: "stub"} =
               ResumeToken.extract_resume("stub --continue <s1> then lemon resume abc")
    end

    test "is case insensitive" do
      assert ResumeToken.extract_resume("LEMON RESUME abc") ==
               %ResumeToken{engine: "lemon", value: "abc"}
    end

    test "returns nil when nothing matches" do
      assert ResumeToken.extract_resume("No token here") == nil
      assert ResumeToken.extract_resume("") == nil
      assert ResumeToken.extract_resume(:not_text) == nil
    end

    test "does not invent tokens for engines with no registered format" do
      assert ResumeToken.extract_resume("custom resume abc") == nil
    end
  end

  describe "extract_resume/2" do
    test "extracts only the requested engine" do
      text = "lemon resume abc123 and stub --continue <s1>"

      assert ResumeToken.extract_resume(text, "lemon").value == "abc123"
      assert ResumeToken.extract_resume(text, "stub").value == "S1"
    end

    test "accepts generic syntax for engines with no registered format" do
      assert ResumeToken.extract_resume("custom resume abc", "custom") ==
               %ResumeToken{engine: "custom", value: "abc"}

      assert ResumeToken.extract_resume("custom resume abc", "other") == nil
    end
  end

  describe "is_resume_line/1" do
    test "accepts a line that is nothing but a resume command" do
      assert ResumeToken.is_resume_line("lemon resume abc12345")
      assert ResumeToken.is_resume_line("`lemon resume abc12345`")
      assert ResumeToken.is_resume_line("  lemon resume abc  ")
      assert ResumeToken.is_resume_line("LEMON RESUME abc")
      assert ResumeToken.is_resume_line("stub --continue <s1>")
    end

    test "rejects a resume command embedded in prose" do
      assert ResumeToken.is_resume_line("Please run lemon resume abc") == false
      assert ResumeToken.is_resume_line("lemon resume abc to continue") == false
      assert ResumeToken.is_resume_line("Some other text") == false
      assert ResumeToken.is_resume_line("") == false
      assert ResumeToken.is_resume_line(nil) == false
    end
  end

  describe "is_resume_line/2" do
    test "answers for the named engine only" do
      assert ResumeToken.is_resume_line("lemon resume abc", "lemon")
      assert ResumeToken.is_resume_line("lemon resume abc", "stub") == false
      assert ResumeToken.is_resume_line("stub --continue <s1>", "stub")
    end

    test "uses generic syntax for engines with no registered format" do
      assert ResumeToken.is_resume_line("custom resume abc", "custom")
      assert ResumeToken.is_resume_line("run custom resume abc", "custom") == false
    end
  end
end
