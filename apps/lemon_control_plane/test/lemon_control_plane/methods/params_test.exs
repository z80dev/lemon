defmodule LemonControlPlane.Methods.ParamsTest do
  use ExUnit.Case, async: true

  @operator_ctx %{auth: %{role: :operator, scopes: [:read, :content]}}

  alias LemonControlPlane.Methods.{Params, TasksActiveList, TasksRecentList}

  test "exact parameter keys take precedence even for false and nil" do
    assert Params.get_param(
             %{"includeEvents" => false, "include_events" => true},
             "includeEvents"
           ) == false

    assert Params.get_param(%{"runId" => nil, "run_id" => "fallback"}, "runId") == nil
    assert Params.get_param(%{"run_id" => "run"}, "runId") == "run"
    assert Params.get_param(nil, "runId") == nil
  end

  test "map access preserves false values and supports defaults" do
    assert Params.get_map(%{"enabled" => true, enabled: false}, :enabled) == false
    assert Params.get_map(%{"status" => "running"}, :status) == "running"
    assert Params.get_map(nil, :status, :missing) == :missing
    assert Params.get_map(%{status: nil}, :status, :missing) == nil
  end

  test "limit and timestamp conversion retain existing wire semantics" do
    assert Params.normalize_limit("20rest", 100, 10) == 10
    assert Params.normalize_limit(0, 100, 200) == 100
    assert Params.to_ms(1_700_000_000) == 1_700_000_000_000
    assert Params.to_ms(1_700_000_000_000) == 1_700_000_000_000
    assert Params.truthy?("FALSE", true) == false
    assert Params.truthy?("unknown", true) == true
  end

  test "task listing preserves the active and recent response differences" do
    params = %{"status" => "completed", "include_events" => "true", "event_limit" => "12"}
    assert {:ok, active} = TasksActiveList.handle(params, @operator_ctx)
    assert {:ok, recent} = TasksRecentList.handle(params, @operator_ctx)
    refute Map.has_key?(active["filters"], "status")
    refute Map.has_key?(active["summary"], "averageDurationMs")
    assert recent["filters"]["status"] == "completed"
    assert Map.has_key?(recent["summary"], "averageDurationMs")
    assert active["filters"]["includeEvents"] == true
    assert recent["filters"]["eventLimit"] == 12
  end
end
