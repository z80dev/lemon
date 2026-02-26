defmodule LemonControlPlane.Methods.AgentsFilesTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.AgentsFilesSet
  alias LemonControlPlane.Methods.AgentsFilesList

  describe "AgentsFilesSet.handle/2" do
    test "stores file with compound key {agent_id, file_name}" do
      agent_id = "agent_#{System.unique_integer()}"
      file_name = "test_file.md"

      params = %{
        "agentId" => agent_id,
        "fileName" => file_name,
        "content" => "# Test Content"
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, result} = AgentsFilesSet.handle(params, ctx)
      assert result["agentId"] == agent_id
      assert result["fileName"] == file_name
      assert result["size"] == byte_size("# Test Content")

      # Verify stored with compound key
      stored = LemonCore.Store.get(:agent_files, {agent_id, file_name})
      assert stored.name == file_name
      assert stored.content == "# Test Content"

      # Cleanup
      LemonCore.Store.delete(:agent_files, {agent_id, file_name})
    end

    test "returns error when fileName is missing" do
      params = %{
        "agentId" => "test",
        "content" => "test content"
      }

      ctx = %{auth: %{role: :operator}}

      {:error, error} = AgentsFilesSet.handle(params, ctx)
      assert String.contains?(inspect(error), "fileName")
    end

    test "returns error when content is missing" do
      params = %{
        "agentId" => "test",
        "fileName" => "test.md"
      }

      ctx = %{auth: %{role: :operator}}

      {:error, error} = AgentsFilesSet.handle(params, ctx)
      assert String.contains?(inspect(error), "content")
    end

    test "uses default agent_id when not provided" do
      file_name = "file_#{System.unique_integer()}.md"

      params = %{
        "fileName" => file_name,
        "content" => "content"
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, result} = AgentsFilesSet.handle(params, ctx)
      assert result["agentId"] == "default"

      # Cleanup
      LemonCore.Store.delete(:agent_files, {"default", file_name})
    end
  end

  describe "AgentsFilesList.handle/2" do
    test "returns empty list when no files exist" do
      agent_id = "nonexistent_#{System.unique_integer()}"

      params = %{"agentId" => agent_id}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = AgentsFilesList.handle(params, ctx)
      assert result["agentId"] == agent_id
      assert result["files"] == []
    end

    test "returns files stored with compound key" do
      agent_id = "agent_#{System.unique_integer()}"
      file_name1 = "file1.md"
      file_name2 = "file2.txt"

      # Store files using the compound key format from AgentsFilesSet
      LemonCore.Store.put(:agent_files, {agent_id, file_name1}, %{
        name: file_name1,
        content: "content1",
        type: "text",
        size: 8,
        updated_at_ms: System.system_time(:millisecond)
      })

      LemonCore.Store.put(:agent_files, {agent_id, file_name2}, %{
        name: file_name2,
        content: "content2",
        type: "text",
        size: 8,
        updated_at_ms: System.system_time(:millisecond)
      })

      params = %{"agentId" => agent_id}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = AgentsFilesList.handle(params, ctx)
      assert result["agentId"] == agent_id
      assert length(result["files"]) == 2

      file_names = Enum.map(result["files"], & &1["name"])
      assert file_name1 in file_names
      assert file_name2 in file_names

      # Cleanup
      LemonCore.Store.delete(:agent_files, {agent_id, file_name1})
      LemonCore.Store.delete(:agent_files, {agent_id, file_name2})
    end

    test "only returns files for specified agent" do
      agent_id1 = "agent_#{System.unique_integer()}"
      agent_id2 = "agent_#{System.unique_integer()}"

      # Store files for different agents
      LemonCore.Store.put(:agent_files, {agent_id1, "file1.md"}, %{
        name: "file1.md",
        content: "content1",
        type: "text",
        size: 8,
        updated_at_ms: System.system_time(:millisecond)
      })

      LemonCore.Store.put(:agent_files, {agent_id2, "file2.md"}, %{
        name: "file2.md",
        content: "content2",
        type: "text",
        size: 8,
        updated_at_ms: System.system_time(:millisecond)
      })

      params = %{"agentId" => agent_id1}
      ctx = %{auth: %{role: :operator}}

      {:ok, result} = AgentsFilesList.handle(params, ctx)
      assert length(result["files"]) == 1
      assert hd(result["files"])["name"] == "file1.md"

      # Cleanup
      LemonCore.Store.delete(:agent_files, {agent_id1, "file1.md"})
      LemonCore.Store.delete(:agent_files, {agent_id2, "file2.md"})
    end

    test "set then list integration - files are visible after set" do
      agent_id = "agent_#{System.unique_integer()}"
      file_name = "integration_test.md"

      # Set a file
      set_params = %{
        "agentId" => agent_id,
        "fileName" => file_name,
        "content" => "Integration test content"
      }

      {:ok, _} = AgentsFilesSet.handle(set_params, %{auth: %{role: :operator}})

      # List files for this agent
      list_params = %{"agentId" => agent_id}
      {:ok, result} = AgentsFilesList.handle(list_params, %{auth: %{role: :operator}})

      assert length(result["files"]) == 1
      file = hd(result["files"])
      assert file["name"] == file_name

      # Cleanup
      LemonCore.Store.delete(:agent_files, {agent_id, file_name})
    end
  end
end
