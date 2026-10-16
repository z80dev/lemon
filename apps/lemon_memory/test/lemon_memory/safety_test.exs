defmodule LemonMemory.SafetyTest do
  use ExUnit.Case, async: true

  alias LemonMemory.Document
  alias LemonMemory.Safety

  test "redact removes complete secret matches and reports the count" do
    planted = "sk-abcdefghijklmnopqrstuvwxyz123456"
    {text, count} = Safety.redact("visible #{planted} password=hunter2")

    assert count == 2
    refute text =~ planted
    refute text =~ "hunter2"
  end

  test "operator redaction removes arbitrary paths, URLs, authorization values, and secret names" do
    content =
      "Read CUSTOM_CLIENT_SECRET at /custom/work/private.txt or " <>
        "ssh://internal.example/repo with Bearer abcdefghijklmnop"

    {text, count} = Safety.redact_for_operator(content)

    assert count == 4

    for secret <- [
          "CUSTOM_CLIENT_SECRET",
          "/custom/work/private.txt",
          "internal.example",
          "abcdefghijklmnop"
        ] do
      refute text =~ secret
    end
  end

  describe "contains_secret?/1" do
    test "detects documented secret patterns" do
      samples = [
        "password=hunter2",
        "api_key: sk-proj-abcdefghijklmnopqrstuvwxyz1234567890",
        "aws key AKIAABCDEFGHIJKLMNOP",
        "-----BEGIN ED25519 PRIVATE KEY-----",
        "jwt eyJabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      ]

      for sample <- samples do
        assert Safety.contains_secret?(sample)
      end
    end

    test "refuses secrets beside query markers and quoted or spaced query values" do
      for {sample, expected} <- [
            {"password:hunter2?check", "[REDACTED]"},
            {~s(gateway?token="hidden"), "gateway?[REDACTED]"},
            {"gateway?token= hidden", "gateway?[REDACTED]"},
            {"gateway?session=public&token=private-value", "gateway?session=public&[REDACTED]"}
          ] do
        assert Safety.contains_secret?(sample), sample
        assert Safety.note_refusal_reason(sample), sample
        assert {^expected, count} = Safety.redact(sample)
        assert count > 0
      end
    end

    test "refuses quoted, nested, and percent-encoded credential shapes" do
      for sample <- [
            ~S(run 'PASSWORD=first&mode=last' now),
            ~S(x=%27PASSWORD%3Dfirst%26mode%3Dlast%27),
            ~S(message%20text=api_key="first second"),
            ~S(message%20text="api_key=first second"),
            ~S(%74oken=api_key="first second"),
            ~S(%2574oken=first),
            ~S(%access_key=first),
            ~S(%bearer=first),
            ~S(token%3Dfirst)
          ] do
        assert Safety.contains_secret?(sample), sample
        assert Safety.note_refusal_reason(sample), sample
        {redacted, count} = Safety.redact(sample)
        assert count > 0
        refute redacted =~ "first"
        refute redacted =~ "second"
      end
    end

    test "ignores clean operational text" do
      refute Safety.contains_secret?("implemented memory lookup and added tests")
      refute Safety.contains_secret?(nil)
    end
  end

  describe "safe_document?/1" do
    test "rejects documents with secret-looking summaries" do
      doc = %Document{
        prompt_summary: "Please remember this token=abc123",
        answer_summary: "I updated the project memory."
      }

      refute Safety.safe_document?(doc)
    end

    test "accepts clean documents" do
      doc = %Document{
        prompt_summary: "Add a focused regression for memory recall",
        answer_summary: "Added a test and updated the docs."
      }

      assert Safety.safe_document?(doc)
    end
  end
end
