defmodule CodingAgent.Tools.MultiEdit do
  @moduledoc """
  MultiEdit tool for the coding agent.

  Applies multiple edit operations to the same file sequentially.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.Edit

  @doc """
  Returns the multiedit tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "multiedit",
      description: "Apply multiple edits to a file sequentially.",
      label: "Multi Edit",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "The path to the file to edit"},
          "edits" => %{
            "type" => "array",
            "description" => "Array of edit operations to apply in order",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "old_text" => %{
                  "type" => "string",
                  "description" => "The exact text to find and replace"
                },
                "new_text" => %{"type" => "string", "description" => "The replacement text"}
              },
              "required" => ["old_text", "new_text"]
            }
          }
        },
        "required" => ["path", "edits"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal, cwd, opts)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    path = Map.get(params, "path", "")
    edits = Map.get(params, "edits", [])

    cond do
      path == "" ->
        {:error, "Path is required"}

      not is_list(edits) ->
        {:error, "Edits must be an array"}

      edits == [] ->
        {:error, "Edits array cannot be empty"}

      true ->
        apply_edits(path, edits, signal, cwd, opts)
    end
  end

  defp apply_edits(path, edits, signal, cwd, opts) do
    results =
      Enum.reduce_while(edits, [], fn edit, acc ->
        if AbortSignal.aborted?(signal) do
          {:halt, {:error, "Operation aborted"}}
        else
          params = %{
            "path" => path,
            "old_text" => Map.get(edit, "old_text"),
            "new_text" => Map.get(edit, "new_text")
          }

          case Edit.execute("", params, signal, nil, cwd, opts) do
            %AgentToolResult{} = result ->
              {:cont, [result | acc]}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end
      end)
      |> case do
        {:error, _} = err -> err
        list when is_list(list) -> Enum.reverse(list)
      end

    case results do
      {:error, reason} ->
        {:error, reason}

      [] ->
        {:error, "No edits applied"}

      results_list ->
        last_result = List.last(results_list)

        %AgentToolResult{
          content: last_result.content || [%TextContent{text: ""}],
          details: %{results: Enum.map(results_list, & &1.details)}
        }
    end
  end
end
