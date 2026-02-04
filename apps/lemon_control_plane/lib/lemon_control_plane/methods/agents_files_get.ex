defmodule LemonControlPlane.Methods.AgentsFilesGet do
  @moduledoc """
  Handler for the agents.files.get control plane method.

  Gets the content of a specific agent file.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "agents.files.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"
    file_name = params["fileName"] || params["file_name"]

    if is_nil(file_name) or file_name == "" do
      {:error, Errors.invalid_request("fileName is required")}
    else
      case get_agent_file(agent_id, file_name) do
        nil ->
          {:error, Errors.not_found("File not found: #{file_name}")}

        file ->
          {:ok, %{
            "agentId" => agent_id,
            "fileName" => file_name,
            "content" => file[:content] || file["content"] || "",
            "type" => to_string(file[:type] || file["type"] || "text"),
            "updatedAt" => file[:updated_at] || file["updatedAt"] || file[:updated_at_ms]
          }}
      end
    end
  end

  defp get_agent_file(agent_id, file_name) do
    case LemonCore.Store.get(:agent_files, {agent_id, file_name}) do
      nil ->
        # Try getting from agent files map
        case LemonCore.Store.get(:agent_files, agent_id) do
          nil -> nil
          files when is_map(files) -> Map.get(files, file_name)
          files when is_list(files) -> Enum.find(files, &(&1[:name] == file_name || &1["name"] == file_name))
        end

      file ->
        file
    end
  end
end
