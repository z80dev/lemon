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
        %{prompt: "Analyze the code structure", subagent: "scout"},
        %{prompt: "Analyze the code structure", subagent: "reviewer"}
      ])

      # Run a single subagent
      {:ok, result} = CodingAgent.Coordinator.run_subagent(coordinator,
        prompt: "Implement the feature",
        subagent: "task-executor"
      )

  ## Architecture

  The Coordinator uses `CodingAgent.SessionSupervisor` to start sessions.
  Supervised lifecycle workers own each session's event subscription and monitor,
  leaving the coordinator responsive during admission, prompt startup and cleanup.
  Results retain specification order, and cancelled admissions clean up any session
  that finishes starting after cancellation. Active IDs remain tracked until their
  workers and sessions have exited.

  Execution deadlines include startup. Remaining subagents are aborted and stopped
  on timeout or cancellation.
  """

  use GenServer

  alias CodingAgent.Session
  alias CodingAgent.Tools.Task.Params

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
          model: LemonAi.Types.Model.t(),
          thinking_level: LemonAgent.Types.thinking_level(),
          settings_manager: CodingAgent.SettingsManager.t() | nil,
          parent_session: String.t() | nil,
          active_subagents: %{String.t() => subagent_state()},
          default_timeout: pos_integer(),
          batches: map(),
          session_starter: (keyword() -> {:ok, pid()} | {:error, term()})
        }

  @typep subagent_state :: %{
           pid: pid() | nil,
           session_id: String.t() | nil,
           monitor_ref: reference(),
           session_monitor_ref: reference() | nil,
           worker_pid: pid() | nil,
           batch: reference(),
           status: :starting | :running | :stopping
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
    default_timeout: 300_000,
    batches: %{},
    session_starter: &CodingAgent.start_session/1
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
        %{prompt: "Research the codebase", subagent: "scout"},
        %{prompt: "Review for bugs", subagent: "reviewer"}
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
        subagent: "task-executor",
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
  def handle_call({:run_subagents, specs, opts}, from, state) do
    timeout = Keyword.get(opts, :timeout, state.default_timeout)
    specs_with_ids = Enum.map(specs, &{generate_subagent_id(), &1})

    cond do
      specs == [] ->
        {:reply, [], state}

      timeout <= 0 ->
        results = Enum.map(specs_with_ids, fn {id, _} -> terminal_result(id, nil, :timeout) end)
        {:reply, results, state}

      true ->
        batch_ref = make_ref()
        timer = Process.send_after(self(), {:batch_timeout, batch_ref}, timeout)

        batch = %{
          from: from,
          ids: Enum.map(specs_with_ids, &elem(&1, 0)),
          results: %{},
          timer: timer,
          stopping: false
        }

        state = %{state | batches: Map.put(state.batches, batch_ref, batch)}
        coordinator = self()
        worker_state = %{state | active_subagents: %{}, batches: %{}}

        state =
          Enum.reduce(specs_with_ids, state, fn {id, spec}, acc ->
            case start_background_task(fn ->
                   run_subagent_worker(coordinator, id, spec, worker_state)
                 end) do
              {:ok, worker} ->
                subagent = %{
                  pid: nil,
                  session_id: nil,
                  monitor_ref: Process.monitor(worker),
                  session_monitor_ref: nil,
                  worker_pid: worker,
                  batch: batch_ref,
                  status: :starting
                }

                %{acc | active_subagents: Map.put(acc.active_subagents, id, subagent)}

              {:error, reason} ->
                put_result(acc, batch_ref, build_error_result(id, nil, reason))
            end
          end)

        {:noreply, maybe_reply_batch(state, batch_ref)}
    end
  end

  def handle_call(:list_active, _from, state) do
    {:reply, Map.keys(state.active_subagents), state}
  end

  def handle_call(:abort_all, _from, state) do
    {:reply, :ok, cancel_all(state)}
  end

  @impl true
  def handle_info({:subagent_session, id, pid}, state) do
    case Map.get(state.active_subagents, id) do
      nil ->
        {:noreply, state}

      subagent ->
        subagent = %{subagent | pid: pid, session_monitor_ref: Process.monitor(pid)}
        {:noreply, %{state | active_subagents: Map.put(state.active_subagents, id, subagent)}}
    end
  end

  def handle_info({:subagent_ready, id, session_id}, state) do
    case Map.get(state.active_subagents, id) do
      nil ->
        {:noreply, state}

      subagent ->
        status = if subagent.status == :stopping, do: :stopping, else: :running
        subagent = %{subagent | session_id: session_id, status: status}
        {:noreply, %{state | active_subagents: Map.put(state.active_subagents, id, subagent)}}
    end
  end

  def handle_info({:subagent_result, id, result}, state) do
    case Map.get(state.active_subagents, id) do
      nil -> {:noreply, state}
      subagent -> {:noreply, put_result(state, subagent.batch, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.active_subagents, fn {_id, subagent} ->
           ref in [subagent.monitor_ref, subagent.session_monitor_ref]
         end) do
      nil ->
        {:noreply, state}

      {id, %{monitor_ref: ^ref} = subagent} ->
        result = build_crashed_result(id, subagent.session_id, reason)
        state = put_result(state, subagent.batch, result)

        if subagent.pid && Process.alive?(subagent.pid) do
          # A worker crash must not orphan the session it already admitted.
          start_background_task(fn -> cleanup_session(subagent.pid) end)
          subagent = %{subagent | worker_pid: nil, status: :stopping}
          {:noreply, %{state | active_subagents: Map.put(state.active_subagents, id, subagent)}}
        else
          {:noreply, finish_subagent(state, id, subagent)}
        end

      {id, subagent} ->
        if subagent.worker_pid do
          subagent = %{subagent | pid: nil, session_monitor_ref: nil}
          {:noreply, %{state | active_subagents: Map.put(state.active_subagents, id, subagent)}}
        else
          {:noreply, finish_subagent(state, id, subagent)}
        end
    end
  end

  def handle_info({:batch_timeout, batch_ref}, state) do
    {:noreply, cancel_batch(state, batch_ref, :timeout)}
  end

  def handle_info({:cleanup_timeout, batch_ref}, state) do
    {:noreply, reply_batch(state, batch_ref)}
  end

  def handle_info(:abort_all, state) do
    {:noreply, cancel_all(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_subagent_worker(coordinator, id, spec, state) do
    owner_ref = Process.monitor(coordinator)

    result =
      try do
        params = %{
          "prompt" => spec.prompt,
          "agent" => spec[:subagent],
          "description" => spec[:description] || "Subagent #{id}"
        }

        with {:ok, validated} <- Params.validate_run_params(params, state.cwd),
             :ok <- check_cancelled(owner_ref),
             {:ok, pid} <- state.session_starter.(build_session_opts(state, validated)) do
          # Do not kill a blocked starter on cancellation: admission may still
          # succeed. Its worker retains ownership and cleans up the late child.
          send(coordinator, {:subagent_session, id, pid})
          session_ref = Process.monitor(pid)
          # Standalone admission may link the session to this worker. Lifecycle
          # ownership is monitor-based, so intentional shutdown must not kill it.
          Process.unlink(pid)

          try do
            with :ok <- check_cancelled(owner_ref) do
              session_id = Session.get_stats(pid).session_id
              send(coordinator, {:subagent_ready, id, session_id})
              run_session(pid, session_ref, session_id, owner_ref, id, validated.prompt)
            else
              {:cancelled, status} -> terminal_result(id, nil, status)
            end
          after
            cleanup_session(pid)
            await_session_down(pid, session_ref)
          end
        else
          {:cancelled, status} -> terminal_result(id, nil, status)
          {:error, reason} -> build_error_result(id, nil, reason)
        end
      rescue
        error in [ArgumentError, LemonCore.Config.ValidationError] ->
          build_error_result(id, nil, Exception.message(error))
      catch
        :exit, reason -> build_crashed_result(id, nil, reason)
      end

    send(coordinator, {:subagent_result, id, result})
    Process.demonitor(owner_ref, [:flush])
  end

  defp run_session(pid, session_ref, session_id, owner_ref, id, prompt) do
    with :ok <- check_cancelled(owner_ref) do
      unsubscribe = Session.subscribe(pid)

      try do
        with :ok <- check_cancelled(owner_ref),
             :ok <- Session.prompt(pid, prompt) do
          await_session_result(id, session_id, session_ref, owner_ref)
        else
          {:cancelled, status} -> terminal_result(id, session_id, status)
          {:error, reason} -> build_error_result(id, session_id, reason)
        end
      after
        unsubscribe.()
      end
    else
      {:cancelled, status} -> terminal_result(id, session_id, status)
    end
  catch
    :exit, reason -> build_crashed_result(id, session_id, reason)
  end

  defp check_cancelled(owner_ref) do
    receive do
      {:cancel, status} -> {:cancelled, status}
      {:DOWN, ^owner_ref, :process, _pid, _reason} -> {:cancelled, :aborted}
    after
      0 -> :ok
    end
  end

  defp await_session_result(id, session_id, session_ref, owner_ref) do
    receive do
      {:session_event, ^session_id, {:agent_end, messages}} ->
        build_completed_result(id, session_id, messages)

      {:session_event, ^session_id, {:error, reason, _partial}} ->
        build_error_result(id, session_id, reason)

      {:DOWN, ^session_ref, :process, _pid, reason} ->
        build_crashed_result(id, session_id, reason)

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        terminal_result(id, session_id, :aborted)

      {:cancel, status} ->
        terminal_result(id, session_id, status)

      _event ->
        await_session_result(id, session_id, session_ref, owner_ref)
    end
  end

  defp build_session_opts(state, validated) do
    Params.build_session_opts(
      state.cwd,
      [
        model: state.model,
        thinking_level: state.thinking_level,
        settings_manager: state.settings_manager,
        parent_session: state.parent_session
      ],
      validated
    )
  end

  defp put_result(state, batch_ref, result) do
    case Map.get(state.batches, batch_ref) do
      nil ->
        state

      batch ->
        batch = %{batch | results: Map.put_new(batch.results, result.id, result)}
        %{state | batches: Map.put(state.batches, batch_ref, batch)}
    end
  end

  defp finish_subagent(state, id, subagent) do
    if subagent.session_monitor_ref, do: Process.demonitor(subagent.session_monitor_ref, [:flush])
    state = %{state | active_subagents: Map.delete(state.active_subagents, id)}
    maybe_reply_batch(state, subagent.batch)
  end

  defp maybe_reply_batch(state, batch_ref) do
    case Map.get(state.batches, batch_ref) do
      nil ->
        state

      batch ->
        if Enum.all?(batch.ids, fn id ->
             Map.has_key?(batch.results, id) && not Map.has_key?(state.active_subagents, id)
           end) do
          reply_batch(state, batch_ref)
        else
          state
        end
    end
  end

  defp reply_batch(state, batch_ref) do
    case Map.pop(state.batches, batch_ref) do
      {nil, _} ->
        state

      {batch, batches} ->
        Process.cancel_timer(batch.timer)
        GenServer.reply(batch.from, Enum.map(batch.ids, &Map.fetch!(batch.results, &1)))
        %{state | batches: batches}
    end
  end

  defp cancel_all(state) do
    state =
      Enum.reduce(Map.keys(state.batches), state, fn batch_ref, acc ->
        cancel_batch(acc, batch_ref, :aborted)
      end)

    # Already-terminal batches may still have admissions or cleanup in flight.
    Enum.each(state.active_subagents, fn {_id, subagent} ->
      if subagent.worker_pid, do: send(subagent.worker_pid, {:cancel, :aborted})
    end)

    state
  end

  defp cancel_batch(state, batch_ref, status) do
    case Map.get(state.batches, batch_ref) do
      nil ->
        state

      %{stopping: true} ->
        state

      batch ->
        Process.cancel_timer(batch.timer)

        state =
          Enum.reduce(batch.ids, state, fn id, acc ->
            case Map.get(acc.active_subagents, id) do
              nil ->
                acc

              subagent ->
                if subagent.worker_pid, do: send(subagent.worker_pid, {:cancel, status})
                if subagent.pid && subagent.status != :stopping do
                  start_background_task(fn -> cleanup_session(subagent.pid) end)
                end
                result = terminal_result(id, subagent.session_id, status)
                subagent = %{subagent | status: :stopping}
                acc = put_result(acc, batch_ref, result)
                %{acc | active_subagents: Map.put(acc.active_subagents, id, subagent)}
            end
          end)

        timer = Process.send_after(self(), {:cleanup_timeout, batch_ref}, @cleanup_wait_timeout)
        batch = %{Map.fetch!(state.batches, batch_ref) | timer: timer, stopping: true}
        state = %{state | batches: Map.put(state.batches, batch_ref, batch)}
        maybe_reply_batch(state, batch_ref)
    end
  end

  defp terminal_result(id, session_id, status) do
    %{id: id, status: status, result: nil, error: status, session_id: session_id}
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
    %{id: id, status: :error, result: nil, error: reason, session_id: session_id}
  end

  defp build_crashed_result(id, session_id, reason) do
    build_error_result(id, session_id, {:crashed, reason})
  end

  defp extract_final_text(messages) do
    messages
    |> Enum.filter(&match?(%LemonAi.Types.AssistantMessage{}, &1))
    |> List.last()
    |> case do
      nil -> ""
      msg -> LemonAi.get_text(msg) || ""
    end
  end

  defp cleanup_session(pid) do
    Session.abort(pid)

    # These sessions are temporary supervisor children. Stopping the process
    # directly avoids waiting behind another session's supervisor admission.
    GenServer.stop(pid, :shutdown, @cleanup_wait_timeout)
  catch
    :exit, _ ->
      # Match the supervisor's bounded shutdown even if a session is stuck in
      # its synchronous startup/termination callback.
      Process.exit(pid, :kill)
  end

  defp await_session_down(pid, ref) do
    # await_session_result may already have consumed this monitor's DOWN.
    if Process.alive?(pid) do
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    else
      Process.demonitor(ref, [:flush])
    end
  end

  defp generate_subagent_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp start_background_task(fun) do
    Task.Supervisor.start_child(@task_supervisor, fun)
  catch
    :exit, {:noproc, _} -> Task.start(fun)
  end
end
