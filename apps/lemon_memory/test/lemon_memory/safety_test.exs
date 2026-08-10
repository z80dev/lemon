defmodule LemonMemory.SafetyTest do
  use ExUnit.Case, async: true

  alias LemonMemory.Document
  alias LemonMemory.Safety

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
