defmodule CodingAgent.Tools.FsCheckpoint do
  @moduledoc """
  Checkpoint inspection and rollback tool.

  Every action is scoped to the current session: the owner comes from
  `CodingAgent.Checkpoint.owner/1` (the trusted session id in the tool's
  options), never from model input or `:session_key`. Checkpoints owned by
  another session are reported as not found.
  """

  alias CodingAgent.Checkpoint
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @doc """
  Returns the checkpoint tool definition.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "fs_checkpoint",
      description:
        "List this session's filesystem checkpoints, preview diffs, restore files from a checkpoint, or delete checkpoints.",
      label: "Checkpoint",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["list", "diff", "restore", "delete"],
            "description" => "Checkpoint action to perform"
          },
          "checkpoint_id" => %{
            "type" => "string",
            "description" => "Checkpoint id for diff, restore, or delete actions."
          },
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Optional path subset for diff or restore."
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update, cwd, opts) do
    with {:ok, owner} <- owner(opts) do
      case params["action"] do
        "list" -> list(owner)
        "diff" -> diff(params, cwd, owner)
        "restore" -> restore(params, cwd, owner, opts)
        "delete" -> delete(params, owner, opts)
        nil -> {:error, "missing required parameter: action"}
        other -> {:error, "unsupported checkpoint action: #{inspect(other)}"}
      end
    end
  end

  defp list(session_id) do
    checkpoints = Checkpoint.list(session_id)

    text =
      case checkpoints do
        [] ->
          "No checkpoints for session #{session_id}."

        _ ->
          checkpoints
          |> Enum.map(fn checkpoint ->
            kind = checkpoint.metadata[:kind] || "session"
            tool = checkpoint.metadata[:tool] || "unknown"
            "#{checkpoint.id} #{checkpoint.timestamp} kind=#{kind} tool=#{tool}"
          end)
          |> Enum.join("\n")
      end

    result(text, %{session_id: session_id, checkpoints: checkpoints})
  end

  defp diff(params, cwd, owner) do
    with {:ok, checkpoint_id} <- checkpoint_id(params),
         {:ok, paths} <- paths(params, cwd),
         {:ok, diff} <-
           Checkpoint.diff_filesystem(checkpoint_id, owner, paths: paths) do
      result(diff.output, diff)
    else
      error -> format_error(error)
    end
  end

  defp restore(params, cwd, owner, opts) do
    with {:ok, checkpoint_id} <- checkpoint_id(params),
         {:ok, paths} <- paths(params, cwd),
         {:ok, restored} <-
           Checkpoint.restore_filesystem(
             checkpoint_id,
             owner,
             checkpoint_event_opts(opts, paths: paths)
           ) do
      text = "Restored #{length(restored.restored)} path(s) from #{checkpoint_id}."
      result(text, restored)
    else
      error -> format_error(error)
    end
  end

  defp delete(params, owner, opts) do
    with {:ok, checkpoint_id} <- checkpoint_id(params),
         :ok <- Checkpoint.delete(checkpoint_id, owner, checkpoint_event_opts(opts)) do
      result("Deleted checkpoint #{checkpoint_id}.", %{
        checkpoint_id: checkpoint_id,
        deleted: true
      })
    else
      error -> format_error(error)
    end
  end

  defp format_error({:error, :not_found}), do: {:error, "checkpoint not found"}

  defp format_error({:error, :not_filesystem_checkpoint}),
    do: {:error, "checkpoint is not a filesystem checkpoint"}

  defp format_error({:error, {:path_not_in_checkpoint, path}}),
    do: {:error, "path is not in checkpoint: #{path}"}

  defp format_error({:error, {:operator_state, reason}}), do: {:error, reason}

  defp format_error(error), do: error

  defp owner(opts) do
    case Checkpoint.owner(opts) do
      nil -> {:error, "fs_checkpoint requires a current session"}
      owner -> {:ok, owner}
    end
  end

  defp checkpoint_id(%{"checkpoint_id" => value}) when is_binary(value) and value != "" do
    if LemonAgent.Checkpoint.valid_id?(value),
      do: {:ok, value},
      else: {:error, "checkpoint not found"}
  end

  defp checkpoint_id(_params), do: {:error, "checkpoint_id is required"}

  defp paths(%{"paths" => paths}, cwd) when is_list(paths) do
    if Enum.all?(paths, &is_binary/1) do
      {:ok, Enum.map(paths, &Path.expand(&1, cwd))}
    else
      {:error, "paths must be an array of strings"}
    end
  end

  defp paths(_params, _cwd), do: {:ok, nil}

  defp result(text, details) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: text}],
      details: details
    }
  end

  defp checkpoint_event_opts(opts, extra \\ []) do
    [
      run_id: Keyword.get(opts, :run_id),
      session_key: Keyword.get(opts, :session_key),
      agent_id: Keyword.get(opts, :agent_id),
      parent_run_id: Keyword.get(opts, :parent_run_id)
    ]
    |> Keyword.merge(extra)
  end
end
