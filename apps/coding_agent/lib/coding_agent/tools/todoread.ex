defmodule CodingAgent.Tools.TodoRead do
  @moduledoc """
  Task-list read tool for the coding agent.

  Reads the complete todo list of the owning session's selected branch (see
  `CodingAgent.Session.Todos`). Results expose string-keyed canonical entries
  in `details.todos` and an ordered full ACP/TUI plan in `details.plan.entries`,
  including completed tasks. Plan entries contain string content/status/priority
  values, with no IDs or extra store metadata.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.AbortSignal
  alias LemonAi.Types.TextContent
  alias CodingAgent.Tools.TodoStore

  @doc """
  Returns the TodoRead tool definition bound to the `:session_pid` option.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session = Keyword.get(opts, :session_pid)

    %AgentTool{
      name: "todoread",
      description: "Read the session todo list.",
      label: "Read Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, session)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          session :: GenServer.server() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, _params, signal, _on_update, session) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, todos} <- readable(session) do
        details = TodoStore.result_details(todos)
        todos = details.todos
        output = Jason.encode!(todos, pretty: true)
        open_count = Enum.count(todos, fn todo -> todo["status"] != "completed" end)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details: Map.put(details, :title, "#{open_count} todos")
        }
      end
    end
  end

  @doc false
  # The selected branch's list as the session materializes it, with the
  # revision a write must be prepared against. Shared by the todo tools.
  @spec current(GenServer.server() | nil) ::
          {:ok, [map()], term()} | {:unsupported, term(), term()} | {:error, String.t()}
  def current(nil), do: {:error, "Session not available"}

  def current(session) do
    case CodingAgent.Session.todos(session) do
      {:ok, todos, revision} -> {:ok, todos, revision}
      {:error, {:unsupported_todo_entry, version}, revision} -> {:unsupported, version, revision}
    end
  catch
    :exit, _ -> {:error, "Session not available"}
  end

  @doc false
  # Read-only views refuse an unreadable list rather than showing other state.
  @spec readable(GenServer.server() | nil) :: {:ok, [map()]} | {:error, String.t()}
  def readable(session) do
    case current(session) do
      {:ok, todos, _revision} ->
        {:ok, todos}

      {:unsupported, version, _revision} ->
        {:error,
         "This branch's todo list was saved in an unsupported format (entry version " <>
           "#{inspect(version)}) and cannot be read. Write the complete list to replace it."}

      {:error, _} = error ->
        error
    end
  end
end
