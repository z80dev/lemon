defmodule LemonControlPlane.Methods.SessionsMaintainTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Registry, SessionsMaintain}
  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.{AgentRuntime, Store}

  @cutoff 1_700_000_000_000
  @preview_table :session_maintenance_previews

  defmodule Runtime do
    def session_maintenance_plan(cutoff) do
      send(self(), {:maintenance_plan, cutoff})

      case Process.get({__MODULE__, :plan}) do
        :raise -> raise "/private/provider-secret"
        result -> result
      end
    end

    def session_maintenance_execute(plan) do
      send(self(), {:maintenance_execute, plan})
      Process.get({__MODULE__, :execution})
    end
  end

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    previous_provider = Application.fetch_env(:lemon_core, :agent_runtime_provider)
    previews = Store.list(@preview_table)

    on_exit(fn ->
      case previous_provider do
        :error -> Application.delete_env(:lemon_core, :agent_runtime_provider)
        {:ok, provider} -> Application.put_env(:lemon_core, :agent_runtime_provider, provider)
      end

      Enum.each(Store.list(@preview_table), fn {key, _} -> Store.delete(@preview_table, key) end)
      Enum.each(previews, fn {key, value} -> Store.put(@preview_table, key, value) end)
    end)

    :ok = AgentRuntime.register(Runtime)
    plan = plan()
    Process.put({Runtime, :plan}, {:ok, plan})

    Process.put(
      {Runtime, :execution},
      {:ok, %{archived_count: 1, swept_count: 1, verified: true}}
    )

    %{plan: plan}
  end

  test "maintenance is registered and requires admin even for previews" do
    assert Registry.lookup("sessions.maintain") == {:ok, SessionsMaintain}
    assert SessionsMaintain.scopes() == [:admin]

    for auth <- [
          %{role: :operator, scopes: [:read]},
          %{role: :operator, scopes: [:write]},
          %{role: :node, scopes: [:invoke, :event]}
        ] do
      assert {:error, _} =
               Registry.dispatch("sessions.maintain", %{"olderThanMs" => @cutoff}, %{auth: auth})

      refute_received {:maintenance_plan, _}
      refute_received {:maintenance_execute, _}
    end
  end

  test "schema requires an integer cutoff and validates optional types" do
    assert Schemas.validate("sessions.maintain", %{"olderThanMs" => @cutoff}) == :ok

    assert Schemas.validate("sessions.maintain", %{
             "olderThanMs" => @cutoff,
             "dryRun" => false,
             "confirmToken" => "exact-preview-token"
           }) == :ok

    for params <- [
          %{},
          %{"olderThanMs" => "1700000000000"},
          %{"olderThanMs" => @cutoff, "dryRun" => "false"},
          %{"olderThanMs" => @cutoff, "confirmToken" => 123}
        ] do
      assert {:error, _} = Schemas.validate("sessions.maintain", params)
      assert {:error, _} = Registry.dispatch("sessions.maintain", params, admin())
      refute_received {:maintenance_plan, _}
    end
  end

  test "handler rejects invalid values before invoking the lifecycle provider" do
    for params <- [
          nil,
          [],
          %{"olderThanMs" => 0},
          %{"olderThanMs" => -1},
          %{"olderThanMs" => 1.5},
          %{"olderThanMs" => @cutoff, "dryRun" => nil},
          %{"olderThanMs" => @cutoff, "dryRun" => "false"},
          %{"olderThanMs" => @cutoff, "confirmToken" => []}
        ] do
      assert {:error, {:invalid_params, _, _}} = SessionsMaintain.handle(params, %{})
      refute_received {:maintenance_plan, _}
      refute_received {:maintenance_execute, _}
    end
  end

  test "default preview delegates the exact cutoff and exposes only the safe wire report" do
    assert {:ok, report} = dispatch(%{"olderThanMs" => @cutoff})
    assert_receive {:maintenance_plan, @cutoff}
    refute_received {:maintenance_execute, _}
    assert report["dryRun"]
    assert report["olderThanMs"] == @cutoff
    assert is_binary(report["confirmationToken"]) and report["confirmationToken"] != ""
    assert report["archiveCount"] == 1
    assert report["orphanCount"] == 1
    assert report["archivedCount"] == 0
    assert report["sweptCount"] == 0
    assert is_boolean(report["verified"])
    assert length(report["candidates"]) == 2

    assert Enum.sort(Map.keys(report)) ==
             Enum.sort(
               ~w(dryRun olderThanMs confirmationToken archiveCount orphanCount archivedCount sweptCount candidates verified)
             )

    for candidate <- report["candidates"] do
      assert Enum.sort(Map.keys(candidate)) == ~w(bytes id kind)
      assert candidate["kind"] in ["archive", "orphan_artifact"]
      assert is_binary(candidate["id"])
      assert candidate["bytes"] in [17, 29]
    end

    refute Jason.encode!(report) =~ "/private/"
    refute Jason.encode!(report) =~ "provider-secret"
  end

  test "confirmation delegates the retained full plan and reports verified counts", %{plan: plan} do
    assert {:ok, preview} = dispatch(%{"olderThanMs" => @cutoff})
    assert_receive {:maintenance_plan, @cutoff}

    assert {:ok, result} = dispatch(confirm(preview))
    assert_receive {:maintenance_execute, ^plan}
    refute result["dryRun"]
    assert result["archivedCount"] == 1
    assert result["sweptCount"] == 1
    assert result["verified"]
    refute Jason.encode!(result) =~ "/private/"
  end

  test "missing and mismatched confirmations fail closed without executing" do
    assert {:error, {:conflict, _, %{"reason" => "confirmation_required"}}} =
             dispatch(%{"olderThanMs" => @cutoff, "dryRun" => false})

    assert {:ok, preview} = dispatch(%{"olderThanMs" => @cutoff})

    assert {:error, {:conflict, _, %{"reason" => "confirmation_mismatch"}}} =
             dispatch(Map.put(confirm(preview), "olderThanMs", @cutoff - 1))

    assert {:error, {:conflict, _, %{"reason" => "confirmation_mismatch"}}} =
             dispatch(Map.put(confirm(preview), "confirmToken", "not-the-preview-token"))

    refute_received {:maintenance_execute, _}
  end

  test "stale candidate revisions surface a stable conflict", %{plan: plan} do
    assert {:ok, preview} = dispatch(%{"olderThanMs" => @cutoff})
    Process.put({Runtime, :execution}, {:error, :confirmation_mismatch})

    assert {:error, {:conflict, message, %{"reason" => "confirmation_mismatch"}}} =
             dispatch(confirm(preview))

    assert message == "Maintenance candidates changed; run a new preview"
    assert_receive {:maintenance_execute, ^plan}
    refute_received {:maintenance_execute, _}
  end

  test "provider failures return unavailable without leaking arbitrary errors" do
    for result <- [
          {:error, :maintenance_unavailable},
          {:error, {:unsafe_path, "/private/provider-secret"}},
          :raise
        ] do
      Process.put({Runtime, :plan}, result)

      assert {:error, {:unavailable, message, details}} = dispatch(%{"olderThanMs" => @cutoff})
      assert message == "Session maintenance could not be completed safely"
      assert details == %{"reason" => "maintenance_unavailable"}
      refute_received {:maintenance_execute, _}
    end
  end

  test "partial execution returns safe report counts and never retries", %{plan: plan} do
    assert {:ok, preview} = dispatch(%{"olderThanMs" => @cutoff})

    Process.put(
      {Runtime, :execution},
      {:error, {:partial_failure, %{archived_count: 1, swept_count: 0, verified: false}}}
    )

    assert {:error, {:internal_error, _, %{"reason" => "partial_failure", "report" => report}}} =
             dispatch(confirm(preview))

    assert report["archivedCount"] == 1
    assert report["sweptCount"] == 0
    refute report["verified"]
    refute Jason.encode!(report) =~ "/private/"
    assert_receive {:maintenance_execute, ^plan}
    refute_received {:maintenance_execute, _}
  end

  defp dispatch(params), do: Registry.dispatch("sessions.maintain", params, admin())
  defp admin, do: %{auth: %{role: :operator, scopes: [:admin]}}

  defp confirm(preview) do
    %{
      "olderThanMs" => preview["olderThanMs"],
      "dryRun" => false,
      "confirmToken" => preview["confirmationToken"]
    }
  end

  defp plan do
    %{
      revision: "private-revision",
      path: "/private/provider-secret",
      candidates: [
        %{kind: :archive, id: "native-session", bytes: 17, path: "/private/journal"},
        %{kind: :orphan_artifact, id: "orphan-session", bytes: 29, path: "/private/artifacts"}
      ]
    }
  end
end
