defmodule LemonAgent.Types do
  @moduledoc """
  Core type definitions for the LemonAgent library.

  This module defines the data structures used for agent configuration,
  state management, tool execution, and event handling.

  ## Overview

  - `AgentTool` - Tool definition with execution function
  - `AgentToolResult` - Result returned from tool execution
  - `ToolSchemaSnapshot` - Per-run immutable tool schema snapshot
  - `AgentContext` - Context for agent conversations
  - `AgentState` - Runtime state of the agent
  - `AgentLoopConfig` - Configuration for the agent loop
  - `AgentEvent` - Events emitted during agent execution
  """

  alias LemonAi.Types.StreamOptions

  # ============================================================================
  # Thinking Level
  # ============================================================================

  @typedoc """
  Thinking/reasoning level for models that support extended reasoning.

  - `:off` - No extended thinking
  - `:auto` - Classify each user prompt with an explicitly configured small model
  - `:minimal` - Minimal reasoning output
  - `:low` - Low reasoning effort
  - `:medium` - Medium reasoning effort
  - `:high` - High reasoning effort
  - `:xhigh` - Extra high reasoning (only supported by certain OpenAI models)
  """
  @type thinking_level :: :off | :auto | :minimal | :low | :medium | :high | :xhigh

  # ============================================================================
  # Agent Message
  # ============================================================================

  @typedoc """
  Agent message type - alias for LemonAi.Types.message().

  This can be extended by applications to include custom message types
  beyond the standard user/assistant/tool_result messages.
  """
  @type agent_message :: LemonAi.Types.message()

  # ============================================================================
  # Agent Tool Result
  # ============================================================================

  defmodule AgentToolResult do
    @moduledoc """
    Result returned from tool execution.

    Contains content blocks (text/images) to be displayed, optional
    details for UI rendering or logging, and trust metadata.

    `:content` is what the model sees — it becomes the tool-result message in
    the transcript, so it should read as an answer rather than as a status
    line. `:details` is not sent to the model: it is for the UI and the logs,
    and is the right place for structured data (ids, counts, the raw response)
    that would only cost tokens in `:content`.

    `:trust` marks content the tool did not author. Anything fetched from the
    network, read from a user-supplied file, or returned by a third-party API
    is `:untrusted`, which tells downstream rendering that instructions inside
    it must not be obeyed. `LemonAgent.Security.ExternalContent` wraps such
    content with the right framing and metadata — use it rather than setting
    the field by hand.

    `:is_error` marks a result that reports a failure (a denied approval, a
    timed-out command) while keeping structured `:details`. The loop sends it
    to the model as an error tool result, exactly like `{:error, reason}`.
    """
    @type content_block :: LemonAi.Types.TextContent.t() | LemonAi.Types.ImageContent.t()
    @type t :: %__MODULE__{
            content: [content_block()],
            details: any(),
            trust: LemonAi.Types.trust_level(),
            is_error: boolean()
          }
    defstruct content: [], details: nil, trust: :trusted, is_error: false
  end

  # ============================================================================
  # Agent Tool
  # ============================================================================

  defmodule AgentTool do
    @moduledoc """
    A tool the agent loop can call: a schema the model sees plus the function
    that runs when it calls it.

    This is the unit every tool in the platform reduces to, whether it is a
    built-in, a tool discovered from an external MCP server, or one contributed
    at runtime by an app the platform does not know about (see
    `LemonAgent.ToolRegistry`).

    ## The shape

      * `:name` — what the model calls. Stable, lowercase, `snake_case`; it is
        matched against the model's tool call after whitespace normalisation,
        and it is the key everything else in the platform uses. Renaming one
        invalidates prompts and cached tool schemas, so treat it as an
        identity.
      * `:description` — what the model reads to decide whether to call it.
        This is prompt text, and it is the main lever on whether the tool gets
        used correctly; say what the tool does, when to use it and what its
        limits are.
      * `:parameters` — a JSON Schema object (`"type" => "object"` with
        `"properties"` and `"required"`), passed to the provider as-is. String
        keys, not atoms.
      * `:label` — a short human-readable name for UI display. Never shown to
        the model.
      * `:execute` — the function below.
      * `:parallel_safe` — opt in to overlapping calls in the same tool batch.
        Defaults to `false`; mutations and tools with ordering dependencies
        must remain sequential. Sequential calls are barriers between parallel
        groups, even when `max_tool_concurrency` is unbounded.
      * `:timeout_ms` — execution deadline override in milliseconds. `nil` inherits
        the loop default (300,000 ms); `:infinity` exempts tools that own their
        deadline or legitimately wait indefinitely.

    ## The execute function

    It is called as `execute.(tool_call_id, params, signal, on_update)`:

      * `tool_call_id` — this invocation's id, for correlating events.
      * `params` — the arguments the model produced, decoded from JSON, so
        **string keys and model-supplied values**. Validate them; a model will
        eventually send a missing field or the wrong type, and a clear
        `{:error, message}` teaches it to retry correctly.
      * `signal` — an abort signal (see `LemonAgent.AbortSignal`), or `nil`.
        Long-running tools should check it and return early; ignoring it means
        a cancelled run keeps working.
      * `on_update` — a one-argument callback taking a partial
        `AgentToolResult`, or `nil`. Calling it pushes a streaming update to
        the UI. It is fire-and-forget and always returns `:ok`.

    Return an `AgentToolResult`, `{:ok, result}` (equivalent), or
    `{:error, reason}`, which the loop turns into an error result the model can
    read and react to. Anything else is treated as an error.

    The loop wraps execution in `try`, so a raise or throw becomes an error
    result rather than killing the run — but the model then gets an exception
    message instead of an explanation. Handle your own failures: a tool that is
    not configured should say so in its result, not raise.

    ## The module convention

    A tool lives in a module exposing `tool/1` (options) and `tool/2` (cwd plus
    options) that build the struct. Both are expected — consumers that have a
    working directory call `tool/2`, those that do not call `tool/1` — and the
    usual definition is `def tool(_cwd, opts), do: tool(opts)`. Building the
    struct on each call rather than at compile time is what lets the
    description and parameters reflect current configuration.

        defmodule MyApp.Tools.Greet do
          alias LemonAgent.Types.{AgentTool, AgentToolResult}
          alias LemonAi.Types.TextContent

          @spec tool(keyword()) :: AgentTool.t()
          def tool(_opts \\\\ []) do
            %AgentTool{
              name: "greet",
              label: "Greet",
              description: "Greet someone by name.",
              parameters: %{
                "type" => "object",
                "properties" => %{
                  "name" => %{"type" => "string", "description" => "Who to greet"}
                },
                "required" => ["name"]
              },
              execute: &execute(&1, &2, &3, &4)
            }
          end

          def tool(_cwd, opts), do: tool(opts)

          def execute(_id, %{"name" => name}, _signal, _on_update) when is_binary(name) do
            %AgentToolResult{content: [%TextContent{text: "Hello, " <> name <> "!"}]}
          end

          def execute(_id, _params, _signal, _on_update) do
            {:error, "Missing required parameter: name"}
          end
        end
    """
    @type on_update :: (LemonAgent.Types.AgentToolResult.t() -> :ok)
    @type execute_fn ::
            (tool_call_id :: String.t(),
             params :: map(),
             signal :: reference() | nil,
             on_update :: on_update() | nil ->
               LemonAgent.Types.AgentToolResult.t()
               | {:ok, LemonAgent.Types.AgentToolResult.t()}
               | {:error, term()})
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            parameters: map(),
            label: String.t(),
            parallel_safe: boolean(),
            timeout_ms: pos_integer() | :infinity | nil,
            execute: execute_fn() | nil
          }
    defstruct name: "",
              description: "",
              parameters: %{},
              label: "",
              parallel_safe: false,
              timeout_ms: nil,
              execute: nil
  end

  # ============================================================================
  # Tool Schema Snapshot
  # ============================================================================

  defmodule ToolSchemaSnapshot do
    @moduledoc """
    Immutable tool schema snapshot used for one agent loop run.
    """

    @type t :: %__MODULE__{
            id: String.t(),
            tools: [LemonAgent.Types.AgentTool.t()],
            tool_names: [String.t()],
            fingerprint: String.t(),
            created_at_ms: integer()
          }
    defstruct id: "",
              tools: [],
              tool_names: [],
              fingerprint: "",
              created_at_ms: 0

    @doc "Build a snapshot from the currently executable tool list."
    @spec new([LemonAgent.Types.AgentTool.t()]) :: t()
    def new(tools) when is_list(tools) do
      tool_names = Enum.map(tools, & &1.name)
      fingerprint = fingerprint(tools)

      %__MODULE__{
        id: "tool_schema_" <> fingerprint <> "_" <> unique_suffix(),
        tools: tools,
        tool_names: tool_names,
        fingerprint: fingerprint,
        created_at_ms: System.system_time(:millisecond)
      }
    end

    @doc """
    Schema-only copy for event subscribers, with every tool's `execute` set to
    `nil`. Execute closures capture their builder's options, so an executable
    snapshot grows with each tool's environment and can exceed subscriber
    delivery limits. The run itself always executes from the full snapshot.
    """
    @spec without_executors(t()) :: t()
    def without_executors(%__MODULE__{tools: tools} = snapshot) do
      %{snapshot | tools: Enum.map(tools, &%{&1 | execute: nil})}
    end

    defp fingerprint(tools) do
      tools
      |> Enum.map(fn tool -> {tool.name, tool.description, tool.parameters} end)
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)
    end

    defp unique_suffix do
      System.unique_integer([:positive, :monotonic])
      |> Integer.to_string(36)
      |> String.downcase()
    end
  end

  # ============================================================================
  # Agent Context
  # ============================================================================

  defmodule AgentContext do
    @moduledoc """
    Context for agent conversations.

    Contains the system prompt, message history, and available tools.
    Similar to LemonAi.Types.Context but uses AgentTool and agent_message.
    """
    @type t :: %__MODULE__{
            system_prompt: String.t() | nil,
            messages: [LemonAgent.Types.agent_message()],
            tools: [LemonAgent.Types.AgentTool.t()]
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
    - `budget_limits` - Canonical cumulative run/session token and dollar caps
    - `budget_usage` - Session spending ledger, retained when history is cleared
    - `run_usage` - Spending in the current prompt (reset only for a new prompt)
    """
    @type t :: %__MODULE__{
            system_prompt: String.t(),
            model: LemonAi.Types.Model.t(),
            thinking_level: LemonAgent.Types.thinking_level(),
            tools: [LemonAgent.Types.AgentTool.t()],
            messages: [LemonAgent.Types.agent_message()],
            budget_limits: map(),
            budget_usage: LemonAgent.Budget.usage(),
            run_usage: LemonAgent.Budget.usage(),
            is_streaming: boolean(),
            stream_message: LemonAgent.Types.agent_message() | nil,
            pending_tool_calls: MapSet.t(String.t()),
            error: String.t() | nil
          }
    defstruct system_prompt: "",
              model: nil,
              thinking_level: :off,
              tools: [],
              messages: [],
              budget_limits: %{},
              budget_usage: %{tokens: 0, cost_usd: 0.0},
              run_usage: %{tokens: 0, cost_usd: 0.0},
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
    - `get_model` - Reads the active model before each response, including tool-driven switches
    - `stream_options_model` - Owner of supplied options; nil means `model`. Rebinding
      happens before classification or streaming, even when `model` is already selected.
    - `resolve_stream_options` - Rebuilds destination options after a live model/provider switch
    - `resolve_thinking` - Resolves auto to concrete effort in the loop task, once per user prompt
    - `thinking_prompt` - Last classified user-prompt marker, retained across continuation
    - `resolved_thinking` - Concrete auto selection, reclamped without reclassifying on model switches
    - `on_thinking_resolved` - Internal cache callback; does not publish classifier events
    - `get_steering_messages` - Returns messages to inject mid-run for steering
    - `has_steering_messages` - Non-consuming queue peek used between tool calls
    - `get_follow_up_messages` - Returns follow-up messages after agent would stop
    - `max_tool_concurrency` - Max concurrent tool calls (default 8; `nil` uses the default, `:infinity` opts out)
    - `max_tool_turns` - Max assistant turns that may execute tools before terminal fallback
    - `max_retries` - Maximum transient provider retries per response (default: 3; 0 disables)
    - `retry_base_delay_ms` - Initial exponential retry delay (default: 2,000ms)
    - `retry_max_delay_ms` - Maximum retry delay (default: 30,000ms)
    - `tool_timeout_ms` - Per-tool task deadline (default 300,000 ms; `nil` uses the default, `:infinity` opts out); tools may declare their own `timeout_ms`
    - `tool_task_supervisor` - Task supervisor used to run tools (defaults to `LemonAgent.ToolTaskSupervisor`)
    - `intent_tracing` - Inject optional provider-only `i` intent (default true)
    - `tool_schema_snapshot` - Per-run snapshot used for provider schemas and tool execution
    - `budget_limits` - Canonical cumulative caps; all nil/omitted disables accounting
    - `budget_usage` - Initial cumulative session usage
    - `budget` - Budget state, including run totals when continuing a prompt
    - `stream_options` - Options for streaming requests
    - `stream_fn` - Custom stream function (defaults to LemonAi.stream_simple/3)
    """
    @type convert_to_llm_fn ::
            ([LemonAgent.Types.agent_message()] ->
               [LemonAi.Types.message()] | {:ok, [LemonAi.Types.message()]} | {:error, term()})
    @type transform_context_fn ::
            ([LemonAgent.Types.agent_message()], signal :: reference() | nil ->
               [LemonAgent.Types.agent_message()]
               | {:ok, [LemonAgent.Types.agent_message()]}
               | {:error, term()})
    @type get_api_key_fn :: (provider :: String.t() -> String.t() | nil)
    @type get_model_fn :: (-> LemonAi.Types.Model.t())
    @type resolve_stream_options_fn ::
            (LemonAi.Types.Model.t(), LemonAi.Types.Model.t(), LemonAi.Types.StreamOptions.t() ->
               LemonAi.Types.StreamOptions.t())
    @type resolve_thinking_fn ::
            (LemonAi.Types.Model.t(), LemonAgent.Types.agent_message(), reference() | nil ->
               {:ok, LemonAi.Types.StreamOptions.thinking_level() | nil} | {:error, :aborted})
    @type on_thinking_resolved_fn ::
            (term(), LemonAi.Types.StreamOptions.thinking_level() | nil -> term())
    @type get_steering_messages_fn :: (-> [LemonAgent.Types.agent_message()])
    @type has_steering_messages_fn :: (-> boolean())
    @type get_follow_up_messages_fn :: (-> [LemonAgent.Types.agent_message()])
    @type stream_fn ::
            (LemonAi.Types.Model.t(),
             LemonAi.Types.Context.t(),
             LemonAi.Types.StreamOptions.t() ->
               {:ok, LemonAi.EventStream.t()} | LemonAi.EventStream.t() | {:error, term()})

    @type t :: %__MODULE__{
            model: LemonAi.Types.Model.t(),
            convert_to_llm: convert_to_llm_fn(),
            transform_context: transform_context_fn() | nil,
            get_api_key: get_api_key_fn() | nil,
            get_model: get_model_fn() | nil,
            resolve_stream_options: resolve_stream_options_fn() | nil,
            resolve_thinking: resolve_thinking_fn() | nil,
            thinking_prompt: term() | nil,
            resolved_thinking: LemonAi.Types.StreamOptions.thinking_level() | nil,
            on_thinking_resolved: on_thinking_resolved_fn() | nil,
            get_steering_messages: get_steering_messages_fn() | nil,
            has_steering_messages: has_steering_messages_fn() | nil,
            get_follow_up_messages: get_follow_up_messages_fn() | nil,
            max_tool_concurrency: pos_integer() | :infinity | nil,
            max_tool_turns: pos_integer() | :infinity | nil,
            max_retries: non_neg_integer(),
            retry_base_delay_ms: non_neg_integer(),
            retry_max_delay_ms: non_neg_integer(),
            tool_timeout_ms: pos_integer() | :infinity | nil,
            tool_task_supervisor: Supervisor.supervisor() | nil,
            intent_tracing: boolean(),
            tool_schema_snapshot: LemonAgent.Types.ToolSchemaSnapshot.t() | nil,
            budget_limits: map() | nil,
            budget_usage: LemonAgent.Budget.usage() | nil,
            budget: LemonAgent.Budget.t() | nil,
            stream_options: LemonAi.Types.StreamOptions.t(),
            stream_options_model: LemonAi.Types.Model.t() | nil,
            stream_fn: stream_fn() | nil
          }
    defstruct model: nil,
              convert_to_llm: nil,
              transform_context: nil,
              get_api_key: nil,
              get_model: nil,
              resolve_stream_options: nil,
              resolve_thinking: nil,
              thinking_prompt: nil,
              resolved_thinking: nil,
              on_thinking_resolved: nil,
              get_steering_messages: nil,
              has_steering_messages: nil,
              get_follow_up_messages: nil,
              max_tool_concurrency: 8,
              max_tool_turns: 25,
              max_retries: 3,
              retry_base_delay_ms: 2_000,
              retry_max_delay_ms: 30_000,
              tool_timeout_ms: 300_000,
              tool_task_supervisor: nil,
              intent_tracing: true,
              tool_schema_snapshot: nil,
              budget_limits: nil,
              budget_usage: nil,
              budget: nil,
              stream_options: %StreamOptions{},
              stream_options_model: nil,
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
  - `{:tool_schema_snapshot, snapshot}` - Tool schema was frozen for this run;
    schema-only, so its tools' `execute` is `nil`
  - `{:loop_state_transition, from, to, metadata}` - Loop lifecycle state changed
  - `{:agent_end, messages}` - Agent run has ended with final messages

  ## Turn Lifecycle
  A turn is one assistant response plus any tool calls/results.
  - `{:turn_start}` - New turn has started
  - `{:turn_end, message, tool_results}` - Turn completed
  - `{:loop_budget_exhausted, details}` - Tool loop budget exhausted with terminal fallback
  - `{:provider_retry, details}` - Transient provider retry scheduled, including delay and attempt
  - `{:provider_retry_end, details}` - Retry sequence succeeded, failed, or was canceled
  - `{:usage_budget_updated, totals}` - Latest run and cumulative session spending
  - `{:budget_warning, details}` - Cost cap cannot reliably price the active model
  - `{:budget_exceeded, details}` - Actionable cumulative cap stop, followed by terminal error

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
          | {:tool_schema_snapshot, snapshot :: LemonAgent.Types.ToolSchemaSnapshot.t()}
          | {:loop_state_transition, from :: atom() | nil, to :: atom(), metadata :: map()}
          | {:agent_end, messages :: [agent_message()]}
          | {:turn_start}
          | {:turn_end, message :: agent_message(),
             tool_results :: [LemonAi.Types.ToolResultMessage.t()]}
          | {:loop_budget_exhausted, details :: map()}
          | {:provider_retry, details :: map()}
          | {:provider_retry_end, details :: map()}
          | {:usage_budget_updated,
             %{run_usage: LemonAgent.Budget.usage(), session_usage: LemonAgent.Budget.usage()}}
          | {:budget_exceeded, details :: LemonAgent.Budget.details()}
          | {:budget_warning, details :: %{message: String.t()}}
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
