defmodule LemonCore.MemoryDocumentTest do
  use ExUnit.Case, async: true

  alias LemonCore.MemoryDocument

  describe "from_run/4" do
    test "builds a document from a basic run record and summary" do
      run_id = "run_test_001"

      record = %{
        events: [
          %{type: :tool_call, tool: "bash"},
          %{type: :tool_call, tool: "read_file"},
          %{type: :tool_call, tool: "bash"}
        ],
        summary: nil,
        started_at: System.system_time(:millisecond) - 5_000
      }

      summary = %{
        session_key: "agent:test_agent:main",
        agent_id: "test_agent",
        prompt: "Fix the broken test",
        completed: %{answer: "Done, fixed the assertion."},
        provider: "anthropic",
        model: "claude-sonnet-4-6"
      }

      doc = MemoryDocument.from_run(run_id, record, summary)

      assert doc.run_id == run_id
      assert doc.session_key == "agent:test_agent:main"
      assert doc.agent_id == "test_agent"
      assert doc.prompt_summary == "Fix the broken test"
      assert doc.answer_summary == "Done, fixed the assertion."
      assert doc.tools_used == ["bash", "read_file"]
      assert doc.provider == "anthropic"
      assert doc.model == "claude-sonnet-4-6"
      assert doc.outcome == :unknown
      assert String.starts_with?(doc.doc_id, "mem_")
      assert doc.ingested_at_ms > 0
    end

    test "infers agent_id from session_key when not in summary" do
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
      summary = %{session_key: "agent:my_bot:main"}

      doc = MemoryDocument.from_run("run_x", record, summary)

      assert doc.agent_id == "my_bot"
    end

    test "assigns default agent_id when session_key is invalid" do
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
      summary = %{session_key: "bad_key"}

      doc = MemoryDocument.from_run("run_x", record, summary)

      assert doc.agent_id == "default"
    end

    test "infers workspace scope when workspace_key is present" do
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}

      summary = %{
        session_key: "agent:bot:main",
        workspace_key: "/home/user/my_project"
      }

      doc = MemoryDocument.from_run("run_x", record, summary)

      assert doc.scope == :workspace
      assert doc.workspace_key == "/home/user/my_project"
    end

    test "defaults to session scope when workspace_key is nil" do
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
      summary = %{session_key: "agent:bot:main"}

      doc = MemoryDocument.from_run("run_x", record, summary)

      assert doc.scope == :session
      assert is_nil(doc.workspace_key)
    end

    test "truncates oversized prompt and answer summaries" do
      long_text = String.duplicate("a", 3_000)
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}

      summary = %{
        session_key: "agent:bot:main",
        prompt: long_text,
        completed: %{answer: long_text}
      }

      doc = MemoryDocument.from_run("run_x", record, summary)

      assert byte_size(doc.prompt_summary) < 3_000
      assert String.ends_with?(doc.prompt_summary, "...[truncated]")
      assert byte_size(doc.answer_summary) < 3_000
      assert String.ends_with?(doc.answer_summary, "...[truncated]")
    end

    test "deduplicates tools_used" do
      record = %{
        events: [
          %{type: :tool_call, tool: "bash"},
          %{type: :tool_call, tool: "bash"},
          %{type: :tool_call, tool: "read_file"}
        ],
        summary: nil,
        started_at: System.system_time(:millisecond)
      }

      doc = MemoryDocument.from_run("run_x", record, %{session_key: "agent:bot:main"})

      assert length(doc.tools_used) == 2
      assert "bash" in doc.tools_used
      assert "read_file" in doc.tools_used
    end

    test "handles missing events gracefully" do
      record = %{summary: nil, started_at: System.system_time(:millisecond)}
      summary = %{session_key: "agent:bot:main"}

      doc = MemoryDocument.from_run("run_x", record, summary)

      assert doc.tools_used == []
    end

    test "infers outcome from completed sub-map" do
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}

      success_doc =
        MemoryDocument.from_run("run_s", record, %{
          session_key: "agent:bot:main",
          completed: %{ok: true, answer: "Done."}
        })

      assert success_doc.outcome == :success

      partial_doc =
        MemoryDocument.from_run("run_p", record, %{
          session_key: "agent:bot:main",
          completed: %{ok: true, answer: ""}
        })

      assert partial_doc.outcome == :partial

      aborted_doc =
        MemoryDocument.from_run("run_a", record, %{
          session_key: "agent:bot:main",
          completed: %{ok: false, error: "user_requested"}
        })

      assert aborted_doc.outcome == :aborted

      failure_doc =
        MemoryDocument.from_run("run_f", record, %{
          session_key: "agent:bot:main",
          completed: %{ok: false, error: "internal_error"}
        })

      assert failure_doc.outcome == :failure
    end

    test "handles nil summary fields gracefully" do
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
      summary = %{session_key: "agent:bot:main", prompt: nil, completed: nil}

      doc = MemoryDocument.from_run("run_x", record, summary)

      assert doc.prompt_summary == ""
      assert doc.answer_summary == ""
      assert is_nil(doc.provider)
      assert is_nil(doc.model)
    end

    test "accepts reference run_ids" do
      ref = make_ref()
      record = %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
      summary = %{session_key: "agent:bot:main"}

      doc = MemoryDocument.from_run(ref, record, summary)

      assert is_binary(doc.run_id)
    end
  end
end
