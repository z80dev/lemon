defmodule AgentCore.Agent do
  @moduledoc """
  GenServer implementation of an AI Agent that manages conversation state and streams.

  This module ports the TypeScript Agent class to Elixir, providing a stateful
  process that handles prompts, tool execution, and event broadcasting to subscribers.

  ## Features

  - **State Management**: Maintains conversation messages, model configuration, and tools
  - **Streaming**: Consumes AgentCore.Loop streams and broadcasts events to subscribers
  - **Queue System**: Supports steering (mid-run interrupts) and follow-up message queues
  - **Abort Support**: Allows cancellation of running streams
  - **Subscriber Management**: Auto-cleanup of dead subscribers via process monitoring

  ## Usage

      {:ok, agent} = AgentCore.Agent.start_link(
        initial_state: %{system_prompt: "You are a helpful assistant"},
        convert_to_llm: &my_converter/1
      )

      # Subscribe to events
      unsubscribe = AgentCore.Agent.subscribe(agent, self())

      # Send a prompt
      :ok = AgentCore.Agent.prompt(agent, "Hello!")

      # Wait for completion
      :ok = AgentCore.Agent.wait_for_idle(agent)

  ## State

  The agent maintains the following state:

  - `agent_state` - The AgentCore.Types.AgentState containing messages, model, tools, etc.
  - `listeners` - List of subscriber PIDs that receive events
  - `abort_ref` - Reference for abort signaling
  - `running_task` - The currently running Task or nil
  - `steering_queue` / `follow_up_queue` - Message queues for mid-run and post-run messages
  - `waiters` - Processes waiting for the agent to become idle
  """

  use GenServer
  require Logger

  alias AgentCore.AbortSignal
  alias AgentCore.Types
  alias AgentCore.Types.{AgentLoopConfig, AgentState}
  alias Ai.Types.StreamOptions

  @follow_up_poll_timeout_ms 50

  # ============================================================================
  # Types
  # ============================================================================

  @type queue_mode :: :all | :one_at_a_time

  @type convert_to_llm_fn ::
          (list(Types.agent_message()) ->
             list(Ai.Types.message()) | {:ok, list(Ai.Types.message())})

  @type transform_context_fn ::
          (list(Types.agent_message()), reference() | nil ->
             {:ok, list(Types.agent_message())} | list(Types.agent_message()))

  @type stream_fn ::
          (Ai.Types.Model.t(), Ai.Types.Context.t(), Ai.Types.StreamOptions.t() ->
             {:ok, Ai.EventStream.t()} | Ai.EventStream.t() | {:error, term()})

  @type get_api_key_fn :: (String.t() -> String.t() | nil)

  @type waiter :: {:call, GenServer.from()} | {:notify, pid(), reference()}

  @type state :: %{
          agent_state: AgentState.t(),
          listeners: list({pid(), reference()}),
          abort_ref: reference() | nil,
          running_task: Task.t() | nil,
          steering_queue: list(Types.agent_message()),
          follow_up_queue: list(Types.agent_message()),
          steering_mode: queue_mode(),
          follow_up_mode: queue_mode(),
          convert_to_llm: convert_to_llm_fn(),
          transform_context: transform_context_fn() | nil,
          stream_fn: stream_fn() | nil,
          session_id: String.t() | nil,
          get_api_key: get_api_key_fn() | nil,
          thinking_budgets: map(),
          stream_options: StreamOptions.t(),
          waiters: list(waiter())
        }

  @type opts :: [
          initial_state: map(),
          convert_to_llm: convert_to_llm_fn(),
          transform_context: transform_context_fn(),
          stream_fn: stream_fn() | nil,
          steering_mode: queue_mode(),
          follow_up_mode: queue_mode(),
          session_id: String.t(),
          get_api_key: get_api_key_fn(),
          thinking_budgets: map(),
          stream_options: StreamOptions.t(),
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
  - `:stream_fn` - Custom stream function (defaults to Loop's `Ai.stream/3`)
  - `:steering_mode` - How to consume steering queue: `:all` or `:one_at_a_time` (default)
  - `:follow_up_mode` - How to consume follow-up queue: `:all` or `:one_at_a_time` (default)
  - `:session_id` - Optional session identifier for provider caching
  - `:get_api_key` - Function to dynamically resolve API keys
  - `:thinking_budgets` - Map of thinking level budgets for token-based providers
  - `:stream_options` - StreamOptions for provider requests (temperature, max_tokens, etc.)
  - `:name` - Optional GenServer name

  ## Examples

      {:ok, agent} = AgentCore.Agent.start_link(
        initial_state: %{system_prompt: "You are helpful"},
        convert_to_llm: fn msgs -> Enum.filter(msgs, &llm_compatible?/1) end
      )
  """
  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Sends a prompt to the agent.

  The prompt can be:
  - A string (converted to a user message)
  - An agent message struct
  - A list of agent message structs

  Returns `:ok` immediately. Use `wait_for_idle/1` to wait for completion.
  Returns `{:error, :already_streaming}` if a prompt is already being processed.

  ## Examples

      :ok = AgentCore.Agent.prompt(agent, "Hello!")
      :ok = AgentCore.Agent.prompt(agent, %{role: :user, content: "Hi", timestamp: now})
      :ok = AgentCore.Agent.prompt(agent, [msg1, msg2])
  """
  @spec prompt(
          GenServer.server(),
          String.t() | Types.agent_message() | list(Types.agent_message())
        ) ::
          :ok | {:error, :already_streaming}
  def prompt(agent, message) do
    GenServer.call(agent, {:prompt, message})
  end

  @doc """
  Continues from the current context.

  Used for retrying after overflow or continuing from existing messages.
  Returns `{:error, :already_streaming}` if already processing.
  Returns `{:error, :no_messages}` if there are no messages to continue from.
  Returns `{:error, :cannot_continue}` if the last message is from the assistant.
  """
  @spec continue(GenServer.server()) ::
          :ok | {:error, :already_streaming | :no_messages | :cannot_continue}
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

      unsubscribe = AgentCore.Agent.subscribe(agent, self())

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

      :ok = AgentCore.Agent.wait_for_idle(agent)
      :ok = AgentCore.Agent.wait_for_idle(agent, timeout: 5000)
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
  @spec set_system_prompt(GenServer.server(), String.t()) :: :ok
  def set_system_prompt(agent, prompt) when is_binary(prompt) do
    GenServer.call(agent, {:set_system_prompt, prompt})
  end

  @doc """
  Sets the model to use for LLM calls.
  """
  @spec set_model(GenServer.server(), Ai.Types.Model.t()) :: :ok
  def set_model(agent, model) do
    GenServer.call(agent, {:set_model, model})
  end

  @doc """
  Sets the thinking/reasoning level.

  Valid levels: :off, :minimal, :low, :medium, :high, :xhigh
  """
  @spec set_thinking_level(GenServer.server(), AgentState.thinking_level()) :: :ok
  def set_thinking_level(agent, level) do
    GenServer.call(agent, {:set_thinking_level, level})
  end

  @doc """
  Sets the available tools.
  """
  @spec set_tools(GenServer.server(), list(AgentCore.Types.AgentTool.t())) :: :ok
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
  """
  @spec steer(GenServer.server(), Types.agent_message()) :: :ok
  def steer(agent, message) do
    GenServer.cast(agent, {:steer, message})
  end

  @doc """
  Queues a follow-up message to be processed after the agent finishes.

  Follow-up messages are delivered only when the agent has no more tool calls
  and no steering messages. Use this for messages that should wait until the
  agent completes its current work.
  """
  @spec follow_up(GenServer.server(), Types.agent_message()) :: :ok
  def follow_up(agent, message) do
    GenServer.cast(agent, {:follow_up, message})
  end

  @doc """
  Clears all pending steering messages.
  """
  @spec clear_steering_queue(GenServer.server()) :: :ok
  def clear_steering_queue(agent) do
    GenServer.call(agent, :clear_steering_queue)
  end

  @doc """
  Clears all pending follow-up messages.
  """
  @spec clear_follow_up_queue(GenServer.server()) :: :ok
  def clear_follow_up_queue(agent) do
    GenServer.call(agent, :clear_follow_up_queue)
  end

  @doc """
  Clears all pending steering and follow-up messages.
  """
  @spec clear_all_queues(GenServer.server()) :: :ok
  def clear_all_queues(agent) do
    GenServer.call(agent, :clear_all_queues)
  end

  @doc """
  Sets the steering queue consumption mode.

  - `:all` - Send all steering messages at once
  - `:one_at_a_time` - Send one steering message per turn
  """
  @spec set_steering_mode(GenServer.server(), queue_mode()) :: :ok
  def set_steering_mode(agent, mode) when mode in [:all, :one_at_a_time] do
    GenServer.call(agent, {:set_steering_mode, mode})
  end

  @doc """
  Sets the follow-up queue consumption mode.

  - `:all` - Send all follow-up messages at once
  - `:one_at_a_time` - Send one follow-up message per turn
  """
  @spec set_follow_up_mode(GenServer.server(), queue_mode()) :: :ok
  def set_follow_up_mode(agent, mode) when mode in [:all, :one_at_a_time] do
    GenServer.call(agent, {:set_follow_up_mode, mode})
  end

  # ============================================================================
  # Getters
  # ============================================================================

  @doc """
  Gets the current agent state.
  """
  @spec get_state(GenServer.server()) :: AgentState.t()
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc """
  Gets the current session ID.
  """
  @spec get_session_id(GenServer.server()) :: String.t() | nil
  def get_session_id(agent) do
    GenServer.call(agent, :get_session_id)
  end

  @doc """
  Sets the session ID for provider caching.
  """
  @spec set_session_id(GenServer.server(), String.t() | nil) :: :ok
  def set_session_id(agent, session_id) do
    GenServer.call(agent, {:set_session_id, session_id})
  end

  @doc """
  Gets the steering queue mode.
  """
  @spec get_steering_mode(GenServer.server()) :: queue_mode()
  def get_steering_mode(agent) do
    GenServer.call(agent, :get_steering_mode)
  end

  @doc """
  Gets the follow-up queue mode.
  """
  @spec get_follow_up_mode(GenServer.server()) :: queue_mode()
  def get_follow_up_mode(agent) do
    GenServer.call(agent, :get_follow_up_mode)
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
      thinking_level: Map.get(initial_state_opts, :thinking_level, :off),
      tools: Map.get(initial_state_opts, :tools, []),
      messages: Map.get(initial_state_opts, :messages, []),
      is_streaming: false,
      stream_message: nil,
      pending_tool_calls: MapSet.new(),
      error: nil
    }

    convert_to_llm = Keyword.get(opts, :convert_to_llm, &default_convert_to_llm/1)
    transform_context = Keyword.get(opts, :transform_context)
    stream_fn = Keyword.get(opts, :stream_fn)
    stream_options = Keyword.get(opts, :stream_options, %StreamOptions{})

    state = %{
      agent_state: agent_state,
      listeners: [],
      abort_ref: nil,
      running_task: nil,
      steering_queue: [],
      follow_up_queue: [],
      follow_up_poll: nil,
      steering_mode: Keyword.get(opts, :steering_mode, :one_at_a_time),
      follow_up_mode: Keyword.get(opts, :follow_up_mode, :one_at_a_time),
      convert_to_llm: convert_to_llm,
      transform_context: transform_context,
      stream_fn: stream_fn,
      session_id: Keyword.get(opts, :session_id),
      get_api_key: Keyword.get(opts, :get_api_key),
      thinking_budgets: Keyword.get(opts, :thinking_budgets, %{}),
      stream_options: stream_options,
      waiters: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:prompt, message}, _from, state) do
    if state.agent_state.is_streaming do
      {:reply, {:error, :already_streaming}, state}
    else
      messages = normalize_prompt_input(message)
      new_state = start_loop(messages, state)
      {:reply, :ok, new_state}
    end
  end

  def handle_call(:continue, _from, state) do
    cond do
      state.agent_state.is_streaming ->
        {:reply, {:error, :already_streaming}, state}

      state.agent_state.messages == [] ->
        {:reply, {:error, :no_messages}, state}

      match?(%{role: :assistant}, List.last(state.agent_state.messages)) ->
        {:reply, {:error, :cannot_continue}, state}

      true ->
        new_state = start_loop(nil, state)
        {:reply, :ok, new_state}
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
        steering_queue: [],
        follow_up_queue: []
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:set_system_prompt, prompt}, _from, state) do
    new_agent_state = %{state.agent_state | system_prompt: prompt}
    {:reply, :ok, %{state | agent_state: new_agent_state}}
  end

  def handle_call({:set_model, model}, _from, state) do
    new_agent_state = %{state.agent_state | model: model}
    {:reply, :ok, %{state | agent_state: new_agent_state}}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    new_agent_state = %{state.agent_state | thinking_level: level}
    {:reply, :ok, %{state | agent_state: new_agent_state}}
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

  def handle_call(:clear_steering_queue, _from, state) do
    {:reply, :ok, %{state | steering_queue: []}}
  end

  def handle_call(:clear_follow_up_queue, _from, state) do
    {:reply, :ok, %{state | follow_up_queue: []}}
  end

  def handle_call(:clear_all_queues, _from, state) do
    {:reply, :ok, %{state | steering_queue: [], follow_up_queue: []}}
  end

  def handle_call({:set_steering_mode, mode}, _from, state) do
    {:reply, :ok, %{state | steering_mode: mode}}
  end

  def handle_call({:set_follow_up_mode, mode}, _from, state) do
    {:reply, :ok, %{state | follow_up_mode: mode}}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.agent_state, state}
  end

  def handle_call(:get_session_id, _from, state) do
    {:reply, state.session_id, state}
  end

  def handle_call({:set_session_id, session_id}, _from, state) do
    {:reply, :ok, %{state | session_id: session_id}}
  end

  def handle_call(:get_steering_mode, _from, state) do
    {:reply, state.steering_mode, state}
  end

  def handle_call(:get_follow_up_mode, _from, state) do
    {:reply, state.follow_up_mode, state}
  end

  # Handle steering/follow-up message requests from the loop task
  def handle_call({:get_steering_messages, abort_ref}, _from, state) do
    if state.abort_ref == abort_ref or match?({:aborted, ^abort_ref}, state.abort_ref) do
      {messages, new_queue} = consume_queue(state.steering_queue, state.steering_mode)
      {:reply, messages, %{state | steering_queue: new_queue}}
    else
      {:reply, [], state}
    end
  end

  def handle_call({:get_follow_up_messages, abort_ref}, from, state) do
    if state.abort_ref == abort_ref or match?({:aborted, ^abort_ref}, state.abort_ref) do
      if state.follow_up_queue != [] do
        {messages, new_queue} = consume_queue(state.follow_up_queue, state.follow_up_mode)
        {:reply, messages, %{state | follow_up_queue: new_queue}}
      else
        # Long-poll briefly to close the race where a follow-up is enqueued right
        # as the loop is finishing. This keeps follow-ups inside the same run.
        poll_ref = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:follow_up_poll_timeout, poll_ref},
            @follow_up_poll_timeout_ms
          )

        state = %{
          state
          | follow_up_poll: %{
              from: from,
              abort_ref: abort_ref,
              poll_ref: poll_ref,
              timer_ref: timer_ref
            }
        }

        {:noreply, state}
      end
    else
      {:reply, [], state}
    end
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
    {:noreply, %{state | steering_queue: state.steering_queue ++ [message]}}
  end

  def handle_cast({:follow_up, message}, state) do
    state = %{state | follow_up_queue: state.follow_up_queue ++ [message]}

    state =
      case state.follow_up_poll do
        %{from: from, abort_ref: poll_abort_ref} = poll ->
          if abort_ref_matches?(state.abort_ref, poll_abort_ref) do
            if poll[:timer_ref], do: Process.cancel_timer(poll.timer_ref)
            {messages, new_queue} = consume_queue(state.follow_up_queue, state.follow_up_mode)
            GenServer.reply(from, messages)
            %{state | follow_up_queue: new_queue, follow_up_poll: nil}
          else
            state
          end

        _ ->
          state
      end

    {:noreply, state}
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

  def handle_info({:agent_event, event}, state) do
    # Event from the running task - update state and broadcast
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

  def handle_info({:follow_up_poll_timeout, poll_ref}, state) do
    case state.follow_up_poll do
      %{poll_ref: ^poll_ref, from: from} ->
        GenServer.reply(from, [])
        {:noreply, %{state | follow_up_poll: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp abort_ref_matches?(state_abort_ref, abort_ref) do
    state_abort_ref == abort_ref or state_abort_ref == {:aborted, abort_ref}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec normalize_prompt_input(String.t() | Types.agent_message() | list(Types.agent_message())) ::
          list(Types.agent_message())
  defp normalize_prompt_input(input) when is_binary(input) do
    [
      %Ai.Types.UserMessage{
        role: :user,
        content: input,
        timestamp: System.system_time(:millisecond)
      }
    ]
  end

  defp normalize_prompt_input(input) when is_list(input), do: input
  defp normalize_prompt_input(input) when is_map(input), do: [input]

  @spec start_loop(list(Types.agent_message()) | nil, state()) :: state()
  defp start_loop(messages, state) do
    abort_ref = AbortSignal.new()
    agent_pid = self()

    # Update agent state to streaming
    new_agent_state = %{
      state.agent_state
      | is_streaming: true,
        stream_message: nil,
        error: nil
    }

    # Build context for the loop
    context = %{
      system_prompt: new_agent_state.system_prompt,
      messages: new_agent_state.messages,
      tools: new_agent_state.tools
    }

    # Build config for the loop
    config = build_loop_config(state, abort_ref, agent_pid)

    # Spawn a supervised task to run the loop
    task =
      Task.Supervisor.async_nolink(AgentCore.LoopTaskSupervisor, fn ->
        run_agent_loop(messages, context, config, abort_ref, agent_pid, state.stream_fn)
      end)

    %{
      state
      | agent_state: new_agent_state,
        abort_ref: abort_ref,
        running_task: task
    }
  end

  @spec build_loop_config(state(), reference(), pid()) :: AgentLoopConfig.t()
  defp build_loop_config(state, abort_ref, agent_pid) do
    reasoning = reasoning_from_thinking_level(state.agent_state.thinking_level)
    stream_options = build_stream_options(state, reasoning)

    %AgentLoopConfig{
      model: state.agent_state.model,
      convert_to_llm: state.convert_to_llm,
      transform_context: state.transform_context,
      get_api_key: state.get_api_key,
      get_steering_messages: fn ->
        GenServer.call(agent_pid, {:get_steering_messages, abort_ref})
      end,
      get_follow_up_messages: fn ->
        GenServer.call(agent_pid, {:get_follow_up_messages, abort_ref})
      end,
      stream_options: stream_options,
      stream_fn: state.stream_fn
    }
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
    try do
      # Get the event stream from AgentCore.Loop with abort signal
      event_stream =
        if messages do
          AgentCore.Loop.agent_loop(messages, context, config, abort_ref, stream_fn, agent_pid)
        else
          AgentCore.Loop.agent_loop_continue(context, config, abort_ref, stream_fn, agent_pid)
        end

      # Consume the stream and forward events
      partial_message =
        event_stream
        |> AgentCore.EventStream.events()
        |> Enum.reduce_while(nil, fn event, partial ->
          # Send event to GenServer
          send(agent_pid, {:agent_event, event})

          # Track partial message state
          new_partial = track_partial_message(event, partial)
          {:cont, new_partial}
        end)

      # Handle any remaining partial message
      handle_remaining_partial(partial_message, agent_pid, abort_ref, config)

      :ok
    rescue
      error ->
        # Send error event
        error_event = build_error_event(error, config)
        send(agent_pid, {:agent_event, error_event})
        {:error, error}
    end
  end

  defp aborted?(abort_ref), do: AbortSignal.aborted?(abort_ref)

  defp track_partial_message({:message_start, message}, _partial), do: message
  defp track_partial_message({:message_update, message, _delta}, _partial), do: message
  defp track_partial_message({:message_end, _message}, _partial), do: nil
  defp track_partial_message(_event, partial), do: partial

  defp handle_remaining_partial(nil, _agent_pid, _abort_ref, _config), do: :ok

  defp handle_remaining_partial(partial, agent_pid, abort_ref, config) do
    # Check if partial has meaningful content
    if partial[:role] == :assistant and has_meaningful_content?(partial[:content] || []) do
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

  defp build_error_event(error, config) do
    error_msg = build_error_message(Exception.message(error), config, :error)
    {:agent_end, [error_msg]}
  end

  defp build_error_message(error_text, %AgentLoopConfig{} = config, stop_reason) do
    model = config.model || %{}

    %Ai.Types.AssistantMessage{
      role: :assistant,
      content: [%Ai.Types.TextContent{type: :text, text: ""}],
      api: Map.get(model, :api),
      provider: Map.get(model, :provider),
      model: Map.get(model, :id, ""),
      usage: %Ai.Types.Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Ai.Types.Cost{
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
  defp handle_agent_event({:message_start, message}, state) do
    new_agent_state = %{state.agent_state | stream_message: message}
    %{state | agent_state: new_agent_state}
  end

  defp handle_agent_event({:message_update, message, _delta}, state) do
    new_agent_state = %{state.agent_state | stream_message: message}
    %{state | agent_state: new_agent_state}
  end

  defp handle_agent_event({:message_end, message}, state) do
    new_messages = state.agent_state.messages ++ [message]

    new_agent_state = %{
      state.agent_state
      | stream_message: nil,
        messages: new_messages
    }

    %{state | agent_state: new_agent_state}
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

    %{state | agent_state: new_agent_state}
  end

  defp handle_agent_event({:error, reason, _partial_state}, state) do
    new_agent_state = %{state.agent_state | error: normalize_error_reason(reason)}
    %{state | agent_state: new_agent_state}
  end

  defp handle_agent_event(_event, state), do: state

  @spec handle_task_completion(term(), state()) :: state()
  defp handle_task_completion(_result, state) do
    abort_ref =
      case state.abort_ref do
        {:aborted, ref} -> ref
        ref -> ref
      end

    AbortSignal.clear(abort_ref)

    # Clear streaming state
    new_agent_state = %{
      state.agent_state
      | is_streaming: false,
        stream_message: nil,
        pending_tool_calls: MapSet.new()
    }

    # Reply to all waiters
    Enum.each(state.waiters, fn
      {:call, from} ->
        GenServer.reply(from, :ok)

      {:notify, pid, ref} ->
        send(pid, {:wait_for_idle, ref, :ok})
    end)

    %{
      state
      | agent_state: new_agent_state,
        abort_ref: nil,
        running_task: nil,
        waiters: []
    }
  end

  @spec broadcast_event(state(), AgentEvent.t()) :: :ok
  defp broadcast_event(state, event) do
    Enum.each(state.listeners, fn {pid, _ref} ->
      send(pid, {:agent_event, event})
    end)

    :ok
  end

  @spec default_convert_to_llm(list(Types.agent_message())) :: list(Ai.Types.message())
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

  @spec consume_queue(list(Types.agent_message()), queue_mode()) ::
          {list(Types.agent_message()), list(Types.agent_message())}
  defp consume_queue([], _mode), do: {[], []}

  defp consume_queue(queue, :one_at_a_time) do
    [first | rest] = queue
    {[first], rest}
  end

  defp consume_queue(queue, :all) do
    {queue, []}
  end

  defp normalize_error_reason(reason) when is_binary(reason), do: reason
  defp normalize_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_error_reason(reason), do: inspect(reason)
end
