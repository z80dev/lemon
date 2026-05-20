defmodule LemonControlPlane.Methods.CheckpointDiff do
  @moduledoc """
  Handler for `checkpoint.diff`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Checkpoint

  @impl true
  def name, do: "checkpoint.diff"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, checkpoint_id} <- checkpoint_id(params),
         {:ok, paths} <- paths(params),
         {:ok, diff} <- Checkpoint.diff_filesystem(checkpoint_id, paths: paths) do
      {:ok,
       %{
         "checkpoint_id" => diff.checkpoint_id,
         "session_hash" => short_hash(diff.session_id),
         "changed" => diff.changed,
         "changed_count" => length(diff.changed),
         "diffs" => stringify_keys(diff.diffs),
         "output" => diff.output,
         "summary" => summary(diff)
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
        {:error, :internal_error, "Failed to diff checkpoint", inspect(reason)}
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

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp summary(diff) do
    output = diff.output || ""

    %{
      "checkpointId" => diff.checkpoint_id,
      "changedCount" => length(diff.changed),
      "diffBytes" => byte_size(output),
      "changedPathsReturned" => true,
      "diffOutputReturned" => output != "",
      "rawSessionIdReturned" => false,
      "cleanup" => %{
        "includesRawSessionId" => false,
        "includesRawFilePaths" => true,
        "includesDiffText" => output != "",
        "includesFileContentText" => output != "",
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
