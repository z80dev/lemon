defmodule LemonControlPlane.Methods.AgentsFilesList do
  @moduledoc """
  Handler for the agents.files.list control plane method.

  Lists files for an agent (e.g., system prompt, memory files, etc.).
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agents.files.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"

    # Get agent files from store
    files = list_agent_files(agent_id)

    {:ok, %{
      "agentId" => agent_id,
      "files" => files
    }}
  end

  defp list_agent_files(agent_id) do
    # Files are stored with compound key {agent_id, file_name} by agents.files.set
    # So we need to scan for all keys matching this agent_id
    all_entries = LemonCore.Store.list(:agent_files)

    all_entries
    |> Enum.filter(fn
      {{^agent_id, _file_name}, _file} -> true
      _ -> false
    end)
    |> Enum.map(fn {_key, file} -> file_to_map(file) end)
  rescue
    # Fallback for old format where files might be stored differently
    _ ->
      case LemonCore.Store.get(:agent_files, agent_id) do
        nil -> []
        files when is_list(files) -> Enum.map(files, &file_to_map/1)
        files when is_map(files) -> Map.values(files) |> Enum.map(&file_to_map/1)
      end
  end

  defp file_to_map(%{name: name, type: type} = file) do
    %{
      "name" => name,
      "type" => to_string(type),
      "size" => file[:size] || 0,
      "updatedAt" => file[:updated_at] || file[:updated_at_ms]
    }
  end

  defp file_to_map(file) when is_map(file) do
    %{
      "name" => file["name"] || file[:name] || "unknown",
      "type" => to_string(file["type"] || file[:type] || "text"),
      "size" => file["size"] || file[:size] || 0,
      "updatedAt" => file["updatedAt"] || file[:updated_at] || file[:updated_at_ms]
    }
  end
end
