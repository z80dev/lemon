defmodule LemonMemory.SessionSearchTest do
  @moduledoc """
  Rendering of memory documents injected into an agent's context. Free-text
  history search is `LemonMemory.Project.search_history/4` (see
  `LemonMemory.ProjectTest` and `LemonMemory.ContextPrivacyTest`).
  """

  use ExUnit.Case, async: true

  alias LemonMemory.Document
  alias LemonMemory.SessionSearch

  test "the unowned search façade is gone" do
    Code.ensure_loaded!(SessionSearch)
    refute function_exported?(SessionSearch, :search, 2)
    refute function_exported?(SessionSearch, :search, 1)
  end

  describe "format_results/1" do
    test "an empty result set renders the no-match sentence" do
      assert SessionSearch.format_results([]) == "No matching memory documents found."
    end

    test "renders numbered entries in order with timestamp, session and summaries" do
      docs = [
        doc(
          doc_id: "mem_format_main",
          run_id: "run_format_main",
          session_key: "agent:fmt:main",
          # 2023-11-14 22:13 UTC
          ingested_at_ms: 1_700_000_000_000,
          prompt_summary: "fix the login bug",
          answer_summary: "swapped the token check"
        ),
        doc(
          session_key: "agent:fmt:side",
          doc_id: "mem_format_side",
          run_id: "run_format_side",
          ingested_at_ms: 1_700_000_060_000,
          prompt_summary: "deploy the api",
          answer_summary: "deployed"
        )
      ]

      assert SessionSearch.format_results(docs) ==
               """
               [1] 2023-11-14 22:13 UTC | session: agent:fmt:main | doc: mem_format_main | run: run_format_main
               Q: fix the login bug
               A: swapped the token check

               [2] 2023-11-14 22:14 UTC | session: agent:fmt:side | doc: mem_format_side | run: run_format_side
               Q: deploy the api
               A: deployed
               """
               |> String.trim()
    end

    test "a document without an ingest timestamp renders an unknown time" do
      rendered =
        SessionSearch.format_results([
          doc(session_key: "agent:fmt:main", ingested_at_ms: nil)
        ])

      assert rendered =~ "[1] unknown | session: agent:fmt:main"
    end
  end

  defp doc(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %Document{
      doc_id: "mem_#{unique}",
      run_id: "run_#{unique}",
      session_key: "agent:session_search_test:main",
      agent_id: "session_search_test",
      workspace_key: nil,
      scope: :session,
      started_at_ms: 0,
      ingested_at_ms: 0,
      prompt_summary: "deploy the api",
      answer_summary: "deployed the api",
      tools_used: ["bash"],
      provider: "anthropic",
      model: "claude-sonnet-4-6",
      outcome: :unknown,
      meta: %{}
    }

    defaults |> struct!(attrs) |> Document.with_index()
  end
end
