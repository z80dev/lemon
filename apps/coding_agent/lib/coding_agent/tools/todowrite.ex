defmodule CodingAgent.Tools.TodoWrite do
  @moduledoc """
  Todo write tool for the coding agent.

  Stores a todo list for the current session.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.TodoStore

  @doc """
  Returns the TodoWrite tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "")

    %AgentTool{
      name: "todowrite",
      description: "Write the session todo list.",
      label: "Write Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "todos" => %{
            "type" => "array",
            "description" => "Updated todo list",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "content" => %{
                  "type" => "string",
                  "description" => "Brief description of the task"
                },
                "status" => %{
                  "type" => "string",
                  "description" => "Task status: pending, in_progress, completed"
                },
                "priority" => %{
                  "type" => "string",
                  "description" => "Priority level: high, medium, low"
                },
                "id" => %{"type" => "string", "description" => "Unique todo id"}
              },
              "required" => ["content", "status", "priority", "id"]
            }
          }
        },
        "required" => ["todos"]
      },
      execute: &execute(&1, &2, &3, &4, session_id)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          session_id :: String.t()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, session_id) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      todos = Map.get(params, "todos")

      cond do
        not is_list(todos) ->
          {:error, "Todos must be an array"}

        session_id == "" ->
          {:error, "Session id not available"}

        true ->
          with :ok <- validate_todos(todos) do
            TodoStore.put(session_id, todos)

            output = Jason.encode!(todos, pretty: true)
            open_count = Enum.count(todos, fn todo -> Map.get(todo, "status") != "completed" end)

            %AgentToolResult{
              content: [%TextContent{text: output}],
              details: %{title: "#{open_count} todos", todos: todos}
            }
          end
      end
    end
  end

  defp validate_todos(todos) when is_list(todos) do
    with :ok <- validate_entries(todos),
         :ok <- validate_unique_ids(todos) do
      :ok
    end
  end

  defp validate_entries(todos) do
    Enum.reduce_while(Enum.with_index(todos, 1), :ok, fn
      {todo, idx}, :ok when is_map(todo) ->
        case validate_todo(todo, idx) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end

      {_todo, idx}, :ok ->
        {:halt, {:error, "Todo #{idx} must be an object"}}
    end)
  end

  defp validate_todo(todo, idx) do
    with :ok <- validate_non_empty_string(todo, "id", idx),
         :ok <- validate_non_empty_string(todo, "content", idx),
         :ok <- validate_status(todo, idx),
         :ok <- validate_priority(todo, idx) do
      :ok
    end
  end

  defp validate_non_empty_string(todo, key, idx) do
    case Map.get(todo, key) do
      value when is_binary(value) ->
        if byte_size(String.trim(value)) > 0 do
          :ok
        else
          {:error, "Todo #{idx} #{key} must be a non-empty string"}
        end

      _ ->
        {:error, "Todo #{idx} #{key} must be a non-empty string"}
    end
  end

  defp validate_status(todo, idx) do
    allowed = ["pending", "in_progress", "completed"]

    case Map.get(todo, "status") do
      value when is_binary(value) ->
        if value in allowed do
          :ok
        else
          {:error, "Todo #{idx} status must be pending, in_progress, or completed"}
        end

      _ ->
        {:error, "Todo #{idx} status must be pending, in_progress, or completed"}
    end
  end

  defp validate_priority(todo, idx) do
    allowed = ["high", "medium", "low"]

    case Map.get(todo, "priority") do
      value when is_binary(value) ->
        if value in allowed do
          :ok
        else
          {:error, "Todo #{idx} priority must be high, medium, or low"}
        end

      _ ->
        {:error, "Todo #{idx} priority must be high, medium, or low"}
    end
  end

  defp validate_unique_ids(todos) do
    ids = Enum.map(todos, &Map.get(&1, "id"))

    if Enum.uniq(ids) == ids do
      :ok
    else
      {:error, "todo ids must be unique"}
    end
  end
end
