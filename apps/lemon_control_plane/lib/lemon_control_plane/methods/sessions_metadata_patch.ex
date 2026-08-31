defmodule LemonControlPlane.Methods.SessionsMetadataPatch do
  @moduledoc """
  Operator mutation for session title, pin, and archive metadata.

  The response deliberately reports title presence and size rather than
  echoing operator-authored title text.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.metadata.patch"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, session_key} <- require_session_key(params),
         {:ok, patch} <- metadata_patch(params),
         {:ok, session} <- LemonCore.SessionLifecycle.patch(session_key, patch) do
      {:ok,
       %{
         "success" => true,
         "sessionKey" => session_key,
         "metadata" => %{
           "titlePresent" => is_binary(session.title),
           "titleBytes" => if(is_binary(session.title), do: byte_size(session.title), else: 0),
           "pinned" => session.pinned,
           "archived" => session.archived,
           "updatedAtMs" => session.metadata_updated_at_ms
         },
         "summary" => %{
           "patchedKeys" => patch |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
           "patchedCount" => map_size(patch),
           "cleanup" => %{
             "includesTitleText" => false,
             "includesMessages" => false,
             "includesRunEvents" => false,
             "includesCredentials" => false,
             "includesSecretValues" => false
           }
         }
       }}
    else
      {:error, :not_found} ->
        {:error, {:not_found, "Session not found", nil}}

      {:error, :empty_patch} ->
        {:error,
         {:invalid_request, "At least one of title, pinned, or archived is required", nil}}

      {:error, {:invalid_title, :too_long}} ->
        {:error, {:invalid_params, "title must be 160 characters or fewer", nil}}

      {:error, {:invalid_title, :not_a_string}} ->
        {:error, {:invalid_params, "title must be a string or null", nil}}

      {:error, {:invalid_boolean, field}} ->
        {:error, {:invalid_params, "#{field} must be a boolean", nil}}

      {:error, {:invalid_request, _, _} = error} ->
        {:error, error}

      {:error, _reason} ->
        {:error, {:internal_error, "Failed to patch session metadata", nil}}
    end
  end

  defp require_session_key(%{"sessionKey" => session_key})
       when is_binary(session_key) and session_key != "",
       do: {:ok, session_key}

  defp require_session_key(_params),
    do: {:error, {:invalid_request, "sessionKey is required", nil}}

  defp metadata_patch(params) do
    patch =
      Enum.reduce([{"title", :title}, {"pinned", :pinned}, {"archived", :archived}], %{}, fn
        {wire_key, key}, acc ->
          if Map.has_key?(params, wire_key),
            do: Map.put(acc, key, Map.get(params, wire_key)),
            else: acc
      end)

    if map_size(patch) == 0, do: {:error, :empty_patch}, else: {:ok, patch}
  end
end
