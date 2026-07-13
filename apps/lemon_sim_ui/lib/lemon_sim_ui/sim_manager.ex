defmodule LemonSimUi.SimManager do
  @moduledoc """
  GenServer managing durable simulation processes.

  Bridges the UI with LemonSim.Kernel.Runner, persists lifecycle and RNG
  checkpoints, and restores supported simulations after runner or service
  restarts. Store outages and transient resume failures retry with bounded
  backoff; exhausted orphan recovery is durably terminalized before cleanup.
  """

  use GenServer

  require Logger

  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.{Runner, State, Store}
  alias LemonSim.LLM.GameHelpers.Runner, as: GameRunner
  alias LemonSim.LLM.Usage

  alias LemonSim.Examples.{
    TicTacToe,
    Skirmish,
    StockMarket,
    Survivor,
    SpaceStation,
    Auction,
    Diplomacy,
    DungeonCrawl,
    TcgShop,
    VendingBench,
    Poker
  }

  alias LemonSim.LLM.GameHelpers.Config, as: SimConfig
  alias LemonSimUi.ProjectRoot

  @lobby_topic "sim:lobby"
  @resumable_domains [:werewolf, :space_station, :stock_market, :survivor, :poker]
  @max_persisted_resumes 5
  @runner_recovery_delay_ms 1_000
  @max_transient_recovery_failures 5
  @recovery_retry_max_ms 30_000

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec lobby_topic() :: String.t()
  def lobby_topic, do: @lobby_topic

  @spec start_sim(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_sim(domain, opts \\ []) do
    GenServer.call(__MODULE__, {:start_sim, domain, opts})
  end

  @spec stop_sim(String.t()) :: :ok | {:error, term()}
  def stop_sim(sim_id) do
    GenServer.call(__MODULE__, {:stop_sim, sim_id})
  end

  @spec abandon_sim(String.t(), term()) :: :ok | {:error, term()}
  def abandon_sim(sim_id, reason) do
    GenServer.call(__MODULE__, {:abandon_sim, sim_id, reason})
  end

  @spec resume_sim(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resume_sim(sim_id) do
    GenServer.call(__MODULE__, {:resume_sim, sim_id})
  end

  @spec list_running() :: [String.t()]
  def list_running do
    GenServer.call(__MODULE__, :list_running)
  end

  @spec runtime_status() :: map()
  def runtime_status do
    GenServer.call(__MODULE__, :runtime_status)
  end

  @spec usage(String.t()) :: map() | nil
  def usage(sim_id) when is_binary(sim_id) do
    GenServer.call(__MODULE__, {:usage, sim_id})
  end

  @spec register_human(String.t(), String.t()) :: :ok
  def register_human(sim_id, team) do
    GenServer.call(__MODULE__, {:register_human, sim_id, team})
  end

  @spec submit_human_move(String.t(), LemonSim.Kernel.Event.t()) :: :ok | {:error, term()}
  def submit_human_move(sim_id, event) do
    GenServer.call(__MODULE__, {:human_move, sim_id, event}, 30_000)
  end

  @spec sim_status(String.t()) :: :running | :waiting_human | :stopped
  def sim_status(sim_id) do
    GenServer.call(__MODULE__, {:status, sim_id})
  end

  @spec enable_auto_loop(atom(), keyword()) :: :ok
  def enable_auto_loop(domain, opts \\ []) do
    GenServer.call(__MODULE__, {:enable_auto_loop, domain, opts})
  end

  @spec disable_auto_loop(atom()) :: :ok
  def disable_auto_loop(domain) do
    GenServer.call(__MODULE__, {:disable_auto_loop, domain})
  end

  @spec auto_loop_status() :: map()
  def auto_loop_status do
    GenServer.call(__MODULE__, :auto_loop_status)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    # Keep linked runner exits as messages so the manager can monitor
    # completion without crashing, while still ensuring runners stop if
    # the manager terminates.
    Process.flag(:trap_exit, true)
    terminate_orphaned_runners()

    # Schedule boot auto-loop after deps have started.
    # Prefer env-var config (backward compat), fall back to TOML [[sim.loop]].
    auto_loop_config =
      case Application.get_env(:lemon_sim_ui, :auto_loop) do
        config when is_list(config) and config != [] -> config
        _ -> load_sim_loop_config()
      end

    if is_list(auto_loop_config) and auto_loop_config != [] do
      Process.send_after(self(), {:boot_auto_loop, auto_loop_config}, 5_000)
    end

    Process.send_after(self(), {:recover_persisted, 0}, 0)

    {:ok,
     %{
       runners: %{},
       human_players: %{},
       auto_loops: %{},
       pending_restarts: %{},
       recovery_queue: [],
       recovery_failures: %{},
       usage_artifacts: %{},
       recovery_persist: &put_state_with_retry/2,
       max_concurrent_runners: Application.get_env(:lemon_sim_ui, :max_concurrent_runners, 8),
       max_stored_simulations: Application.get_env(:lemon_sim_ui, :max_stored_simulations, 500)
     }}
  end

  @impl true
  def handle_call({:start_sim, domain, opts}, _from, state) do
    case do_start_sim(domain, opts, state) do
      {:ok, sim_id, new_state} ->
        {:reply, {:ok, sim_id}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:stop_sim, sim_id}, _from, state) do
    state = stop_runner_if_present(state, sim_id)

    case persist_terminal_state(sim_id, "stopped", "operator_stop") do
      {:ok, stopped_state} ->
        broadcast_update(stopped_state)
        {:reply, :ok, state |> prune_stored_simulations() |> drain_recovery_queue()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:abandon_sim, sim_id, reason}, _from, state) do
    state = stop_runner_if_present(state, sim_id)

    case persist_terminal_state(sim_id, "failed", "arena_abandoned:#{inspect(reason)}") do
      {:ok, failed_state} ->
        broadcast_update(failed_state)
        {:reply, :ok, state |> prune_stored_simulations() |> drain_recovery_queue()}

      {:error, persist_reason} ->
        {:reply, {:error, persist_reason}, state}
    end
  end

  def handle_call({:resume_sim, sim_id}, _from, state) do
    case resume_stored_sim(sim_id, state) do
      {:ok, new_state} -> {:reply, {:ok, sim_id}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:list_running, _from, state) do
    {:reply, Map.keys(state.runners), state}
  end

  def handle_call(:runtime_status, _from, state) do
    state = ensure_auto_loop_keys(state)

    status = %{
      active_runners: map_size(state.runners),
      max_concurrent_runners: state.max_concurrent_runners,
      max_stored_simulations: state.max_stored_simulations,
      queued_recoveries:
        state.recovery_queue
        |> Kernel.++(Map.keys(state.recovery_failures))
        |> MapSet.new()
        |> MapSet.size()
    }

    {:reply, status, state}
  end

  def handle_call({:usage, sim_id}, _from, state) do
    state = ensure_auto_loop_keys(state)

    usage =
      get_in(state, [:runners, sim_id, :usage_collector])
      |> read_usage_artifact(sim_id)
      |> Kernel.||(Map.get(state.usage_artifacts, sim_id))
      |> Kernel.||(persisted_usage(sim_id))

    {:reply, usage, state}
  end

  def handle_call({:register_human, sim_id, team}, _from, state) do
    human_players = Map.put(state.human_players, sim_id, team)
    {:reply, :ok, %{state | human_players: human_players}}
  end

  def handle_call({:human_move, sim_id, event}, _from, state) do
    case Map.get(state.runners, sim_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      %{ref: pid} ->
        send(pid, {:human_move, event})
        {:reply, :ok, state}
    end
  end

  def handle_call({:status, sim_id}, _from, state) do
    status =
      case Map.get(state.runners, sim_id) do
        nil -> :stopped
        _ -> :running
      end

    {:reply, status, state}
  end

  def handle_call({:enable_auto_loop, domain, opts}, _from, state) do
    state = ensure_auto_loop_keys(state)
    loop_config = %{enabled: true, opts: opts, game_count: 0, current_sim_id: nil}
    auto_loops = Map.put(state.auto_loops, domain, loop_config)
    state = %{state | auto_loops: auto_loops}

    # Start first game if none of this domain is currently running
    domain_running? =
      Enum.any?(state.runners, fn {_id, %{domain: d}} -> d == domain end)

    state =
      if domain_running? do
        state
      else
        case do_start_sim(domain, opts, state) do
          {:ok, sim_id, new_state} ->
            auto_loops =
              Map.update!(new_state.auto_loops, domain, fn lc ->
                %{lc | current_sim_id: sim_id, game_count: lc.game_count + 1}
              end)

            %{new_state | auto_loops: auto_loops}

          {:error, _reason, new_state} ->
            new_state
        end
      end

    {:reply, :ok, state}
  end

  def handle_call({:disable_auto_loop, domain}, _from, state) do
    state = ensure_auto_loop_keys(state)
    auto_loops = Map.delete(state.auto_loops, domain)

    # Cancel any pending restart timer
    pending_restarts =
      case Map.pop(state.pending_restarts, domain) do
        {nil, pr} ->
          pr

        {timer_ref, pr} ->
          Process.cancel_timer(timer_ref)
          pr
      end

    {:reply, :ok, %{state | auto_loops: auto_loops, pending_restarts: pending_restarts}}
  end

  def handle_call(:auto_loop_status, _from, state) do
    {:reply, Map.get(state, :auto_loops, %{}), state}
  end

  @auto_loop_restart_delay_ms 8_000

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = ensure_auto_loop_keys(state)

    {sim_id, runner_entry} =
      Enum.find(state.runners, {nil, nil}, fn {_id, %{ref: ref}} -> ref == pid end)

    if sim_id do
      domain = runner_entry.domain
      collector = Map.get(runner_entry, :usage_collector)
      {state, stored_state} = capture_final_usage(state, sim_id, collector)
      stop_usage_collector(collector)
      runners = Map.delete(state.runners, sim_id)
      human_players = Map.delete(state.human_players, sim_id)
      broadcast_lobby()

      state = %{state | runners: runners, human_players: human_players}

      if is_nil(stored_state) or recoverable_run?(stored_state) do
        Process.send_after(self(), {:recover_runner, sim_id}, @runner_recovery_delay_ms)
      end

      # Check if auto-loop should restart this domain
      state =
        case Map.get(state.auto_loops, domain) do
          %{enabled: true} ->
            # Verify game actually finished
            case stored_state do
              %{world: world} ->
                status = MapHelpers.get_key(world, :status)

                if status == "game_over" do
                  timer_ref =
                    Process.send_after(
                      self(),
                      {:auto_loop_restart, domain},
                      @auto_loop_restart_delay_ms
                    )

                  %{state | pending_restarts: Map.put(state.pending_restarts, domain, timer_ref)}
                else
                  state
                end

              _ ->
                state
            end

          _ ->
            state
        end

      {:noreply, state |> prune_stored_simulations() |> drain_recovery_queue()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:recover_runner, sim_id}, state) do
    state = ensure_auto_loop_keys(state)

    if Map.has_key?(state.runners, sim_id) do
      {:noreply, clear_recovery_failure(state, sim_id)}
    else
      {:noreply, attempt_recovery(state, sim_id, "crashed")}
    end
  end

  def handle_info({:finalize_failed_recovery, sim_id, reason}, state) do
    state = ensure_auto_loop_keys(state)

    if Map.has_key?(state.runners, sim_id) do
      {:noreply, clear_recovery_failure(state, sim_id)}
    else
      {:noreply, persist_failed_recovery(state, sim_id, reason)}
    end
  end

  def handle_info({:auto_loop_restart, domain}, state) do
    state = ensure_auto_loop_keys(state)
    pending_restarts = Map.delete(state.pending_restarts, domain)
    state = %{state | pending_restarts: pending_restarts}

    case Map.get(state.auto_loops, domain) do
      %{enabled: true, opts: opts} ->
        # Guard: no sim of this domain already running
        domain_running? =
          Enum.any?(state.runners, fn {_id, %{domain: d}} -> d == domain end)

        if domain_running? do
          {:noreply, state}
        else
          case do_start_sim(domain, opts, state) do
            {:ok, sim_id, new_state} ->
              auto_loops =
                Map.update!(new_state.auto_loops, domain, fn lc ->
                  %{lc | current_sim_id: sim_id, game_count: lc.game_count + 1}
                end)

              {:noreply, %{new_state | auto_loops: auto_loops}}

            {:error, reason, new_state} ->
              Logger.error(
                "[SimManager] Auto-loop restart failed for #{domain}: #{inspect(reason)}"
              )

              {:noreply, new_state}
          end
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:boot_auto_loop, config}, state) do
    state = ensure_auto_loop_keys(state)

    state =
      Enum.reduce(config, state, fn {domain, opts}, acc ->
        domain = if is_binary(domain), do: String.to_existing_atom(domain), else: domain
        opts = if is_list(opts), do: opts, else: Keyword.new(opts)

        loop_config = %{enabled: true, opts: opts, game_count: 0, current_sim_id: nil}
        auto_loops = Map.put(acc.auto_loops, domain, loop_config)
        acc = %{acc | auto_loops: auto_loops}

        case Enum.find(acc.runners, fn {_sim_id, entry} -> entry.domain == domain end) do
          {sim_id, _entry} ->
            auto_loops =
              Map.update!(acc.auto_loops, domain, fn loop ->
                %{loop | current_sim_id: sim_id}
              end)

            %{acc | auto_loops: auto_loops}

          nil ->
            case do_start_sim(domain, opts, acc) do
              {:ok, sim_id, new_acc} ->
                auto_loops =
                  Map.update!(new_acc.auto_loops, domain, fn lc ->
                    %{lc | current_sim_id: sim_id, game_count: lc.game_count + 1}
                  end)

                %{new_acc | auto_loops: auto_loops}

              {:error, reason, new_acc} ->
                Logger.error(
                  "[SimManager] Boot auto-loop failed for #{domain}: #{inspect(reason)}"
                )

                new_acc
            end
        end
      end)

    {:noreply, state}
  end

  def handle_info(:recover_persisted, state) do
    handle_info({:recover_persisted, 0}, state)
  end

  def handle_info({:recover_persisted, attempt}, state) do
    case LemonCore.Store.ping() do
      :ok ->
        recoverable_ids =
          Store.list_states()
          |> Enum.filter(&recoverable_run?/1)
          |> Enum.sort_by(&run_meta_value(&1, :started_at_ms, 0))
          |> Enum.map(& &1.sim_id)
          |> Enum.reject(&Map.has_key?(state.runners, &1))

        recovered_state =
          Enum.reduce(recoverable_ids, state, &enqueue_recovery(&2, &1))
          |> drain_recovery_queue()

        {:noreply, recovered_state}

      {:error, reason} ->
        exponent = min(attempt, 8)
        delay = min(trunc(:math.pow(2, exponent)) * 200, @recovery_retry_max_ms)

        Logger.warning(
          "[SimManager] store unavailable during boot recovery: #{inspect(reason)}; retrying in #{delay}ms"
        )

        Process.send_after(self(), {:recover_persisted, min(attempt + 1, 8)}, delay)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private helpers ---

  # Ensures auto_loops/pending_restarts keys exist in state, for hot-code-reload
  # compatibility when the GenServer was started before these keys were added.
  defp ensure_auto_loop_keys(state) do
    state
    |> Map.put_new(:auto_loops, %{})
    |> Map.put_new(:pending_restarts, %{})
    |> Map.put_new(:recovery_queue, [])
    |> Map.put_new(:recovery_failures, %{})
    |> Map.put_new(:usage_artifacts, %{})
    |> Map.put_new(:recovery_persist, &put_state_with_retry/2)
    |> Map.put_new(
      :max_concurrent_runners,
      Application.get_env(:lemon_sim_ui, :max_concurrent_runners, 8)
    )
    |> Map.put_new(
      :max_stored_simulations,
      Application.get_env(:lemon_sim_ui, :max_stored_simulations, 500)
    )
  end

  defp runner_capacity_reached?(state) do
    state = ensure_auto_loop_keys(state)
    map_size(state.runners) >= state.max_concurrent_runners
  end

  defp enqueue_recovery(state, sim_id) do
    state = ensure_auto_loop_keys(state)

    if sim_id in state.recovery_queue or Map.has_key?(state.runners, sim_id) do
      state
    else
      %{state | recovery_queue: state.recovery_queue ++ [sim_id]}
    end
  end

  defp drain_recovery_queue(state) do
    state = ensure_auto_loop_keys(state)

    case state.recovery_queue do
      [sim_id | remaining] when map_size(state.runners) < state.max_concurrent_runners ->
        state
        |> Map.put(:recovery_queue, remaining)
        |> attempt_recovery(sim_id, "persisted")
        |> drain_recovery_queue()

      _ ->
        state
    end
  end

  defp attempt_recovery(state, sim_id, source) do
    case resume_stored_sim(sim_id, state) do
      {:ok, next} ->
        Logger.info("[SimManager] recovered #{source} simulation #{sim_id}")
        clear_recovery_failure(next, sim_id)

      {:error, :capacity_exceeded, next} ->
        enqueue_recovery(next, sim_id)

      {:error, reason, next}
      when reason in [:not_found, :game_over, :already_running, :turn_budget_exhausted] ->
        Logger.warning(
          "[SimManager] cannot recover #{source} simulation #{sim_id}: #{inspect(reason)}"
        )

        clear_recovery_failure(next, sim_id)

      {:error, {:not_resumable, _reason} = reason, next} ->
        Logger.warning(
          "[SimManager] cannot recover #{source} simulation #{sim_id}: #{inspect(reason)}"
        )

        clear_recovery_failure(next, sim_id)

      {:error, reason, next} ->
        retry_or_fail_recovery(next, sim_id, reason)
    end
  end

  defp retry_or_fail_recovery(state, sim_id, reason) do
    failures = Map.get(state.recovery_failures, sim_id, 0) + 1
    state = put_in(state.recovery_failures[sim_id], failures)

    if failures >= @max_transient_recovery_failures do
      Logger.error(
        "[SimManager] recovery exhausted for #{sim_id} after #{failures} transient failures: #{inspect(reason)}"
      )

      persist_failed_recovery(state, sim_id, reason)
    else
      delay =
        min(@runner_recovery_delay_ms * trunc(:math.pow(2, failures - 1)), @recovery_retry_max_ms)

      Logger.warning(
        "[SimManager] recovery attempt #{failures}/#{@max_transient_recovery_failures} failed for #{sim_id}: " <>
          "#{inspect(reason)}; retrying in #{delay}ms"
      )

      Process.send_after(self(), {:recover_runner, sim_id}, delay)
      state
    end
  end

  defp persist_failed_recovery(state, sim_id, reason) do
    case Store.get_state(sim_id) do
      %State{} = stored_state ->
        failed_state = mark_run_failed(stored_state, "recovery_failed: #{inspect(reason)}")

        case persist_recovery_state(state, failed_state, 3) do
          :ok ->
            Logger.error("[SimManager] durably failed orphaned simulation #{sim_id}")
            broadcast_update(failed_state)
            state |> clear_recovery_failure(sim_id) |> prune_stored_simulations()

          {:error, persist_reason} ->
            Logger.error(
              "[SimManager] failed to terminalize orphaned #{sim_id}: #{inspect(persist_reason)}; retrying"
            )

            Process.send_after(
              self(),
              {:finalize_failed_recovery, sim_id, reason},
              @recovery_retry_max_ms
            )

            state
        end

      nil ->
        case LemonCore.Store.ping() do
          :ok ->
            clear_recovery_failure(state, sim_id)

          {:error, persist_reason} ->
            Logger.error(
              "[SimManager] store unavailable while terminalizing #{sim_id}: #{inspect(persist_reason)}; retrying"
            )

            Process.send_after(
              self(),
              {:finalize_failed_recovery, sim_id, reason},
              @recovery_retry_max_ms
            )

            state
        end
    end
  end

  defp clear_recovery_failure(state, sim_id) do
    %{state | recovery_failures: Map.delete(state.recovery_failures, sim_id)}
  end

  defp prune_stored_simulations(state) do
    state = ensure_auto_loop_keys(state)

    stale_ids =
      Store.list_states()
      |> Enum.filter(fn stored_state ->
        run_meta_value(stored_state, :status) in ["completed", "failed", "stopped"] or
          MapHelpers.get_key(stored_state.world, :status) == "game_over"
      end)
      |> Enum.sort_by(
        fn stored_state ->
          run_meta_value(
            stored_state,
            :finished_at_ms,
            run_meta_value(stored_state, :started_at_ms, 0)
          )
        end,
        :desc
      )
      |> Enum.drop(state.max_stored_simulations)
      |> Enum.map(& &1.sim_id)

    Enum.each(stale_ids, &Store.delete_state/1)
    %{state | usage_artifacts: Map.drop(state.usage_artifacts, stale_ids)}
  end

  defp resume_stored_sim(sim_id, state) do
    cond do
      Map.has_key?(state.runners, sim_id) ->
        {:error, :already_running, state}

      runner_capacity_reached?(state) ->
        {:error, :capacity_exceeded, state}

      true ->
        case Store.get_state(sim_id) do
          nil ->
            {:error, :not_found, state}

          stored_state ->
            resume_loaded_state(stored_state, state)
        end
    end
  end

  defp resume_loaded_state(stored_state, state) do
    world_status = MapHelpers.get_key(stored_state.world, :status)
    lifecycle_status = run_meta_value(stored_state, :status)
    resumable = run_meta_value(stored_state, :resumable, true)
    recovery_attempts = run_meta_value(stored_state, :recovery_attempts, 0)

    cond do
      world_status == "game_over" ->
        {:error, :game_over, state}

      lifecycle_status in ["completed", "failed", "stopped"] or resumable == false ->
        {:error, {:not_resumable, lifecycle_status || "unknown"}, state}

      recovery_attempts >= @max_persisted_resumes ->
        fail_exhausted_recovery(stored_state, state)

      true ->
        domain = domain_from_state(stored_state)

        with {:ok, modules, run_opts} <- build_resume_opts(domain, stored_state),
             {:ok, run_opts} <- apply_persisted_turn_budget(run_opts, stored_state) do
          resumed_state =
            put_run_meta(stored_state, %{
              status: "running",
              resumable: true,
              finished_at_ms: nil,
              failure_reason: nil,
              resume_count: run_meta_value(stored_state, :resume_count, 0) + 1,
              recovery_attempts: recovery_attempts + 1
            })

          case persist_recovery_state(state, resumed_state, 3) do
            :ok ->
              {:ok, usage_collector} =
                Usage.start_link(resumed_state.sim_id, run_meta_value(resumed_state, :usage))

              run_opts = Keyword.put(run_opts, :usage_collector, usage_collector)
              task_ref = start_runner(resumed_state, modules, run_opts, nil)

              runners =
                Map.put(state.runners, resumed_state.sim_id, %{
                  ref: task_ref,
                  domain: domain,
                  usage_collector: usage_collector
                })

              broadcast_update(resumed_state)
              {:ok, %{state | runners: runners}}

            {:error, reason} ->
              {:error, {:persistence_failed, reason}, state}
          end
        else
          {:error, :turn_budget_exhausted} ->
            fail_terminal_recovery(stored_state, :turn_budget_exhausted, state)

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp apply_persisted_turn_budget(run_opts, state) do
    max_turns = run_meta_value(state, :max_turns, Keyword.get(run_opts, :driver_max_turns, 50))
    turns_completed = run_meta_value(state, :turns_completed, 0)

    if is_integer(max_turns) and is_integer(turns_completed) and turns_completed < max_turns do
      {:ok, Keyword.put(run_opts, :driver_max_turns, max_turns)}
    else
      {:error, :turn_budget_exhausted}
    end
  end

  defp recoverable_run?(state) do
    is_struct(state, State) and
      MapHelpers.get_key(state.world, :status) != "game_over" and
      run_meta_value(state, :status) == "running" and
      run_meta_value(state, :resumable, false) == true
  end

  defp fail_exhausted_recovery(stored_state, state) do
    fail_terminal_recovery(stored_state, :recovery_limit_exceeded, state)
  end

  defp fail_terminal_recovery(stored_state, reason, state) do
    failed_state = mark_run_failed(stored_state, reason)

    case persist_recovery_state(state, failed_state, 3) do
      :ok ->
        broadcast_update(failed_state)
        {:error, {:not_resumable, to_string(reason)}, state}

      {:error, reason} ->
        {:error, {:persistence_failed, reason}, state}
    end
  end

  defp domain_from_state(state) do
    case run_meta_value(state, :domain) do
      domain when is_binary(domain) ->
        Enum.find(@resumable_domains, :unknown, &(to_string(&1) == domain))

      _ ->
        domain_from_sim_id(state.sim_id)
    end
  end

  defp do_start_sim(domain, opts, state) do
    sim_id = Keyword.get(opts, :sim_id, generate_id(domain))
    human_player = Keyword.get(opts, :human_player)

    cond do
      Map.has_key?(state.runners, sim_id) ->
        # Overwriting the runner entry would strand the old task and leak its
        # usage collector (stop_sim/:DOWN look entries up by the stored ref).
        {:error, :already_running, state}

      runner_capacity_reached?(state) ->
        {:error, :capacity_exceeded, state}

      Store.get_state(sim_id) != nil ->
        {:error, :already_exists, state}

      true ->
        do_start_sim(domain, opts, state, sim_id, human_player)
    end
  end

  defp do_start_sim(domain, opts, state, sim_id, human_player) do
    # Seeding before world construction makes each domain's randomized
    # role/seat assignment reproducible for a recorded arena seed.
    case Keyword.get(opts, :seed) do
      seed when is_integer(seed) -> :rand.seed(:exsss, {seed, seed + 1, seed + 2})
      _ -> :ok
    end

    case build_initial_state(domain, sim_id, opts) do
      {:ok, initial_state, modules, run_opts} ->
        run_opts = maybe_override_driver_max_turns(run_opts, opts)
        {:ok, usage_collector} = Usage.start_link(sim_id)
        run_opts = Keyword.put(run_opts, :usage_collector, usage_collector)
        initial_state = initialize_run_metadata(initial_state, domain, opts, run_opts)

        case put_state_with_retry(initial_state, 3) do
          :ok ->
            broadcast_lobby()

            task_ref = start_runner(initial_state, modules, run_opts, human_player)

            runners =
              Map.put(state.runners, sim_id, %{
                ref: task_ref,
                domain: domain,
                usage_collector: usage_collector
              })

            human_players =
              if human_player do
                Map.put(state.human_players, sim_id, human_player)
              else
                state.human_players
              end

            {:ok, sim_id, %{state | runners: runners, human_players: human_players}}

          {:error, reason} ->
            stop_usage_collector(usage_collector)
            {:error, {:persistence_failed, reason}, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp build_initial_state(:tic_tac_toe, sim_id, opts) do
    max_turns = Keyword.get(opts, :max_turns, 20)

    initial_state = %{TicTacToe.initial_state() | sim_id: sim_id}
    modules = TicTacToe.modules()

    {model, stream_options} = resolve_default_model_for_ui()

    run_opts =
      TicTacToe.default_opts(model: model, stream_options: stream_options)
      |> Keyword.put(:driver_max_turns, max_turns)
      |> Keyword.put(:persist?, true)
      |> Keyword.put(:on_before_step, nil)
      |> Keyword.put(:on_after_step, &on_after_step/2)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:skirmish, sim_id, opts) do
    max_turns = Keyword.get(opts, :max_turns, 48)

    # Pass through all skirmish-specific opts (squad, map_width, map_height, map_preset, rng_seed)
    initial_state = %{Skirmish.initial_state(opts) | sim_id: sim_id}

    modules = Skirmish.modules()

    {model, stream_options} = resolve_default_model_for_ui()

    run_opts =
      Skirmish.default_opts(Keyword.merge(opts, model: model, stream_options: stream_options))
      |> Keyword.put(:driver_max_turns, max_turns)
      |> Keyword.put(:persist?, true)
      |> Keyword.put(:on_before_step, nil)
      |> Keyword.put(:on_after_step, &on_after_step/2)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:werewolf, sim_id, opts) do
    model_specs = Keyword.get(opts, :model_specs, [])

    werewolf_opts =
      opts
      |> Keyword.put(:sim_id, sim_id)
      |> Keyword.put(:generate_lore?, false)

    initial_state = LemonSim.Examples.Werewolf.initial_state(werewolf_opts)
    modules = LemonSim.Examples.Werewolf.modules()

    player_ids =
      initial_state.world
      |> MapHelpers.get_key(:players)
      |> Kernel.||(%{})
      |> Map.keys()
      |> Enum.sort()

    if model_specs != [] and length(model_specs) != length(player_ids) do
      raise ArgumentError,
            "Werewolf model_specs must contain exactly #{length(player_ids)} entries"
    end

    config = load_project_config()

    {initial_state, run_opts} =
      if model_specs != [] do
        model_assignments =
          player_ids
          |> Enum.zip(model_specs)
          |> Enum.into(%{}, fn {player_id, spec} ->
            {provider, model_id} = parse_model_spec(spec)
            model = resolve_model!(provider, model_id, config)
            api_key = SimConfig.resolve_provider_api_key!(provider, config, "werewolf")
            {player_id, {model, api_key}}
          end)

        state_with_models = attach_model_assignments(initial_state, model_assignments)
        {default_model, default_key} = model_assignments |> Map.values() |> List.first()

        run_opts =
          LemonSim.Examples.Werewolf.default_opts(
            model: default_model,
            stream_options: %{api_key: default_key}
          )
          |> Keyword.put(:persist?, true)
          |> Keyword.put(:on_before_step, nil)
          |> Keyword.put(:on_after_step, &on_after_step/2)
          |> Keyword.put(:model_assignments, model_assignments)

        {state_with_models, run_opts}
      else
        {model, stream_options} = resolve_default_model_for_ui()

        run_opts =
          LemonSim.Examples.Werewolf.default_opts(model: model, stream_options: stream_options)
          |> Keyword.put(:persist?, true)
          |> Keyword.put(:on_before_step, nil)
          |> Keyword.put(:on_after_step, &on_after_step/2)

        {initial_state, run_opts}
      end

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:stock_market, sim_id, opts) do
    player_count = Keyword.get(opts, :player_count, 4)
    model_specs = Keyword.get(opts, :model_specs, [])

    initial_state = %{StockMarket.initial_state(player_count: player_count) | sim_id: sim_id}
    modules = StockMarket.modules()

    {initial_state, run_opts} =
      build_multi_model_opts(initial_state, modules, model_specs, player_count,
        default_opts_fn: &StockMarket.default_opts/1
      )

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:poker, sim_id, opts) do
    player_count = Keyword.get(opts, :player_count, 6)
    model_specs = Keyword.get(opts, :model_specs, [])

    # Poker draws its deck order from the :seed opt (not :rand), so the arena
    # seed must be forwarded for reproducible shuffles.
    poker_opts =
      case Keyword.get(opts, :seed) do
        seed when is_integer(seed) -> [player_count: player_count, seed: seed]
        _ -> [player_count: player_count]
      end

    initial_state = %{Poker.initial_state(poker_opts) | sim_id: sim_id}
    modules = Poker.modules()

    {initial_state, run_opts} =
      build_multi_model_opts(initial_state, modules, model_specs, player_count,
        default_opts_fn: &Poker.default_opts/1
      )

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:survivor, sim_id, opts) do
    player_count = Keyword.get(opts, :player_count, 8)
    model_specs = Keyword.get(opts, :model_specs, [])

    initial_state = %{Survivor.initial_state(player_count: player_count) | sim_id: sim_id}
    modules = Survivor.modules()

    {initial_state, run_opts} =
      build_multi_model_opts(initial_state, modules, model_specs, player_count,
        default_opts_fn: &Survivor.default_opts/1
      )

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:space_station, sim_id, opts) do
    player_count = Keyword.get(opts, :player_count, 6)
    model_specs = Keyword.get(opts, :model_specs, [])

    initial_state = %{SpaceStation.initial_state(player_count: player_count) | sim_id: sim_id}
    modules = SpaceStation.modules()

    {initial_state, run_opts} =
      build_multi_model_opts(initial_state, modules, model_specs, player_count,
        default_opts_fn: &SpaceStation.default_opts/1
      )

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:auction, sim_id, opts) do
    player_count = Keyword.get(opts, :player_count, 4)

    initial_state = %{Auction.initial_state(player_count: player_count) | sim_id: sim_id}
    modules = Auction.modules()
    run_opts = Auction.default_opts(opts)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:diplomacy, sim_id, opts) do
    player_count = Keyword.get(opts, :player_count, 4)

    initial_state = %{Diplomacy.initial_state(player_count: player_count) | sim_id: sim_id}
    modules = Diplomacy.modules()
    run_opts = Diplomacy.default_opts(opts)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:dungeon_crawl, sim_id, opts) do
    party_size = Keyword.get(opts, :party_size, 4)

    initial_state = %{DungeonCrawl.initial_state(party_size: party_size) | sim_id: sim_id}
    modules = DungeonCrawl.modules()
    run_opts = DungeonCrawl.default_opts(opts)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:vending_bench, sim_id, opts) do
    max_days = Keyword.get(opts, :max_days, 30)
    max_turns = Keyword.get(opts, :max_turns, Keyword.get(opts, :driver_max_turns, 300))

    config = load_project_config()

    {model, stream_options} =
      case Keyword.get(opts, :operator_model_spec, Keyword.get(opts, :model_spec)) do
        nil -> resolve_default_model_for_ui()
        spec -> resolve_model_stream_options!(spec, config, "vending bench")
      end

    {physical_worker_model, physical_worker_stream_options} =
      case Keyword.get(
             opts,
             :physical_worker_model_spec,
             Keyword.get(opts, :worker_model_spec)
           ) do
        nil -> {model, stream_options}
        spec -> resolve_model_stream_options!(spec, config, "vending bench")
      end

    initial_state =
      VendingBench.initial_state(
        sim_id: sim_id,
        max_days: max_days,
        model: model,
        physical_worker_model: physical_worker_model
      )

    modules = VendingBench.modules()

    run_opts =
      VendingBench.default_opts(model: model, stream_options: stream_options)
      |> Keyword.put(:physical_worker_model, physical_worker_model)
      |> Keyword.put(:physical_worker_stream_options, physical_worker_stream_options)
      |> Keyword.put(:driver_max_turns, max_turns)
      |> Keyword.put(:persist?, true)
      |> Keyword.put(:on_before_step, nil)
      |> Keyword.put(:on_after_step, nil)
      |> Keyword.put(:support_tool_matcher, &VendingBench.support_tool?/1)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:tcg_shop, sim_id, opts) do
    max_days = Keyword.get(opts, :max_days, 14)
    max_turns = Keyword.get(opts, :max_turns, Keyword.get(opts, :driver_max_turns, 180))

    config = load_project_config()

    {model, stream_options} =
      case Keyword.get(opts, :operator_model_spec) ||
             opts |> Keyword.get(:model_specs, []) |> List.first() do
        nil -> resolve_default_model_for_ui()
        spec -> resolve_model_stream_options!(spec, config, "tcg shop")
      end

    initial_state =
      TcgShop.initial_state(
        sim_id: sim_id,
        max_days: max_days,
        model: model
      )

    modules = TcgShop.modules()

    run_opts =
      TcgShop.default_opts(model: model, stream_options: stream_options)
      |> Keyword.put(:driver_max_turns, max_turns)
      |> Keyword.put(:persist?, true)
      |> Keyword.put(:on_before_step, nil)
      |> Keyword.put(:on_after_step, nil)
      |> Keyword.put(:support_tool_matcher, &TcgShop.support_tool?/1)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(domain, _sim_id, _opts) do
    {:error, {:unknown_domain, domain}}
  end

  # Runners are supervised children of LemonSimUi.SimRunnerSupervisor (not
  # linked to this GenServer), so a runner crash can never take SimManager
  # down and cleanup of the dead child is OTP-managed. SimManager still
  # `Process.monitor/1`s the child pid itself so the existing :DOWN-based
  # bookkeeping (runners map cleanup, auto-loop restart, usage collector
  # teardown) keeps working unchanged.
  defp start_runner(initial_state, modules, run_opts, human_player) do
    fun = fn ->
      restore_rng(initial_state)

      if human_player do
        run_interactive(initial_state, modules, run_opts, human_player)
      else
        run_ai_only(initial_state, modules, run_opts)
      end
    end

    child_spec = %{id: make_ref(), start: {Task, :start_link, [fun]}, restart: :temporary}

    {:ok, pid} = DynamicSupervisor.start_child(LemonSimUi.SimRunnerSupervisor, child_spec)
    Process.monitor(pid)
    pid
  end

  defp stop_usage_collector(collector) when is_pid(collector) do
    if Process.alive?(collector), do: Agent.stop(collector)
    :ok
  end

  defp stop_usage_collector(_collector), do: :ok

  defp read_usage_artifact(collector, sim_id) when is_pid(collector) do
    try do
      Usage.artifact(collector, sim_id)
    catch
      :exit, _ -> nil
    end
  end

  defp read_usage_artifact(_collector, _sim_id), do: nil

  defp persisted_usage(sim_id) do
    case Store.get_state(sim_id) do
      %State{} = stored_state -> run_meta_value(stored_state, :usage)
      _ -> nil
    end
  end

  defp capture_final_usage(state, sim_id, collector) do
    case read_usage_artifact(collector, sim_id) do
      usage when is_map(usage) ->
        state = put_in(state.usage_artifacts[sim_id], usage)

        case Store.get_state(sim_id) do
          %State{} = stored_state ->
            stored_state = put_run_meta(stored_state, %{usage: usage})

            case put_state_with_retry(stored_state, 3) do
              :ok ->
                {state, stored_state}

              {:error, reason} ->
                Logger.error(
                  "[SimManager] failed to persist final usage for #{sim_id}: #{inspect(reason)}"
                )

                {state, Store.get_state(sim_id)}
            end

          _ ->
            {state, nil}
        end

      _ ->
        {state, Store.get_state(sim_id)}
    end
  end

  @max_step_retries 3

  # Drives the AI-only loop through the same shared primitive the CLI uses —
  # `GameHelpers.Runner.run/5` / `run_multi_model/5`, both built on
  # `LemonSim.Kernel.Runner.run_until_terminal/3` — instead of reimplementing
  # decide/step orchestration (including, for multi-model games, the
  # Agent-held-active-model `complete_fn`/`on_before_step` switching that
  # `run_multi_model/5` now owns outright). What SimManager still contributes,
  # as thin glue around that shared loop:
  #
  #   * a `checkpoint` Agent holding the state the last turn completed on
  #     (plus how many turns have completed overall). The `on_after_step` /
  #     `print_step` callback below updates it every turn and returns
  #     `{:ok, traced_state}`, which `run_until_terminal/3`'s resumable state
  #     hook feeds into the next turn; `resumable?: true` returns that same
  #     state again on failure, so a retry always resumes from the right
  #     place.
  #   * per-step persistence + PubSub broadcast, via that same hook, folding
  #     `append_decision_trace/4`'s plan_history bookkeeping into the state
  #     the model itself sees on later turns (`SectionedProjector` renders
  #     `plan_history` back into the prompt) — the reason this can't be a bare
  #     `run_until_terminal/3` call with a notify-only hook.
  #   * retry-with-backoff across transient step failures and crashes, capped
  #     at `@max_step_retries` consecutive failures, and the absolute turn
  #     budget across those retries: each retry narrows `driver_max_turns` by
  #     however many turns have already completed, since `run_until_terminal/3`
  #     resets its own internal turn counter on every call.
  defp run_ai_only(state, modules, opts) do
    max_turns = run_meta_value(state, :max_turns, Keyword.get(opts, :driver_max_turns, 50))
    turns_completed = run_meta_value(state, :turns_completed, 0)
    model_assignments = Keyword.get(opts, :model_assignments)

    {:ok, checkpoint} = Agent.start_link(fn -> {state, turns_completed} end)

    try do
      run_ai_loop_with_retry(modules, opts, model_assignments, max_turns, checkpoint, 0)
    after
      if Process.alive?(checkpoint), do: Agent.stop(checkpoint)
    end
  end

  defp run_ai_loop_with_retry(
         _modules,
         _opts,
         _model_assignments,
         _max_turns,
         checkpoint,
         retries
       )
       when retries >= @max_step_retries do
    {state, turn} = Agent.get(checkpoint, & &1)
    ctx = sim_context(state, turn)

    Logger.error(
      "[SimManager] #{state.sim_id} giving up after #{@max_step_retries} consecutive failures " <>
        "(phase=#{ctx.phase}, day=#{ctx.day}, actor=#{ctx.actor}, turn=#{turn})",
      sim_id: state.sim_id
    )

    state =
      record_sim_error(
        state,
        turn,
        :retry_limit_exceeded,
        "Gave up after #{@max_step_retries} consecutive step failures " <>
          "(phase=#{ctx.phase}, day=#{ctx.day}, actor=#{ctx.actor})"
      )
      |> mark_run_failed(:retry_limit_exceeded)

    persist_state!(state)
    broadcast_update(state)
  end

  defp run_ai_loop_with_retry(modules, opts, model_assignments, max_turns, checkpoint, retries) do
    {state, turns_completed} = Agent.get(checkpoint, & &1)
    remaining = max_turns - turns_completed

    if remaining <= 0 do
      report_turn_limit_exceeded(state, max_turns)
    else
      restore_rng(state)
      after_step_fn = ai_loop_after_step(checkpoint, turns_completed)

      call_opts =
        opts
        |> Keyword.put(:driver_max_turns, remaining)
        |> Keyword.put(:resumable?, true)
        |> Keyword.put(:persist?, true)
        |> Keyword.put(:on_after_step, after_step_fn)

      default_opts_fn = fn _overrides -> call_opts end

      callbacks = [
        print_setup: fn _state -> :ok end,
        print_result: fn _world -> :ok end,
        announce_turn: fn _turn, _state -> :ok end,
        print_step: after_step_fn
      ]

      result =
        try do
          if model_assignments do
            GameRunner.run_multi_model(state, modules, default_opts_fn, call_opts, callbacks)
          else
            GameRunner.run(state, modules, default_opts_fn, call_opts, callbacks)
          end
        catch
          kind, reason -> {:runner_crash, kind, reason, __STACKTRACE__}
        end

      handle_ai_loop_result(
        result,
        modules,
        opts,
        model_assignments,
        max_turns,
        checkpoint,
        retries,
        turns_completed
      )
    end
  end

  defp handle_ai_loop_result(
         {:ok, final_state},
         _modules,
         _opts,
         _model_assignments,
         _max_turns,
         _checkpoint,
         _retries,
         _call_start_turn
       ) do
    # Idempotent with the last on_after_step call — covers the (rare) case
    # where `state` was already terminal before a single step ran, which
    # never invokes on_after_step at all.
    final_state = mark_run_completed_if_terminal(final_state)
    persist_state!(final_state)
    broadcast_update(final_state)
  end

  defp handle_ai_loop_result(
         {:error, {:turn_limit_exceeded, _}, resume_state},
         _modules,
         _opts,
         _model_assignments,
         max_turns,
         checkpoint,
         _retries,
         _call_start_turn
       ) do
    Agent.update(checkpoint, fn {_state, turn} -> {resume_state, turn} end)
    report_turn_limit_exceeded(resume_state, max_turns)
  end

  defp handle_ai_loop_result(
         {:error, {:step_failed, reason}, resume_state},
         modules,
         opts,
         model_assignments,
         max_turns,
         checkpoint,
         retries,
         call_start_turn
       ) do
    turn = Agent.get(checkpoint, fn {_state, t} -> t end)
    ctx = sim_context(resume_state, turn)
    consecutive_failures = if turn > call_start_turn, do: 1, else: retries + 1

    Logger.warning(
      "[SimManager] #{resume_state.sim_id} step error (retry #{consecutive_failures}/#{@max_step_retries}, " <>
        "phase=#{ctx.phase}, day=#{ctx.day}, actor=#{ctx.actor}, turn=#{turn}): " <>
        inspect_error(reason),
      sim_id: resume_state.sim_id
    )

    logged_state = record_sim_error(resume_state, turn, :step_error, inspect_error(reason))
    persist_state!(logged_state)
    broadcast_update(logged_state)
    # The recorded error must ride along into the retry, exactly like the
    # pre-delegation do_ai_loop rebinding `state` before recursing — otherwise
    # it silently vanishes as soon as the retried turn succeeds and this
    # errorless resume_state becomes stale.
    Agent.update(checkpoint, fn {_state, t} -> {logged_state, t} end)
    Process.sleep(2000 * consecutive_failures)

    run_ai_loop_with_retry(
      modules,
      opts,
      model_assignments,
      max_turns,
      checkpoint,
      consecutive_failures
    )
  end

  defp handle_ai_loop_result(
         {:runner_crash, kind, reason, stacktrace},
         modules,
         opts,
         model_assignments,
         max_turns,
         checkpoint,
         retries,
         call_start_turn
       ) do
    {state, turn} = Agent.get(checkpoint, & &1)
    ctx = sim_context(state, turn)
    consecutive_failures = if turn > call_start_turn, do: 1, else: retries + 1

    Logger.error(
      "[SimManager] #{state.sim_id} step crashed (retry #{consecutive_failures}/#{@max_step_retries}, " <>
        "phase=#{ctx.phase}, day=#{ctx.day}, actor=#{ctx.actor}, turn=#{turn}): " <>
        "#{kind} #{inspect_error(reason)}\n" <>
        Exception.format_stacktrace(stacktrace),
      sim_id: state.sim_id
    )

    logged_state = record_sim_error(state, turn, :step_crash, "#{kind}: #{inspect_error(reason)}")
    persist_state!(logged_state)
    broadcast_update(logged_state)
    # See the matching comment in the {:step_failed, ...} clause above: the
    # recorded error must ride along into the retry, or it vanishes as soon
    # as the retried turn succeeds.
    Agent.update(checkpoint, fn {_state, t} -> {logged_state, t} end)
    Process.sleep(2000 * consecutive_failures)

    run_ai_loop_with_retry(
      modules,
      opts,
      model_assignments,
      max_turns,
      checkpoint,
      consecutive_failures
    )
  end

  defp report_turn_limit_exceeded(state, max_turns) do
    Logger.warning("[SimManager] #{state.sim_id} hit max turns (#{max_turns})",
      sim_id: state.sim_id,
      turn: max_turns
    )

    state =
      record_sim_error(state, max_turns, :turn_limit_exceeded, "Hit max turns (#{max_turns})")
      |> mark_run_failed(:turn_limit_exceeded)

    persist_state!(state)
    broadcast_update(state)
  end

  # `run_until_terminal/3` calls this with the *relative* turn number for this
  # invocation (always restarts at 1); `turns_before` (turns already completed
  # across earlier retries) puts it back on the sim's absolute turn count, so
  # `Runner.step/3`'s per-step behavior above and this delegated loop log/
  # record identical turn numbers.
  defp ai_loop_after_step(checkpoint, turns_before) do
    fn relative_turn, result ->
      case result do
        %{state: _next_state} ->
          {before_state, _turn} = Agent.get(checkpoint, & &1)
          overall_turn = turns_before + relative_turn
          traced_state = advance_after_successful_step(before_state, result, overall_turn - 1)
          Agent.update(checkpoint, fn _ -> {traced_state, overall_turn} end)
          {:ok, traced_state}

        _ ->
          :ok
      end
    end
  end

  defp run_interactive(state, modules, opts, human_team) do
    terminal? = Keyword.get(opts, :terminal?, fn _s -> false end)
    max_turns = Keyword.get(opts, :driver_max_turns, 50)
    do_interactive_loop(state, modules, opts, terminal?, max_turns, 0, human_team)
  end

  defp do_interactive_loop(state, _modules, _opts, _terminal?, max_turns, turn, _human_team)
       when turn >= max_turns do
    state = mark_run_failed(state, :turn_limit_exceeded)
    persist_state!(state)
    broadcast_update(state)
  end

  defp do_interactive_loop(state, modules, opts, terminal?, max_turns, turn, human_team) do
    if terminal?.(state) do
      state = mark_run_completed_if_terminal(state)
      persist_state!(state)
      broadcast_update(state)
    else
      if human_turn?(state, human_team) do
        # Wait for human move
        broadcast_update(state)

        receive do
          {:human_move, event} ->
            updater = Map.get(modules, :updater)

            case Runner.ingest_events(state, [event], updater, opts) do
              {:ok, next_state, _signal} ->
                next_state = checkpoint_run(next_state, turn + 1)
                persist_state!(next_state)
                broadcast_update(next_state)

                do_interactive_loop(
                  next_state,
                  modules,
                  opts,
                  terminal?,
                  max_turns,
                  turn + 1,
                  human_team
                )

              {:error, _reason} ->
                # Retry — let human try again
                do_interactive_loop(
                  state,
                  modules,
                  opts,
                  terminal?,
                  max_turns,
                  turn,
                  human_team
                )
            end
        after
          300_000 ->
            state = mark_run_failed(state, :human_timeout)
            persist_state!(state)
            broadcast_update(state)
        end
      else
        maybe_call_on_before_step(opts, turn, state)

        case Runner.step(state, modules, opts) do
          {:ok, result} ->
            next_state = advance_after_successful_step(state, result, turn)
            Process.sleep(500)

            do_interactive_loop(
              next_state,
              modules,
              opts,
              terminal?,
              max_turns,
              turn + 1,
              human_team
            )

          {:error, reason} ->
            ctx = sim_context(state, turn)

            Logger.warning(
              "[SimManager] #{state.sim_id} interactive step error " <>
                "(phase=#{ctx.phase}, day=#{ctx.day}, actor=#{ctx.actor}, turn=#{turn}): " <>
                inspect_error(reason),
              sim_id: state.sim_id
            )

            state = record_sim_error(state, turn, :step_error, inspect_error(reason))
            state = mark_run_failed(state, :step_error)
            persist_state!(state)
            broadcast_update(state)
        end
      end
    end
  end

  defp human_turn?(state, human_team) do
    world = state.world

    cond do
      # TicTacToe: human_team is "X" or "O", current_player matches
      Map.has_key?(world, :board) or Map.has_key?(world, "board") ->
        MapHelpers.get_key(world, :current_player) == human_team

      # Skirmish: human_team is "red" or "blue", active actor's team matches
      Map.has_key?(world, :units) or Map.has_key?(world, "units") ->
        actor_id = MapHelpers.get_key(world, :active_actor_id)
        units = MapHelpers.get_key(world, :units) || %{}
        actor = Map.get(units, actor_id)
        actor && MapHelpers.get_key(actor, :team) == human_team

      true ->
        false
    end
  end

  # Used by do_interactive_loop/7's AI-turn branch (the delegated AI-only path
  # in run_ai_loop_with_retry/6 no longer needs this: run_multi_model/5 invokes
  # on_before_step itself for its Agent-held model switching).
  defp maybe_call_on_before_step(opts, turn, state) do
    case Keyword.get(opts, :on_before_step) do
      f when is_function(f, 2) -> f.(turn, state)
      _ -> :ok
    end
  end

  # Shared between do_interactive_loop/7's AI-turn branch and
  # ai_loop_after_step/2 (the run_ai_only/3 delegated path): folds the step's
  # decision into plan_history (read back by SectionedProjector as the
  # :plan_history prompt section, so it must be part of the returned state
  # rather than a side effect), persists, and broadcasts. Returns the traced
  # state for the caller to recurse on / feed back into the loop.
  defp advance_after_successful_step(before_state, result, turn) do
    next_state =
      result.state
      |> append_decision_trace(before_state, turn + 1, result)
      |> checkpoint_run(turn + 1)

    persist_state!(next_state)
    broadcast_update(next_state)
    next_state
  end

  defp on_after_step(turn, %{state: next_state}) do
    next_state = checkpoint_run(next_state, turn + 1)
    persist_state!(next_state)
    broadcast_update(next_state)
  end

  defp on_after_step(_turn, _result), do: :ok

  defp broadcast_update(%State{} = state) do
    LemonSim.Kernel.Bus.broadcast_world_update(state.sim_id, %{state: state})
    broadcast_lobby()
  end

  defp broadcast_update(sim_id) when is_binary(sim_id) do
    LemonSim.Kernel.Bus.broadcast_world_update(sim_id, %{})
    broadcast_lobby()
  end

  defp broadcast_lobby do
    event = LemonCore.Event.new(:sim_lobby_changed, %{})
    LemonCore.Bus.broadcast(@lobby_topic, event)
  end

  @doc false
  def append_decision_trace(%State{} = next_state, %State{} = before_state, turn, result) do
    decision = Map.get(result, :decision, %{})
    calls = decision |> fetch(:executed_calls, "executed_calls", []) |> List.wrap()
    attempted_events = result |> Map.get(:events, []) |> List.wrap()
    rejection = current_rejection(next_state, before_state)
    events = if rejection, do: [rejection], else: attempted_events
    ctx = sim_context(before_state, turn)

    tool_names =
      calls |> Enum.map(&fetch(&1, :tool_name, "tool_name", nil)) |> Enum.reject(&is_nil/1)

    event_names = events |> Enum.map(&fetch(&1, :kind, "kind", "event")) |> Enum.map(&to_string/1)

    summary =
      cond do
        rejection ->
          "#{ctx.actor} action rejected"

        tool_names != [] ->
          "#{ctx.actor} used #{Enum.join(tool_names, ", ")}"

        event_names != [] ->
          "#{ctx.actor} produced #{Enum.join(event_names, ", ")}"

        true ->
          "#{ctx.actor} completed a model step"
      end

    rationale =
      if rejection do
        fetch(rejection.payload, :reason, "reason", "Action rejected")
      else
        visible_decision_rationale(decision) ||
          visible_tool_trace(calls) ||
          visible_event_trace(events)
      end

    State.append_plan_step(next_state, %{
      summary: summary,
      rationale: rationale,
      meta: %{
        kind: "model_trace",
        turn: turn,
        actor: ctx.actor,
        day: ctx.day,
        phase: ctx.phase,
        tools: tool_names,
        events: event_names
      }
    })
  end

  defp current_rejection(next_state, before_state) do
    case List.last(next_state.recent_events) do
      %{kind: "action_rejected"} = event when next_state.version > before_state.version -> event
      _ -> nil
    end
  end

  defp visible_decision_rationale(%{} = decision) do
    [:rationale, :thought, :reasoning, :summary, :message]
    |> Enum.find_value(fn key ->
      decision
      |> fetch(key, Atom.to_string(key), nil)
      |> present_string()
    end)
  end

  defp visible_decision_rationale(_), do: nil

  defp visible_tool_trace([]), do: nil

  defp visible_tool_trace(calls) do
    calls
    |> Enum.take(5)
    |> Enum.map(fn call ->
      tool = fetch(call, :tool_name, "tool_name", "tool")
      args = call |> fetch(:arguments, "arguments", %{}) |> summarize_map()

      result =
        call |> fetch(:result_text, "result_text", nil) |> present_string() |> truncate(180)

      cond do
        result && args != "" -> "#{tool}(#{args}) -> #{result}"
        result -> "#{tool} -> #{result}"
        args != "" -> "#{tool}(#{args})"
        true -> to_string(tool)
      end
    end)
    |> Enum.join("\n")
    |> truncate(900)
  end

  defp visible_event_trace([]), do: nil

  defp visible_event_trace(events) do
    events
    |> Enum.take(5)
    |> Enum.map(fn event ->
      kind = fetch(event, :kind, "kind", "event")
      payload = event |> fetch(:payload, "payload", %{}) |> summarize_map()
      if payload == "", do: to_string(kind), else: "#{kind}: #{payload}"
    end)
    |> Enum.join("\n")
    |> truncate(900)
  end

  defp summarize_map(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> secretish_key?(key) end)
    |> Enum.take(4)
    |> Enum.map(fn {key, value} -> "#{key}=#{summarize_value(value)}" end)
    |> Enum.join(", ")
  end

  defp summarize_map(_), do: ""

  defp summarize_value(value) when is_binary(value), do: truncate(value, 120)
  defp summarize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp summarize_value(value) when is_number(value), do: to_string(value)
  defp summarize_value(value), do: inspect(value, limit: 4, printable_limit: 120)

  defp secretish_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(
      &(String.contains?(&1, "key") or String.contains?(&1, "token") or
          String.contains?(&1, "secret"))
    )
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(nil), do: nil
  defp present_string(value), do: value |> to_string() |> present_string()

  defp truncate(nil, _max), do: nil

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value

  defp fetch(map, atom_key, string_key, default) when is_map(map) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  defp fetch(_map, _atom_key, _string_key, default), do: default

  defp generate_id(:tic_tac_toe), do: "ttt_#{random_hex(4)}"
  defp generate_id(:skirmish), do: "skm_#{random_hex(4)}"
  defp generate_id(:werewolf), do: "ww_#{random_hex(4)}"
  defp generate_id(:stock_market), do: "stk_#{random_hex(4)}"
  defp generate_id(:survivor), do: "srv_#{random_hex(4)}"
  defp generate_id(:space_station), do: "spc_#{random_hex(4)}"
  defp generate_id(:vending_bench), do: "vb_#{random_hex(4)}"
  defp generate_id(:tcg_shop), do: "tcg_#{random_hex(4)}"
  defp generate_id(:poker), do: "pkr_#{random_hex(4)}"
  defp generate_id(_), do: "sim_#{random_hex(4)}"

  defp domain_from_sim_id("ww_" <> _), do: :werewolf
  defp domain_from_sim_id("ttt_" <> _), do: :tic_tac_toe
  defp domain_from_sim_id("skm_" <> _), do: :skirmish
  defp domain_from_sim_id("stk_" <> _), do: :stock_market
  defp domain_from_sim_id("srv_" <> _), do: :survivor
  defp domain_from_sim_id("spc_" <> _), do: :space_station
  defp domain_from_sim_id("vb_" <> _), do: :vending_bench
  defp domain_from_sim_id("tcg_" <> _), do: :tcg_shop
  defp domain_from_sim_id("pkr_" <> _), do: :poker
  defp domain_from_sim_id(_), do: :unknown

  # Domains whose games can resume mid-flight: the world stores per-player
  # "provider/model_id" strings, so assignments can be rebuilt from the
  # persisted state alone.
  @resumable_examples %{
    werewolf: LemonSim.Examples.Werewolf,
    space_station: SpaceStation,
    stock_market: StockMarket,
    survivor: Survivor,
    poker: Poker
  }

  defp build_resume_opts(domain, state) when is_map_key(@resumable_examples, domain) do
    example = Map.fetch!(@resumable_examples, domain)
    modules = example.modules()

    # Check if state has per-player model assignments and rebuild them
    players = MapHelpers.get_key(state.world, :players) || %{}

    model_info_count =
      Enum.count(players, fn {_id, player} -> MapHelpers.get_key(player, :model) != nil end)

    run_opts =
      if model_info_count == map_size(players) and model_info_count > 0 do
        config = load_project_config()

        model_assignments =
          players
          |> Enum.filter(fn {_id, p} -> MapHelpers.get_key(p, :model) != nil end)
          |> Enum.into(%{}, fn {player_id, p} ->
            spec = MapHelpers.get_key(p, :model)
            {provider, model_id} = parse_model_spec(spec)
            m = resolve_model!(provider, model_id, config)
            api_key = SimConfig.resolve_provider_api_key!(provider, config, to_string(domain))
            {player_id, {m, api_key}}
          end)

        {default_model, default_key} = model_assignments |> Map.values() |> List.first()

        example.default_opts(
          model: default_model,
          stream_options: %{api_key: default_key}
        )
        |> Keyword.put(:persist?, true)
        |> Keyword.put(:on_before_step, nil)
        |> Keyword.put(:on_after_step, &on_after_step/2)
        |> Keyword.put(:model_assignments, model_assignments)
      else
        if model_info_count > 0 do
          raise "Persisted #{domain} model assignments are incomplete"
        end

        {model, stream_options} =
          case run_meta_value(state, :model) do
            spec when is_binary(spec) ->
              resolve_model_stream_options!(spec, load_project_config(), to_string(domain))

            _ ->
              resolve_default_model_for_ui()
          end

        example.default_opts(model: model, stream_options: stream_options)
        |> Keyword.put(:persist?, true)
        |> Keyword.put(:on_before_step, nil)
        |> Keyword.put(:on_after_step, &on_after_step/2)
      end

    {:ok, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_resume_opts(domain, _state) do
    {:error, "Resume not yet supported for #{domain}"}
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end

  defp initialize_run_metadata(state, domain, start_opts, run_opts) do
    max_turns = Keyword.get(run_opts, :driver_max_turns, 50)
    model = Keyword.get(run_opts, :model)

    model_spec =
      if match?(%Ai.Types.Model{}, model), do: "#{model.provider}/#{model.id}", else: nil

    rng_state =
      case :rand.export_seed() do
        :undefined -> nil
        exported -> exported
      end

    put_run_meta(state, %{
      schema_version: 1,
      domain: to_string(domain),
      status: "running",
      resumable: domain in @resumable_domains and is_nil(Keyword.get(start_opts, :human_player)),
      started_at_ms: System.system_time(:millisecond),
      finished_at_ms: nil,
      failure_reason: nil,
      turns_completed: 0,
      resume_count: 0,
      recovery_attempts: 0,
      arena_domain: Keyword.get(start_opts, :arena_domain),
      max_turns: max_turns,
      seed: Keyword.get(start_opts, :seed),
      model: model_spec,
      rng_state: rng_state,
      start_opts: sanitize_start_opts(start_opts)
    })
  end

  defp maybe_override_driver_max_turns(run_opts, opts) do
    case Keyword.get(opts, :driver_max_turns) do
      max_turns when is_integer(max_turns) and max_turns > 0 ->
        Keyword.put(run_opts, :driver_max_turns, max_turns)

      _ ->
        run_opts
    end
  end

  defp sanitize_start_opts(opts) do
    opts
    |> Keyword.take([
      :seed,
      :player_count,
      :model_specs,
      :max_turns,
      :driver_max_turns,
      :arena_domain,
      :balanced_roles?,
      :role_rotation_index,
      :max_days,
      :rng_seed,
      :map_width,
      :map_height,
      :map_preset
    ])
    |> Enum.into(%{})
  end

  defp checkpoint_run(state, turns_completed) do
    rng_state =
      case :rand.export_seed() do
        :undefined -> nil
        exported -> exported
      end

    updates = %{
      turns_completed: turns_completed,
      rng_state: rng_state,
      recovery_attempts: 0
    }

    updates =
      if MapHelpers.get_key(state.world, :status) == "game_over" do
        Map.merge(updates, %{
          status: "completed",
          resumable: false,
          finished_at_ms: System.system_time(:millisecond)
        })
      else
        updates
      end

    put_run_meta(state, updates)
  end

  defp mark_run_completed_if_terminal(state) do
    if MapHelpers.get_key(state.world, :status) == "game_over" do
      put_run_meta(state, %{
        status: "completed",
        resumable: false,
        finished_at_ms: System.system_time(:millisecond)
      })
    else
      state
    end
  end

  defp mark_run_failed(state, reason) do
    put_run_meta(state, %{
      status: "failed",
      resumable: false,
      failure_reason: to_string(reason),
      finished_at_ms: System.system_time(:millisecond)
    })
  end

  defp put_run_meta(state, updates) do
    meta = state.meta || %{}
    run = Map.merge(MapHelpers.get_key(meta, :run) || %{}, updates)
    %{state | meta: Map.put(meta, :run, run), version: state.version + 1}
  end

  defp run_meta_value(state, key, default \\ nil) do
    run = state.meta |> Kernel.||(%{}) |> MapHelpers.get_key(:run) |> Kernel.||(%{})
    fetch(run, key, Atom.to_string(key), default)
  end

  defp terminate_orphaned_runners do
    LemonSimUi.SimRunnerSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(LemonSimUi.SimRunnerSupervisor, pid)
    end)
  end

  defp stop_runner_if_present(state, sim_id) do
    case Map.get(state.runners, sim_id) do
      nil ->
        state

      entry ->
        terminate_runner(Map.fetch!(entry, :ref))
        collector = Map.get(entry, :usage_collector)
        {state, _stored_state} = capture_final_usage(state, sim_id, collector)
        stop_usage_collector(collector)

        %{
          state
          | runners: Map.delete(state.runners, sim_id),
            human_players: Map.delete(state.human_players, sim_id)
        }
    end
  end

  defp terminate_runner(pid) when is_pid(pid) do
    monitor = Process.monitor(pid)

    case DynamicSupervisor.terminate_child(LemonSimUi.SimRunnerSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)

      {:error, _reason} ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      5_000 ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(monitor, [:flush])
        end
    end
  end

  defp persist_terminal_state(sim_id, status, reason) do
    case Store.get_state(sim_id) do
      %State{} = stored_state ->
        terminal_state =
          put_run_meta(stored_state, %{
            status: status,
            resumable: false,
            failure_reason: reason,
            finished_at_ms: System.system_time(:millisecond)
          })

        case put_state_with_retry(terminal_state, 3) do
          :ok -> {:ok, terminal_state}
          {:error, persist_reason} -> {:error, {:persistence_failed, persist_reason}}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp restore_rng(state) do
    case run_meta_value(state, :rng_state) do
      nil ->
        case run_meta_value(state, :seed) do
          seed when is_integer(seed) -> :rand.seed(:exsss, {seed, seed + 1, seed + 2})
          _ -> :ok
        end

      exported ->
        :rand.seed(exported)
    end
  end

  defp persist_state!(state) do
    case put_state_with_retry(state, 3) do
      :ok -> state
      {:error, reason} -> raise "simulation persistence failed: #{inspect(reason)}"
    end
  end

  defp put_state_with_retry(state, retries) when retries > 0 do
    case Store.put_state(state) do
      :ok ->
        :ok

      {:error, :sqlite_busy} ->
        Process.sleep(100)
        put_state_with_retry(state, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_state_with_retry(_state, 0), do: {:error, :sqlite_busy}

  defp persist_recovery_state(state, stored_state, retries) do
    state = ensure_auto_loop_keys(state)
    state.recovery_persist.(stored_state, retries)
  end

  # -- Model resolution helpers --

  # Resolves a default model + API key for non-multi-model sims started from the UI.
  # Tries Lemon config first, falls back to first available Gemini model.
  defp resolve_default_model_for_ui do
    config = load_project_config()

    model =
      try do
        SimConfig.resolve_configured_model!(config, "sim")
      rescue
        _ -> Ai.Models.get_model(:google_gemini_cli, "gemini-2.5-flash")
      end

    api_key =
      try do
        SimConfig.resolve_provider_api_key!(model.provider, config, "sim")
      rescue
        _ -> nil
      end

    {model, %{api_key: api_key}}
  end

  def parse_model_spec(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, model_id] -> {resolve_model_provider!(provider), model_id}
      [_] -> parse_slash_model_spec(spec)
    end
  end

  # World snapshots store per-player models as "provider/model_id" (see
  # Werewolf.attach_model_assignments/2); resume reads specs back from the
  # world, so that shape must parse too. A leading segment that is not a known
  # provider falls through to the bare-model default.
  defp parse_slash_model_spec(spec) do
    with [provider, model_id] <- String.split(spec, "/", parts: 2),
         {:ok, resolved} <- lookup_model_provider(provider) do
      {resolved, model_id}
    else
      _ -> {:anthropic, spec}
    end
  end

  defp resolve_model_provider!(provider_name) do
    case lookup_model_provider(provider_name) do
      {:ok, provider} -> provider
      :error -> raise ArgumentError, "unknown model provider: #{provider_name}"
    end
  end

  defp lookup_model_provider(provider_name) do
    canonical_name = SimConfig.provider_name(provider_name)

    Enum.find(Ai.Models.get_providers(), fn provider ->
      SimConfig.provider_name(provider) == canonical_name
    end)
    |> case do
      nil -> :error
      provider -> {:ok, provider}
    end
  end

  defp resolve_model!(provider, model_id, config) do
    case Ai.Models.get_model(provider, model_id) do
      %Ai.Types.Model{} = model ->
        SimConfig.apply_provider_base_url(model, config)

      nil ->
        raise "Could not resolve model #{provider}/#{model_id}"
    end
  end

  defp resolve_model_stream_options!(spec, config, game_name) do
    {provider, model_id} = parse_model_spec(spec)
    model = resolve_model!(provider, model_id, config)
    api_key = SimConfig.resolve_provider_api_key!(provider, config, game_name)
    {model, %{api_key: api_key}}
  end

  # Shared helper for games that support multi-model assignments (stock_market, survivor, space_station).
  defp build_multi_model_opts(initial_state, _modules, model_specs, player_count, opts) do
    default_opts_fn = Keyword.fetch!(opts, :default_opts_fn)

    # Assignments must be keyed by the world's actual player ids — survivor
    # seats real names, most other domains player_N. Specs zip positionally
    # over the sorted ids (the shared seat-order convention).
    player_ids =
      case MapHelpers.get_key(initial_state.world, :players) do
        players when is_map(players) and map_size(players) > 0 ->
          players |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

        _ ->
          Enum.map(1..player_count, &"player_#{&1}")
      end

    if model_specs != [] do
      config = load_project_config()

      model_assignments =
        player_ids
        |> Enum.zip(model_specs)
        |> Enum.into(%{}, fn {player_id, spec} ->
          {provider, model_id} = parse_model_spec(spec)
          model = resolve_model!(provider, model_id, config)
          api_key = SimConfig.resolve_provider_api_key!(provider, config, "sim")
          {player_id, {model, api_key}}
        end)

      state_with_models = attach_model_assignments(initial_state, model_assignments)
      {default_model, default_key} = model_assignments |> Map.values() |> List.first()

      run_opts =
        default_opts_fn.(model: default_model, stream_options: %{api_key: default_key})
        |> Keyword.put(:persist?, true)
        |> Keyword.put(:on_before_step, nil)
        |> Keyword.put(:on_after_step, &on_after_step/2)
        |> Keyword.put(:model_assignments, model_assignments)

      {state_with_models, run_opts}
    else
      {model, stream_options} = resolve_default_model_for_ui()

      run_opts =
        default_opts_fn.(model: model, stream_options: stream_options)
        |> Keyword.put(:persist?, true)
        |> Keyword.put(:on_before_step, nil)
        |> Keyword.put(:on_after_step, &on_after_step/2)

      {initial_state, run_opts}
    end
  end

  defp attach_model_assignments(state, model_assignments) do
    players =
      (state.world[:players] || state.world["players"] || %{})
      |> Enum.into(%{}, fn {player_id, info} ->
        case Map.get(model_assignments, player_id) do
          {model, _key} ->
            {player_id, Map.put(info, :model, "#{model.provider}/#{model.id}")}

          nil ->
            {player_id, info}
        end
      end)

    %{state | world: Map.put(state.world, :players, players)}
  end

  defp load_project_config do
    LemonCore.Config.Modular.load(project_dir: ProjectRoot.resolve(__DIR__))
  end

  # Reads [[sim.loop]] entries from .lemon/config.toml and converts them
  # to the [{domain_atom, opts_keyword}] format expected by boot_auto_loop.
  # Uses raw TOML parsing (not Config.Modular) because the struct doesn't
  # preserve unknown sections like [sim].
  defp load_sim_loop_config do
    project_dir = ProjectRoot.resolve(__DIR__)
    toml_path = Path.join([project_dir, ".lemon", "config.toml"])

    case File.read(toml_path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, raw} ->
            raw
            |> get_in(["sim", "loop"])
            |> case do
              entries when is_list(entries) and entries != [] ->
                Enum.map(entries, &parse_sim_loop_entry/1)

              _ ->
                []
            end

          {:error, reason} ->
            Logger.warning("[SimManager] Failed to parse sim loop config: #{inspect(reason)}")
            []
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("[SimManager] Failed to read sim loop config: #{inspect(reason)}")
        []
    end
  end

  defp parse_sim_loop_entry(entry) when is_map(entry) do
    domain = Map.fetch!(entry, "domain") |> String.to_existing_atom()

    opts =
      entry
      |> Map.drop(["domain"])
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)

    {domain, opts}
  end

  # -- Error logging helpers --

  defp sim_context(%State{} = state, turn) do
    %{
      phase: MapHelpers.get_key(state.world, :phase) || "?",
      day: MapHelpers.get_key(state.world, :day_number) || "?",
      actor: MapHelpers.get_key(state.world, :active_actor_id) || "none",
      turn: turn
    }
  end

  defp record_sim_error(%State{} = state, turn, kind, message) do
    ctx = sim_context(state, turn)

    entry = %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      kind: kind,
      message: message,
      phase: ctx.phase,
      day: ctx.day,
      actor: ctx.actor,
      turn: turn
    }

    errors = MapHelpers.get_key(state.world, :runner_errors) || []
    # Keep last 20 errors
    updated_errors = Enum.take(errors ++ [entry], -20)
    State.put_world(state, Map.put(state.world, :runner_errors, updated_errors))
  end

  defp inspect_error(reason) when is_binary(reason), do: reason
  defp inspect_error(reason), do: inspect(reason, limit: 5, printable_limit: 500)
end
