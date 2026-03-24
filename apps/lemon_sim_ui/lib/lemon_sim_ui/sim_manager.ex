defmodule LemonSimUi.SimManager do
  @moduledoc """
  GenServer managing running simulation processes.

  Bridges the UI with LemonSim.Runner by spawning linked runner
  processes and providing start/stop/list operations.
  """

  use GenServer

  require Logger

  alias LemonCore.MapHelpers
  alias LemonSim.{Runner, State, Store}

  alias LemonSim.Examples.{
    TicTacToe,
    Skirmish,
    StockMarket,
    Survivor,
    SpaceStation,
    Auction,
    Diplomacy,
    DungeonCrawl,
    VendingBench
  }

  alias LemonSim.GameHelpers.Config, as: SimConfig
  alias LemonSimUi.ProjectRoot

  @lobby_topic "sim:lobby"

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

  @spec stop_sim(String.t()) :: :ok | {:error, :not_found}
  def stop_sim(sim_id) do
    GenServer.call(__MODULE__, {:stop_sim, sim_id})
  end

  @spec resume_sim(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resume_sim(sim_id) do
    GenServer.call(__MODULE__, {:resume_sim, sim_id})
  end

  @spec list_running() :: [String.t()]
  def list_running do
    GenServer.call(__MODULE__, :list_running)
  end

  @spec register_human(String.t(), String.t()) :: :ok
  def register_human(sim_id, team) do
    GenServer.call(__MODULE__, {:register_human, sim_id, team})
  end

  @spec submit_human_move(String.t(), LemonSim.Event.t()) :: :ok | {:error, term()}
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

    {:ok,
     %{
       runners: %{},
       human_players: %{},
       auto_loops: %{},
       pending_restarts: %{}
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
    case Map.get(state.runners, sim_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{ref: ref} ->
        Process.exit(ref, :shutdown)
        runners = Map.delete(state.runners, sim_id)
        human_players = Map.delete(state.human_players, sim_id)
        broadcast_lobby()
        {:reply, :ok, %{state | runners: runners, human_players: human_players}}
    end
  end

  def handle_call({:resume_sim, sim_id}, _from, state) do
    if Map.has_key?(state.runners, sim_id) do
      {:reply, {:error, :already_running}, state}
    else
      case Store.get_state(sim_id) do
        nil ->
          {:reply, {:error, :not_found}, state}

        stored_state ->
          status = MapHelpers.get_key(stored_state.world, :status)

          if status == "game_over" do
            {:reply, {:error, :game_over}, state}
          else
            domain = domain_from_sim_id(sim_id)

            case build_resume_opts(domain, stored_state) do
              {:ok, modules, run_opts} ->
                broadcast_lobby()

                task_ref = start_runner(stored_state, modules, run_opts, nil)
                runners = Map.put(state.runners, sim_id, %{ref: task_ref, domain: domain})

                {:reply, {:ok, sim_id}, %{state | runners: runners}}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
          end
      end
    end
  end

  def handle_call(:list_running, _from, state) do
    {:reply, Map.keys(state.runners), state}
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
      runners = Map.delete(state.runners, sim_id)
      human_players = Map.delete(state.human_players, sim_id)
      broadcast_lobby()

      state = %{state | runners: runners, human_players: human_players}

      # Check if auto-loop should restart this domain
      state =
        case Map.get(state.auto_loops, domain) do
          %{enabled: true} ->
            # Verify game actually finished
            case Store.get_state(sim_id) do
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

      {:noreply, state}
    else
      {:noreply, state}
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

        case do_start_sim(domain, opts, acc) do
          {:ok, sim_id, new_acc} ->
            auto_loops =
              Map.update!(new_acc.auto_loops, domain, fn lc ->
                %{lc | current_sim_id: sim_id, game_count: lc.game_count + 1}
              end)

            %{new_acc | auto_loops: auto_loops}

          {:error, reason, new_acc} ->
            Logger.error("[SimManager] Boot auto-loop failed for #{domain}: #{inspect(reason)}")
            new_acc
        end
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private helpers ---

  # Ensures auto_loops/pending_restarts keys exist in state, for hot-code-reload
  # compatibility when the GenServer was started before these keys were added.
  defp ensure_auto_loop_keys(state) do
    state
    |> Map.put_new(:auto_loops, %{})
    |> Map.put_new(:pending_restarts, %{})
  end

  defp do_start_sim(domain, opts, state) do
    sim_id = Keyword.get(opts, :sim_id, generate_id(domain))
    human_player = Keyword.get(opts, :human_player)

    case build_initial_state(domain, sim_id, opts) do
      {:ok, initial_state, modules, run_opts} ->
        put_state_with_retry(initial_state, 3)
        maybe_start_post_launch_tasks(domain, initial_state, run_opts)
        broadcast_lobby()

        task_ref = start_runner(initial_state, modules, run_opts, human_player)

        runners = Map.put(state.runners, sim_id, %{ref: task_ref, domain: domain})

        human_players =
          if human_player do
            Map.put(state.human_players, sim_id, human_player)
          else
            state.human_players
          end

        {:ok, sim_id, %{state | runners: runners, human_players: human_players}}

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

    initial_state = VendingBench.initial_state(sim_id: sim_id, max_days: max_days)
    modules = VendingBench.modules()

    {model, stream_options} = resolve_default_model_for_ui()

    support_tool_matcher = fn tool ->
      String.starts_with?(tool.name, "memory_") or
        tool.name in ~w(read_inbox check_balance check_storage inspect_supplier_directory review_recent_sales)
    end

    run_opts =
      VendingBench.default_opts(model: model, stream_options: stream_options)
      |> Keyword.put(:persist?, true)
      |> Keyword.put(:on_before_step, nil)
      |> Keyword.put(:on_after_step, &on_after_step/2)
      |> Keyword.put(:support_tool_matcher, support_tool_matcher)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(domain, _sim_id, _opts) do
    {:error, {:unknown_domain, domain}}
  end

  defp maybe_start_post_launch_tasks(:werewolf, initial_state, run_opts) do
    maybe_generate_werewolf_lore(initial_state, run_opts)
  end

  defp maybe_start_post_launch_tasks(_domain, _initial_state, _run_opts), do: :ok

  defp start_runner(initial_state, modules, run_opts, human_player) do
    pid =
      spawn_link(fn ->
        if human_player do
          run_interactive(initial_state, modules, run_opts, human_player)
        else
          run_ai_only(initial_state, modules, run_opts)
        end
      end)

    Process.monitor(pid)
    pid
  end

  defp run_ai_only(state, modules, opts) do
    terminal? = Keyword.get(opts, :terminal?, fn _s -> false end)
    max_turns = Keyword.get(opts, :driver_max_turns, 50)
    model_assignments = Keyword.get(opts, :model_assignments)

    # If multi-model, set up the model-switching complete_fn
    opts =
      if model_assignments do
        {default_model, default_key} = model_assignments |> Map.values() |> List.first()
        {:ok, model_agent} = Agent.start_link(fn -> {default_model, default_key} end)

        complete_fn = fn _model, context, stream_options ->
          {actual_model, api_key} = Agent.get(model_agent, & &1)
          actual_stream_options = stream_options |> Map.new() |> Map.put(:api_key, api_key)
          Ai.complete(actual_model, context, actual_stream_options)
        end

        on_before_step = fn _turn, step_state ->
          actor_id = LemonCore.MapHelpers.get_key(step_state.world, :active_actor_id)

          case Map.get(model_assignments, actor_id) do
            {model, key} -> Agent.update(model_agent, fn _ -> {model, key} end)
            nil -> :ok
          end
        end

        opts
        |> Keyword.put(:complete_fn, complete_fn)
        |> Keyword.put(:on_before_step, on_before_step)
      else
        opts
      end

    do_ai_loop(state, modules, opts, terminal?, max_turns, 0)
  end

  defp do_ai_loop(state, _modules, _opts, _terminal?, max_turns, turn)
       when turn >= max_turns do
    Logger.warning("[SimManager] #{state.sim_id} hit max turns (#{max_turns})",
      sim_id: state.sim_id,
      turn: turn
    )

    state = record_sim_error(state, turn, :turn_limit_exceeded, "Hit max turns (#{max_turns})")
    Store.put_state(state)
    broadcast_update(state)
  end

  defp do_ai_loop(state, modules, opts, terminal?, max_turns, turn) do
    do_ai_loop(state, modules, opts, terminal?, max_turns, turn, 0)
  end

  @max_step_retries 3

  defp do_ai_loop(state, _modules, _opts, _terminal?, _max_turns, turn, retries)
       when retries >= @max_step_retries do
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

    Store.put_state(state)
    broadcast_update(state)
  end

  defp do_ai_loop(state, modules, opts, terminal?, max_turns, turn, retries) do
    if terminal?.(state) do
      Store.put_state(state)
      broadcast_update(state)
    else
      # Call on_before_step if provided (used by multi-model to switch the active model)
      case Keyword.get(opts, :on_before_step) do
        f when is_function(f, 2) -> f.(turn, state)
        _ -> :ok
      end

      try do
        case Runner.step(state, modules, opts) do
          {:ok, result} ->
            Store.put_state(result.state)
            broadcast_update(result.state)
            Process.sleep(500)
            do_ai_loop(result.state, modules, opts, terminal?, max_turns, turn + 1, 0)

          {:error, reason} ->
            ctx = sim_context(state, turn)

            Logger.warning(
              "[SimManager] #{state.sim_id} step error (retry #{retries + 1}/#{@max_step_retries}, " <>
                "phase=#{ctx.phase}, day=#{ctx.day}, actor=#{ctx.actor}, turn=#{turn}): " <>
                inspect_error(reason),
              sim_id: state.sim_id
            )

            state = record_sim_error(state, turn, :step_error, inspect_error(reason))
            Store.put_state(state)
            broadcast_update(state)
            Process.sleep(2000 * (retries + 1))
            do_ai_loop(state, modules, opts, terminal?, max_turns, turn, retries + 1)
        end
      catch
        kind, reason ->
          ctx = sim_context(state, turn)
          stacktrace = __STACKTRACE__

          Logger.error(
            "[SimManager] #{state.sim_id} step crashed (retry #{retries + 1}/#{@max_step_retries}, " <>
              "phase=#{ctx.phase}, day=#{ctx.day}, actor=#{ctx.actor}, turn=#{turn}): " <>
              "#{kind} #{inspect_error(reason)}\n" <>
              Exception.format_stacktrace(stacktrace),
            sim_id: state.sim_id
          )

          state =
            record_sim_error(state, turn, :step_crash, "#{kind}: #{inspect_error(reason)}")

          Store.put_state(state)
          broadcast_update(state)
          Process.sleep(2000 * (retries + 1))
          do_ai_loop(state, modules, opts, terminal?, max_turns, turn, retries + 1)
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
    Store.put_state(state)
    broadcast_update(state)
  end

  defp do_interactive_loop(state, modules, opts, terminal?, max_turns, turn, human_team) do
    if terminal?.(state) do
      Store.put_state(state)
      broadcast_update(state)
    else
      if is_human_turn?(state, human_team) do
        # Wait for human move
        broadcast_update(state)

        receive do
          {:human_move, event} ->
            updater = Map.get(modules, :updater)

            case Runner.ingest_events(state, [event], updater, opts) do
              {:ok, next_state, _signal} ->
                Store.put_state(next_state)
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
            # 5 minute timeout
            Store.put_state(state)
            broadcast_update(state)
        end
      else
        # Call on_before_step for multi-model switching
        case Keyword.get(opts, :on_before_step) do
          f when is_function(f, 2) -> f.(turn, state)
          _ -> :ok
        end

        case Runner.step(state, modules, opts) do
          {:ok, result} ->
            Store.put_state(result.state)
            broadcast_update(result.state)
            Process.sleep(500)

            do_interactive_loop(
              result.state,
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
            Store.put_state(state)
            broadcast_update(state)
        end
      end
    end
  end

  defp is_human_turn?(state, human_team) do
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

  defp on_after_step(_turn, %{state: next_state}) do
    Store.put_state(next_state)
    broadcast_update(next_state)
  end

  defp on_after_step(_turn, _result), do: :ok

  defp broadcast_update(%State{} = state) do
    LemonSim.Bus.broadcast_world_update(state.sim_id, %{state: state})
    broadcast_lobby()
  end

  defp broadcast_update(sim_id) when is_binary(sim_id) do
    LemonSim.Bus.broadcast_world_update(sim_id, %{})
    broadcast_lobby()
  end

  defp broadcast_lobby do
    event = LemonCore.Event.new(:sim_lobby_changed, %{})
    LemonCore.Bus.broadcast(@lobby_topic, event)
  end

  defp generate_id(:tic_tac_toe), do: "ttt_#{random_hex(4)}"
  defp generate_id(:skirmish), do: "skm_#{random_hex(4)}"
  defp generate_id(:werewolf), do: "ww_#{random_hex(4)}"
  defp generate_id(:stock_market), do: "stk_#{random_hex(4)}"
  defp generate_id(:survivor), do: "srv_#{random_hex(4)}"
  defp generate_id(:space_station), do: "spc_#{random_hex(4)}"
  defp generate_id(:vending_bench), do: "vb_#{random_hex(4)}"
  defp generate_id(_), do: "sim_#{random_hex(4)}"

  defp domain_from_sim_id("ww_" <> _), do: :werewolf
  defp domain_from_sim_id("ttt_" <> _), do: :tic_tac_toe
  defp domain_from_sim_id("skm_" <> _), do: :skirmish
  defp domain_from_sim_id("stk_" <> _), do: :stock_market
  defp domain_from_sim_id("srv_" <> _), do: :survivor
  defp domain_from_sim_id("spc_" <> _), do: :space_station
  defp domain_from_sim_id("vb_" <> _), do: :vending_bench
  defp domain_from_sim_id(_), do: :unknown

  defp build_resume_opts(:werewolf, state) do
    modules = LemonSim.Examples.Werewolf.modules()
    {model, stream_options} = resolve_default_model_for_ui()

    # Check if state has per-player model assignments and rebuild them
    players = MapHelpers.get_key(state.world, :players) || %{}

    has_model_info =
      Enum.any?(players, fn {_id, p} -> MapHelpers.get_key(p, :model) != nil end)

    run_opts =
      if has_model_info do
        config = load_project_config()

        model_assignments =
          players
          |> Enum.filter(fn {_id, p} -> MapHelpers.get_key(p, :model) != nil end)
          |> Enum.into(%{}, fn {player_id, p} ->
            spec = MapHelpers.get_key(p, :model)
            {provider, model_id} = parse_model_spec(spec)
            m = resolve_model!(provider, model_id, config)
            api_key = SimConfig.resolve_provider_api_key!(provider, config, "werewolf")
            {player_id, {m, api_key}}
          end)

        {default_model, default_key} = model_assignments |> Map.values() |> List.first()

        LemonSim.Examples.Werewolf.default_opts(
          model: default_model,
          stream_options: %{api_key: default_key}
        )
        |> Keyword.put(:persist?, true)
        |> Keyword.put(:on_before_step, nil)
        |> Keyword.put(:on_after_step, &on_after_step/2)
        |> Keyword.put(:model_assignments, model_assignments)
      else
        LemonSim.Examples.Werewolf.default_opts(model: model, stream_options: stream_options)
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

  defp put_state_with_retry(state, retries) when retries > 0 do
    case Store.put_state(state) do
      :ok ->
        :ok

      {:error, :sqlite_busy} ->
        Process.sleep(100)
        put_state_with_retry(state, retries - 1)

      {:error, reason} ->
        raise "Store.put_state failed: #{inspect(reason)}"
    end
  end

  defp put_state_with_retry(_state, 0), do: :ok

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
      [model_id] -> {:anthropic, model_id}
    end
  end

  defp resolve_model_provider!(provider_name) do
    canonical_name = SimConfig.provider_name(provider_name)

    Enum.find(Ai.Models.get_providers(), fn provider ->
      SimConfig.provider_name(provider) == canonical_name
    end) ||
      raise ArgumentError, "unknown model provider: #{provider_name}"
  end

  defp resolve_model!(provider, model_id, config) do
    case Ai.Models.get_model(provider, model_id) do
      %Ai.Types.Model{} = model ->
        SimConfig.apply_provider_base_url(model, config)

      nil ->
        raise "Could not resolve model #{provider}/#{model_id}"
    end
  end

  # Shared helper for games that support multi-model assignments (stock_market, survivor, space_station).
  defp build_multi_model_opts(initial_state, _modules, model_specs, player_count, opts) do
    default_opts_fn = Keyword.fetch!(opts, :default_opts_fn)
    player_ids = Enum.map(1..player_count, &"player_#{&1}")

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

  defp maybe_generate_werewolf_lore(initial_state, run_opts) do
    players = MapHelpers.get_key(initial_state.world, :players) || %{}
    backstory_connections = MapHelpers.get_key(initial_state.world, :backstory_connections) || []
    existing_profiles = MapHelpers.get_key(initial_state.world, :character_profiles) || %{}
    model = Keyword.get(run_opts, :model)
    stream_options = Keyword.get(run_opts, :stream_options, %{})

    if players != %{} and existing_profiles == %{} and model do
      sim_id = initial_state.sim_id

      Task.start(fn ->
        case LemonSim.Examples.Werewolf.Lore.generate(
               players,
               backstory_connections,
               model,
               stream_options
             ) do
          {:ok, profiles} when map_size(profiles) > 0 ->
            merge_werewolf_character_profiles(sim_id, profiles)

          _ ->
            :ok
        end
      end)
    else
      :ok
    end
  end

  defp merge_werewolf_character_profiles(sim_id, profiles) do
    case Store.get_state(sim_id) do
      nil ->
        :ok

      state ->
        existing_profiles = MapHelpers.get_key(state.world, :character_profiles) || %{}

        if existing_profiles == %{} do
          merged_profiles = Map.merge(existing_profiles, profiles)
          updated_state = State.put_world(state, %{character_profiles: merged_profiles})

          put_state_with_retry(updated_state, 3)
          broadcast_update(updated_state)
        else
          :ok
        end
    end
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
