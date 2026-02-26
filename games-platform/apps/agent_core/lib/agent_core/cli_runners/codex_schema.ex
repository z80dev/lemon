defmodule AgentCore.CliRunners.CodexSchema do
  @moduledoc """
  Codex CLI JSONL event schema definitions.

  This module defines all the event types emitted by `codex exec --json`.
  Events are decoded from newline-delimited JSON (JSONL) format.

  ## Event Categories

  ### Session Lifecycle
  - `ThreadStarted` - Session has started with a thread_id
  - `TurnStarted` - New conversation turn has begun
  - `TurnCompleted` - Conversation turn has finished (includes usage)
  - `TurnFailed` - Turn failed with error

  ### Stream Events
  - `StreamError` - Stream-level error or reconnection notice

  ### Item Events
  Items represent discrete work units within a turn:
  - `ItemStarted` - Item has begun
  - `ItemUpdated` - Item has progress update
  - `ItemCompleted` - Item has finished

  ### Item Types
  - `AgentMessageItem` - Final text response from agent
  - `ReasoningItem` - Extended thinking/reasoning text
  - `CommandExecutionItem` - Shell command execution
  - `FileChangeItem` - File modifications
  - `McpToolCallItem` - MCP tool invocation
  - `WebSearchItem` - Web search query
  - `TodoListItem` - Task list
  - `ErrorItem` - Error message

  ## Decoding

      case CodexSchema.decode_event(json_line) do
        {:ok, %ThreadStarted{thread_id: id}} -> ...
        {:ok, %ItemCompleted{item: item}} -> ...
        {:error, reason} -> ...
      end

  """

  # ============================================================================
  # Helper Types
  # ============================================================================

  defmodule Usage do
    @moduledoc "Token usage statistics"
    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            cached_input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer()
          }
    defstruct input_tokens: 0, cached_input_tokens: 0, output_tokens: 0
  end

  defmodule ThreadError do
    @moduledoc "Error information for failed turns"
    @type t :: %__MODULE__{message: String.t()}
    defstruct message: ""
  end

  defmodule FileUpdateChange do
    @moduledoc "Individual file change within a FileChangeItem"
    @type change_kind :: :add | :delete | :update
    @type t :: %__MODULE__{
            path: String.t(),
            kind: change_kind()
          }
    defstruct path: "", kind: :update
  end

  defmodule McpToolCallItemResult do
    @moduledoc "Result from an MCP tool call"
    @type t :: %__MODULE__{content: list()}
    defstruct content: []
  end

  defmodule McpToolCallItemError do
    @moduledoc "Error from an MCP tool call"
    @type t :: %__MODULE__{message: String.t()}
    defstruct message: ""
  end

  defmodule TodoItem do
    @moduledoc "Individual todo item"
    @type t :: %__MODULE__{
            text: String.t(),
            completed: boolean()
          }
    defstruct text: "", completed: false
  end

  # ============================================================================
  # Thread Item Types (discriminated union)
  # ============================================================================

  defmodule AgentMessageItem do
    @moduledoc "Final text response from agent"
    @type t :: %__MODULE__{
            type: :agent_message,
            id: String.t(),
            text: String.t()
          }
    defstruct type: :agent_message, id: "", text: ""
  end

  defmodule ReasoningItem do
    @moduledoc "Extended thinking/reasoning text"
    @type t :: %__MODULE__{
            type: :reasoning,
            id: String.t(),
            text: String.t()
          }
    defstruct type: :reasoning, id: "", text: ""
  end

  defmodule CommandExecutionItem do
    @moduledoc "Shell command execution"
    @type status :: :in_progress | :completed | :failed | :declined
    @type t :: %__MODULE__{
            type: :command_execution,
            id: String.t(),
            command: String.t(),
            aggregated_output: String.t() | nil,
            exit_code: integer() | nil,
            status: status()
          }
    defstruct type: :command_execution,
              id: "",
              command: "",
              aggregated_output: nil,
              exit_code: nil,
              status: :in_progress
  end

  defmodule FileChangeItem do
    @moduledoc "File modifications"
    @type status :: :in_progress | :completed | :failed
    @type t :: %__MODULE__{
            type: :file_change,
            id: String.t(),
            changes: [FileUpdateChange.t()],
            status: status()
          }
    defstruct type: :file_change, id: "", changes: [], status: :in_progress
  end

  defmodule McpToolCallItem do
    @moduledoc "MCP tool invocation"
    @type status :: :in_progress | :completed | :failed
    @type t :: %__MODULE__{
            type: :mcp_tool_call,
            id: String.t(),
            server: String.t(),
            tool: String.t(),
            arguments: map(),
            result: McpToolCallItemResult.t() | nil,
            error: McpToolCallItemError.t() | nil,
            status: status()
          }
    defstruct type: :mcp_tool_call,
              id: "",
              server: "",
              tool: "",
              arguments: %{},
              result: nil,
              error: nil,
              status: :in_progress
  end

  defmodule WebSearchItem do
    @moduledoc "Web search query"
    @type t :: %__MODULE__{
            type: :web_search,
            id: String.t(),
            query: String.t()
          }
    defstruct type: :web_search, id: "", query: ""
  end

  defmodule TodoListItem do
    @moduledoc "Task/todo list"
    @type t :: %__MODULE__{
            type: :todo_list,
            id: String.t(),
            items: [TodoItem.t()]
          }
    defstruct type: :todo_list, id: "", items: []
  end

  defmodule ErrorItem do
    @moduledoc "Error message"
    @type t :: %__MODULE__{
            type: :error,
            id: String.t(),
            message: String.t()
          }
    defstruct type: :error, id: "", message: ""
  end

  @typedoc "Union of all thread item types"
  @type thread_item ::
          AgentMessageItem.t()
          | ReasoningItem.t()
          | CommandExecutionItem.t()
          | FileChangeItem.t()
          | McpToolCallItem.t()
          | WebSearchItem.t()
          | TodoListItem.t()
          | ErrorItem.t()

  # ============================================================================
  # Thread Event Types
  # ============================================================================

  defmodule ThreadStarted do
    @moduledoc "Session has started"
    @type t :: %__MODULE__{
            type: :"thread.started",
            thread_id: String.t()
          }
    defstruct type: :"thread.started", thread_id: ""
  end

  defmodule TurnStarted do
    @moduledoc "Conversation turn has begun"
    @type t :: %__MODULE__{type: :"turn.started"}
    defstruct type: :"turn.started"
  end

  defmodule TurnCompleted do
    @moduledoc "Conversation turn has finished"
    @type t :: %__MODULE__{
            type: :"turn.completed",
            usage: Usage.t()
          }
    defstruct type: :"turn.completed", usage: %Usage{}
  end

  defmodule TurnFailed do
    @moduledoc "Turn failed with error"
    @type t :: %__MODULE__{
            type: :"turn.failed",
            error: ThreadError.t()
          }
    defstruct type: :"turn.failed", error: %ThreadError{}
  end

  defmodule StreamError do
    @moduledoc "Stream-level error or notice"
    @type t :: %__MODULE__{
            type: :error,
            message: String.t()
          }
    defstruct type: :error, message: ""
  end

  defmodule ItemStarted do
    @moduledoc "Work item has begun"
    @type t :: %__MODULE__{
            type: :"item.started",
            item: AgentCore.CliRunners.CodexSchema.thread_item()
          }
    defstruct type: :"item.started", item: nil
  end

  defmodule ItemUpdated do
    @moduledoc "Work item has progress"
    @type t :: %__MODULE__{
            type: :"item.updated",
            item: AgentCore.CliRunners.CodexSchema.thread_item()
          }
    defstruct type: :"item.updated", item: nil
  end

  defmodule ItemCompleted do
    @moduledoc "Work item has finished"
    @type t :: %__MODULE__{
            type: :"item.completed",
            item: AgentCore.CliRunners.CodexSchema.thread_item()
          }
    defstruct type: :"item.completed", item: nil
  end

  @typedoc "Union of all thread event types"
  @type thread_event ::
          ThreadStarted.t()
          | TurnStarted.t()
          | TurnCompleted.t()
          | TurnFailed.t()
          | StreamError.t()
          | ItemStarted.t()
          | ItemUpdated.t()
          | ItemCompleted.t()

  # ============================================================================
  # Decoding
  # ============================================================================

  @doc """
  Decode a JSON line into a thread event struct.

  Returns `{:ok, event}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> CodexSchema.decode_event(~s|{"type":"thread.started","thread_id":"abc123"}|)
      {:ok, %ThreadStarted{thread_id: "abc123"}}

      iex> CodexSchema.decode_event(~s|{"type":"item.completed","item":{"type":"agent_message","id":"1","text":"Hello"}}|)
      {:ok, %ItemCompleted{item: %AgentMessageItem{id: "1", text: "Hello"}}}

  """
  @spec decode_event(String.t() | binary()) :: {:ok, thread_event()} | {:error, term()}
  def decode_event(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, data} -> decode_event_map(data)
      {:error, _} = err -> err
    end
  end

  @doc """
  Decode a map (already parsed JSON) into a thread event struct.
  """
  @spec decode_event_map(map()) :: {:ok, thread_event()} | {:error, term()}
  def decode_event_map(%{"type" => type} = data) do
    case type do
      "thread.started" ->
        {:ok, %ThreadStarted{thread_id: data["thread_id"] || ""}}

      "turn.started" ->
        {:ok, %TurnStarted{}}

      "turn.completed" ->
        usage = decode_usage(data["usage"])
        {:ok, %TurnCompleted{usage: usage}}

      "turn.failed" ->
        error = decode_thread_error(data["error"])
        {:ok, %TurnFailed{error: error}}

      "error" ->
        {:ok, %StreamError{message: data["message"] || ""}}

      "item.started" ->
        case decode_item(data["item"]) do
          {:ok, item} -> {:ok, %ItemStarted{item: item}}
          error -> error
        end

      "item.updated" ->
        case decode_item(data["item"]) do
          {:ok, item} -> {:ok, %ItemUpdated{item: item}}
          error -> error
        end

      "item.completed" ->
        case decode_item(data["item"]) do
          {:ok, item} -> {:ok, %ItemCompleted{item: item}}
          error -> error
        end

      unknown ->
        {:error, {:unknown_event_type, unknown}}
    end
  end

  def decode_event_map(_), do: {:error, :missing_type}

  # ============================================================================
  # Private Decoders
  # ============================================================================

  defp decode_usage(nil), do: %Usage{}

  defp decode_usage(data) when is_map(data) do
    %Usage{
      input_tokens: data["input_tokens"] || 0,
      cached_input_tokens: data["cached_input_tokens"] || 0,
      output_tokens: data["output_tokens"] || 0
    }
  end

  defp decode_thread_error(nil), do: %ThreadError{}

  defp decode_thread_error(data) when is_map(data) do
    %ThreadError{message: data["message"] || ""}
  end

  defp decode_item(nil), do: {:error, :missing_item}

  defp decode_item(%{"type" => type} = data) do
    case type do
      "agent_message" ->
        {:ok,
         %AgentMessageItem{
           id: data["id"] || "",
           text: data["text"] || ""
         }}

      "reasoning" ->
        {:ok,
         %ReasoningItem{
           id: data["id"] || "",
           text: data["text"] || ""
         }}

      "command_execution" ->
        {:ok,
         %CommandExecutionItem{
           id: data["id"] || "",
           command: data["command"] || "",
           aggregated_output: data["aggregated_output"],
           exit_code: data["exit_code"],
           status: decode_status(data["status"])
         }}

      "file_change" ->
        changes = Enum.map(data["changes"] || [], &decode_file_change/1)

        {:ok,
         %FileChangeItem{
           id: data["id"] || "",
           changes: changes,
           status: decode_status(data["status"])
         }}

      "mcp_tool_call" ->
        {:ok,
         %McpToolCallItem{
           id: data["id"] || "",
           server: data["server"] || "",
           tool: data["tool"] || "",
           arguments: data["arguments"] || %{},
           result: decode_mcp_result(data["result"]),
           error: decode_mcp_error(data["error"]),
           status: decode_status(data["status"])
         }}

      "web_search" ->
        {:ok,
         %WebSearchItem{
           id: data["id"] || "",
           query: data["query"] || ""
         }}

      "todo_list" ->
        items = Enum.map(data["items"] || [], &decode_todo_item/1)

        {:ok,
         %TodoListItem{
           id: data["id"] || "",
           items: items
         }}

      "error" ->
        {:ok,
         %ErrorItem{
           id: data["id"] || "",
           message: data["message"] || ""
         }}

      unknown ->
        {:error, {:unknown_item_type, unknown}}
    end
  end

  defp decode_item(_), do: {:error, :invalid_item}

  defp decode_status(nil), do: :in_progress
  defp decode_status("in_progress"), do: :in_progress
  defp decode_status("completed"), do: :completed
  defp decode_status("failed"), do: :failed
  defp decode_status("declined"), do: :declined
  defp decode_status(_), do: :in_progress

  defp decode_file_change(data) when is_map(data) do
    kind =
      case data["kind"] do
        "add" -> :add
        "delete" -> :delete
        "update" -> :update
        _ -> :update
      end

    %FileUpdateChange{
      path: data["path"] || "",
      kind: kind
    }
  end

  defp decode_file_change(_), do: %FileUpdateChange{}

  defp decode_mcp_result(nil), do: nil

  defp decode_mcp_result(data) when is_map(data) do
    %McpToolCallItemResult{content: data["content"] || []}
  end

  defp decode_mcp_error(nil), do: nil

  defp decode_mcp_error(data) when is_map(data) do
    %McpToolCallItemError{message: data["message"] || ""}
  end

  defp decode_todo_item(data) when is_map(data) do
    %TodoItem{
      text: data["text"] || "",
      completed: data["completed"] || false
    }
  end

  defp decode_todo_item(_), do: %TodoItem{}
end
