defmodule LemonControlPlane.Methods.SessionsTree do
  @moduledoc """
  Reads a bounded page of the native session tree. Entry `text` and `label`
  are content and need `operator.content`; read-only callers get the tree
  structure with `textBytes`.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @metadata_fields ~w(id parentId type role timestamp isActive isLeaf rewindable)
  @entry_fields @metadata_fields ++ ~w(text label)

  @impl true
  def name, do: "sessions.tree"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    content? = Authorize.content?(ctx)

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
             |> Map.put("entries", Enum.map(entries, &entry(&1, content?)))
             |> Map.put("branches", Enum.map(branches, &Map.take(&1, ~w(leafId active))))
             |> Map.put("contentWithheld", not content?)}
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

  defp entry(entry, true), do: Map.take(entry, @entry_fields)

  defp entry(entry, false) do
    text = Map.get(entry, "text")

    entry
    |> Map.take(@metadata_fields)
    |> Map.put("textBytes", if(is_binary(text), do: byte_size(text), else: 0))
  end
end
