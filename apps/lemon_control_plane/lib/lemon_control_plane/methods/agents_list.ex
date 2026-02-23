defmodule LemonControlPlane.Methods.AgentsList do
  @moduledoc """
  Handler for the agents.list method.

  Delegates to AgentDirectoryList for richer agent data and adds backward-compatible
  `"id"` field alongside `"agentId"`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agents.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    case LemonControlPlane.Methods.AgentDirectoryList.handle(params, ctx) do
      {:ok, payload} ->
        agents =
          (payload["agents"] || [])
          |> Enum.map(fn a ->
            Map.put(a, "id", a["agentId"] || a["id"])
          end)

        {:ok, %{"agents" => agents}}

      error ->
        error
    end
  rescue
    _ -> {:ok, %{"agents" => []}}
  catch
    :exit, _ -> {:ok, %{"agents" => []}}
  end
end
