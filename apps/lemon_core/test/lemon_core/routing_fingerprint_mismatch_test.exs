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

  @moduletag :tmp_dir

  alias LemonCore.{MemoryIngest, MemoryStore, RoutingFeedbackStore, TaskFingerprint}

  setup %{tmp_dir: tmp_dir} do
    routing_dir = Path.join(tmp_dir, "rfm_#{System.unique_integer([:positive])}")
    memory_dir = Path.join(tmp_dir, "mem_#{System.unique_integer([:positive])}")
    routing_name = :"rfm_#{System.unique_integer([:positive])}"
    memory_name = :"mem_#{System.unique_integer([:positive])}"

    {:ok, feedback_pid} =
      RoutingFeedbackStore.start_link(path: routing_dir, name: routing_name, min_sample_size: 1)

    {:ok, memory_pid} = MemoryStore.start_link(path: memory_dir, name: memory_name)

    {:ok, ingest_pid} =
      GenServer.start_link(MemoryIngest,
        config_loader: fn ->
          %{
            features: %LemonCore.Config.Features{
              session_search: :off,
              routing_feedback: :"default-on"
            }
          }
        end,
        memory_store: memory_pid,
        routing_feedback_store: feedback_pid
      )

    on_exit(fn ->
      if Process.alive?(ingest_pid), do: GenServer.stop(ingest_pid)
      if Process.alive?(memory_pid), do: GenServer.stop(memory_pid)
      if Process.alive?(feedback_pid), do: GenServer.stop(feedback_pid)
    end)

    %{feedback_pid: feedback_pid, ingest_pid: ingest_pid}
  end

  defp seed(pid, key, n \\ 5) do
    for _ <- 1..n, do: GenServer.cast(pid, {:record, key, "success", 1000})
    Process.sleep(30)
  end

  defp sample_inputs do
    record = %{
      started_at: 1_000,
      events: [
        %{type: :tool_call, tool: "bash"},
        %{type: :tool_call, tool: "read_file"}
      ]
    }

    summary = %{
      session_key: "agent:bot:main",
      agent_id: "bot",
      cwd: "/workspace",
      prompt: "implement the feature",
      completed: %{ok: true, answer: "Done."},
      provider: "anthropic",
      model: "claude-sonnet"
    }

    {record, summary}
  end

  test "MemoryIngest writes routing feedback that the router lookup can read", %{
    feedback_pid: feedback_pid,
    ingest_pid: ingest_pid
  } do
    {record, summary} = sample_inputs()

    for idx <- 1..3 do
      MemoryIngest.ingest(ingest_pid, "run_rfm_#{idx}", record, summary)
    end

    :sys.get_state(ingest_pid)
    GenServer.call(feedback_pid, :store_stats)

    lookup_fp = %TaskFingerprint{
      task_family: TaskFingerprint.classify_prompt(summary.prompt),
      workspace_key: summary.cwd
      # toolset defaults to []
    }

    lookup_context = TaskFingerprint.context_key(lookup_fp)

    assert {:ok, "claude-sonnet"} =
             GenServer.call(feedback_pid, {:best_model_for_context, lookup_context})
  end

  test "keys written WITH real toolset are not found by empty-toolset lookup (pre-fix bug)", %{
    feedback_pid: feedback_pid
  } do
    {record, summary} = sample_inputs()

    # Pre-fix MemoryIngest wrote with full toolset in key
    doc = LemonCore.MemoryDocument.from_run("run_rfm_pre_fix", record, summary)
    ingest_fp = TaskFingerprint.from_document(doc)
    stored_key_with_toolset = TaskFingerprint.key(ingest_fp)

    seed(feedback_pid, stored_key_with_toolset)

    # RunOrchestrator lookup uses empty toolset
    lookup_fp = %TaskFingerprint{
      task_family: TaskFingerprint.classify_prompt(summary.prompt),
      workspace_key: summary.cwd
    }

    lookup_context = TaskFingerprint.context_key(lookup_fp)

    # LIKE prefix mismatch: stored key has real toolset, lookup context has "-" toolset
    assert {:insufficient_data, 0} =
             GenServer.call(feedback_pid, {:best_model_for_context, lookup_context})
  end
end
