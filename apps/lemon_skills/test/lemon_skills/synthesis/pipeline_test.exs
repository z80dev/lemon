defmodule LemonSkills.Synthesis.PipelineTest do
  # async: false — these tests drive the LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS
  # environment variable, which is process-global.
  use ExUnit.Case, async: false

  alias LemonMemory.Document
  alias LemonSkills.Synthesis.DraftStore
  alias LemonSkills.Synthesis.Pipeline

  @flag_env "LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS"

  # ── Injected collaborators ────────────────────────────────────────────────

  defmodule StubStore do
    @moduledoc false
    def get_by_agent(_agent_id, opts) do
      send(Process.get(:test_pid), {:get_by_agent, opts})
      Process.get(:stub_docs, [])
    end

    def get_by_session(_key, _opts), do: Process.get(:stub_docs, [])
    def get_by_workspace(_key, _opts), do: Process.get(:stub_docs, [])
  end

  # Honors :since_ms and :limit the way LemonMemory.Store does: the OLDEST
  # unseen window, oldest-first.
  defmodule WatermarkStore do
    @moduledoc false
    def get_by_agent(_agent_id, opts) do
      since_ms = Keyword.get(opts, :since_ms)
      limit = Keyword.get(opts, :limit, 20)

      Process.get(:stub_docs, [])
      |> Enum.filter(&(is_nil(since_ms) or &1.ingested_at_ms > since_ms))
      |> Enum.sort_by(&{&1.ingested_at_ms, &1.doc_id})
      |> Enum.take(limit)
    end

    def get_by_session(key, opts), do: get_by_agent(key, opts)
    def get_by_workspace(key, opts), do: get_by_agent(key, opts)
  end

  defmodule ExitingStore do
    @moduledoc false
    def get_by_agent(_agent_id, _opts), do: exit(:noproc)
    def get_by_session(_key, _opts), do: exit(:noproc)
    def get_by_workspace(_key, _opts), do: exit(:noproc)
  end

  defmodule PassAudit do
    @moduledoc false
    def audit(_dir, _scope, _key, _opts) do
      {:ok, %{"final_verdict" => "pass", "combined_findings" => [], "approval_required" => false}}
    end

    def audit_status(_record), do: :pass
  end

  defmodule BlockAudit do
    @moduledoc false
    def audit(_dir, _scope, _key, _opts) do
      {:ok,
       %{
         "final_verdict" => "block",
         "combined_findings" => ["secret"],
         "approval_required" => true
       }}
    end

    def audit_status(_record), do: :block
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  setup do
    Process.put(:test_pid, self())

    tmp =
      Path.join(
        System.tmp_dir!(),
        "synthesis_pipeline_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    previous_flag = System.get_env(@flag_env)

    on_exit(fn ->
      File.rm_rf!(tmp)

      case previous_flag do
        nil -> System.delete_env(@flag_env)
        value -> System.put_env(@flag_env, value)
      end
    end)

    {:ok, tmp: tmp}
  end

  defp base_opts(ctx, extra) do
    Keyword.merge(
      [
        global: false,
        cwd: ctx.tmp,
        store_mod: StubStore,
        audit_mod: PassAudit
      ],
      extra
    )
  end

  defp doc(tag, ingested_at_ms) do
    %Document{
      doc_id: "doc-#{tag}",
      run_id: "run-#{tag}",
      session_key: "session-1",
      agent_id: "agent-1",
      workspace_key: nil,
      scope: :agent,
      started_at_ms: ingested_at_ms,
      ingested_at_ms: ingested_at_ms,
      prompt_summary: String.duplicate("implement #{tag} k8s deployment script ", 3),
      answer_summary: String.duplicate("use kubectl apply with the deployment manifest ", 4),
      tools_used: ["bash"],
      provider: "anthropic",
      model: "claude-sonnet",
      outcome: :success,
      meta: %{}
    }
  end

  defp put_docs(docs), do: Process.put(:stub_docs, docs)

  # ── Feature gating ────────────────────────────────────────────────────────

  describe "opt-in feature gating" do
    test "opt-in flag without opt_in: true stays disabled", ctx do
      System.put_env(@flag_env, "opt-in")
      put_docs([])

      assert {:error, :feature_disabled} =
               Pipeline.run(:agent, "agent-1", base_opts(ctx, []))
    end

    test "opt-in flag with opt_in: true runs", ctx do
      System.put_env(@flag_env, "opt-in")
      put_docs([])

      assert {:ok, %{total_candidates: 0}} =
               Pipeline.run(:agent, "agent-1", base_opts(ctx, opt_in: true))
    end

    test "off flag is a kill switch even with opt_in: true", ctx do
      System.put_env(@flag_env, "off")
      put_docs([])

      assert {:error, :feature_disabled} =
               Pipeline.run(:agent, "agent-1", base_opts(ctx, opt_in: true))
    end

    test "default-on flag runs without opt_in", ctx do
      System.put_env(@flag_env, "default-on")
      put_docs([])

      assert {:ok, %{total_candidates: 0}} =
               Pipeline.run(:agent, "agent-1", base_opts(ctx, []))
    end
  end

  # ── Watermark filtering ───────────────────────────────────────────────────

  describe "since_ms filtering" do
    setup do
      System.put_env(@flag_env, "default-on")
      :ok
    end

    test "considers only documents newer than the watermark", ctx do
      put_docs([doc("alpha", 100), doc("beta", 200), doc("gamma", 300)])

      assert {:ok, result} = Pipeline.run(:agent, "agent-1", base_opts(ctx, since_ms: 200))

      assert result.total_candidates == 1
      assert result.latest_doc_ms == 300
      assert length(result.generated) == 1
    end

    test "nil watermark considers everything", ctx do
      put_docs([doc("alpha", 100), doc("beta", 200), doc("gamma", 300)])

      assert {:ok, result} = Pipeline.run(:agent, "agent-1", base_opts(ctx, since_ms: nil))

      assert result.total_candidates == 3
      assert result.latest_doc_ms == 300
    end

    test "empty document list yields a nil watermark and no candidates", ctx do
      put_docs([])

      assert {:ok, result} = Pipeline.run(:agent, "agent-1", base_opts(ctx, []))

      assert result.total_candidates == 0
      assert result.latest_doc_ms == nil
      assert result.generated == []
      assert result.skipped == []
    end

    test "latest_doc_ms covers documents that failed candidate selection", ctx do
      # A newer document that is not a candidate (failure outcome) must still
      # advance the watermark, otherwise every pass re-examines it forever.
      unqualified = %{doc("gamma", 300) | outcome: :failure}
      put_docs([doc("alpha", 100), unqualified])

      assert {:ok, result} = Pipeline.run(:agent, "agent-1", base_opts(ctx, []))

      assert result.total_candidates == 1
      assert result.latest_doc_ms == 300
    end

    test "max_docs is forwarded to the store", ctx do
      put_docs([])

      assert {:ok, _} = Pipeline.run(:agent, "agent-1", base_opts(ctx, max_docs: 7))
      assert_received {:get_by_agent, opts}
      assert Keyword.get(opts, :limit) == 7
    end

    test "since_ms is pushed down to the store", ctx do
      put_docs([])

      assert {:ok, _} = Pipeline.run(:agent, "agent-1", base_opts(ctx, since_ms: 4242))
      assert_received {:get_by_agent, opts}
      assert Keyword.get(opts, :since_ms) == 4242
    end
  end

  # ── Backlog draining ──────────────────────────────────────────────────────

  describe "backlogs larger than max_docs" do
    setup do
      System.put_env(@flag_env, "default-on")
      :ok
    end

    test "successive passes observe every document exactly once", ctx do
      docs =
        for i <- 1..120, do: doc("d#{String.pad_leading("#{i}", 3, "0")}", 1_700_000_000_000 + i)

      put_docs(docs)

      {seen, watermark} =
        Enum.reduce(1..3, {[], 0}, fn _pass, {seen, since_ms} ->
          opts = base_opts(ctx, store_mod: WatermarkStore, max_docs: 50, since_ms: since_ms)
          assert {:ok, result} = Pipeline.run(:agent, "agent-1", opts)

          window = WatermarkStore.get_by_agent("agent-1", limit: 50, since_ms: since_ms)
          assert result.latest_doc_ms == List.last(window).ingested_at_ms

          {seen ++ Enum.map(window, & &1.doc_id), result.latest_doc_ms}
        end)

      assert length(seen) == 120
      assert Enum.uniq(seen) == seen
      assert MapSet.new(seen) == MapSet.new(docs, & &1.doc_id)
      assert watermark == 1_700_000_000_120
    end

    test "a full fetch window reports backlog saturation", ctx do
      put_docs(for i <- 1..10, do: doc("sat-#{i}", 1_000 + i))

      opts = base_opts(ctx, store_mod: WatermarkStore, max_docs: 5)
      assert {:ok, result} = Pipeline.run(:agent, "agent-1", opts)
      assert result.backlog_saturated

      opts = base_opts(ctx, store_mod: WatermarkStore, max_docs: 50)
      assert {:ok, result} = Pipeline.run(:agent, "agent-1", opts)
      refute result.backlog_saturated
    end
  end

  # ── Audit accounting ──────────────────────────────────────────────────────

  describe "audit verdicts" do
    setup do
      System.put_env(@flag_env, "default-on")
      :ok
    end

    test "passing audit keeps the draft on disk", ctx do
      put_docs([doc("alpha", 100)])

      assert {:ok, result} = Pipeline.run(:agent, "agent-1", base_opts(ctx, []))

      assert [key] = result.generated
      assert result.skipped == []
      assert File.dir?(DraftStore.draft_dir(key, global: false, cwd: ctx.tmp))
    end

    test "blocking audit records :blocked_by_audit and deletes the draft", ctx do
      put_docs([doc("alpha", 100)])

      assert {:ok, result} =
               Pipeline.run(:agent, "agent-1", base_opts(ctx, audit_mod: BlockAudit))

      assert result.generated == []
      assert [{_key_hint, :blocked_by_audit}] = result.skipped
      assert result.total_candidates == 1

      {:ok, drafts} = DraftStore.list(global: false, cwd: ctx.tmp)
      assert drafts == []
    end
  end

  # ── Crash isolation and dedup ─────────────────────────────────────────────

  describe "resilience" do
    setup do
      System.put_env(@flag_env, "default-on")
      :ok
    end

    test "a store that exits yields an empty pass rather than crashing", ctx do
      assert {:ok, result} =
               Pipeline.run(:agent, "agent-1", base_opts(ctx, store_mod: ExitingStore))

      assert result.total_candidates == 0
      assert result.latest_doc_ms == nil
    end

    test "re-running over the same documents skips already-written drafts", ctx do
      put_docs([doc("alpha", 100)])

      assert {:ok, first} = Pipeline.run(:agent, "agent-1", base_opts(ctx, []))
      assert [_key] = first.generated

      assert {:ok, second} = Pipeline.run(:agent, "agent-1", base_opts(ctx, []))
      assert second.generated == []
      assert [{_key_hint, reason}] = second.skipped
      assert is_binary(reason)
      assert reason =~ "already exists"
    end
  end
end
