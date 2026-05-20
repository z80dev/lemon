defmodule LemonControlPlane.Methods.CheckpointRestore do
  @moduledoc """
  Handler for `checkpoint.restore`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Checkpoint

  @impl true
  def name, do: "checkpoint.restore"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, checkpoint_id} <- checkpoint_id(params),
         {:ok, paths} <- paths(params),
         {:ok, restored} <-
           Checkpoint.restore_filesystem(checkpoint_id,
             paths: paths,
             run_id: get_param(params, "runId"),
             session_key: get_param(params, "sessionKey"),
             agent_id: get_param(params, "agentId"),
             parent_run_id: get_param(params, "parentRunId")
           ) do
      {:ok,
       %{
         "checkpoint_id" => restored.checkpoint_id,
         "session_hash" => short_hash(restored.session_id),
         "restored" => restored.restored,
         "restored_count" => length(restored.restored),
         "summary" => summary(restored)
       }}
    else
      {:error, :not_filesystem_checkpoint} ->
        {:error, :invalid_request, "checkpoint is not a filesystem checkpoint", nil}

      {:error, {:path_not_in_checkpoint, path}} ->
        {:error, :invalid_request, "path is not in checkpoint", %{"path" => path}}

      {:error, :not_found} ->
        {:error, :not_found, "checkpoint not found", nil}

      {:error, reason} when is_binary(reason) ->
        {:error, :invalid_request, reason, nil}

      {:error, reason} ->
        {:error, :internal_error, "Failed to restore checkpoint", inspect(reason)}
    end
  end

  defp checkpoint_id(%{"checkpointId" => value}) when is_binary(value) and value != "",
    do: {:ok, value}

  defp checkpoint_id(%{"checkpoint_id" => value}) when is_binary(value) and value != "",
    do: {:ok, value}

  defp checkpoint_id(_params), do: {:error, "checkpointId is required"}

  defp paths(%{"paths" => paths}) when is_list(paths) do
    if Enum.all?(paths, &is_binary/1),
      do: {:ok, paths},
      else: {:error, "paths must be an array of strings"}
  end

  defp paths(%{"paths" => _paths}), do: {:error, "paths must be an array of strings"}
  defp paths(_params), do: {:ok, nil}

  defp get_param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp summary(restored) do
    %{
      "checkpointId" => restored.checkpoint_id,
      "restoredCount" => length(restored.restored),
      "restoredPathsReturned" => true,
      "rawSessionIdReturned" => false,
      "cleanup" => %{
        "includesRawSessionId" => false,
        "includesRawFilePaths" => true,
        "includesFileContentText" => false,
        "includesDiffText" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
