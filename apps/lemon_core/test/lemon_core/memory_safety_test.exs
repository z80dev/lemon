defmodule LemonCore.MemorySafetyTest do
  use ExUnit.Case, async: true

  alias LemonCore.MemoryDocument
  alias LemonCore.MemorySafety

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
        assert MemorySafety.contains_secret?(sample)
      end
    end

    test "ignores clean operational text" do
      refute MemorySafety.contains_secret?("implemented memory lookup and added tests")
      refute MemorySafety.contains_secret?(nil)
    end
  end

  describe "safe_document?/1" do
    test "rejects documents with secret-looking summaries" do
      doc = %MemoryDocument{
        prompt_summary: "Please remember this token=abc123",
        answer_summary: "I updated the project memory."
      }

      refute MemorySafety.safe_document?(doc)
    end

    test "accepts clean documents" do
      doc = %MemoryDocument{
        prompt_summary: "Add a focused regression for memory recall",
        answer_summary: "Added a test and updated the docs."
      }

      assert MemorySafety.safe_document?(doc)
    end
  end
end
