defmodule LemonControlPlane.SessionMaintenanceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonControlPlane.SessionLifecycle

  @table :session_maintenance_previews
  @index_table :session_maintenance_preview_index
  @index_key :retained
  @cutoff 1_700_000_000_000

  defmodule Provider do
    def session_maintenance_plan(_cutoff), do: {:ok, Process.get(:maintenance_plan)}

    def session_maintenance_execute(plan) do
      send(self(), {:executed, plan})

      Process.get(:maintenance_execute, fn _ ->
        {:ok, %{archived_count: 1, swept_count: 0, verified: true}}
      end).(plan)
    end
  end

  setup do
    provider = Application.fetch_env(:lemon_core, :agent_runtime_provider)
    {:ok, retained} = Store.fetch_all(@table)
    Enum.each(retained, fn {key, _} -> :ok = Store.delete(@table, key) end)
    {:ok, saved_index} = Store.fetch(@index_table, @index_key)
    :ok = Store.delete(@index_table, @index_key)
    :ok = Application.put_env(:lemon_core, :agent_runtime_provider, Provider)

    Process.put(:maintenance_plan, %{
      candidates: [%{kind: :archive, id: "/private/journal", bytes: 12}],
      revision: "private revision"
    })

    on_exit(fn ->
      {:ok, current} = Store.fetch_all(@table)
      Enum.each(current, fn {key, _} -> :ok = Store.delete(@table, key) end)
      Enum.each(retained, fn {key, value} -> :ok = Store.put(@table, key, value) end)
      :ok = Store.delete(@index_table, @index_key)
      if saved_index, do: Store.put(@index_table, @index_key, saved_index)

      case provider do
        {:ok, value} -> Application.put_env(:lemon_core, :agent_runtime_provider, value)
        :error -> Application.delete_env(:lemon_core, :agent_runtime_provider)
      end
    end)

    :ok
  end

  test "preview retains a private plan without executing or leaking identifiers" do
    assert {:ok, report} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    assert report.dry_run and not report.verified
    assert report.archive_count == 1
    assert report.orphan_count == 0
    assert report.archived_count == 0
    assert report.swept_count == 0
    assert [%{kind: :archive, id: id, bytes: 12}] = report.candidates
    assert id =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(report) =~ "private"
    refute_received {:executed, _}
    assert {:ok, [{_, %{plan: plan}}]} = Store.fetch_all(@table)
    assert plan == Process.get(:maintenance_plan)
  end

  test "requires an issued token and its exact cutoff, then consumes it once" do
    assert {:error, :confirmation_required} =
             SessionLifecycle.maintenance(older_than_ms: @cutoff, dry_run: false)

    assert {:error, :confirmation_mismatch} = execute("invented")
    assert {:ok, report} = SessionLifecycle.maintenance(older_than_ms: @cutoff)

    assert {:error, :confirmation_mismatch} =
             SessionLifecycle.maintenance(
               older_than_ms: @cutoff + 1,
               dry_run: false,
               confirm_token: report.confirmation_token
             )

    assert {:error, :confirmation_mismatch} = execute(report.confirmation_token)
    assert {:ok, report} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    assert {:ok, executed} = execute(report.confirmation_token)
    assert executed.verified and not executed.dry_run
    assert executed.archived_count == 1
    assert_received {:executed, _}
    assert {:error, :confirmation_mismatch} = execute(report.confirmation_token)
    refute_received {:executed, _}
  end

  test "invalid cutoffs and missing runtime fail closed" do
    for cutoff <- [nil, 0, -1, "yesterday", 1.5] do
      assert {:error, :invalid_older_than_ms} =
               SessionLifecycle.maintenance(older_than_ms: cutoff)
    end

    Application.delete_env(:lemon_core, :agent_runtime_provider)

    assert {:error, :maintenance_unavailable} =
             SessionLifecycle.maintenance(older_than_ms: @cutoff)
  end

  test "a failed mutation never replays and never leaks the exception" do
    Process.put(:maintenance_execute, fn _ -> raise "private mutation failure" end)
    assert {:ok, preview} = SessionLifecycle.maintenance(older_than_ms: @cutoff)

    log =
      capture_log(fn ->
        assert {:error, :outcome_unknown} = execute(preview.confirmation_token)
      end)

    assert log =~ "SessionMaintenance execute callback failed"
    refute log =~ "private mutation failure"
    assert_received {:executed, _}
    assert {:error, :confirmation_mismatch} = execute(preview.confirmation_token)
    refute_received {:executed, _}
  end

  test "expired previews and changed store owners are invalidated" do
    for patch <- [%{expires_at_ms: 0}, %{store_owner: self()}] do
      assert {:ok, report} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
      {:ok, [{key, value}]} = Store.fetch_all(@table)
      :ok = Store.put(@table, key, Map.merge(value, patch))
      assert {:error, :confirmation_mismatch} = execute(report.confirmation_token)
      refute_received {:executed, _}
    end
  end

  test "retention and display are bounded without truncating the bound plan" do
    candidates = for i <- 1..101, do: %{kind: :orphan_artifact, id: "id-#{i}", bytes: i}
    Process.put(:maintenance_plan, %{candidates: candidates})
    assert {:ok, first} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    assert first.orphan_count == 101
    assert length(first.candidates) == 100

    for _ <- 1..32 do
      assert {:ok, _} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    end

    assert {:ok, retained} = Store.fetch_all(@table)
    assert length(retained) == 32
    assert {:ok, index} = Store.fetch(@index_table, @index_key)
    assert map_size(index) == 32
    assert Enum.sort(Map.keys(index)) == retained |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert Enum.all?(index, fn {_, metadata} -> not Map.has_key?(metadata, :plan) end)
    assert Enum.all?(retained, fn {_, entry} -> length(entry.plan.candidates) == 101 end)
    assert {:error, :confirmation_mismatch} = execute(first.confirmation_token)
  end

  test "indexed retention leaves unindexed rows unread and they cannot authorize execution" do
    assert {:ok, issued} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    assert {:ok, entry} = Store.fetch(@table, issued.confirmation_token)
    :ok = Store.put(@table, "unindexed", entry)

    assert {:ok, _} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    assert {:error, :confirmation_mismatch} = execute("unindexed")
    assert {:ok, ^entry} = Store.fetch(@table, "unindexed")
    refute_received {:executed, _}
  end

  test "caller death after dispatch cannot replay an already claimed preview" do
    assert {:ok, preview} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:maintenance_execute, fn _ ->
          send(parent, :mutation_entered)

          receive do
            :never -> :ok
          end
        end)

        execute(preview.confirmation_token)
      end)

    on_exit(fn ->
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end)

    assert_receive :mutation_entered, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:error, :confirmation_mismatch} = execute(preview.confirmation_token)
    refute_received {:executed, _}
  end

  test "concurrent confirmations admit exactly one mutation" do
    assert {:ok, preview} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :execute -> execute(preview.confirmation_token)
          end
        end)
      end

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, :execute))
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, %{verified: true}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :confirmation_mismatch})) == 1
  end

  test "changing providers invalidates an issued preview" do
    assert {:ok, preview} = SessionLifecycle.maintenance(older_than_ms: @cutoff)
    Application.delete_env(:lemon_core, :agent_runtime_provider)
    assert {:error, :confirmation_mismatch} = execute(preview.confirmation_token)
    refute_received {:executed, _}
  end

  defp execute(token) do
    SessionLifecycle.maintenance(
      older_than_ms: @cutoff,
      dry_run: false,
      confirm_token: token
    )
  end
end
