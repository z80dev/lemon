defmodule LemonControlPlane.Methods.MonitoringMethodsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the 5 new control-plane monitoring method implementations:
  - RunsActiveList
  - RunsRecentList
  - TasksActiveList
  - TasksRecentList
  - RunGraphGet
  """

  describe "RunsActiveList" do
    alias LemonControlPlane.Methods.RunsActiveList

    test "name/0 returns correct method name" do
      assert RunsActiveList.name() == "runs.active.list"
    end

    test "scopes/0 returns read scope" do
      assert RunsActiveList.scopes() == [:read]
    end

    test "handle/2 with nil params returns valid runs list" do
      {:ok, result} = RunsActiveList.handle(nil, %{})
      assert is_list(result["runs"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 with empty params returns valid runs list" do
      {:ok, result} = RunsActiveList.handle(%{}, %{})
      assert is_list(result["runs"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 total matches runs count" do
      {:ok, result} = RunsActiveList.handle(%{}, %{})
      assert result["total"] == length(result["runs"])
    end

    test "handle/2 with agentId filter records filter in response" do
      {:ok, result} = RunsActiveList.handle(%{"agentId" => "test-agent"}, %{})
      assert result["filters"]["agentId"] == "test-agent"
    end

    test "handle/2 with sessionKey filter records filter in response" do
      {:ok, result} = RunsActiveList.handle(%{"sessionKey" => "sk:test"}, %{})
      assert result["filters"]["sessionKey"] == "sk:test"
    end

    test "handle/2 with valid limit records limit in filters" do
      {:ok, result} = RunsActiveList.handle(%{"limit" => 10}, %{})
      assert result["filters"]["limit"] == 10
    end

    test "handle/2 with limit as string parses it" do
      {:ok, result} = RunsActiveList.handle(%{"limit" => "25"}, %{})
      assert result["filters"]["limit"] == 25
    end

    test "handle/2 clamps limit to max 200" do
      {:ok, result} = RunsActiveList.handle(%{"limit" => 9999}, %{})
      assert result["filters"]["limit"] <= 200
    end

    test "handle/2 with negative limit uses default" do
      {:ok, result} = RunsActiveList.handle(%{"limit" => -5}, %{})
      assert is_integer(result["filters"]["limit"])
      assert result["filters"]["limit"] > 0
    end

    test "handle/2 response always contains runs, total, and filters keys" do
      {:ok, result} = RunsActiveList.handle(%{}, %{})
      assert Map.has_key?(result, "runs")
      assert Map.has_key?(result, "total")
      assert Map.has_key?(result, "filters")
    end

    test "handle/2 with combined filters returns valid response" do
      {:ok, result} =
        RunsActiveList.handle(
          %{"agentId" => "my-agent", "sessionKey" => "sk:abc", "limit" => 5},
          %{}
        )

      assert is_list(result["runs"])
      assert result["filters"]["agentId"] == "my-agent"
      assert result["filters"]["sessionKey"] == "sk:abc"
      assert result["filters"]["limit"] == 5
    end
  end

  describe "RunsRecentList" do
    alias LemonControlPlane.Methods.RunsRecentList

    test "name/0 returns correct method name" do
      assert RunsRecentList.name() == "runs.recent.list"
    end

    test "scopes/0 returns read scope" do
      assert RunsRecentList.scopes() == [:read]
    end

    test "handle/2 with nil params returns valid runs list" do
      {:ok, result} = RunsRecentList.handle(nil, %{})
      assert is_list(result["runs"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 with empty params returns valid runs list" do
      {:ok, result} = RunsRecentList.handle(%{}, %{})
      assert is_list(result["runs"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 total matches runs count" do
      {:ok, result} = RunsRecentList.handle(%{}, %{})
      assert result["total"] == length(result["runs"])
    end

    test "handle/2 with agentId filter records filter in response" do
      {:ok, result} = RunsRecentList.handle(%{"agentId" => "test-agent"}, %{})
      assert result["filters"]["agentId"] == "test-agent"
    end

    test "handle/2 with sessionKey filter records filter in response" do
      {:ok, result} = RunsRecentList.handle(%{"sessionKey" => "sk:test"}, %{})
      assert result["filters"]["sessionKey"] == "sk:test"
    end

    test "handle/2 with status filter records filter in response" do
      {:ok, result} = RunsRecentList.handle(%{"status" => "completed"}, %{})
      assert result["filters"]["status"] == "completed"
    end

    test "handle/2 with valid limit records limit in filters" do
      {:ok, result} = RunsRecentList.handle(%{"limit" => 20}, %{})
      assert result["filters"]["limit"] == 20
    end

    test "handle/2 with limit as string parses it" do
      {:ok, result} = RunsRecentList.handle(%{"limit" => "30"}, %{})
      assert result["filters"]["limit"] == 30
    end

    test "handle/2 clamps limit to max 200" do
      {:ok, result} = RunsRecentList.handle(%{"limit" => 9999}, %{})
      assert result["filters"]["limit"] <= 200
    end

    test "handle/2 with negative limit uses default" do
      {:ok, result} = RunsRecentList.handle(%{"limit" => -1}, %{})
      assert is_integer(result["filters"]["limit"])
      assert result["filters"]["limit"] > 0
    end

    test "handle/2 response always contains runs, total, and filters keys" do
      {:ok, result} = RunsRecentList.handle(%{}, %{})
      assert Map.has_key?(result, "runs")
      assert Map.has_key?(result, "total")
      assert Map.has_key?(result, "filters")
    end

    test "handle/2 filters always contains status key" do
      {:ok, result} = RunsRecentList.handle(%{}, %{})
      assert Map.has_key?(result["filters"], "status")
    end

    test "handle/2 with error status filter returns valid response" do
      {:ok, result} = RunsRecentList.handle(%{"status" => "error"}, %{})
      assert is_list(result["runs"])
      assert result["filters"]["status"] == "error"
    end

    test "handle/2 with aborted status filter returns valid response" do
      {:ok, result} = RunsRecentList.handle(%{"status" => "aborted"}, %{})
      assert is_list(result["runs"])
      assert result["filters"]["status"] == "aborted"
    end
  end

  describe "TasksActiveList" do
    alias LemonControlPlane.Methods.TasksActiveList

    test "name/0 returns correct method name" do
      assert TasksActiveList.name() == "tasks.active.list"
    end

    test "scopes/0 returns read scope" do
      assert TasksActiveList.scopes() == [:read]
    end

    test "handle/2 with nil params returns valid tasks list" do
      {:ok, result} = TasksActiveList.handle(nil, %{})
      assert is_list(result["tasks"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 with empty params returns valid tasks list" do
      {:ok, result} = TasksActiveList.handle(%{}, %{})
      assert is_list(result["tasks"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 total matches tasks count" do
      {:ok, result} = TasksActiveList.handle(%{}, %{})
      assert result["total"] == length(result["tasks"])
    end

    test "handle/2 with runId filter records filter in response" do
      {:ok, result} = TasksActiveList.handle(%{"runId" => "run-abc"}, %{})
      assert result["filters"]["runId"] == "run-abc"
    end

    test "handle/2 with agentId filter records filter in response" do
      {:ok, result} = TasksActiveList.handle(%{"agentId" => "test-agent"}, %{})
      assert result["filters"]["agentId"] == "test-agent"
    end

    test "handle/2 with valid limit records limit in filters" do
      {:ok, result} = TasksActiveList.handle(%{"limit" => 10}, %{})
      assert result["filters"]["limit"] == 10
    end

    test "handle/2 with limit as string parses it" do
      {:ok, result} = TasksActiveList.handle(%{"limit" => "15"}, %{})
      assert result["filters"]["limit"] == 15
    end

    test "handle/2 clamps limit to max 200" do
      {:ok, result} = TasksActiveList.handle(%{"limit" => 9999}, %{})
      assert result["filters"]["limit"] <= 200
    end

    test "handle/2 with negative limit uses default" do
      {:ok, result} = TasksActiveList.handle(%{"limit" => -3}, %{})
      assert is_integer(result["filters"]["limit"])
      assert result["filters"]["limit"] > 0
    end

    test "handle/2 response always contains tasks, total, and filters keys" do
      {:ok, result} = TasksActiveList.handle(%{}, %{})
      assert Map.has_key?(result, "tasks")
      assert Map.has_key?(result, "total")
      assert Map.has_key?(result, "filters")
    end

    test "handle/2 filters contains runId and agentId keys" do
      {:ok, result} = TasksActiveList.handle(%{}, %{})
      assert Map.has_key?(result["filters"], "runId")
      assert Map.has_key?(result["filters"], "agentId")
    end

    test "handle/2 with combined filters returns valid response" do
      {:ok, result} =
        TasksActiveList.handle(%{"runId" => "run-1", "agentId" => "agent-1", "limit" => 5}, %{})

      assert is_list(result["tasks"])
      assert result["filters"]["runId"] == "run-1"
      assert result["filters"]["agentId"] == "agent-1"
    end
  end

  describe "TasksRecentList" do
    alias LemonControlPlane.Methods.TasksRecentList

    test "name/0 returns correct method name" do
      assert TasksRecentList.name() == "tasks.recent.list"
    end

    test "scopes/0 returns read scope" do
      assert TasksRecentList.scopes() == [:read]
    end

    test "handle/2 with nil params returns valid tasks list" do
      {:ok, result} = TasksRecentList.handle(nil, %{})
      assert is_list(result["tasks"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 with empty params returns valid tasks list" do
      {:ok, result} = TasksRecentList.handle(%{}, %{})
      assert is_list(result["tasks"])
      assert is_integer(result["total"])
      assert is_map(result["filters"])
    end

    test "handle/2 total matches tasks count" do
      {:ok, result} = TasksRecentList.handle(%{}, %{})
      assert result["total"] == length(result["tasks"])
    end

    test "handle/2 with runId filter records filter in response" do
      {:ok, result} = TasksRecentList.handle(%{"runId" => "run-xyz"}, %{})
      assert result["filters"]["runId"] == "run-xyz"
    end

    test "handle/2 with agentId filter records filter in response" do
      {:ok, result} = TasksRecentList.handle(%{"agentId" => "my-agent"}, %{})
      assert result["filters"]["agentId"] == "my-agent"
    end

    test "handle/2 with status filter records filter in response" do
      {:ok, result} = TasksRecentList.handle(%{"status" => "completed"}, %{})
      assert result["filters"]["status"] == "completed"
    end

    test "handle/2 with valid limit records limit in filters" do
      {:ok, result} = TasksRecentList.handle(%{"limit" => 25}, %{})
      assert result["filters"]["limit"] == 25
    end

    test "handle/2 with limit as string parses it" do
      {:ok, result} = TasksRecentList.handle(%{"limit" => "40"}, %{})
      assert result["filters"]["limit"] == 40
    end

    test "handle/2 clamps limit to max 200" do
      {:ok, result} = TasksRecentList.handle(%{"limit" => 5000}, %{})
      assert result["filters"]["limit"] <= 200
    end

    test "handle/2 with negative limit uses default" do
      {:ok, result} = TasksRecentList.handle(%{"limit" => -10}, %{})
      assert is_integer(result["filters"]["limit"])
      assert result["filters"]["limit"] > 0
    end

    test "handle/2 response always contains tasks, total, and filters keys" do
      {:ok, result} = TasksRecentList.handle(%{}, %{})
      assert Map.has_key?(result, "tasks")
      assert Map.has_key?(result, "total")
      assert Map.has_key?(result, "filters")
    end

    test "handle/2 filters always contains status key" do
      {:ok, result} = TasksRecentList.handle(%{}, %{})
      assert Map.has_key?(result["filters"], "status")
    end

    test "handle/2 with timeout status filter returns valid response" do
      {:ok, result} = TasksRecentList.handle(%{"status" => "timeout"}, %{})
      assert is_list(result["tasks"])
      assert result["filters"]["status"] == "timeout"
    end

    test "handle/2 with aborted status filter returns valid response" do
      {:ok, result} = TasksRecentList.handle(%{"status" => "aborted"}, %{})
      assert is_list(result["tasks"])
      assert result["filters"]["status"] == "aborted"
    end

    test "handle/2 with error status filter returns valid response" do
      {:ok, result} = TasksRecentList.handle(%{"status" => "error"}, %{})
      assert is_list(result["tasks"])
      assert result["filters"]["status"] == "error"
    end
  end

  describe "RunGraphGet" do
    alias LemonControlPlane.Methods.RunGraphGet

    test "name/0 returns correct method name" do
      assert RunGraphGet.name() == "run.graph.get"
    end

    test "scopes/0 returns read scope" do
      assert RunGraphGet.scopes() == [:read]
    end

    test "handle/2 with nil params returns error for missing runId" do
      {:error, error} = RunGraphGet.handle(nil, %{})
      assert match?({:invalid_request, _, _}, error) or match?({:invalid_request, _}, error)
    end

    test "handle/2 with empty params returns error for missing runId" do
      {:error, error} = RunGraphGet.handle(%{}, %{})
      assert match?({:invalid_request, _, _}, error) or match?({:invalid_request, _}, error)
    end

    test "handle/2 with valid runId returns graph structure" do
      {:ok, result} = RunGraphGet.handle(%{"runId" => "run-test-123"}, %{})
      assert result["runId"] == "run-test-123"
      assert is_map(result["graph"])
      assert is_integer(result["nodeCount"])
      assert result["nodeCount"] >= 1
    end

    test "handle/2 graph contains runId, status, and children" do
      {:ok, result} = RunGraphGet.handle(%{"runId" => "run-abc"}, %{})
      graph = result["graph"]
      assert Map.has_key?(graph, "runId")
      assert Map.has_key?(graph, "status")
      assert Map.has_key?(graph, "children")
    end

    test "handle/2 graph children is a list" do
      {:ok, result} = RunGraphGet.handle(%{"runId" => "run-abc"}, %{})
      assert is_list(result["graph"]["children"])
    end

    test "handle/2 graph runId matches requested runId" do
      {:ok, result} = RunGraphGet.handle(%{"runId" => "run-xyz-456"}, %{})
      assert result["graph"]["runId"] == "run-xyz-456"
    end

    test "handle/2 nodeCount is at least 1 for any valid runId" do
      {:ok, result} = RunGraphGet.handle(%{"runId" => "run-some-id"}, %{})
      assert result["nodeCount"] >= 1
    end

    test "handle/2 response always contains runId, graph, and nodeCount keys" do
      {:ok, result} = RunGraphGet.handle(%{"runId" => "run-check"}, %{})
      assert Map.has_key?(result, "runId")
      assert Map.has_key?(result, "graph")
      assert Map.has_key?(result, "nodeCount")
    end

    test "handle/2 with empty string runId returns error" do
      {:error, _} = RunGraphGet.handle(%{"runId" => ""}, %{})
    end

    test "handle/2 graph status is a string" do
      {:ok, result} = RunGraphGet.handle(%{"runId" => "run-status-check"}, %{})
      assert is_binary(result["graph"]["status"])
    end

    test "handle/2 supports deep graph options and reflects them in response" do
      {:ok, result} =
        RunGraphGet.handle(
          %{
            "runId" => "run-options-check",
            "maxDepth" => 4,
            "childLimit" => 15,
            "includeRunRecord" => true,
            "includeRunEvents" => true,
            "runEventLimit" => 25,
            "includeIntrospection" => true,
            "introspectionLimit" => 30
          },
          %{}
        )

      assert result["options"]["maxDepth"] == 4
      assert result["options"]["childLimit"] == 15
      assert result["options"]["includeRunRecord"] == true
      assert result["options"]["includeRunEvents"] == true
      assert result["options"]["runEventLimit"] == 25
      assert result["options"]["includeIntrospection"] == true
      assert result["options"]["introspectionLimit"] == 30
    end

    test "handle/2 includes optional runRecord and introspection keys when requested" do
      {:ok, result} =
        RunGraphGet.handle(
          %{
            "runId" => "run-deep-keys",
            "includeRunRecord" => true,
            "includeIntrospection" => true
          },
          %{}
        )

      graph = result["graph"]
      assert Map.has_key?(graph, "runRecord")
      assert Map.has_key?(graph, "introspection")
    end
  end
end
