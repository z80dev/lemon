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
           status: :running | :completed | :error | :stopping
         }

  @cleanup_wait_timeout 5_000
  @task_supervisor CodingAgent.TaskSupervisor

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
    GenServer.call(coordinator, :abort_all, :infinity)
  catch
    :exit, _ ->
      :ok
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
        if subagent_state.status == :stopping do
          {:noreply, remove_subagent(id, state)}
        else
          Logger.warning(
            "Subagent #{id} (#{subagent_state.session_id}) crashed: #{inspect(reason)}"
          )

          {:noreply, remove_subagent(id, state)}
        end

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

  def handle_info(:abort_all, state) do
    new_state = abort_all_subagents(state)
    {:noreply, new_state}
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

  @spec collect_results(
          [{String.t(), subagent_spec(), {:ok, subagent_state()} | {:error, term()}}],
          pos_integer(),
          t()
        ) ::
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
  defp await_subagents([], _deadline, results, state) do
    await_cleanup_completion(results, state)
  end

  defp await_subagents(pending_ids, deadline, results, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      handle_await_timeout(pending_ids, results, state)
    else
      receive do
        msg ->
          case handle_await_message(msg, pending_ids, results, state) do
            {:continue, new_pending, new_results, new_state} ->
              await_subagents(new_pending, deadline, new_results, new_state)

            {:done, final_results, final_state} ->
              {final_results, final_state}

            :exit ->
              exit(:terminate)
          end
      after
        min(remaining, 1000) ->
          await_subagents(pending_ids, deadline, results, state)
      end
    end
  end

  # Handle timeout case
  defp handle_await_timeout(pending_ids, results, state) do
    timeout_results = build_timeout_results(pending_ids, results, state)
    new_state = Enum.reduce(pending_ids, state, &cleanup_subagent/2)
    await_cleanup_completion(timeout_results, new_state)
  end

  defp build_timeout_results(pending_ids, results, state) do
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
  end

  # Handle different message types during await
  defp handle_await_message({:"$gen_call", from, :list_active}, pending_ids, results, state) do
    GenServer.reply(from, Map.keys(state.active_subagents))
    {:continue, pending_ids, results, state}
  end

  defp handle_await_message({:"$gen_call", from, :abort_all}, pending_ids, results, state) do
    GenServer.reply(from, :ok)
    aborted_results = build_aborted_results(pending_ids, results, state)
    new_state = abort_all_subagents(state)
    {:done, aborted_results, new_state}
  end

  defp handle_await_message(:abort_all, pending_ids, results, state) do
    aborted_results = build_aborted_results(pending_ids, results, state)
    new_state = abort_all_subagents(state)
    {:done, aborted_results, new_state}
  end

  defp handle_await_message({:system, from, {:terminate, _reason}}, _pending_ids, _results, _state) do
    GenServer.reply(from, :ok)
    :exit
  end

  defp handle_await_message(
         {:session_event, session_id, {:agent_end, messages}},
         pending_ids,
         results,
         state
       ) do
    case find_subagent_by_session(state, session_id) do
      {id, _subagent_state} ->
        if id in pending_ids do
          result = build_completed_result(id, session_id, messages)
          new_state = cleanup_subagent(id, state)
          {:continue, List.delete(pending_ids, id), Map.put(results, id, result), new_state}
        else
          {:continue, pending_ids, results, state}
        end

      _ ->
        {:continue, pending_ids, results, state}
    end
  end

  defp handle_await_message(
         {:session_event, session_id, {:error, reason, _partial}},
         pending_ids,
         results,
         state
       ) do
    case find_subagent_by_session(state, session_id) do
      {id, _subagent_state} ->
        if id in pending_ids do
          result = build_error_result(id, session_id, reason)
          new_state = cleanup_subagent(id, state)
          {:continue, List.delete(pending_ids, id), Map.put(results, id, result), new_state}
        else
          {:continue, pending_ids, results, state}
        end

      _ ->
        {:continue, pending_ids, results, state}
    end
  end

  defp handle_await_message({:DOWN, ref, :process, _pid, reason}, pending_ids, results, state) do
    case find_subagent_by_monitor(state, ref) do
      {id, %{status: :stopping}} ->
        new_state = remove_subagent(id, state)
        {:continue, List.delete(pending_ids, id), results, new_state}

      {id, subagent_state} ->
        if id in pending_ids do
          result = build_crashed_result(id, subagent_state.session_id, reason)
          new_state = remove_subagent(id, state)
          {:continue, List.delete(pending_ids, id), Map.put(results, id, result), new_state}
        else
          {:continue, pending_ids, results, state}
        end

      _ ->
        {:continue, pending_ids, results, state}
    end
  end

  defp handle_await_message(_other, pending_ids, results, state) do
    {:continue, pending_ids, results, state}
  end

  # Result builders
  defp build_aborted_results(pending_ids, results, state) do
    Enum.reduce(pending_ids, results, fn id, acc ->
      subagent = Map.get(state.active_subagents, id)
      session_id = if subagent, do: subagent.session_id, else: nil

      Map.put(acc, id, %{
        id: id,
        status: :aborted,
        result: nil,
        error: :aborted,
        session_id: session_id
      })
    end)
  end

  defp build_completed_result(id, session_id, messages) do
    %{
      id: id,
      status: :completed,
      result: extract_final_text(messages),
      error: nil,
      session_id: session_id
    }
  end

  defp build_error_result(id, session_id, reason) do
    %{
      id: id,
      status: :error,
      result: nil,
      error: reason,
      session_id: session_id
    }
  end

  defp build_crashed_result(id, session_id, reason) do
    %{
      id: id,
      status: :error,
      result: nil,
      error: {:crashed, reason},
      session_id: session_id
    }
  end

  @spec await_cleanup_completion(%{String.t() => subagent_result()}, t()) ::
          {%{String.t() => subagent_result()}, t()}
  defp await_cleanup_completion(results, state) do
    deadline = System.monotonic_time(:millisecond) + @cleanup_wait_timeout
    do_await_cleanup_completion(results, state, deadline)
  end

  @spec do_await_cleanup_completion(%{String.t() => subagent_result()}, t(), integer()) ::
          {%{String.t() => subagent_result()}, t()}
  defp do_await_cleanup_completion(results, state, deadline) do
    cond do
      not cleanup_pending?(state) ->
        {results, state}

      deadline_exceeded?(deadline) ->
        {results, state}

      true ->
        receive do
          msg ->
            case handle_cleanup_message(msg, state) do
              {:continue, new_state} ->
                do_await_cleanup_completion(results, new_state, deadline)

              :exit ->
                exit(:terminate)
            end
        after
          cleanup_poll_interval(deadline) ->
            do_await_cleanup_completion(results, state, deadline)
        end
    end
  end

  defp deadline_exceeded?(deadline) do
    deadline - System.monotonic_time(:millisecond) <= 0
  end

  defp cleanup_poll_interval(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    min(max(remaining, 0), 1000)
  end

  defp handle_cleanup_message({:"$gen_call", from, :list_active}, state) do
    GenServer.reply(from, Map.keys(state.active_subagents))
    {:continue, state}
  end

  defp handle_cleanup_message({:"$gen_call", from, :abort_all}, state) do
    GenServer.reply(from, :ok)
    {:continue, abort_all_subagents(state)}
  end

  defp handle_cleanup_message(:abort_all, state) do
    {:continue, abort_all_subagents(state)}
  end

  defp handle_cleanup_message({:system, from, {:terminate, _reason}}, _state) do
    GenServer.reply(from, :ok)
    :exit
  end

  defp handle_cleanup_message({:DOWN, ref, :process, _pid, reason}, state) do
    new_state =
      case find_subagent_by_monitor(state, ref) do
        {id, %{status: :stopping}} ->
          remove_subagent(id, state)

        {id, subagent_state} ->
          Logger.warning(
            "Subagent #{id} (#{subagent_state.session_id}) crashed: #{inspect(reason)}"
          )

          remove_subagent(id, state)

        nil ->
          state
      end

    {:continue, new_state}
  end

  defp handle_cleanup_message(_other, state) do
    {:continue, state}
  end

  @spec cleanup_pending?(t()) :: boolean()
  defp cleanup_pending?(state) do
    Enum.any?(state.active_subagents, fn {_id, subagent_state} ->
      subagent_state.status == :stopping
    end)
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

      %{status: :stopping} ->
        state

      subagent_state ->
        if subagent_state.pid && Process.alive?(subagent_state.pid) do
          pid = subagent_state.pid

          # Stop asynchronously, but keep bookkeeping until the :DOWN confirms
          # the process is actually gone.
          _ =
            start_background_task(fn ->
              try do
                Session.abort(pid)
              rescue
                _ -> :ok
              end

              try do
                stop_session(pid)
              rescue
                _ -> :ok
              end
            end)

          new_subagents =
            Map.put(state.active_subagents, id, %{subagent_state | status: :stopping})

          %{state | active_subagents: new_subagents}
        else
          if subagent_state.monitor_ref do
            Process.demonitor(subagent_state.monitor_ref, [:flush])
          end

          remove_subagent(id, state)
        end
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

  defp start_background_task(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:noproc, _}} ->
        Task.start(fun)

      {:error, :noproc} ->
        Task.start(fun)

      {:error, reason} ->
        Logger.warning(
          "Failed to start supervised coordinator task: #{inspect(reason)}; falling back to Task.start/1"
        )

        Task.start(fun)
    end
  end
end
