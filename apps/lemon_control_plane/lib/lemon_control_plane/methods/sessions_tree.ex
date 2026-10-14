defmodule LemonControlPlane.Methods.SessionsTree do
  @moduledoc "Reads a bounded page of the native session tree."
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @entry_fields ~w(id parentId type role text timestamp isActive isLeaf rewindable label)

  @impl true
  def name, do: "sessions.tree"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, limit} <- NativeSessions.integer(params, "limit", 100, 1, 500),
         {:ok, offset} <- NativeSessions.integer(params, "offset", 0, 0, 1_000_000) do
      result =
        AgentRuntime.call(
          :session_tree,
          [key, cwd, [limit: limit, offset: offset]],
          {:error, :unavailable}
        )

      case result do
        {:ok, %{"entries" => entries, "branches" => branches} = tree}
        when is_list(entries) and is_list(branches) ->
          if Enum.all?(entries, &is_map/1) and Enum.all?(branches, &is_map/1) do
            {:ok,
             tree
             |> Map.take(~w(sessionId leafId totalEntries offset hasMore))
             |> Map.put("sessionKey", key)
             |> Map.put("entries", Enum.map(entries, &Map.take(&1, @entry_fields)))
             |> Map.put("branches", Enum.map(branches, &Map.take(&1, ~w(leafId active))))}
          else
            NativeSessions.failure(:invalid_response)
          end

        {:error, reason} ->
          NativeSessions.failure(reason)

        _ ->
          NativeSessions.failure(:invalid_response)
      end
    end
  end
end
