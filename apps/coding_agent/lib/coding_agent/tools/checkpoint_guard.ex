defmodule CodingAgent.Tools.CheckpointGuard do
  @moduledoc false

  alias CodingAgent.Checkpoint

  @spec before_mutation([String.t()], String.t(), keyword(), map()) ::
          {:ok, map() | nil} | {:error, term()}
  def before_mutation(paths, cwd, opts, metadata) when is_list(paths) do
    if Keyword.get(opts, :filesystem_checkpoints, true) do
      case session_id(opts) do
        nil ->
          {:ok, nil}

        session_id ->
          Checkpoint.create_filesystem(session_id, paths,
            cwd: cwd,
            tool: Map.get(metadata, :tool),
            metadata: metadata,
            run_id: Keyword.get(opts, :run_id),
            session_key: Keyword.get(opts, :session_key),
            agent_id: Keyword.get(opts, :agent_id),
            parent_run_id: Keyword.get(opts, :parent_run_id)
          )
      end
    else
      {:ok, nil}
    end
  end

  @spec put_details(map(), map() | nil) :: map()
  def put_details(details, nil), do: details

  def put_details(details, checkpoint) do
    details
    |> Map.put(:checkpoint_id, checkpoint.id)
    |> Map.put(:checkpoint_kind, "filesystem")
  end

  defp session_id(opts) do
    opts
    |> Keyword.take([:session_id, :session_key, :run_id])
    |> Keyword.values()
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end
end
