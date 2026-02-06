defmodule AgentCore.Types do
  @moduledoc """
  Core type definitions for the AgentCore library.

  This module defines the data structures used for agent configuration,
  state management, tool execution, and event handling.

  ## Overview

  - `AgentTool` - Tool definition with execution function
  - `AgentToolResult` - Result returned from tool execution
  - `AgentContext` - Context for agent conversations
  - `AgentState` - Runtime state of the agent
  - `AgentLoopConfig` - Configuration for the agent loop
  - `AgentEvent` - Events emitted during agent execution
  """

  alias Ai.Types.StreamOptions

  # ============================================================================
  # Thinking Level
  # ============================================================================

  @typedoc """
  Thinking/reasoning level for models that support extended reasoning.

  - `:off` - No extended thinking
  - `:minimal` - Minimal reasoning output
  - `:low` - Low reasoning effort
  - `:medium` - Medium reasoning effort
  - `:high` - High reasoning effort
  - `:xhigh` - Extra high reasoning (only supported by certain OpenAI models)
  """
  @type thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh

  # ============================================================================
  # Agent Message
  # ============================================================================

  @typedoc """
  Agent message type - alias for Ai.Types.message().

  This can be extended by applications to include custom message types
  beyond the standard user/assistant/tool_result messages.
  """
  @type agent_message :: Ai.Types.message()

  # ============================================================================
  # Agent Tool Result
  # ============================================================================

  defmodule AgentToolResult do
    @moduledoc """
    Result returned from tool execution.

    Contains content blocks (text/images) to be displayed and optional
    details for UI rendering or logging.
    """
    @type content_block :: Ai.Types.TextContent.t() | Ai.Types.ImageContent.t()
    @type t :: %__MODULE__{
            content: [content_block()],
            details: any()
          }
    defstruct content: [], details: nil
  end

  # ============================================================================
  # Agent Tool
  # ============================================================================

  defmodule AgentTool do
    @moduledoc """
    Tool definition with execution function for agent use.

    Extends the base Ai.Types.Tool concept with:
    - A human-readable label for UI display
    - An execute function that performs the tool's action

    ## Execute Function

    The execute function receives:
    - `tool_call_id` - Unique identifier for this tool invocation
    - `params` - Parameters parsed from the tool call
    - `signal` - Abort signal for cancellation (can be nil)
    - `on_update` - Callback for streaming partial results

    Returns an `AgentToolResult` with content and details.
    """
    @type on_update :: (AgentCore.Types.AgentToolResult.t() -> :ok)
    @type execute_fn ::
            (tool_call_id :: String.t(),
             params :: map(),
             signal :: reference() | nil,
             on_update :: on_update() | nil ->
               AgentCore.Types.AgentToolResult.t()
               | {:ok, AgentCore.Types.AgentToolResult.t()}
               | {:error, term()})
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            parameters: map(),
            label: String.t(),
            execute: execute_fn()
          }
    defstruct name: "",
              description: "",
              parameters: %{},
              label: "",
              execute: nil
  end

  # ============================================================================
  # Agent Context
  # ============================================================================

  defmodule AgentContext do
    @moduledoc """
    Context for agent conversations.

    Contains the system prompt, message history, and available tools.
    Similar to Ai.Types.Context but uses AgentTool and agent_message.
    """
    @type t :: %__MODULE__{
            system_prompt: String.t() | nil,
            messages: [AgentCore.Types.agent_message()],
            tools: [AgentCore.Types.AgentTool.t()]
          }
    defstruct system_prompt: nil, messages: [], tools: []

    @doc "Create a new empty agent context"
    def new(opts \\ []) do
      %__MODULE__{
        system_prompt: Keyword.get(opts, :system_prompt),
        messages: Keyword.get(opts, :messages, []),
        tools: Keyword.get(opts, :tools, [])
      }
    end
  end

  # ============================================================================
  # Agent State
  # ============================================================================

  defmodule AgentState do
    @moduledoc """
    Runtime state of the agent containing all configuration and conversation data.

    ## Fields

    - `system_prompt` - The system prompt for the agent
    - `model` - The AI model being used
    - `thinking_level` - Level of extended reasoning
    - `tools` - Available tools for the agent
    - `messages` - Conversation history (can include custom message types)
    - `is_streaming` - Whether currently streaming a response
    - `stream_message` - The message being streamed (if any)
    - `pending_tool_calls` - Set of tool call IDs awaiting execution
    - `error` - Error message if the agent encountered an error
    """
    @type t :: %__MODULE__{
            system_prompt: String.t(),
            model: Ai.Types.Model.t(),
            thinking_level: AgentCore.Types.thinking_level(),
            tools: [AgentCore.Types.AgentTool.t()],
            messages: [AgentCore.Types.agent_message()],
            is_streaming: boolean(),
            stream_message: AgentCore.Types.agent_message() | nil,
            pending_tool_calls: MapSet.t(String.t()),
            error: String.t() | nil
          }
    defstruct system_prompt: "",
              model: nil,
              thinking_level: :off,
              tools: [],
              messages: [],
              is_streaming: false,
              stream_message: nil,
              pending_tool_calls: MapSet.new(),
              error: nil
  end

  # ============================================================================
  # Agent Loop Config
  # ============================================================================

  defmodule AgentLoopConfig do
    @moduledoc """
    Configuration for the agent loop.

    ## Required Fields

    - `model` - The AI model to use
    - `convert_to_llm` - Function to convert agent messages to LLM-compatible messages

    ## Optional Fields

    - `transform_context` - Transform applied to context before `convert_to_llm`
      (useful for context window management, injecting external context)
    - `get_api_key` - Resolves API key dynamically for each LLM call
      (useful for short-lived OAuth tokens)
    - `get_steering_messages` - Returns messages to inject mid-run for steering
    - `get_follow_up_messages` - Returns follow-up messages after agent would stop
    - `stream_options` - Options for streaming requests
    - `stream_fn` - Custom stream function (defaults to Ai.stream_simple/3)
    """
    @type convert_to_llm_fn ::
            ([AgentCore.Types.agent_message()] ->
               [Ai.Types.message()] | {:ok, [Ai.Types.message()]} | {:error, term()})
    @type transform_context_fn ::
            ([AgentCore.Types.agent_message()], signal :: reference() | nil ->
               [AgentCore.Types.agent_message()]
               | {:ok, [AgentCore.Types.agent_message()]}
               | {:error, term()})
    @type get_api_key_fn :: (provider :: String.t() -> String.t() | nil)
    @type get_steering_messages_fn :: (-> [AgentCore.Types.agent_message()])
    @type get_follow_up_messages_fn :: (-> [AgentCore.Types.agent_message()])
    @type stream_fn ::
            (Ai.Types.Model.t(), Ai.Types.Context.t(), Ai.Types.StreamOptions.t() ->
               {:ok, Ai.EventStream.t()} | Ai.EventStream.t() | {:error, term()})

    @type t :: %__MODULE__{
            model: Ai.Types.Model.t(),
            convert_to_llm: convert_to_llm_fn(),
            transform_context: transform_context_fn() | nil,
            get_api_key: get_api_key_fn() | nil,
            get_steering_messages: get_steering_messages_fn() | nil,
            get_follow_up_messages: get_follow_up_messages_fn() | nil,
            stream_options: Ai.Types.StreamOptions.t(),
            stream_fn: stream_fn() | nil
          }
    defstruct model: nil,
              convert_to_llm: nil,
              transform_context: nil,
              get_api_key: nil,
              get_steering_messages: nil,
              get_follow_up_messages: nil,
              stream_options: %StreamOptions{},
              stream_fn: nil
  end

  # ============================================================================
  # Agent Events
  # ============================================================================

  @typedoc """
  Events emitted by the Agent for UI updates and lifecycle tracking.

  These events provide fine-grained information about messages, turns,
  and tool executions.

  ## Agent Lifecycle
  - `{:agent_start}` - Agent run has started
  - `{:agent_end, messages}` - Agent run has ended with final messages

  ## Turn Lifecycle
  A turn is one assistant response plus any tool calls/results.
  - `{:turn_start}` - New turn has started
  - `{:turn_end, message, tool_results}` - Turn completed

  ## Message Lifecycle
  Emitted for user, assistant, and tool_result messages.
  - `{:message_start, message}` - Message processing started
  - `{:message_update, message, assistant_event}` - Streaming update (assistant only)
  - `{:message_end, message}` - Message processing complete

  ## Tool Execution Lifecycle
  - `{:tool_execution_start, id, name, args}` - Tool execution started
  - `{:tool_execution_update, id, name, args, partial_result}` - Streaming partial result
  - `{:tool_execution_end, id, name, result, is_error}` - Tool execution complete

  ## Error Handling
  - `{:error, reason, partial_state}` - Agent loop errored
  """
  @type agent_event ::
          {:agent_start}
          | {:agent_end, messages :: [agent_message()]}
          | {:turn_start}
          | {:turn_end, message :: agent_message(),
             tool_results :: [Ai.Types.ToolResultMessage.t()]}
          | {:message_start, message :: agent_message()}
          | {:message_update, message :: agent_message(), assistant_event :: term()}
          | {:message_end, message :: agent_message()}
          | {:tool_execution_start, id :: String.t(), name :: String.t(), args :: map()}
          | {:tool_execution_update, id :: String.t(), name :: String.t(), args :: map(),
             partial_result :: AgentToolResult.t()}
          | {:tool_execution_end, id :: String.t(), name :: String.t(),
             result :: AgentToolResult.t(), is_error :: boolean()}
          | {:error, reason :: term(), partial_state :: term()}
end
