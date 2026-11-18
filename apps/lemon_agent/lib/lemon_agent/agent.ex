defmodule LemonAgent.Agent do
  @moduledoc """
  GenServer implementation of an AI Agent that manages conversation state and streams.

  This module ports the TypeScript Agent class to Elixir, providing a stateful
  process that handles prompts, tool execution, and event broadcasting to subscribers.

  ## Features

  - **State Management**: Maintains conversation messages, model configuration, and tools
  - **Streaming**: Consumes LemonAgent.Loop streams and broadcasts events to subscribers
  - **Queue System**: Supports steering (mid-run interrupts) and follow-up message queues
  - **Abort Support**: Allows cancellation of running streams
  - **Subscriber Management**: Auto-cleanup of dead subscribers via process monitoring

  ## Usage

      {:ok, agent} = LemonAgent.Agent.start_link(
        initial_state: %{system_prompt: "You are a helpful assistant"},
        convert_to_llm: &my_converter/1
      )

      # Subscribe to events
      unsubscribe = LemonAgent.Agent.subscribe(agent, self())

      # Send a prompt
      :ok = LemonAgent.Agent.prompt(agent, "Hello!")

      # Wait for completion
      :ok = LemonAgent.Agent.wait_for_idle(agent)

  ## State

  The agent maintains the following state:

  - `agent_state` - The LemonAgent.Types.AgentState containing messages, model, tools, etc.
  - `listeners` - List of subscriber PIDs that receive events
  - `abort_ref` - Reference for abort signaling
  - `running_task` - The currently running Task or nil
  - `steering_queue` / `follow_up_queue` - Message queues for mid-run and post-run messages
  - `waiters` - Processes waiting for the agent to become idle
  """

  use GenServer

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_server(status, [:session_id, :loop_closing])
  end

  require Logger

  alias LemonAgent.{AbortSignal, AutoThinking, Budget}
  alias LemonAgent.Types
  alias LemonAgent.Types.{AgentLoopConfig, AgentState}
  alias LemonAi.StreamAccumulator
  alias LemonAi.Types.StreamOptions
  alias LemonCore.Introspection

  @default_queue_call_timeout_ms :timer.minutes(30)

  # ============================================================================
  # Types
  # ============================================================================

  @type convert_to_llm_fn ::
          (list(Types.agent_message()) ->
             list(LemonAi.Types.message()) | {:ok, list(LemonAi.Types.message())})

  @type transform_context_fn ::
          (list(Types.agent_message()), reference() | nil ->
             {:ok, list(Types.agent_message())} | list(Types.agent_message()))

  @type stream_fn ::
          (LemonAi.Types.Model.t(), LemonAi.Types.Context.t(), LemonAi.Types.StreamOptions.t() ->
             {:ok, LemonAi.EventStream.t()} | LemonAi.EventStream.t() | {:error, term()})

  @type get_api_key_fn :: (String.t() -> String.t() | nil)

  @type waiter :: {:call, GenServer.from()} | {:notify, pid(), reference()}

  @type state :: %{
          agent_state: AgentState.t(),
          stream_accumulator: StreamAccumulator.t() | nil,
          listeners: list({pid(), reference()}),
          abort_ref: reference() | nil,
          running_task: Task.t() | nil,
          steering_queue: list(Types.agent_message()),
          follow_up_queue: list(Types.agent_message()),
          convert_to_llm: convert_to_llm_fn(),
          transform_context: transform_context_fn() | nil,
          stream_fn: stream_fn() | nil,
          system_prompt_observer: pid() | nil,
          response_system_prompt: LemonAi.SystemPrompt.t(),
          session_id: String.t() | nil,
          get_api_key: get_api_key_fn() | nil,
          resolve_stream_options: AgentLoopConfig.resolve_stream_options_fn() | nil,
          model_routing: map() | nil,
          resolve_thinking: AgentLoopConfig.resolve_thinking_fn() | nil,
          thinking_prompt: term() | nil,
          resolved_thinking: StreamOptions.thinking_level() | nil,
          thinking_budgets: map(),
          stream_options: StreamOptions.t(),
          stream_options_model: LemonAi.Types.Model.t() | nil,
          max_tool_turns: pos_integer() | :infinity | nil,
          max_tool_concurrency: pos_integer() | :infinity | nil,
          max_retries: non_neg_integer(),
          retry_base_delay_ms: non_neg_integer(),
          retry_max_delay_ms: non_neg_integer(),
          tool_timeout_ms: pos_integer() | :infinity | nil,
          intent_tracing: boolean(),
          queue_call_timeout: timeout(),
          waiters: list(waiter())
        }

  @type opts :: [
          initial_state: map(),
          convert_to_llm: convert_to_llm_fn(),
          transform_context: transform_context_fn(),
          stream_fn: stream_fn() | nil,
          system_prompt_observer: pid(),
          session_id: String.t(),
          get_api_key: get_api_key_fn(),
          resolve_stream_options: AgentLoopConfig.resolve_stream_options_fn(),
          model_routing: map() | nil,
          resolve_thinking: AgentLoopConfig.resolve_thinking_fn(),
          thinking_budgets: map(),
          stream_options: StreamOptions.t(),
          budget_limits: map(),
          budget_usage: Budget.usage(),
          max_tool_turns: pos_integer() | :infinity | nil,
          max_tool_concurrency: pos_integer() | :infinity | nil,
          max_retries: non_neg_integer(),
          retry_base_delay_ms: non_neg_integer(),
          retry_max_delay_ms: non_neg_integer(),
          tool_timeout_ms: pos_integer() | :infinity | nil,
          intent_tracing: boolean(),
          queue_call_timeout: timeout(),
          hibernate_after: timeout(),
          name: GenServer.name()
        ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts an Agent GenServer.

  ## Options

  - `:initial_state` - Map merged into the default AgentState
  - `:convert_to_llm` - Function to convert agent messages to LLM messages (required)
  - `:transform_context` - Optional function to transform context before conversion
  - `:stream_fn` - Custom stream function (defaults to Loop's `LemonAi.stream/3`)
  - `:system_prompt_observer` - Optional journal owner. Receives the exact ordered
    prompt as `{:agent_system_prompt, agent, prompt}` immediately before each
    assistant `:message_end`; ordinary subscribers never receive prompt snapshots.
  - `:session_id` - Optional session identifier for provider caching
  - `:get_api_key` - Function to dynamically resolve API keys
  - `:resolve_stream_options` - Rebuilds options for idle/live model switches in the loop task
  - `:model_routing` - Prepared opt-in model-routing policy; `set_model/2` disables it
  - `:resolve_thinking` - Bounded per-user-prompt classifier callback for configured `:auto`
  - `:thinking_budgets` - Map of thinking level budgets for token-based providers
  - `:stream_options` - StreamOptions for provider requests (temperature, max_tokens, etc.)
  - `:budget_limits` - Cumulative run/session token and estimated-dollar caps (nil = unlimited)
  - `:budget_usage` - Initial cumulative session totals, independent of message history
  - `:max_tool_turns` - Max assistant tool-use turns before terminal fallback, or `:infinity`
    (default: 25; `CodingAgent.Session` passes `:infinity` unless `[runtime] max_tool_turns` is set)
  - `:max_tool_concurrency` - Maximum overlapping calls for `parallel_safe` tools (default 8; `:infinity` opts out)
  - `:max_retries` - Single transient retry budget per response (default: 3; 0 disables);
    the loop owns retries and disables nested provider attempts
  - `:retry_base_delay_ms` - Initial exponential retry delay (default: 2,000ms);
    concurrency/rate throttles wait at least 10s plus jitter
  - `:retry_max_delay_ms` - Backoff cap (default: 30,000ms; explicit retry-after honored up to 120s)
  - `:tool_timeout_ms` - Per-tool task deadline (default 300,000 ms; `:infinity` opts out; tools can override)
  - `:intent_tracing` - Include optional provider-only tool intent (default true)
  - `:queue_call_timeout` - Timeout for loop queue polling GenServer calls (`:infinity` or ms, default: 30 minutes)
  - `:name` - Optional GenServer name
  - `:hibernate_after` - Idle milliseconds before OTP hibernation (default 5,000);
    `:infinity` disables it. Does not delay incoming messages or system/code-change requests.

  ## Examples

      {:ok, agent} = LemonAgent.Agent.start_link(
        initial_state: %{system_prompt: "You are helpful"},
        convert_to_llm: fn msgs -> Enum.filter(msgs, &llm_compatible?/1) end
      )
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    # Keep short inter-message gaps warm; reclaim heaps between user turns.
    server_opts = [hibernate_after: Keyword.get(opts, :hibernate_after, 5_000)]
    server_opts = if name, do: Keyword.put(server_opts, :name, name), else: server_opts
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Sends a prompt to the agent.

  The prompt can be:
  - A string (converted to a user message)
  - An agent message struct
  - A list of agent message structs

  Returns `:ok` immediately. Use `wait_for_idle/1` to wait for completion.
  Returns `{:error, :already_streaming}` if a prompt is already being processed.
  Returns `{:error, :task_capacity_reached | :task_supervisor_unavailable}` when
  the loop cannot be admitted; the agent state and conversation are unchanged.

  ## Examples

      :ok = LemonAgent.Agent.prompt(agent, "Hello!")
      :ok = LemonAgent.Agent.prompt(agent, %{role: :user, content: "Hi", timestamp: now})
      :ok = LemonAgent.Agent.prompt(agent, [msg1, msg2])
  """
  @spec prompt(
          GenServer.server(),
          String.t() | Types.agent_message() | list(Types.agent_message())
        ) ::
          :ok
          | {:error, :already_streaming | :task_capacity_reached | :task_supervisor_unavailable}
  def prompt(agent, message) do
    GenServer.call(agent, {:prompt, message})
  end

  @doc """
  Continues from the current context.

  Used for retrying after overflow or continuing from existing messages.
  Returns `{:error, :already_streaming}` if already processing.
  Returns `{:error, :no_messages}` if there are no messages to continue from.
  Returns `{:error, :cannot_continue}` if the last message is from the assistant.
  Task admission errors match `prompt/2` and leave the current context unchanged.
  """
  @spec continue(GenServer.server()) ::
          :ok
          | {:error,
             :already_streaming
             | :no_messages
             | :cannot_continue
             | :task_capacity_reached
             | :task_supervisor_unavailable}
  def continue(agent) do
    GenServer.call(agent, :continue)
  end

  @doc """
  Aborts the currently running stream.

  This sends an abort signal to the running task, which will cause it to
  terminate as soon as possible. The abort is asynchronous - use `wait_for_idle/1`
  to wait for the task to actually complete.
  """
  @spec abort(GenServer.server()) :: :ok
  def abort(agent) do
    GenServer.cast(agent, :abort)
  end

  @doc """
  Subscribes a process to agent events.

  The subscriber will receive `{:agent_event, event}` messages for each event
  emitted by the agent. The subscriber is automatically monitored and will be
  removed if it exits.

  Returns an unsubscribe function that can be called to stop receiving events.

  ## Examples

      unsubscribe = LemonAgent.Agent.subscribe(agent, self())

      receive do
        {:agent_event, %{type: :message_end} = event} ->
          IO.puts("Got message: \#{inspect(event)}")
      end

      unsubscribe.()
  """
  @spec subscribe(GenServer.server(), pid()) :: (-> :ok)
  def subscribe(agent, subscriber_pid) when is_pid(subscriber_pid) do
    GenServer.call(agent, {:subscribe, subscriber_pid})
  end

  @doc """
  Waits for the agent to become idle (no running task).

  If the agent is already idle, returns immediately with `:ok`.
  If the agent is streaming, blocks until the current run completes.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: `:infinity`)

  ## Examples

      :ok = LemonAgent.Agent.wait_for_idle(agent)
      :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5000)
  """
  @spec wait_for_idle(GenServer.server(), keyword() | timeout()) :: :ok | {:error, :timeout}
  def wait_for_idle(agent, opts \\ [])

  def wait_for_idle(agent, timeout) when is_integer(timeout) or timeout == :infinity do
    wait_for_idle(agent, timeout: timeout)
  end

  def wait_for_idle(agent, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    ref = make_ref()

    case GenServer.call(agent, {:wait_for_idle, self(), ref}) do
      :ok ->
        :ok

      :registered ->
        receive do
          {:wait_for_idle, ^ref, :ok} ->
            :ok
        after
          timeout ->
            GenServer.cast(agent, {:cancel_wait_for_idle, self(), ref})

            receive do
              {:wait_for_idle, ^ref, :ok} -> :ok
            after
              0 -> {:error, :timeout}
            end
        end
    end
  end

  @doc """
  Resets the agent to initial state.

  Clears all messages, queues, and error state. Does not change configuration
  like system_prompt, model, or tools.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(agent) do
    GenServer.call(agent, :reset)
  end

  # ============================================================================
  # State Mutators
  # ============================================================================

  @doc """
  Sets the system prompt.
  """
  @spec set_system_prompt(GenServer.server(), LemonAi.SystemPrompt.t()) :: :ok
  def set_system_prompt(agent, prompt) when is_binary(prompt) or is_list(prompt) do
    GenServer.call(agent, {:set_system_prompt, prompt})
  end

  @doc """
  Sets the model to use for LLM calls.

  Provider-owned options are rebound in the loop task before the next classifier
  or model request. Selecting a model does not resolve credentials in the caller.
  Explicit selections disable automatic routing. Internal branch restoration may
  supply the destination's prepared policy with `:model_routing`.
  """
  @spec set_model(GenServer.server(), LemonAi.Types.Model.t(), keyword()) :: :ok
  def set_model(agent, model, opts \\ []) do
    GenServer.call(agent, {:set_model, model, Keyword.get(opts, :model_routing)})
  end

  @doc """
  Replaces options for subsequent turns, owned by the currently selected model.

  Provider switches still rebuild and sanitize these options in the loop.
  """
  @spec set_stream_options(GenServer.server(), StreamOptions.t()) :: :ok
  def set_stream_options(agent, %StreamOptions{} = options) do
    GenServer.call(agent, {:set_stream_options, options})
  end

  @doc """
  Sets the thinking/reasoning level.

  Valid levels: :off, :auto, :minimal, :low, :medium, :high, :xhigh
  """
  @spec set_thinking_level(GenServer.server(), Types.thinking_level()) :: :ok
  def set_thinking_level(agent, level) do
    GenServer.call(agent, {:set_thinking_level, level})
  end

  @doc """
  Sets the available tools.
  """
  @spec set_tools(GenServer.server(), list(LemonAgent.Types.AgentTool.t())) :: :ok
  def set_tools(agent, tools) when is_list(tools) do
    GenServer.call(agent, {:set_tools, tools})
  end

  @doc """
  Replaces all messages in the conversation.
  """
  @spec replace_messages(GenServer.server(), list(Types.agent_message())) :: :ok
  def replace_messages(agent, messages) when is_list(messages) do
    GenServer.call(agent, {:replace_messages, messages})
  end

  @doc """
  Appends a message to the conversation.
  """
  @spec append_message(GenServer.server(), Types.agent_message()) :: :ok
  def append_message(agent, message) do
    GenServer.call(agent, {:append_message, message})
  end

  # ============================================================================
  # Queue Controls
  # ============================================================================

  @doc """
  Queues a steering message to interrupt the agent mid-run.

  Steering messages are delivered after the current tool execution completes,
  skipping remaining tool calls. Use this for "steering" the agent while it's working.
  Pass `system_prompt: prompt` to apply a per-turn prompt refresh when the queued
  message is consumed by an already-running loop.

  Pass `preempt: false` for agent-originated input: already-issued tool calls
  finish before delivery at the next turn boundary. All variants acknowledge
  enqueueing synchronously. Human steering retains its preempting default.
  Pass `defer_start: true` when restoring accepted journal input.
  """
  @spec steer(GenServer.server(), Types.agent_message(), keyword()) :: :ok
  def steer(agent, message, opts \\ []) do
    queued = queued_message(message, opts)

    queued =
      if Keyword.get(opts, :preempt, true) do
        queued
      else
        wrapper =
          if is_map(queued) and Map.has_key?(queued, :message),
            do: queued,
            else: %{message: queued}

        Map.put(wrapper, :preempt, false)
      end

    GenServer.call(agent, {:steer, queued, Keyword.get(opts, :defer_start, false)})
  end

  @doc "Withdraws an accepted steering message before it is bound to a turn."
  @spec withdraw_steer(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def withdraw_steer(agent, id), do: GenServer.call(agent, {:withdraw_steer, id})

  @doc """
  Queues a redirect message: the in-flight model request is canceled (keeping
  completed tool results), and the loop retries with this correction appended.

  Unlike `abort/1`, a redirect never stops the run. While tools are executing
  it degrades to steering semantics — the tools finish, and the correction is
  delivered before the next model call without canceling anything. When no run
  is active it degrades to `follow_up/3` semantics. Pass `system_prompt:
  prompt` to apply a per-turn prompt refresh when the queued message is
  consumed. The call returns only after the correction is queued and any
  active model request has been signaled, so a fast completion cannot race
  ahead of an accepted redirect.
  """
  @spec redirect(GenServer.server(), Types.agent_message(), keyword()) :: :ok
  def redirect(agent, message, opts \\ []) do
    GenServer.call(agent, {:redirect, queued_message(message, opts)})
  end

  @doc """
  Queues a follow-up message to be processed after the agent finishes.

  Follow-up messages are delivered only when the agent has no more tool calls
  and no steering messages. Use this for messages that should wait until the
  agent completes its current work. Pass `system_prompt: prompt` to apply a
  per-turn prompt refresh when the queued message is consumed.

  Returns `:ok` after enqueueing. Inputs accepted after the deterministic closing
  handshake start the next run. Pass `defer_start: true` when restoring a journal
  to queue input without executing a model call.
  """
  @spec follow_up(GenServer.server(), Types.agent_message(), keyword()) :: :ok
  def follow_up(agent, message, opts \\ []) do
    GenServer.call(
      agent,
      {:follow_up, queued_message(message, opts), Keyword.get(opts, :defer_start, false)}
    )
  end

  # ============================================================================
  # Getters
  # ============================================================================

  @doc """
  Gets the current agent state, materializing the in-flight assistant message
  from its accumulated chunks only for this snapshot.
  """
  @spec get_state(GenServer.server()) :: AgentState.t()
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc "Non-consuming steering queue peek bound to the active invocation signal."
  @spec has_steering_messages?(GenServer.server(), reference() | nil) :: boolean()
  def has_steering_messages?(agent, signal) do
    GenServer.call(agent, {:has_steering_messages, signal}, 1_000)
  end

  @doc """
  Gets the current session ID.
  """
  @spec get_session_id(GenServer.server()) :: String.t() | nil
  def get_session_id(agent) do
    GenServer.call(agent, :get_session_id)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    initial_state_opts = Keyword.get(opts, :initial_state, %{})

    agent_state = %AgentState{
      system_prompt: Map.get(initial_state_opts, :system_prompt, ""),
      model: Map.get(initial_state_opts, :model),
      thinking_level:
        AutoThinking.normalize_level(Map.get(initial_state_opts, :thinking_level, :off)),
      tools: Map.get(initial_state_opts, :tools, []),
      messages: Map.get(initial_state_opts, :messages, []),
      budget_limits:
        Keyword.get(opts, :budget_limits, Map.get(initial_state_opts, :budget_limits, %{})),
      budget_usage:
        Budget.normalize_usage(
          Keyword.get(opts, :budget_usage, Map.get(initial_state_opts, :budget_usage))
        ),
      is_streaming: false,
      stream_message: nil,
      pending_tool_calls: MapSet.new(),
      error: nil
    }

    convert_to_llm = Keyword.get(opts, :convert_to_llm, &default_convert_to_llm/1)
    transform_context = Keyword.get(opts, :transform_context)
    stream_fn = Keyword.get(opts, :stream_fn)
    stream_options = Keyword.get(opts, :stream_options, %StreamOptions{})
    queue_call_timeout = resolve_queue_call_timeout(opts)

    state = %{
      agent_state: agent_state,
      stream_accumulator: nil,
      listeners: [],
      abort_ref: nil,
      running_task: nil,
      bound_input_ids: MapSet.new(),
      steering_queue: [],
      follow_up_queue: [],
      queue_consumer: nil,
      loop_closing: false,
      convert_to_llm: convert_to_llm,
      transform_context: transform_context,
      tool_result_max_bytes: Keyword.get(opts, :tool_result_max_bytes),
      stream_fn: stream_fn,
      system_prompt_observer: Keyword.get(opts, :system_prompt_observer),
      response_system_prompt: agent_state.system_prompt,
      stream_rules: Keyword.get(opts, :stream_rules, []),
      on_stream_rule: Keyword.get(opts, :on_stream_rule),
      session_id: Keyword.get(opts, :session_id),
      get_api_key: Keyword.get(opts, :get_api_key),
      resolve_stream_options: Keyword.get(opts, :resolve_stream_options),
      model_routing: Keyword.get(opts, :model_routing),
      resolve_thinking: Keyword.get(opts, :resolve_thinking),
      thinking_prompt: nil,
      resolved_thinking: nil,
      thinking_budgets: Keyword.get(opts, :thinking_budgets, %{}),
      stream_options: stream_options,
      stream_options_model: agent_state.model,
      max_tool_turns: Keyword.get(opts, :max_tool_turns, 25),
      max_tool_concurrency: Keyword.get(opts, :max_tool_concurrency) || 8,
      max_retries: Keyword.get(opts, :max_retries, 3),
      retry_base_delay_ms: Keyword.get(opts, :retry_base_delay_ms, 2_000),
      retry_max_delay_ms: Keyword.get(opts, :retry_max_delay_ms, 30_000),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms) || 300_000,
      intent_tracing: Keyword.get(opts, :intent_tracing, true),
      queue_call_timeout: queue_call_timeout,
      waiters: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, message}, _from, state) do
    if state.running_task != nil do
      {:reply, {:error, :already_streaming}, state}
    else
      messages = normalize_prompt_input(message)

      case start_loop(messages, state) do
        {:ok, new_state} -> {:reply, :ok, new_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:follow_up, message, true}, _from, state) do
    {:reply, :ok, append_input(state, :follow_up_queue, message)}
  end

  def handle_call({:follow_up, message, false}, from, state) do
    handle_call({:follow_up, message}, from, state)
  end

  def handle_call({:follow_up, message}, _from, state) do
    {:reply, :ok, enqueue_follow_up(state, message)}
  end

  def handle_call(:continue, _from, state) do
    cond do
      state.running_task != nil ->
        {:reply, {:error, :already_streaming}, state}

      state.agent_state.messages == [] ->
        {:reply, {:error, :no_messages}, state}

      match?(%{role: :assistant}, List.last(state.agent_state.messages)) ->
        {:reply, {:error, :cannot_continue}, state}

      true ->
        case start_loop(nil, state) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    monitor_ref = Process.monitor(pid)
    new_listeners = [{pid, monitor_ref} | state.listeners]
    agent_pid = self()

    unsubscribe = fn ->
      GenServer.cast(agent_pid, {:unsubscribe, pid})
    end

    {:reply, unsubscribe, %{state | listeners: new_listeners}}
  end

  def handle_call({:wait_for_idle, pid, ref}, _from, state) do
    if state.running_task == nil do
      {:reply, :ok, state}
    else
      new_waiters = [{:notify, pid, ref} | state.waiters]
      {:reply, :registered, %{state | waiters: new_waiters}}
    end
  end

  def handle_call(:wait_for_idle, from, state) do
    if state.running_task == nil do
      {:reply, :ok, state}
    else
      new_waiters = [{:call, from} | state.waiters]
      {:noreply, %{state | waiters: new_waiters}}
    end
  end

  def handle_call(:reset, _from, state) do
    new_agent_state = %{
      state.agent_state
      | messages: [],
        is_streaming: false,
        stream_message: nil,
        pending_tool_calls: MapSet.new(),
        error: nil
    }

    new_state = %{
      state
      | agent_state: new_agent_state,
        stream_accumulator: nil,
        steering_queue: [],
        follow_up_queue: [],
        loop_closing: false,
        bound_input_ids: MapSet.new(),
        thinking_prompt: nil,
        resolved_thinking: nil
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:set_system_prompt, prompt}, _from, state) do
    new_agent_state = %{state.agent_state | system_prompt: prompt}
    {:reply, :ok, %{state | agent_state: new_agent_state}}
  end

  def handle_call({:set_model, model, model_routing}, _from, state) do
    new_agent_state = %{state.agent_state | model: model}
    # With no initial model, the first selection owns the supplied options.
    # Later selections retain that owner until the loop rebuilds its local options.
    {:reply, :ok,
     %{
       state
       | agent_state: new_agent_state,
         model_routing: model_routing,
         stream_options_model: state.stream_options_model || model
     }}
  end

  def handle_call({:set_stream_options, options}, _from, state) do
    {:reply, :ok,
     %{state | stream_options: options, stream_options_model: state.agent_state.model}}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    new_agent_state = %{state.agent_state | thinking_level: AutoThinking.normalize_level(level)}

    {:reply, :ok,
     %{state | agent_state: new_agent_state, thinking_prompt: nil, resolved_thinking: nil}}
  end

  def handle_call({:set_tools, tools}, _from, state) do
    new_agent_state = %{state.agent_state | tools: tools}
    {:reply, :ok, %{state | agent_state: new_agent_state}}
  end

  def handle_call({:replace_messages, messages}, _from, state) do
    new_agent_state = %{state.agent_state | messages: messages}
    {:reply, :ok, %{state | agent_state: new_agent_state}}
  end

  def handle_call({:append_message, message}, _from, state) do
    new_messages = state.agent_state.messages ++ [message]
    new_agent_state = %{state.agent_state | messages: new_messages}
    {:reply, :ok, %{state | agent_state: new_agent_state}}
  end

  def handle_call({:redirect, message}, _from, state) do
    {:reply, :ok, apply_redirect(state, message)}
  end

  def handle_call(:get_state, _from, state) do
    agent_state =
      case state.stream_accumulator do
        nil ->
          state.agent_state

        accumulator ->
          %{state.agent_state | stream_message: StreamAccumulator.snapshot(accumulator)}
      end

    {:reply, agent_state, state}
  end

  def handle_call(:get_model, _from, state) do
    {:reply, state.agent_state.model, state}
  end

  def handle_call({:route_model, context, options}, _from, state) do
    result =
      LemonAgent.ModelRuntime.ModelRouting.select(
        state.model_routing,
        state.agent_state.model,
        context,
        options
      )

    {:reply, result, state}
  end

  def handle_call({:check_model_cost, model, context, options}, _from, state) do
    result =
      LemonAgent.ModelRuntime.ModelRouting.check_cap(
        state.model_routing,
        model,
        context,
        options
      )

    {:reply, result, state}
  end

  def handle_call({:auto_thinking_resolved, abort_ref, marker, effort}, _from, state) do
    state =
      if state.agent_state.thinking_level == :auto and
           ((is_nil(marker) and
               (state.abort_ref == abort_ref or match?({:aborted, ^abort_ref}, state.abort_ref))) or
              (state.abort_ref == abort_ref and not AbortSignal.aborted?(abort_ref))) do
        %{state | thinking_prompt: marker, resolved_thinking: effort}
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:has_steering_messages, abort_ref}, _from, state) do
    {has_steering, state} = drain_loop_queue(state, :has_steering)
    {:reply, state.abort_ref == abort_ref and has_steering, state}
  end

  def handle_call({:withdraw_steer, id}, _from, state) when is_binary(id) and id != "" do
    {withdrawn, queue} = Enum.split_with(state.steering_queue, &(input_id(&1) == id))
    result = if withdrawn == [], do: {:error, :not_found}, else: :ok
    state = %{state | steering_queue: queue}

    if is_pid(state.queue_consumer) do
      send(state.queue_consumer, {:lemon_steering_changed, state.abort_ref})
    end

    {:reply, result, state}
  end

  def handle_call({:withdraw_steer, _id}, _from, state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call({:steer, message, true}, _from, state) do
    {:reply, :ok, append_input(state, :steering_queue, message)}
  end

  def handle_call({:steer, message, false}, from, state) do
    handle_call({:steer, message}, from, state)
  end

  def handle_call({:steer, message}, _from, state) do
    {:reply, :ok, enqueue_steering(state, message)}
  end

  @impl true
  def handle_cast(:abort, state) do
    abort_ref =
      case state.abort_ref do
        {:aborted, ref} -> ref
        ref -> ref
      end

    if abort_ref do
      AbortSignal.abort(abort_ref)
      # Send abort signal - the task monitors this
      send(self(), {:abort_signal, abort_ref})
    end

    {:noreply, state}
  end

  def handle_cast({:steer, message}, state) do
    {:noreply, enqueue_steering(state, message)}
  end

  def handle_cast({:redirect, message}, state) do
    {:noreply, apply_redirect(state, message)}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    new_listeners =
      Enum.reject(state.listeners, fn {listener_pid, monitor_ref} ->
        if listener_pid == pid do
          Process.demonitor(monitor_ref, [:flush])
          true
        else
          false
        end
      end)

    {:noreply, %{state | listeners: new_listeners}}
  end

  def handle_cast({:cancel_wait_for_idle, pid, ref}, state) do
    new_waiters =
      Enum.reject(state.waiters, fn
        {:notify, waiter_pid, waiter_ref} -> waiter_pid == pid and waiter_ref == ref
        _ -> false
      end)

    {:noreply, %{state | waiters: new_waiters}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      state.running_task && state.running_task.ref == ref ->
        new_state = handle_task_completion({:error, reason}, state)
        {:noreply, new_state}

      true ->
        # Subscriber died, remove from listeners
        new_listeners =
          Enum.reject(state.listeners, fn {listener_pid, monitor_ref} ->
            listener_pid == pid and monitor_ref == ref
          end)

        {:noreply, %{state | listeners: new_listeners}}
    end
  end

  def handle_info({:agent_event, {:system_prompt, prompt}}, state) do
    {:noreply, %{state | response_system_prompt: prompt}}
  end

  def handle_info({:agent_event, event}, state) do
    # Event from the running task - update state and broadcast
    if match?({:message_end, %LemonAi.Types.AssistantMessage{}}, event) and
         is_pid(state.system_prompt_observer) do
      send(
        state.system_prompt_observer,
        {:agent_system_prompt, self(), state.response_system_prompt}
      )
    end

    new_state = handle_agent_event(event, state)
    broadcast_event(new_state, event)
    {:noreply, new_state}
  end

  def handle_info({:task_complete, task_ref, result}, state) do
    if state.running_task && state.running_task.ref == task_ref do
      new_state = handle_task_completion(result, state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    if state.running_task && state.running_task.ref == ref do
      new_state = handle_task_completion(result, state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:abort_signal, abort_ref}, state) do
    if state.abort_ref == abort_ref do
      # Store abort flag for task to check
      {:noreply, %{state | abort_ref: {:aborted, abort_ref}}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:loop_queue, pid, request_ref, abort_ref, kind}, state) do
    if state.abort_ref == abort_ref and not AbortSignal.aborted?(abort_ref) do
      state = %{state | queue_consumer: pid}
      {messages, state} = drain_loop_queue(state, kind)

      state =
        if is_list(messages) and messages != [] do
          ids = messages |> Enum.map(&input_id/1) |> Enum.reject(&is_nil/1)
          broadcast_event(state, {:input_bound, ids})
          %{state | bound_input_ids: Enum.reduce(ids, state.bound_input_ids, &MapSet.put(&2, &1))}
        else
          state
        end

      send(pid, {:loop_queue, request_ref, messages})
      {:noreply, state}
    else
      send(pid, {:loop_queue, request_ref, if(kind == :has_steering, do: false, else: [])})
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp consume_steering_queue(queue) do
    {preempting, deferred} = Enum.split_with(queue, &preempting_message?/1)
    consume_queue(preempting ++ deferred)
  end

  defp preempting_message?(%{preempt: false}), do: false
  defp preempting_message?(_message), do: true

  defp queued_message(message, opts) do
    case Keyword.get(opts, :system_prompt) do
      prompt when (is_binary(prompt) and prompt != "") or is_list(prompt) ->
        %{message: message, system_prompt: prompt}

      _ ->
        message
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec normalize_prompt_input(String.t() | Types.agent_message() | list(Types.agent_message())) ::
          list(Types.agent_message())
  defp normalize_prompt_input(input) when is_binary(input) do
    [
      %LemonAi.Types.UserMessage{
        role: :user,
        content: input,
        timestamp: System.system_time(:millisecond)
      }
    ]
  end

  defp normalize_prompt_input(input) when is_list(input), do: input
  defp normalize_prompt_input(input) when is_map(input), do: [input]

  @spec start_loop(list(Types.agent_message()) | nil, state(), keyword()) ::
          {:ok, state()} | {:error, term()}
  defp start_loop(messages, state, opts \\ []) do
    abort_ref = AbortSignal.new()
    agent_pid = self()

    # Update agent state to streaming
    new_agent_state = %{
      state.agent_state
      | is_streaming: true,
        stream_message: nil,
        error: nil,
        run_usage:
          if(is_nil(messages), do: state.agent_state.run_usage, else: %{tokens: 0, cost_usd: 0.0})
    }

    # Build context for the loop
    context = %{
      system_prompt: new_agent_state.system_prompt,
      messages: new_agent_state.messages,
      tools: new_agent_state.tools
    }

    # Build config for the loop
    config = build_loop_config(%{state | agent_state: new_agent_state}, abort_ref, agent_pid)

    config =
      if Keyword.get(opts, :queued_start, false),
        do: %{config | hooks: Map.put(config.hooks, :queued_start, true)},
        else: config

    case LemonCore.TaskSupervisor.async_nolink(LemonAgent.LoopTaskSupervisor, fn ->
           run_agent_loop(messages, context, config, abort_ref, agent_pid, state.stream_fn)
         end) do
      {:ok, task} ->
        model_id =
          case new_agent_state.model do
            %{id: id} when is_binary(id) -> id
            _ -> ""
          end

        Introspection.record(
          :agent_loop_started,
          %{
            model: model_id,
            tool_count: length(new_agent_state.tools),
            message_count: length(new_agent_state.messages),
            is_continue: messages == nil
          },
          session_key: state.session_id,
          provenance: :direct
        )

        {:ok,
         %{
           state
           | agent_state: new_agent_state,
             stream_accumulator: nil,
             response_system_prompt: context.system_prompt,
             abort_ref: abort_ref,
             queue_consumer: nil,
             loop_closing: false,
             running_task: task
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec build_loop_config(state(), reference(), pid()) :: AgentLoopConfig.t()
  defp build_loop_config(state, abort_ref, agent_pid) do
    reasoning =
      if state.agent_state.thinking_level == :auto do
        if state.thinking_prompt,
          do: state.resolved_thinking,
          else: AutoThinking.default_effort(state.agent_state.model)
      else
        reasoning_from_thinking_level(state.agent_state.thinking_level)
      end

    stream_options = build_stream_options(state, reasoning)
    queue_call_timeout = state.queue_call_timeout

    %AgentLoopConfig{
      model: state.agent_state.model,
      stream_options_model: state.stream_options_model,
      convert_to_llm: state.convert_to_llm,
      transform_context: state.transform_context,
      tool_result_max_bytes: state.tool_result_max_bytes,
      get_api_key: state.get_api_key,
      get_model: fn -> GenServer.call(agent_pid, :get_model, queue_call_timeout) end,
      resolve_stream_options: state.resolve_stream_options,
      resolve_model:
        if state.model_routing do
          fn context, options ->
            GenServer.call(agent_pid, {:route_model, context, options}, queue_call_timeout)
          end
        end,
      check_model_cost:
        if state.model_routing do
          fn model, context, options ->
            GenServer.call(
              agent_pid,
              {:check_model_cost, model, context, options},
              queue_call_timeout
            )
          end
        end,
      resolve_thinking:
        if(state.agent_state.thinking_level == :auto,
          do: state.resolve_thinking || (&AutoThinking.resolve/3)
        ),
      thinking_prompt: state.thinking_prompt,
      resolved_thinking: state.resolved_thinking,
      on_thinking_resolved: fn marker, effort ->
        GenServer.call(
          agent_pid,
          {:auto_thinking_resolved, abort_ref, marker, effort},
          queue_call_timeout
        )
      end,
      budget_limits: state.agent_state.budget_limits,
      budget_usage: state.agent_state.budget_usage,
      budget:
        if Budget.enabled?(state.agent_state.budget_limits) do
          %{
            Budget.new(state.agent_state.budget_limits, state.agent_state.budget_usage)
            | run_usage: state.agent_state.run_usage
          }
        end,
      max_tool_turns: state.max_tool_turns,
      max_tool_concurrency: state.max_tool_concurrency,
      max_retries: state.max_retries,
      retry_base_delay_ms: state.retry_base_delay_ms,
      retry_max_delay_ms: state.retry_max_delay_ms,
      tool_timeout_ms: state.tool_timeout_ms,
      intent_tracing: state.intent_tracing,
      stream_options: stream_options,
      hooks: %{
        queue_owner: agent_pid,
        queue_ref: abort_ref,
        queue_timeout: state.queue_call_timeout,
        emit_system_prompt: is_pid(state.system_prompt_observer),
        stream_rules: state.stream_rules,
        on_stream_rule: state.on_stream_rule
      },
      stream_fn: state.stream_fn
    }
  end

  defp resolve_queue_call_timeout(opts) do
    opts
    |> Keyword.get(
      :queue_call_timeout,
      Application.get_env(:lemon_agent, :queue_call_timeout_ms, @default_queue_call_timeout_ms)
    )
    |> normalize_queue_call_timeout()
  end

  defp normalize_queue_call_timeout(:infinity), do: :infinity
  defp normalize_queue_call_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp normalize_queue_call_timeout(timeout) do
    Logger.warning(
      "Invalid LemonAgent.Agent queue_call_timeout=#{inspect(timeout)}; defaulting to #{@default_queue_call_timeout_ms}ms"
    )

    @default_queue_call_timeout_ms
  end

  defp reasoning_from_thinking_level(:off), do: nil
  defp reasoning_from_thinking_level(level), do: level

  @spec run_agent_loop(
          list(Types.agent_message()) | nil,
          map(),
          AgentLoopConfig.t(),
          reference(),
          pid(),
          stream_fn() | nil
        ) :: :ok | {:error, term()}
  defp run_agent_loop(messages, context, config, abort_ref, agent_pid, stream_fn) do
    # Get the event stream from LemonAgent.Loop with abort signal
    event_stream =
      if messages do
        LemonAgent.Loop.agent_loop(messages, context, config, abort_ref, stream_fn, agent_pid)
      else
        LemonAgent.Loop.agent_loop_continue(context, config, abort_ref, stream_fn, agent_pid)
      end

    # Forward deltas without maintaining another copy of the partial message.
    message_open? =
      event_stream
      |> LemonAgent.EventStream.events()
      |> Enum.reduce(false, fn event, message_open? ->
        send(agent_pid, {:agent_event, event})
        track_message_open(event, message_open?)
      end)

    # This ordered call snapshots the Agent's accumulator only if the stream
    # stopped without closing its last message.
    if message_open? do
      partial_message = get_state(agent_pid).stream_message
      handle_remaining_partial(partial_message, agent_pid, abort_ref, config)
    end

    :ok
  rescue
    error ->
      # Persist the failed turn before terminal delivery can be fenced.
      error_text = Exception.message(error)
      error_msg = build_error_message(error_text, config, :error)
      send(agent_pid, {:agent_event, {:message_end, error_msg}})
      send(agent_pid, {:agent_event, {:error, error_text, %{messages: [error_msg]}}})
      {:error, error}
  end

  defp aborted?(abort_ref), do: AbortSignal.aborted?(abort_ref)

  defp track_message_open({:message_start, %{role: :assistant}}, _open?), do: true
  defp track_message_open({:message_start, _message}, _open?), do: false
  defp track_message_open({:message_end, _message}, _open?), do: false
  defp track_message_open({:provider_retry, _details}, _open?), do: false
  defp track_message_open(_event, open?), do: open?

  defp handle_remaining_partial(nil, _agent_pid, _abort_ref, _config), do: :ok

  defp handle_remaining_partial(partial, agent_pid, abort_ref, config) do
    # Check if partial has meaningful content
    if Map.get(partial, :role) == :assistant and
         has_meaningful_content?(Map.get(partial, :content, [])) do
      # Append the partial message
      send(agent_pid, {:agent_event, {:message_end, partial}})
    else
      # Check if aborted
      if aborted?(abort_ref) do
        error_msg = build_error_message("Request was aborted", config, :aborted)
        send(agent_pid, {:agent_event, {:message_end, error_msg}})
      end
    end
  end

  defp has_meaningful_content?(content) when is_list(content) do
    Enum.any?(content, fn
      %{type: :thinking, thinking: text} -> String.trim(text) != ""
      %{type: :text, text: text} -> String.trim(text) != ""
      %{type: :tool_call, name: name} -> String.trim(name) != ""
      _ -> false
    end)
  end

  defp has_meaningful_content?(_), do: false

  defp build_error_message(error_text, %AgentLoopConfig{} = config, stop_reason) do
    model = config.model || %{}

    %LemonAi.Types.AssistantMessage{
      role: :assistant,
      content: [%LemonAi.Types.TextContent{type: :text, text: ""}],
      api: Map.get(model, :api),
      provider: Map.get(model, :provider),
      model: Map.get(model, :id, ""),
      usage: %LemonAi.Types.Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %LemonAi.Types.Cost{
          input: 0.0,
          output: 0.0,
          cache_read: 0.0,
          cache_write: 0.0,
          total: 0.0
        }
      },
      stop_reason: stop_reason,
      error_message: error_text,
      timestamp: System.system_time(:millisecond)
    }
  end

  @spec handle_agent_event(Types.agent_event(), state()) :: state()
  defp handle_agent_event({:message_start, %LemonAi.Types.AssistantMessage{} = message}, state) do
    %{
      state
      | agent_state: %{state.agent_state | stream_message: nil},
        stream_accumulator: StreamAccumulator.new(message)
    }
  end

  defp handle_agent_event({:message_start, message}, state) do
    new_agent_state = %{state.agent_state | stream_message: message}
    %{state | agent_state: new_agent_state, stream_accumulator: nil}
  end

  defp handle_agent_event({:message_update, event}, state) do
    case state.stream_accumulator do
      nil -> state
      accumulator -> %{state | stream_accumulator: StreamAccumulator.apply(accumulator, event)}
    end
  end

  defp handle_agent_event({:message_end, message}, state) do
    new_messages = state.agent_state.messages ++ [message]

    new_agent_state = %{
      state.agent_state
      | stream_message: nil,
        messages: new_messages
    }

    %{state | agent_state: new_agent_state, stream_accumulator: nil}
  end

  defp handle_agent_event({:tool_execution_start, id, _name, _args}, state) do
    new_pending = MapSet.put(state.agent_state.pending_tool_calls, id)
    new_agent_state = %{state.agent_state | pending_tool_calls: new_pending}
    %{state | agent_state: new_agent_state}
  end

  defp handle_agent_event({:tool_execution_end, id, _name, _result, _is_error}, state) do
    new_pending = MapSet.delete(state.agent_state.pending_tool_calls, id)
    new_agent_state = %{state.agent_state | pending_tool_calls: new_pending}
    %{state | agent_state: new_agent_state}
  end

  defp handle_agent_event({:turn_end, message, _tool_results}, state) do
    # Emit introspection event for turn observation
    Introspection.record(
      :agent_turn_observed,
      %{
        has_error: match?(%{error_message: err} when is_binary(err) and err != "", message)
      },
      session_key: state.session_id,
      provenance: :inferred
    )

    # Check for error in the message
    error =
      case message do
        %{error_message: err} when is_binary(err) and err != "" -> err
        _ -> nil
      end

    if error do
      new_agent_state = %{state.agent_state | error: error}
      %{state | agent_state: new_agent_state}
    else
      state
    end
  end

  defp handle_agent_event({:agent_end, _messages}, state) do
    new_agent_state = %{
      state.agent_state
      | is_streaming: false,
        stream_message: nil
    }

    %{state | agent_state: new_agent_state, stream_accumulator: nil}
  end

  defp handle_agent_event(
         {:usage_budget_updated, %{run_usage: run_usage, session_usage: session_usage}},
         state
       ) do
    %{
      state
      | agent_state: %{state.agent_state | run_usage: run_usage, budget_usage: session_usage}
    }
  end

  defp handle_agent_event({:error, reason, _partial_state}, state) do
    new_agent_state = %{state.agent_state | error: normalize_error_reason(reason)}
    %{state | agent_state: new_agent_state}
  end

  defp handle_agent_event({:provider_retry, _details}, state) do
    %{
      state
      | agent_state: %{state.agent_state | stream_message: nil, error: nil},
        stream_accumulator: nil
    }
  end

  defp handle_agent_event(_event, state), do: state

  @spec handle_task_completion(term(), state()) :: state()
  defp handle_task_completion(_result, state) do
    # Emit introspection event for loop end
    Introspection.record(
      :agent_loop_ended,
      %{
        message_count: length(state.agent_state.messages),
        had_error: state.agent_state.error != nil,
        was_aborted: match?({:aborted, _}, state.abort_ref)
      },
      session_key: state.session_id,
      provenance: :direct
    )

    # Clear streaming state
    new_agent_state = %{
      state.agent_state
      | is_streaming: false,
        stream_message: nil,
        pending_tool_calls: MapSet.new()
    }

    idle_state = %{
      state
      | agent_state: new_agent_state,
        stream_accumulator: nil,
        abort_ref: nil,
        running_task: nil,
        queue_consumer: nil
    }

    next_state = if state.loop_closing, do: maybe_start_queued(idle_state), else: idle_state

    if next_state.running_task do
      next_state
    else
      Enum.each(state.waiters, fn
        {:call, from} -> GenServer.reply(from, :ok)
        {:notify, pid, ref} -> send(pid, {:wait_for_idle, ref, :ok})
      end)

      %{next_state | waiters: []}
    end
  end

  @spec broadcast_event(state(), Types.agent_event()) :: :ok
  defp broadcast_event(state, event) do
    Enum.each(state.listeners, fn {pid, _ref} ->
      send(pid, {:agent_event, event})
    end)

    :ok
  end

  @spec default_convert_to_llm(list(Types.agent_message())) :: list(LemonAi.Types.message())
  defp default_convert_to_llm(messages) do
    Enum.filter(messages, fn msg ->
      case msg do
        %{role: role} when role in [:user, :assistant, :tool_result] -> true
        _ -> false
      end
    end)
  end

  defp build_stream_options(state, reasoning) do
    base =
      case state.stream_options do
        %StreamOptions{} = opts -> opts
        _ -> %StreamOptions{}
      end

    session_id = state.session_id || base.session_id

    thinking_budgets =
      cond do
        is_map(state.thinking_budgets) and map_size(state.thinking_budgets) > 0 ->
          state.thinking_budgets

        is_map(base.thinking_budgets) ->
          base.thinking_budgets

        true ->
          %{}
      end

    %StreamOptions{
      base
      | session_id: session_id,
        reasoning: reasoning,
        thinking_budgets: thinking_budgets
    }
  end

  defp apply_redirect(state, message) do
    case {state.running_task, state.abort_ref} do
      {task, abort_ref} when not is_nil(task) and is_reference(abort_ref) ->
        # Enqueue the correction before raising the redirect flag so it is
        # already in the steering queue when the loop observes the flag and
        # drains steering. The abort_ref stays a plain reference: a redirect
        # must never flip it to the {:aborted, ref} sentinel, or was_aborted
        # bookkeeping would misreport.
        state = enqueue_steering(state, message)
        AbortSignal.request_redirect(abort_ref)
        state

      _ ->
        # No live run (idle, or the current run is already aborting):
        # degrade to follow-up semantics.
        enqueue_follow_up(state, message)
    end
  end

  defp enqueue_follow_up(state, message) do
    state = append_input(state, :follow_up_queue, message)
    maybe_start_queued(state)
  end

  defp enqueue_steering(state, message) do
    state = append_input(state, :steering_queue, message)

    if is_pid(state.queue_consumer) do
      send(state.queue_consumer, {:lemon_steering_changed, state.abort_ref})
    end

    if state.loop_closing, do: maybe_start_queued(state), else: state
  end

  defp maybe_start_queued(%{running_task: nil} = state) do
    if state.steering_queue != [] or state.follow_up_queue != [] do
      queued = %{
        state
        | steering_queue: state.steering_queue ++ state.follow_up_queue,
          follow_up_queue: []
      }

      case start_loop(nil, queued, queued_start: true) do
        {:ok, started} ->
          started

        {:error, reason} ->
          # Admission rejection leaves queued input in place for the next run.
          Logger.warning("LemonAgent queued input not started: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp maybe_start_queued(state), do: state

  defp drain_loop_queue(state, :has_steering) do
    {Enum.any?(state.steering_queue, &preempting_message?/1), state}
  end

  defp drain_loop_queue(state, :steering) do
    {messages, queue} = consume_steering_queue(state.steering_queue)
    {messages, %{state | steering_queue: queue}}
  end

  defp drain_loop_queue(state, :follow_up) do
    cond do
      state.steering_queue != [] ->
        drain_loop_queue(state, :steering)

      state.follow_up_queue != [] ->
        {messages, queue} = consume_queue(state.follow_up_queue)
        {messages, %{state | follow_up_queue: queue}}

      true ->
        {[], %{state | loop_closing: true}}
    end
  end

  defp input_id(%{message: message}), do: input_id(message)
  defp input_id(message) when is_map(message), do: Map.get(message, :id)
  defp input_id(_message), do: nil

  defp append_input(state, queue, message) do
    id = input_id(message)

    duplicate? =
      is_binary(id) and
        (MapSet.member?(state.bound_input_ids, id) or
           Enum.any?(state.steering_queue, &(input_id(&1) == id)) or
           Enum.any?(state.follow_up_queue, &(input_id(&1) == id)))

    if duplicate? do
      state
    else
      Map.update!(state, queue, &(&1 ++ [message]))
    end
  end

  @spec consume_queue(list(Types.agent_message())) ::
          {list(Types.agent_message()), list(Types.agent_message())}
  defp consume_queue([]), do: {[], []}
  defp consume_queue([first | rest]), do: {[first], rest}

  defp normalize_error_reason({:budget_exceeded, %{message: message}}), do: message
  defp normalize_error_reason(reason) when is_binary(reason), do: reason
  defp normalize_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_error_reason(reason), do: inspect(reason)
end
