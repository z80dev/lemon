defmodule LemonControlPlane.Methods.AgentsFilesSet do
  @moduledoc """
  Handler for the agents.files.set control plane method.

  Sets/updates the content of an agent file.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "agents.files.set"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"
    file_name = params["fileName"] || params["file_name"]
    content = params["content"]
    file_type = params["type"] || "text"

    cond do
      is_nil(file_name) or file_name == "" ->
        {:error, Errors.invalid_request("fileName is required")}

      is_nil(content) ->
        {:error, Errors.invalid_request("content is required")}

      true ->
        file = %{
          name: file_name,
          content: content,
          type: file_type,
          size: byte_size(content),
          updated_at_ms: System.system_time(:millisecond)
        }

        # Store with compound key
        LemonCore.Store.put(:agent_files, {agent_id, file_name}, file)

        {:ok, %{
          "agentId" => agent_id,
          "fileName" => file_name,
          "size" => byte_size(content),
          "updatedAt" => file.updated_at_ms
        }}
    end
  end
end
