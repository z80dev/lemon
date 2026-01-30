defmodule CodingAgent.Coordinator do
  @moduledoc """
  GenServer that coordinates multiple concurrent subagent executions.

  The Coordinator manages the lifecycle of subagent sessions, providing:
  - Concurrent execution of multiple subagents with the same prompt
  - Single subagent execution with result collection
  - Process monitoring and crash handling
  - Configurable timeouts with automatic cleanup
  - Registry tracking for all spawned subagents

  ## Usage

      # Start the coordinator
      {:ok, coordinator} = CodingAgent.Coordinator.start_link(
        cwd: "/path/to/project",
        model: my_model
      )

      # Run multiple subagents concurrently
      results = CodingAgent.Coordinator.run_subagents(coordinator, [
        %{prompt: "Analyze the code structure", subagent: "research"},
        %{prompt: "Analyze the code structure", subagent: "review"}
      ])

      # Run a single subagent
      {:ok, result} = CodingAgent.Coordinator.run_subagent(coordinator,
        prompt: "Implement the feature",
        subagent: "implement"
      )

  ## Architecture

  The Coordinator uses `CodingAgent.SessionSupervisor` to start sessions,
  ensuring proper supervision. Each subagent is monitored for crashes,
  and all active subagents are tracked by ID in the state.

  Timeouts are enforced at the coordinator level. When a timeout occurs,
  all remaining subagents are aborted and stopped.
  """

  use GenServer
  require Logger

  alias CodingAgent.Session
  alias CodingAgent.Subagents

  # ============================================================================
  # Types
  # ============================================================================

  @type subagent_spec :: %{
          required(:prompt) => String.t(),
          optional(:subagent) => String.t() | nil,
          optional(:description) => String.t() | nil
        }

  @type subagent_result :: %{
          id: String.t(),
          status: :completed | :error | :timeout | :aborted,
          result: String.t() | nil,
          error: term() | nil,
          session_id: String.t() | nil
        }

  @type t :: %__MODULE__{
          cwd: String.t(),
          model: Ai.Types.Model.t(),
          thinking_level: AgentCore.Types.thinking_level(),
          settings_manager: CodingAgent.SettingsManager.t() | nil,
          parent_session: String.t() | nil,
          active_subagents: %{String.t() => subagent_state()},
          default_timeout: pos_integer()
        }

  @typep subagent_state :: %{
           pid: pid(),
           session_id: String.t(),
           monitor_ref: reference(),
           caller: {pid(), reference()} | nil,
           status: :running | :completed | :error
         }

  defstruct [
    :cwd,
    :model,
    :thinking_level,
    :settings_manager,
    :parent_session,
    active_subagents: %{},
    default_timeout: 300_000
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts a new Coordinator GenServer.

  ## Options (required)

    * `:cwd` - Working directory for subagent sessions
    * `:model` - The AI model to use for subagents

  ## Options (optional)

    * `:thinking_level` - Extended reasoning level (default: :off)
    * `:settings_manager` - Settings manager for API keys and configuration
    * `:parent_session` - Parent session ID for lineage tracking
    * `:default_timeout` - Default timeout in ms for subagent execution (default: 300_000)
    * `:name` - GenServer name for registration
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Run multiple subagents concurrently and collect all results.

  Spawns N subagent sessions, each with the given prompt (optionally specialized
  by subagent type). Waits for all to complete or timeout.

  ## Parameters

    * `coordinator` - The coordinator pid or name
    * `specs` - List of subagent specifications (maps with :prompt, optional :subagent, :description)
    * `opts` - Options including :timeout (default: coordinator's default_timeout)

  ## Returns

  A list of `subagent_result` maps, one for each spec in the same order.

  ## Examples

      results = CodingAgent.Coordinator.run_subagents(coordinator, [
        %{prompt: "Research the codebase", subagent: "research"},
        %{prompt: "Review for bugs", subagent: "review"}
      ], timeout: 60_000)
  """
  @spec run_subagents(GenServer.server(), [subagent_spec()], keyword()) :: [subagent_result()]
  def run_subagents(coordinator, specs, opts \\ []) when is_list(specs) do
    GenServer.call(coordinator, {:run_subagents, specs, opts}, :infinity)
  end

  @doc """
  Run a single subagent and wait for the result.

  ## Parameters

    * `coordinator` - The coordinator pid or name
    * `opts` - Options including :prompt (required), :subagent, :description, :timeout

  ## Returns

    * `{:ok, result}` - The subagent completed successfully with the result text
    * `{:error, reason}` - The subagent failed or timed out

  ## Examples

      {:ok, result} = CodingAgent.Coordinator.run_subagent(coordinator,
        prompt: "Implement the login feature",
        subagent: "implement",
        timeout: 120_000
      )
  """
  @spec run_subagent(GenServer.server(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_subagent(coordinator, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    subagent = Keyword.get(opts, :subagent)
    description = Keyword.get(opts, :description)
    timeout = Keyword.get(opts, :timeout)

    spec = %{prompt: prompt, subagent: subagent, description: description}
    run_opts = if timeout, do: [timeout: timeout], else: []

    case run_subagents(coordinator, [spec], run_opts) do
      [%{status: :completed, result: result}] -> {:ok, result}
      [%{status: status, error: error}] -> {:error, {status, error}}
    end
  end

  @doc """
  List all currently active subagent session IDs.
  """
  @spec list_active(GenServer.server()) :: [String.t()]
  def list_active(coordinator) do
    GenServer.call(coordinator, :list_active)
  end

  @doc """
  Abort all active subagents.

  This will send abort signals to all running subagent sessions and stop them.
  """
  @spec abort_all(GenServer.server()) :: :ok
  def abort_all(coordinator) do
    GenServer.call(coordinator, :abort_all)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    model = Keyword.fetch!(opts, :model)

    state = %__MODULE__{
      cwd: cwd,
      model: model,
      thinking_level: Keyword.get(opts, :thinking_level, :off),
      settings_manager: Keyword.get(opts, :settings_manager),
      parent_session: Keyword.get(opts, :parent_session),
      default_timeout: Keyword.get(opts, :default_timeout, 300_000),
      active_subagents: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:run_subagents, specs, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, state.default_timeout)

    # Generate IDs for each spec
    specs_with_ids =
      Enum.map(specs, fn spec ->
        id = generate_subagent_id()
        {id, spec}
      end)

    # Start all subagents
    {started, state} =
      Enum.reduce(specs_with_ids, {[], state}, fn {id, spec}, {acc, st} ->
        case start_subagent(id, spec, st) do
          {:ok, subagent_state, new_state} ->
            {[{id, spec, {:ok, subagent_state}} | acc], new_state}

          {:error, reason} ->
            {[{id, spec, {:error, reason}} | acc], st}
        end
      end)

    started = Enum.reverse(started)

    # Collect results with timeout
    {results, final_state} = collect_results(started, timeout, state)

    # Map results back to the original spec order
    results_map = Map.new(results, fn result -> {result.id, result} end)

    ordered_results =
      Enum.map(specs_with_ids, fn {id, _spec} ->
        Map.get(results_map, id, %{
          id: id,
          status: :error,
          result: nil,
          error: :not_found,
          session_id: nil
        })
      end)

    {:reply, ordered_results, final_state}
  end

  def handle_call(:list_active, _from, state) do
    ids = Map.keys(state.active_subagents)
    {:reply, ids, state}
  end

  def handle_call(:abort_all, _from, state) do
    new_state = abort_all_subagents(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Find the subagent that crashed
    case find_subagent_by_monitor(state, ref) do
      {id, subagent_state} ->
        Logger.warning(
          "Subagent #{id} (#{subagent_state.session_id}) crashed: #{inspect(reason)}"
        )

        new_subagents =
          Map.update!(state.active_subagents, id, fn sa ->
            %{sa | status: :error, pid: nil}
          end)

        {:noreply, %{state | active_subagents: new_subagents}}

      nil ->
        # Unknown process, ignore
        {:noreply, state}
    end
  end

  def handle_info({:session_event, session_id, event}, state) do
    # Find the subagent by session_id
    case find_subagent_by_session(state, session_id) do
      {id, _subagent_state} ->
        handle_session_event(id, event, state)

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec start_subagent(String.t(), subagent_spec(), t()) ::
          {:ok, subagent_state(), t()} | {:error, term()}
  defp start_subagent(id, spec, state) do
    prompt = spec.prompt
    subagent_id = spec[:subagent]
    description = spec[:description] || "Subagent #{id}"

    # Apply subagent prompt if specified
    final_prompt =
      case maybe_apply_subagent_prompt(prompt, subagent_id, state.cwd) do
        {:error, _} = err -> err
        p -> p
      end

    case final_prompt do
      {:error, reason} ->
        {:error, reason}

      prompt_text ->
        session_opts = build_session_opts(state, description)

        case CodingAgent.start_session(session_opts) do
          {:ok, pid} ->
            session_id = Session.get_stats(pid).session_id

            # Subscribe to session events
            _unsub = Session.subscribe(pid)

            # Monitor the session process
            monitor_ref = Process.monitor(pid)

            subagent_state = %{
              pid: pid,
              session_id: session_id,
              monitor_ref: monitor_ref,
              caller: nil,
              status: :running
            }

            new_state = %{
              state
              | active_subagents: Map.put(state.active_subagents, id, subagent_state)
            }

            # Start the prompt
            case Session.prompt(pid, prompt_text) do
              :ok ->
                {:ok, subagent_state, new_state}

              {:error, reason} ->
                # Clean up on prompt failure
                cleanup_subagent(id, new_state)
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec build_session_opts(t(), String.t()) :: keyword()
  defp build_session_opts(state, _description) do
    base_opts = [
      cwd: state.cwd,
      model: state.model,
      thinking_level: state.thinking_level,
      register: true
    ]

    base_opts
    |> maybe_add_opt(:settings_manager, state.settings_manager)
    |> maybe_add_opt(:parent_session, state.parent_session)
  end

  @spec maybe_add_opt(keyword(), atom(), term()) :: keyword()
  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec maybe_apply_subagent_prompt(String.t(), String.t() | nil, String.t()) ::
          String.t() | {:error, term()}
  defp maybe_apply_subagent_prompt(prompt, nil, _cwd), do: prompt
  defp maybe_apply_subagent_prompt(prompt, "", _cwd), do: prompt

  defp maybe_apply_subagent_prompt(prompt, subagent_id, cwd) do
    case Subagents.get(cwd, subagent_id) do
      nil ->
        {:error, "Unknown subagent: #{subagent_id}"}

      agent ->
        agent.prompt <> "\n\n" <> prompt
    end
  end

  @spec collect_results([{String.t(), subagent_spec(), {:ok, subagent_state()} | {:error, term()}}], pos_integer(), t()) ::
          {[subagent_result()], t()}
  defp collect_results(started, timeout, state) do
    # Separate successful starts from failures
    {successes, failures} =
      Enum.split_with(started, fn {_id, _spec, result} ->
        match?({:ok, _}, result)
      end)

    # Create immediate results for failures
    failure_results =
      Enum.map(failures, fn {id, _spec, {:error, reason}} ->
        %{
          id: id,
          status: :error,
          result: nil,
          error: reason,
          session_id: nil
        }
      end)

    # Wait for successful ones
    success_ids = Enum.map(successes, fn {id, _spec, _} -> id end)
    deadline = System.monotonic_time(:millisecond) + timeout

    {success_results, final_state} = await_subagents(success_ids, deadline, %{}, state)

    {failure_results ++ Map.values(success_results), final_state}
  end

  @spec await_subagents([String.t()], integer(), %{String.t() => subagent_result()}, t()) ::
          {%{String.t() => subagent_result()}, t()}
  defp await_subagents([], _deadline, results, state), do: {results, state}

  defp await_subagents(pending_ids, deadline, results, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Timeout - abort remaining and return timeout results
      timeout_results =
        Enum.reduce(pending_ids, results, fn id, acc ->
          subagent = Map.get(state.active_subagents, id)
          session_id = if subagent, do: subagent.session_id, else: nil

          Map.put(acc, id, %{
            id: id,
            status: :timeout,
            result: nil,
            error: :timeout,
            session_id: session_id
          })
        end)

      # Abort all pending
      new_state =
        Enum.reduce(pending_ids, state, fn id, st ->
          cleanup_subagent(id, st)
        end)

      {timeout_results, new_state}
    else
      receive do
        {:session_event, session_id, {:agent_end, messages}} ->
          case find_subagent_by_session(state, session_id) do
            {id, _subagent_state} ->
              if id in pending_ids do
                # Extract final text from messages
                result_text = extract_final_text(messages)

                result = %{
                  id: id,
                  status: :completed,
                  result: result_text,
                  error: nil,
                  session_id: session_id
                }

                # Cleanup the subagent
                new_state = cleanup_subagent(id, state)
                new_pending = List.delete(pending_ids, id)
                new_results = Map.put(results, id, result)

                await_subagents(new_pending, deadline, new_results, new_state)
              else
                await_subagents(pending_ids, deadline, results, state)
              end

            _ ->
              await_subagents(pending_ids, deadline, results, state)
          end

        {:session_event, session_id, {:error, reason, _partial}} ->
          case find_subagent_by_session(state, session_id) do
            {id, _subagent_state} ->
              if id in pending_ids do
                result = %{
                  id: id,
                  status: :error,
                  result: nil,
                  error: reason,
                  session_id: session_id
                }

                new_state = cleanup_subagent(id, state)
                new_pending = List.delete(pending_ids, id)
                new_results = Map.put(results, id, result)

                await_subagents(new_pending, deadline, new_results, new_state)
              else
                await_subagents(pending_ids, deadline, results, state)
              end

            _ ->
              await_subagents(pending_ids, deadline, results, state)
          end

        {:DOWN, ref, :process, _pid, reason} ->
          case find_subagent_by_monitor(state, ref) do
            {id, subagent_state} ->
              if id in pending_ids do
                result = %{
                  id: id,
                  status: :error,
                  result: nil,
                  error: {:crashed, reason},
                  session_id: subagent_state.session_id
                }

                new_state = remove_subagent(id, state)
                new_pending = List.delete(pending_ids, id)
                new_results = Map.put(results, id, result)

                await_subagents(new_pending, deadline, new_results, new_state)
              else
                await_subagents(pending_ids, deadline, results, state)
              end

            _ ->
              await_subagents(pending_ids, deadline, results, state)
          end

        _other ->
          await_subagents(pending_ids, deadline, results, state)
      after
        min(remaining, 1000) ->
          await_subagents(pending_ids, deadline, results, state)
      end
    end
  end

  @spec extract_final_text([map()]) :: String.t()
  defp extract_final_text(messages) do
    messages
    |> Enum.filter(&match?(%Ai.Types.AssistantMessage{}, &1))
    |> List.last()
    |> case do
      nil -> ""
      msg -> Ai.get_text(msg) || ""
    end
  end

  @spec find_subagent_by_session(t(), String.t()) :: {String.t(), subagent_state()} | nil
  defp find_subagent_by_session(state, session_id) do
    Enum.find(state.active_subagents, fn {_id, sa} ->
      sa.session_id == session_id
    end)
  end

  @spec find_subagent_by_monitor(t(), reference()) :: {String.t(), subagent_state()} | nil
  defp find_subagent_by_monitor(state, ref) do
    Enum.find(state.active_subagents, fn {_id, sa} ->
      sa.monitor_ref == ref
    end)
  end

  @spec cleanup_subagent(String.t(), t()) :: t()
  defp cleanup_subagent(id, state) do
    case Map.get(state.active_subagents, id) do
      nil ->
        state

      subagent_state ->
        # Demonitor
        if subagent_state.monitor_ref do
          Process.demonitor(subagent_state.monitor_ref, [:flush])
        end

        # Stop the session
        if subagent_state.pid && Process.alive?(subagent_state.pid) do
          try do
            Session.abort(subagent_state.pid)
            stop_session(subagent_state.pid)
          rescue
            _ -> :ok
          end
        end

        remove_subagent(id, state)
    end
  end

  @spec remove_subagent(String.t(), t()) :: t()
  defp remove_subagent(id, state) do
    %{state | active_subagents: Map.delete(state.active_subagents, id)}
  end

  @spec abort_all_subagents(t()) :: t()
  defp abort_all_subagents(state) do
    Enum.reduce(Map.keys(state.active_subagents), state, fn id, st ->
      cleanup_subagent(id, st)
    end)
  end

  @spec stop_session(pid()) :: :ok
  defp stop_session(session) when is_pid(session) do
    try do
      if Process.whereis(CodingAgent.SessionSupervisor) do
        _ = CodingAgent.SessionSupervisor.stop_session(session)
      else
        GenServer.stop(session, :normal, 5_000)
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  @spec handle_session_event(String.t(), term(), t()) :: {:noreply, t()}
  defp handle_session_event(_id, _event, state) do
    # Events are handled in await_subagents, this is just for completeness
    {:noreply, state}
  end

  @spec generate_subagent_id() :: String.t()
  defp generate_subagent_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
