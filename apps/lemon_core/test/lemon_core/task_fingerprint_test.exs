defmodule LemonCore.TaskFingerprintTest do
  use ExUnit.Case, async: true

  alias LemonCore.MemoryDocument
  alias LemonCore.TaskFingerprint

  defp doc(overrides \\ %{}) do
    base = %MemoryDocument{
      doc_id: "mem_test",
      run_id: "run_001",
      session_key: "agent:bot:main",
      agent_id: "bot",
      prompt_summary: "",
      answer_summary: "",
      tools_used: [],
      outcome: :unknown,
      scope: :session,
      started_at_ms: 0,
      ingested_at_ms: 1_000
    }

    Map.merge(base, overrides)
  end

  describe "from_document/1" do
    test "code task family from code keywords" do
      for keyword <- ~w(implement fix debug refactor build write create test) do
        fp = TaskFingerprint.from_document(doc(%{prompt_summary: "#{keyword} the auth module"}))
        assert fp.task_family == :code, "expected :code for keyword #{keyword}"
      end
    end

    test "query task family from query keywords" do
      for keyword <- ~w(explain describe analyze compare review) do
        fp = TaskFingerprint.from_document(doc(%{prompt_summary: "#{keyword} the code"}))
        assert fp.task_family == :query, "expected :query for keyword #{keyword}"
      end
    end

    test "file_ops task family from file keywords" do
      fp = TaskFingerprint.from_document(doc(%{prompt_summary: "read the config file"}))
      assert fp.task_family == :file_ops
    end

    test "chat task family from chat keywords" do
      fp = TaskFingerprint.from_document(doc(%{prompt_summary: "yes thanks"}))
      assert fp.task_family == :chat
    end

    test "unknown family for unrecognized prompt" do
      fp = TaskFingerprint.from_document(doc(%{prompt_summary: "blorp zorb norp"}))
      assert fp.task_family == :unknown
    end

    test "unknown family for nil prompt" do
      fp = TaskFingerprint.from_document(doc(%{prompt_summary: nil}))
      assert fp.task_family == :unknown
    end

    test "unknown family for empty prompt" do
      fp = TaskFingerprint.from_document(doc(%{prompt_summary: ""}))
      assert fp.task_family == :unknown
    end

    test "toolset is sorted and deduplicated from tools_used" do
      fp =
        TaskFingerprint.from_document(
          doc(%{tools_used: ["bash", "read_file", "bash", "write_file"]})
        )

      assert fp.toolset == ["bash", "read_file", "write_file"]
    end

    test "empty toolset when no tools used" do
      fp = TaskFingerprint.from_document(doc(%{tools_used: []}))
      assert fp.toolset == []
    end

    test "inherits workspace_key from document" do
      fp = TaskFingerprint.from_document(doc(%{workspace_key: "/home/user/project"}))
      assert fp.workspace_key == "/home/user/project"
    end

    test "workspace_key is nil when document has none" do
      fp = TaskFingerprint.from_document(doc(%{workspace_key: nil}))
      assert is_nil(fp.workspace_key)
    end

    test "inherits model and provider" do
      fp =
        TaskFingerprint.from_document(
          doc(%{model: "claude-sonnet-4-6", provider: "anthropic"})
        )

      assert fp.model == "claude-sonnet-4-6"
      assert fp.provider == "anthropic"
    end
  end

  describe "key/1" do
    test "returns a deterministic string" do
      fp = %TaskFingerprint{
        task_family: :code,
        toolset: ["bash", "read_file"],
        workspace_key: "/home/user/proj",
        provider: "anthropic",
        model: "claude-sonnet-4-6"
      }

      key = TaskFingerprint.key(fp)
      assert key == "code|bash,read_file|/home/user/proj|anthropic|claude-sonnet-4-6"
    end

    test "uses dashes for nil fields" do
      fp = %TaskFingerprint{
        task_family: :unknown,
        toolset: [],
        workspace_key: nil,
        provider: nil,
        model: nil
      }

      key = TaskFingerprint.key(fp)
      assert key == "unknown|-|-|-|-"
    end

    test "empty toolset maps to dash segment" do
      fp = %TaskFingerprint{task_family: :chat, toolset: []}
      key = TaskFingerprint.key(fp)
      assert String.contains?(key, "|-|")
    end

    test "same fingerprint always produces same key" do
      fp = TaskFingerprint.from_document(doc(%{
        prompt_summary: "implement the feature",
        tools_used: ["bash"],
        model: "opus",
        provider: "anthropic"
      }))

      assert TaskFingerprint.key(fp) == TaskFingerprint.key(fp)
    end

    test "different toolsets produce different keys" do
      fp1 = %TaskFingerprint{task_family: :code, toolset: ["bash"]}
      fp2 = %TaskFingerprint{task_family: :code, toolset: ["read_file"]}
      refute TaskFingerprint.key(fp1) == TaskFingerprint.key(fp2)
    end
  end

  describe "context_key/1" do
    test "returns 3-segment key without provider and model" do
      fp = %TaskFingerprint{
        task_family: :code,
        toolset: ["bash", "read_file"],
        workspace_key: "/home/user/proj",
        provider: "anthropic",
        model: "claude-sonnet-4-6"
      }

      ctx = TaskFingerprint.context_key(fp)
      assert ctx == "code|bash,read_file|/home/user/proj"
    end

    test "context_key is a prefix of key" do
      fp = %TaskFingerprint{
        task_family: :query,
        toolset: ["bash"],
        workspace_key: "/srv/app",
        provider: "openai",
        model: "gpt-4o"
      }

      assert String.starts_with?(TaskFingerprint.key(fp), TaskFingerprint.context_key(fp) <> "|")
    end

    test "uses dash for empty toolset and nil workspace" do
      fp = %TaskFingerprint{task_family: :unknown, toolset: [], workspace_key: nil}
      assert TaskFingerprint.context_key(fp) == "unknown|-|-"
    end

    test "is deterministic for same fingerprint" do
      fp = %TaskFingerprint{
        task_family: :file_ops,
        toolset: ["write_file"],
        workspace_key: "/tmp/test"
      }

      assert TaskFingerprint.context_key(fp) == TaskFingerprint.context_key(fp)
    end
  end

  describe "classify_prompt/1" do
    test "classifies nil as :unknown" do
      assert TaskFingerprint.classify_prompt(nil) == :unknown
    end

    test "classifies empty string as :unknown" do
      assert TaskFingerprint.classify_prompt("") == :unknown
    end

    test "classifies code keywords" do
      assert TaskFingerprint.classify_prompt("implement the login feature") == :code
      assert TaskFingerprint.classify_prompt("fix the bug in parser") == :code
    end

    test "classifies query keywords" do
      assert TaskFingerprint.classify_prompt("explain how the router works") == :query
    end

    test "classifies file ops keywords" do
      assert TaskFingerprint.classify_prompt("read the config file") == :file_ops
    end

    test "classifies chat keywords" do
      assert TaskFingerprint.classify_prompt("yes thanks") == :chat
    end

    test "returns :unknown for unrecognized prompt" do
      assert TaskFingerprint.classify_prompt("blorp zorb norp") == :unknown
    end
  end

  describe "task_families/0" do
    test "includes all expected families" do
      families = TaskFingerprint.task_families()
      assert :code in families
      assert :query in families
      assert :file_ops in families
      assert :chat in families
      assert :unknown in families
    end
  end
end
