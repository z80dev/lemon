defmodule LemonAutomation.CronContextTest do
  # async: false — reads and writes the shared LemonCore.Store cron tables.
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronContext, CronJob, CronRun, CronStore}

  setup do
    token = System.unique_integer([:positive, :monotonic])
    source_id = "cron_ctx_source_#{token}"
    target_id = "cron_ctx_target_#{token}"

    on_exit(fn ->
      CronStore.delete_job(source_id)
      CronStore.delete_job(target_id)

      for run <- CronStore.list_runs(source_id, limit: 200) do
        CronStore.delete_run(run.id)
      end

      for event <- CronStore.list_audit_events(job_id: target_id, limit: 200) do
        CronStore.delete_audit_event(event.id)
      end
    end)

    {:ok, token: token, source_id: source_id, target_id: target_id}
  end

  describe "augment_prompt/2" do
    test "returns the prompt unchanged when context_from is nil", %{target_id: target_id} do
      job = target_job(target_id, nil)
      assert CronContext.augment_prompt(job, "do the thing") == "do the thing"
    end

    test "prepends the chained context block", ctx do
      seed_source(ctx, "collected findings")
      job = target_job(ctx.target_id, ctx.source_id)

      augmented = CronContext.augment_prompt(job, "summarize the findings")

      assert String.starts_with?(augmented, "## Chained Context")
      assert augmented =~ "collected findings"
      assert String.ends_with?(augmented, "summarize the findings")
    end

    test "returns the original prompt when context resolution raises", %{target_id: target_id} do
      # A non-binary context_from makes CronStore.get_job/1 raise inside the block.
      job = %{target_job(target_id, "cron_missing") | context_from: :not_a_binary}

      assert CronContext.augment_prompt(job, "still runs") == "still runs"
    end

    test "non-binary prompts pass through untouched", %{target_id: target_id} do
      job = target_job(target_id, "cron_missing")
      assert CronContext.augment_prompt(job, nil) == nil
    end
  end

  describe "context_block/1" do
    test "renders source identity, run id, timestamp and output", ctx do
      run = seed_source(ctx, "line one\nline two")
      source = CronStore.get_job(ctx.source_id)
      block = CronContext.context_block(target_job(ctx.target_id, ctx.source_id))

      assert block =~ "## Chained Context (from job \"#{source.name}\" / #{ctx.source_id})"
      assert block =~ "- source_run: #{run.id}"

      {:ok, dt} = DateTime.from_unix(run.completed_at_ms, :millisecond)
      assert block =~ "- completed_at: #{DateTime.to_iso8601(dt)}"
      assert block =~ "line one\nline two"
    end

    test "truncates oversized output to valid UTF-8 within the byte bound", ctx do
      big = String.duplicate("é", 9_000)
      seed_source(ctx, big)

      block = CronContext.context_block(target_job(ctx.target_id, ctx.source_id))
      [_header, body] = String.split(block, "\n\n", parts: 2)

      assert byte_size(body) <= 8_000
      assert String.valid?(body)
      assert byte_size(body) > 7_900
    end

    test "missing source job renders an explicit note and audits", ctx do
      block = CronContext.context_block(target_job(ctx.target_id, ctx.source_id))

      assert block =~ "no longer exists"
      assert block =~ ctx.source_id

      assert "context_source_missing" in audit_actions(ctx.target_id)
    end

    test "source with no completed run renders an explicit note and audits", ctx do
      seed_source_job(ctx)

      CronStore.put_run(%CronRun{
        id: "run_ctx_failed_#{ctx.token}",
        job_id: ctx.source_id,
        status: :failed,
        started_at_ms: 1_000,
        completed_at_ms: 1_010,
        triggered_by: :schedule,
        error: "boom"
      })

      block = CronContext.context_block(target_job(ctx.target_id, ctx.source_id))

      assert block =~ "no completed run output"
      assert "context_source_missing" in audit_actions(ctx.target_id)
    end

    test "source whose completed run has blank output counts as no output", ctx do
      seed_source_job(ctx)

      CronStore.put_run(%CronRun{
        id: "run_ctx_blank_#{ctx.token}",
        job_id: ctx.source_id,
        status: :completed,
        started_at_ms: 1_000,
        completed_at_ms: 1_010,
        triggered_by: :schedule,
        output: "   \n  "
      })

      block = CronContext.context_block(target_job(ctx.target_id, ctx.source_id))
      assert block =~ "no completed run output"
    end

    test "notes a newer failed run while still using the older completed output", ctx do
      seed_source(ctx, "older but good")

      CronStore.put_run(%CronRun{
        id: "run_ctx_newer_#{ctx.token}",
        job_id: ctx.source_id,
        status: :timeout,
        started_at_ms: 5_000,
        completed_at_ms: 5_010,
        triggered_by: :schedule,
        error: "Run exceeded timeout"
      })

      block = CronContext.context_block(target_job(ctx.target_id, ctx.source_id))

      assert block =~ "older but good"

      assert block =~
               "- note: most recent run run_ctx_newer_#{ctx.token} ended with status timeout"

      assert block =~ "Run exceeded timeout"
    end

    test "omits the note when the completed run is also the newest", ctx do
      seed_source(ctx, "fresh")
      block = CronContext.context_block(target_job(ctx.target_id, ctx.source_id))
      refute block =~ "- note:"
    end
  end

  defp target_job(id, context_from) do
    %CronJob{
      id: id,
      name: "Target Job",
      schedule: "* * * * *",
      agent_id: "agent_ctx",
      session_key: "agent:agent_ctx:main",
      prompt: "summarize",
      context_from: context_from
    }
  end

  defp seed_source_job(ctx) do
    job = %CronJob{
      id: ctx.source_id,
      name: "Source Job #{ctx.token}",
      schedule: "* * * * *",
      agent_id: "agent_ctx",
      session_key: "agent:agent_ctx:main",
      prompt: "collect",
      created_at_ms: 1_000
    }

    :ok = CronStore.put_job(job)
    job
  end

  defp seed_source(ctx, output) do
    seed_source_job(ctx)

    run = %CronRun{
      id: "run_ctx_ok_#{ctx.token}",
      job_id: ctx.source_id,
      run_id: "router_ctx_#{ctx.token}",
      status: :completed,
      started_at_ms: 1_000,
      completed_at_ms: 1_700_000_000_000,
      duration_ms: 10,
      triggered_by: :schedule,
      output: output
    }

    :ok = CronStore.put_run(run)
    run
  end

  defp audit_actions(job_id) do
    CronStore.list_audit_events(job_id: job_id, limit: 100)
    |> Enum.map(& &1.action)
  end
end
