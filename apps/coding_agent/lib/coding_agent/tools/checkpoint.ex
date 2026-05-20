defmodule CodingAgent.Tools.Checkpoint do
  @moduledoc """
  Checkpoint inspection and rollback tool.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.Checkpoint

  @doc """
  Returns the checkpoint tool definition.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "checkpoint",
      description:
        "List filesystem checkpoints, preview diffs, restore files from a checkpoint, or delete checkpoints.",
      label: "Checkpoint",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["list", "diff", "restore", "delete"],
            "description" => "Checkpoint action to perform"
          },
          "session_id" => %{
            "type" => "string",
            "description" =>
              "Session id to list checkpoints for. Defaults to the current session."
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
    case params["action"] do
      "list" -> list(params, opts)
      "diff" -> diff(params, cwd)
      "restore" -> restore(params, cwd, opts)
      "delete" -> delete(params, opts)
      nil -> {:error, "missing required parameter: action"}
      other -> {:error, "unsupported checkpoint action: #{inspect(other)}"}
    end
  end

  defp list(params, opts) do
    with {:ok, session_id} <- session_id(params, opts) do
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
  end

  defp diff(params, cwd) do
    with {:ok, checkpoint_id} <- checkpoint_id(params),
         {:ok, paths} <- paths(params, cwd),
         {:ok, diff} <- Checkpoint.diff_filesystem(checkpoint_id, paths: paths) do
      result(diff.output, diff)
    else
      {:error, :not_filesystem_checkpoint} ->
        {:error, "checkpoint is not a filesystem checkpoint"}

      {:error, {:path_not_in_checkpoint, path}} ->
        {:error, "path is not in checkpoint: #{path}"}

      error ->
        error
    end
  end

  defp restore(params, cwd, opts) do
    with {:ok, checkpoint_id} <- checkpoint_id(params),
         {:ok, paths} <- paths(params, cwd),
         {:ok, restored} <-
           Checkpoint.restore_filesystem(
             checkpoint_id,
             checkpoint_event_opts(opts, paths: paths)
           ) do
      text = "Restored #{length(restored.restored)} path(s) from #{checkpoint_id}."
      result(text, restored)
    else
      {:error, :not_filesystem_checkpoint} ->
        {:error, "checkpoint is not a filesystem checkpoint"}

      {:error, {:path_not_in_checkpoint, path}} ->
        {:error, "path is not in checkpoint: #{path}"}

      error ->
        error
    end
  end

  defp delete(params, opts) do
    with {:ok, checkpoint_id} <- checkpoint_id(params),
         :ok <- Checkpoint.delete(checkpoint_id, checkpoint_event_opts(opts)) do
      result("Deleted checkpoint #{checkpoint_id}.", %{
        checkpoint_id: checkpoint_id,
        deleted: true
      })
    end
  end

  defp session_id(%{"session_id" => value}, _opts) when is_binary(value) and value != "",
    do: {:ok, value}

  defp session_id(_params, opts) do
    case Keyword.get(opts, :session_id) || Keyword.get(opts, :session_key) ||
           Keyword.get(opts, :run_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "session_id is required for list when no current session is available"}
    end
  end

  defp checkpoint_id(%{"checkpoint_id" => value}) when is_binary(value) and value != "",
    do: {:ok, value}

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
