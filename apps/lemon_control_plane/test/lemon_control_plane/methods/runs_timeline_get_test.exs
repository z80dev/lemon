defmodule LemonControlPlane.Methods.RunsTimelineGetTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Registry, RunsTimelineGet}
  alias LemonCore.{IntrospectionStore, Store, UsageLedger, UsageStore}
  alias LemonCore.Store.EtsBackend

  defmodule Tasks do
    def list_tasks, do: Process.get(:timeline_tasks, [])
  end

  defmodule FailingBackend do
    @behaviour LemonCore.Store.Backend
    defdelegate init(opts), to: EtsBackend
    defdelegate put(state, table, key, value), to: EtsBackend
    defdelegate put_new(state, table, key, value), to: EtsBackend
    defdelegate get(state, table, key), to: EtsBackend
    defdelegate delete(state, table, key), to: EtsBackend
    def list(_state, :introspection_log), do: {:error, :backend_failure}
    def list(state, table), do: EtsBackend.list(state, table)
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    original = :sys.get_state(Store)
    provider = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, Tasks)

    :sys.replace_state(Store, fn state ->
      {:ok, backend_state} = EtsBackend.init([])
      %{state | backend: EtsBackend, backend_state: backend_state}
    end)

    on_exit(fn ->
      :sys.replace_state(Store, fn current ->
        Enum.each(current.backend_state, fn {_key, table} -> :ets.delete(table) end)
        original
      end)

      if provider,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, provider),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    %{run_id: "timeline-#{LemonCore.Id.uuid()}", at_ms: System.system_time(:millisecond)}
  end

  test "registered with read scope" do
    if is_nil(Process.whereis(Registry)), do: start_supervised!(Registry)
    assert RunsTimelineGet.name() == "runs.timeline.get"
    assert RunsTimelineGet.scopes() == [:read]
    assert Registry.lookup("runs.timeline.get") == {:ok, RunsTimelineGet}
  end

  test "orders lifecycle and paired tool spans without exposing payload contents", ctx do
    event(ctx, :run_completed, 90, %{ok: true, duration_ms: 90})

    event(ctx, :tool_call_completed, 60, %{
      tool_call_id: "b",
      ok: false,
      duration_ms: 25,
      result: "private"
    })

    event(ctx, :tool_call_dispatched, 35, %{
      tool_call_id: "b",
      tool_name: "bash",
      arguments: "private"
    })

    event(ctx, :tool_call_completed, 50, %{tool_call_id: "a", ok: true, duration_ms: 30})
    event(ctx, :tool_call_dispatched, 20, %{tool_call_id: "a", tool_name: "read"})
    event(ctx, :run_started, 0)
    event(ctx, :agent_loop_started, 5)
    event(ctx, :agent_turn_observed, 10)
    event(ctx, :agent_loop_ended, 70)
    event(ctx, :answer_finalize_started, 75)
    event(ctx, :answer_finalize_completed, 80)
    event(ctx, :unrelated_event, 82, %{prompt: "private"})

    assert {:ok, result} = timeline(ctx)
    entries = result["entries"]

    assert Enum.map(entries, & &1["atMs"]) ==
             Enum.map([0, 5, 10, 20, 35, 70, 75, 80, 90], &(ctx.at_ms + &1))

    assert Enum.filter(entries, &(&1["kind"] == "tool_call")) == [
             %{
               "atMs" => ctx.at_ms + 20,
               "kind" => "tool_call",
               "label" => "read",
               "durationMs" => 30,
               "ok" => true,
               "status" => "completed"
             },
             %{
               "atMs" => ctx.at_ms + 35,
               "kind" => "tool_call",
               "label" => "bash",
               "durationMs" => 25,
               "ok" => false,
               "status" => "error"
             }
           ]

    refute inspect(result) =~ "private"
    refute result["truncated"]
  end

  test "unmatched dispatch remains pending and completion without dispatch is retained", ctx do
    event(ctx, :tool_call_dispatched, 0, %{tool_call_id: "pending", tool_name: "bash"})

    event(ctx, :tool_call_completed, 5, %{
      tool_call_id: "orphan",
      tool_name: "read",
      ok: true,
      duration_ms: 2
    })

    assert {:ok, %{"entries" => [pending, completed]}} = timeline(ctx)
    assert pending["status"] == "pending"
    assert pending["ok"] == nil
    assert pending["durationMs"] == nil
    assert completed["status"] == "completed"
    assert completed["label"] == "read"
  end

  test "includes active and terminal children only for the exact parent", ctx do
    event(ctx, :run_started, 0)

    Process.put(:timeline_tasks, [
      {"child-ok",
       %{
         parent_run_id: ctx.run_id,
         status: :completed,
         started_at: DateTime.from_unix!(ctx.at_ms + 5, :millisecond),
         completed_at: ctx.at_ms + 15,
         description: "private"
       }},
      {"child-active",
       %{"parent_run_id" => ctx.run_id, "status" => "running", "inserted_at" => ctx.at_ms + 6}},
      {"foreign", %{parent_run_id: "another-run", status: :completed}}
    ])

    assert {:ok, %{"entries" => [_, child, active]}} = timeline(ctx)
    assert child["kind"] == "subagent"
    assert child["label"] == "subagent child-ok"
    assert child["durationMs"] == 10
    assert child["ok"] == true
    assert active["status"] == "active"
    assert active["ok"] == nil
    refute inspect(child) =~ "private"
  end

  test "caps the latest entries at 500 in chronological order", ctx do
    for offset <- 0..500, do: event(ctx, :agent_turn_observed, offset)
    assert {:ok, result} = timeline(ctx)
    assert result["truncated"]
    assert length(result["entries"]) == 500
    assert hd(result["entries"])["atMs"] == ctx.at_ms + 1
    assert List.last(result["entries"])["atMs"] == ctx.at_ms + 500
  end

  test "exactly 500 entries are not truncated", ctx do
    for offset <- 0..499, do: event(ctx, :agent_turn_observed, offset)
    assert {:ok, %{"truncated" => false, "entries" => entries}} = timeline(ctx)
    assert length(entries) == 500
  end

  test "classifies aborted and crashed terminals", ctx do
    event(ctx, :run_completed, 1, %{ok: false, error: "user_requested"})
    event(ctx, :run_failed, 2)
    assert {:ok, %{"entries" => [aborted, crashed]}} = timeline(ctx)
    assert aborted["status"] == "aborted"
    assert crashed["status"] == "crashed"
    assert crashed["ok"] == false
  end

  test "unknown run is not found, not a successful empty timeline", ctx do
    assert {:error, {:not_found, "Run not found", nil}} = timeline(ctx)
  end

  test "validates run id before storage access" do
    for params <- [
          nil,
          %{},
          %{"runId" => " "},
          %{"runId" => 1},
          %{"runId" => String.duplicate("x", 257)}
        ] do
      assert {:error, {:invalid_request, _, nil}} = RunsTimelineGet.handle(params, %{})
    end
  end

  @tag capture_log: true
  test "storage failure is unavailable, never empty history", ctx do
    :sys.replace_state(Store, &%{&1 | backend: FailingBackend})
    assert {:error, {:internal_error, "Run timeline is unavailable", nil}} = timeline(ctx)
  end

  test "task lookup failure is unavailable rather than silently omitting children", ctx do
    event(ctx, :run_started, 0)
    Process.put(:timeline_tasks, {:error, :storage_down})
    assert {:error, {:internal_error, "Run timeline is unavailable", nil}} = timeline(ctx)
  end

  test "joins run usage through the shared bounded history helper", ctx do
    event(ctx, :run_started, 0)
    event(ctx, :run_completed, 100, %{ok: true})

    summary = %{
      completed: %{
        usage: %{
          occurrences: [
            %{
              at_ms: ctx.at_ms + 50,
              provider: "local",
              model: "fixture",
              usage: %{input: 3, output: 2, cost: 0.0, price_known: true}
            }
          ]
        }
      }
    }

    for entry <- UsageLedger.entries(ctx.run_id, "timeline-session", summary) do
      assert :ok = UsageStore.put_occurrence(UsageLedger.occurrence_record(entry))
    end

    assert {:ok, %{"usage" => usage}} = timeline(ctx)
    assert usage["tokens"] == %{"input" => 3, "output" => 2, "total" => 5}
    assert usage["costUsd"] == 0.0
    assert usage["model"] == "fixture"
  end

  test "usage derives a missing start from the terminal duration like recent history", ctx do
    event(ctx, :run_completed, 100, %{ok: true, duration_ms: 100})

    summary = %{
      completed: %{
        usage: %{
          occurrences: [
            %{
              at_ms: ctx.at_ms + 50,
              provider: "local",
              model: "fixture",
              usage: %{input: 2, output: 1, cost: 0.0}
            }
          ]
        }
      }
    }

    for entry <- UsageLedger.entries(ctx.run_id, "timeline-session", summary) do
      assert :ok = UsageStore.put_occurrence(UsageLedger.occurrence_record(entry))
    end

    assert {:ok, %{"usage" => %{"tokens" => %{"total" => 3}}}} = timeline(ctx)
  end

  test "source-window exhaustion reports truncation even with few projected entries", ctx do
    event(ctx, :run_started, 0)
    for offset <- 1..1000, do: event(ctx, :unrelated_event, offset)
    assert {:ok, %{"entries" => [], "truncated" => true}} = timeline(ctx)
  end

  defp timeline(ctx), do: RunsTimelineGet.handle(%{"runId" => ctx.run_id}, %{})

  defp event(ctx, kind, offset, payload \\ %{}) do
    assert :ok =
             IntrospectionStore.append(%{
               event_id: LemonCore.Id.uuid(),
               event_type: kind,
               ts_ms: ctx.at_ms + offset,
               run_id: ctx.run_id,
               provenance: :direct,
               payload: payload
             })
  end
end
