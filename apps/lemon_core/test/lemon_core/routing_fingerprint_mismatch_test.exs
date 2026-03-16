defmodule LemonCore.RoutingFingerprintMismatchTest do
  @moduledoc """
  Regression tests for C1: routing fingerprint mismatch between ingest (write)
  and orchestrator lookup (read) paths.

  The bug: MemoryIngest wrote fingerprint keys that included the real toolset
  (e.g., "code|bash,read_file|/workspace|provider|model"), but RunOrchestrator
  looked up with an empty-toolset context_key ("code|-|/workspace").  The LIKE
  prefix never matched, so best_model_for_context always returned
  {:insufficient_data, 0}.

  The fix: MemoryIngest strips toolset to [] before building the stored key,
  aligning write and read paths.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{MemoryDocument, RoutingFeedbackStore, TaskFingerprint}

  setup do
    dir = System.tmp_dir!() |> Path.join("rfm_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:ok, pid} =
      GenServer.start_link(RoutingFeedbackStore, [path: dir],
        name: :"rfm_#{:erlang.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(dir)
    end)

    %{pid: pid}
  end

  defp seed(pid, key, n \\ 5) do
    for _ <- 1..n, do: GenServer.cast(pid, {:record, key, "success", 1000})
    Process.sleep(30)
  end

  defp sample_doc do
    %MemoryDocument{
      doc_id: "mem_rfm",
      run_id: "run_rfm",
      session_key: "agent:bot:main",
      agent_id: "bot",
      workspace_key: "/workspace",
      prompt_summary: "implement the feature",
      tools_used: ["bash", "read_file"],
      model: "claude-sonnet",
      provider: "anthropic",
      outcome: :success,
      scope: :workspace,
      started_at_ms: 0,
      ingested_at_ms: 1000,
      answer_summary: "",
      meta: %{}
    }
  end

  test "empty-toolset lookup finds keys written without toolset (post-fix write path)", %{pid: pid} do
    doc = sample_doc()

    # Post-fix MemoryIngest writes with toolset stripped to []
    ingest_fp = TaskFingerprint.from_document(doc)
    stored_key = TaskFingerprint.key(%{ingest_fp | toolset: []})

    seed(pid, stored_key)

    # RunOrchestrator builds a lookup fingerprint with no toolset
    lookup_fp = %TaskFingerprint{
      task_family: TaskFingerprint.classify_prompt(doc.prompt_summary),
      workspace_key: doc.workspace_key
      # toolset defaults to []
    }

    lookup_context = TaskFingerprint.context_key(lookup_fp)

    assert {:ok, "claude-sonnet"} =
             GenServer.call(pid, {:best_model_for_context, lookup_context})
  end

  test "keys written WITH real toolset are not found by empty-toolset lookup (pre-fix bug)", %{pid: pid} do
    doc = sample_doc()

    # Pre-fix MemoryIngest wrote with full toolset in key
    ingest_fp = TaskFingerprint.from_document(doc)
    stored_key_with_toolset = TaskFingerprint.key(ingest_fp)

    seed(pid, stored_key_with_toolset)

    # RunOrchestrator lookup uses empty toolset
    lookup_fp = %TaskFingerprint{
      task_family: TaskFingerprint.classify_prompt(doc.prompt_summary),
      workspace_key: doc.workspace_key
    }

    lookup_context = TaskFingerprint.context_key(lookup_fp)

    # LIKE prefix mismatch: stored key has real toolset, lookup context has "-" toolset
    assert {:insufficient_data, 0} =
             GenServer.call(pid, {:best_model_for_context, lookup_context})
  end
end
