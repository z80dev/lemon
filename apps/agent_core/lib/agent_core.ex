defmodule AgentCore do
  @moduledoc """
  High-level agent execution library built on top of the `Ai` library.

  AgentCore provides a complete framework for building AI agents that can:

  - Execute multi-turn conversations with tool use
  - Stream responses with fine-grained event notifications
  - Handle complex agentic loops (prompt -> response -> tool calls -> results -> repeat)
  - Manage agent state and lifecycle as a GenServer

  ## Relationship to the Ai Library

  The `Ai` library provides low-level LLM API abstractions - streaming, message types,
  provider implementations, etc. AgentCore builds on top of this to provide:

  - **Agent Loop** - The core loop that handles tool execution and multi-turn conversations
  - **Agent GenServer** - A supervised process that manages agent state and handles concurrency
  - **Event System** - Rich events for UI integration and progress tracking
  - **Extended Types** - Agent-specific types like `AgentTool` with execute functions

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                         Your Application                        │
  └─────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  AgentCore                                                      │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
  │  │    Agent    │  │    Loop     │  │  EventStream / Types    │ │
  │  │  (GenServer)│  │ (core logic)│  │  (events & structures)  │ │
  │  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  Ai Library                                                     │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
  │  │   stream/3  │  │   Types     │  │      Providers          │ │
  │  │ complete/3  │  │  Context    │  │ (Anthropic, OpenAI,...) │ │
  │  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Quick Start

  ### Using the Agent GenServer (recommended)

  The Agent GenServer provides a supervised, stateful interface with event subscriptions:

      # Start an agent
      {:ok, agent} = AgentCore.new_agent(
        model: my_model,
        system_prompt: "You are a helpful assistant.",
        tools: [read_file_tool, write_file_tool]
      )

      # Subscribe to events
      AgentCore.subscribe(agent, self())

      # Send a prompt (non-blocking)
      :ok = AgentCore.prompt(agent, "Hello, can you help me?")

      # Receive events as they arrive
      receive do
        {:agent_event, {:message_start, msg}} ->
          IO.puts("Assistant started responding...")

        {:agent_event, {:message_update, msg, delta}} ->
          IO.write(delta)

        {:agent_event, {:tool_execution_start, id, name, args}} ->
          IO.puts("Executing tool: \#{name}")

        {:agent_event, {:agent_end, messages}} ->
          IO.puts("Agent finished with \#{length(messages)} messages")
      end

      # Or wait for the agent to finish
      :ok = AgentCore.wait_for_idle(agent)
      state = AgentCore.get_state(agent)

  ### Using the Loop directly (advanced)

  For more control, you can use the Loop module directly:

      alias AgentCore.{Loop, Types}

      # Create initial state
      state = %Types.AgentState{
        system_prompt: "You are helpful",
        model: my_model,
        tools: my_tools,
        messages: []
      }

      # Create config with required callbacks
      config = %Types.AgentLoopConfig{
        model: my_model,
        convert_to_llm: &my_convert_fn/1
      }

      # Run the loop (returns a stream of events)
      state
      |> Loop.agent_loop(config, user_message)
      |> Enum.each(fn event ->
        IO.inspect(event)
      end)

  ## Events

  AgentCore emits detailed events throughout agent execution:

  ### Agent Lifecycle
  - `{:agent_start}` - Agent run has begun
  - `{:agent_end, messages}` - Agent run completed with final message list

  ### Turn Lifecycle
  - `{:turn_start}` - New turn (LLM call) has started
  - `{:turn_end, message, tool_results}` - Turn completed

  ### Message Lifecycle
  - `{:message_start, message}` - Message processing started
  - `{:message_update, message, delta}` - Streaming update
  - `{:message_end, message}` - Message processing complete

  ### Tool Execution
  - `{:tool_execution_start, id, name, args}` - Tool started
  - `{:tool_execution_update, id, name, args, partial}` - Partial result
  - `{:tool_execution_end, id, name, result, is_error}` - Tool completed

  ## Configuration

  The `AgentLoopConfig` struct controls agent behavior:

      %AgentCore.Types.AgentLoopConfig{
        # Required: the model to use
        model: my_model,

        # Required: convert agent messages to LLM format
        convert_to_llm: fn messages -> {:ok, llm_messages} end,

        # Optional: transform context before each LLM call
        # (useful for context window management)
        transform_context: fn messages, signal -> {:ok, transformed} end,

        # Optional: get API key dynamically (for OAuth tokens)
        get_api_key: fn provider -> api_key end,

        # Optional: inject steering messages mid-run
        get_steering_messages: fn -> [] end,

        # Optional: add follow-up prompts to keep agent running
        get_follow_up_messages: fn -> [] end,

        # Optional: streaming options
        stream_options: %Ai.Types.StreamOptions{}
      }

  ## Modules

  - `AgentCore.Agent` - GenServer for stateful agent management
  - `AgentCore.Loop` - Core agentic loop implementation
  - `AgentCore.EventStream` - Async event producer/consumer
  - `AgentCore.Types` - Type definitions and structs
  - `AgentCore.Proxy` - Stream proxy for event transformation
  """

  alias AgentCore.Types.{AgentContext, AgentTool, AgentToolResult}

  # ============================================================================
  # Type Aliases
  # ============================================================================

  @typedoc "Reference to an Agent GenServer process"
  @type agent :: AgentCore.Agent.t()

  @typedoc "Events emitted during agent execution"
  @type event :: AgentCore.Types.agent_event()

  @typedoc "Agent state containing messages, tools, and configuration"
  @type state :: AgentCore.Types.AgentState.t()

  @typedoc "Context for agent conversations"
  @type context :: AgentCore.Types.AgentContext.t()

  @typedoc "Configuration for the agent loop"
  @type config :: AgentCore.Types.AgentLoopConfig.t()

  @typedoc "Tool definition with execute function"
  @type tool :: AgentCore.Types.AgentTool.t()

  @typedoc "Result from tool execution"
  @type tool_result :: AgentCore.Types.AgentToolResult.t()

  @typedoc "Thinking/reasoning level"
  @type thinking_level :: AgentCore.Types.thinking_level()

  # ============================================================================
  # Agent GenServer Delegates
  # ============================================================================

  @doc """
  Start a new Agent GenServer.

  This is an alias for `AgentCore.Agent.start_link/1`.

  ## Options

    * `:model` - (required) The AI model to use (`Ai.Types.Model.t()`)
    * `:system_prompt` - System prompt for the agent (default: "")
    * `:tools` - List of `AgentTool` structs (default: [])
    * `:thinking_level` - Extended reasoning level (default: `:off`)
    * `:convert_to_llm` - Function to convert agent messages to LLM format
    * `:transform_context` - Optional context transformation function
    * `:get_api_key` - Optional function to resolve API keys dynamically
    * `:stream_options` - Options for streaming requests

  ## Examples

      {:ok, agent} = AgentCore.new_agent(
        model: claude_model,
        system_prompt: "You are a helpful coding assistant.",
        tools: [read_tool, write_tool, execute_tool]
      )
  """
  @spec new_agent(keyword()) :: GenServer.on_start()
  def new_agent(opts) do
    AgentCore.Agent.start_link(normalize_agent_opts(opts))
  end

  @doc """
  Start and link an Agent GenServer.

  See `new_agent/1` for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    AgentCore.Agent.start_link(normalize_agent_opts(opts))
  end

  @doc """
  Send a prompt to the agent.

  This starts a new agent run. The agent will process the prompt,
  potentially make tool calls, and continue until it completes or
  is aborted.

  ## Examples

      :ok = AgentCore.prompt(agent, "What files are in the current directory?")
  """
  @spec prompt(agent(), String.t() | Types.agent_message() | list(Types.agent_message())) ::
          :ok | {:error, term()}
  defdelegate prompt(agent, message), to: AgentCore.Agent

  @doc """
  Continue a paused agent run.

  Use this after handling required user input or approval.
  """
  @spec continue(agent()) :: :ok | {:error, term()}
  defdelegate continue(agent), to: AgentCore.Agent

  @doc """
  Abort the current agent run.

  This signals cancellation to any running tool executions and stops
  the agent loop.
  """
  @spec abort(agent()) :: :ok
  defdelegate abort(agent), to: AgentCore.Agent

  @doc """
  Subscribe to agent events.

  The subscriber will receive messages in the format:

      {:agent_event, event}

  where `event` is one of the agent event types.

  ## Examples

      AgentCore.subscribe(agent, self())

      receive do
        {:agent_event, {:agent_end, messages}} ->
          IO.puts("Done!")
      end
  """
  @spec subscribe(agent(), pid()) :: (-> :ok)
  defdelegate subscribe(agent, subscriber), to: AgentCore.Agent

  @doc """
  Block until the agent is idle (not processing).

  ## Options

    * `:timeout` - How long to wait (default: `:infinity`)

  ## Examples

      :ok = AgentCore.wait_for_idle(agent)
      state = AgentCore.get_state(agent)
  """
  @spec wait_for_idle(agent(), keyword() | timeout()) :: :ok | {:error, :timeout}
  defdelegate wait_for_idle(agent, timeout \\ :infinity), to: AgentCore.Agent

  @doc """
  Reset the agent state, clearing all messages.
  """
  @spec reset(agent()) :: :ok
  defdelegate reset(agent), to: AgentCore.Agent

  @doc """
  Get the current agent state.

  Returns the full `AgentState` struct including messages, tools,
  streaming status, and any errors.
  """
  @spec get_state(agent()) :: state()
  defdelegate get_state(agent), to: AgentCore.Agent

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_agent_opts(opts) do
    {initial_state, opts} = Keyword.pop(opts, :initial_state, %{})
    initial_state = normalize_initial_state(initial_state)

    initial_state_overrides =
      opts
      |> Keyword.take([:system_prompt, :model, :thinking_level, :tools, :messages])
      |> Enum.into(%{})

    merged_initial_state = Map.merge(initial_state, initial_state_overrides)

    opts
    |> Keyword.drop([:system_prompt, :model, :thinking_level, :tools, :messages])
    |> Keyword.put(:initial_state, merged_initial_state)
  end

  defp normalize_initial_state(state) when is_list(state), do: Enum.into(state, %{})
  defp normalize_initial_state(state) when is_map(state), do: state
  defp normalize_initial_state(_state), do: %{}

  # ============================================================================
  # Loop Delegates
  # ============================================================================

  @doc """
  Run the agent loop starting with prompts.

  This is the core function that implements the agentic loop:
  1. Send message to LLM
  2. Process response
  3. Execute any tool calls
  4. If tool calls were made, loop back to step 1
  5. When no tool calls, emit agent_end and return

  Returns a `Stream` that emits events as they occur.

  ## Parameters

    * `prompts` - List of messages to start with
    * `context` - AgentContext with system prompt and tools
    * `config` - AgentLoopConfig with model and callbacks
    * `stream_fn` - Optional custom stream function (default: Ai.stream/3)

  ## Examples

      context
      |> AgentCore.agent_loop([user_msg], config)
      |> Enum.each(&handle_event/1)
  """
  @spec agent_loop([AgentCore.Types.agent_message()], context(), config(), function() | nil) ::
          Enumerable.t()
  def agent_loop(prompts, context, config, stream_fn \\ nil) do
    AgentCore.Loop.stream(prompts, context, config, stream_fn)
  end

  @doc """
  Continue the agent loop without adding a new user message.

  Used for continuing after tool results have been added to context.

  ## Parameters

    * `context` - AgentContext with messages including tool results
    * `config` - AgentLoopConfig with model and callbacks
    * `stream_fn` - Optional custom stream function
  """
  @spec agent_loop_continue(context(), config(), function() | nil) :: Enumerable.t()
  def agent_loop_continue(context, config, stream_fn \\ nil) do
    AgentCore.Loop.stream_continue(context, config, stream_fn)
  end

  # ============================================================================
  # Convenience Functions
  # ============================================================================

  @doc """
  Create a new agent context.

  ## Options

    * `:system_prompt` - System prompt for the conversation
    * `:messages` - Initial messages (default: [])
    * `:tools` - Available tools (default: [])

  ## Examples

      context = AgentCore.new_context(
        system_prompt: "You are helpful",
        tools: [my_tool]
      )
  """
  @spec new_context(keyword()) :: context()
  def new_context(opts \\ []) do
    AgentContext.new(opts)
  end

  @doc """
  Create a new agent tool.

  ## Fields

    * `:name` - (required) Tool name for LLM to call
    * `:description` - (required) What the tool does
    * `:parameters` - JSON Schema for parameters (default: %{})
    * `:label` - Human-readable label for UI (default: same as name)
    * `:execute` - (required) Function to execute the tool

  The execute function receives:
    * `tool_call_id` - Unique ID for this invocation
    * `params` - Parsed parameters from the tool call
    * `signal` - Abort signal reference (or nil)
    * `on_update` - Callback for streaming partial results

  ## Examples

      read_tool = AgentCore.new_tool(
        name: "read_file",
        description: "Read the contents of a file",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string", "description" => "File path"}
          },
          "required" => ["path"]
        },
        label: "Read File",
        execute: fn _id, %{"path" => path}, _signal, _on_update ->
          case File.read(path) do
            {:ok, content} ->
              %AgentCore.Types.AgentToolResult{
                content: [%Ai.Types.TextContent{text: content}]
              }
            {:error, reason} ->
              {:error, reason}
          end
        end
      )
  """
  @spec new_tool(keyword()) :: tool()
  def new_tool(opts) do
    %AgentTool{
      name: Keyword.fetch!(opts, :name),
      description: Keyword.fetch!(opts, :description),
      parameters: Keyword.get(opts, :parameters, %{}),
      label: Keyword.get(opts, :label, Keyword.fetch!(opts, :name)),
      execute: Keyword.fetch!(opts, :execute)
    }
  end

  @doc """
  Create a new tool result.

  ## Options

    * `:content` - List of content blocks (default: [])
    * `:details` - Optional details for logging/UI

  ## Examples

      result = AgentCore.new_tool_result(
        content: [%Ai.Types.TextContent{text: "File contents here"}],
        details: %{bytes_read: 1024}
      )
  """
  @spec new_tool_result(keyword()) :: tool_result()
  def new_tool_result(opts \\ []) do
    %AgentToolResult{
      content: Keyword.get(opts, :content, []),
      details: Keyword.get(opts, :details)
    }
  end

  @doc """
  Create a text content block.

  Convenience wrapper for `Ai.Types.TextContent`.

  ## Examples

      content = AgentCore.text_content("Hello, world!")
  """
  @spec text_content(String.t()) :: Ai.Types.TextContent.t()
  def text_content(text) when is_binary(text) do
    %Ai.Types.TextContent{text: text}
  end

  @doc """
  Create an image content block.

  ## Examples

      content = AgentCore.image_content(base64_data, "image/png")
  """
  @spec image_content(String.t(), String.t()) :: Ai.Types.ImageContent.t()
  def image_content(data, mime_type \\ "image/png") do
    %Ai.Types.ImageContent{data: data, mime_type: mime_type}
  end

  @doc """
  Extract text from a tool result or message content.

  ## Examples

      text = AgentCore.get_text(tool_result)
  """
  @spec get_text(tool_result() | [Ai.Types.TextContent.t() | Ai.Types.ImageContent.t()]) ::
          String.t()
  def get_text(%AgentToolResult{content: content}), do: get_text(content)

  def get_text(content) when is_list(content) do
    content
    |> Enum.filter(&match?(%Ai.Types.TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end
end
