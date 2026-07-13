defmodule LemonSimUi.Arena do
  @moduledoc """
  Always-on arena for one simulation domain: keeps a league game running at
  all times and records every finished game into persistent standings.

  One `Arena` process runs per enabled domain (werewolf, space_station,
  stock_market, survivor, poker — see `@domains`). Each game samples a randomized
  model lineup from the domain's configured pool
  (`LemonSim.Bench.League.plan_match/2`); the recorded seed reproduces both
  the lineup and the scenario's own role/seat randomization.

  The arena is resilient by construction:

    * finished games (world status `game_over`) are recorded into the league
      via the domain's `LemonSim.Bench.League.Registry` adapter, and a fresh
      game starts after a short intermission;
    * games that die mid-flight are resumed via `SimManager.resume_sim/1`
      with backoff, then abandoned and replaced after repeated failures;
    * a watchdog tick re-checks the world every minute, so a missed PubSub
      message can never permanently stall the arena;
    * on restart the arena reconciles unrecorded terminal games before it
      adopts or starts a runner, and marks each league write in persisted
      simulation metadata.

  Configuration lives under `config :lemon_sim_ui, :arenas` — a keyword list
  of per-domain options (`enabled`, `models`, `player_count`, `game_delay_ms`,
  `league_dir`). Runtime env wiring: `LEMON_ARENA_<DOMAIN>_*` (see
  `config/runtime.exs`), with `WEREWOLF_ARENA_*` kept as werewolf aliases.
  """

  use GenServer

  require Logger

  alias LemonCore.MapHelpers
  alias LemonSim.Bench.{Domains, League}
  alias LemonSim.Kernel.State
  alias LemonSimUi.SimManager

  # Registration point: the always-on arena runs one process per domain
  # registered in `LemonSim.Bench.Domains` with a `league_adapter` — that's
  # the same source `Bench.Scorecard.Registry` and `Bench.League.Registry`
  # derive from, so a new arena domain needs one entry there, not here too.
  @arena_domain_descriptors Domains.arena_domains()

  @domains Enum.map(@arena_domain_descriptors, &String.to_atom(&1.id))

  @sim_prefixes Map.new(@arena_domain_descriptors, &{String.to_atom(&1.id), &1.sim_id_prefix})

  # `LemonSim.Bench.Domains` documents `default_player_count` as each
  # domain's own solo-mode default, which the always-on arena doesn't always
  # match: poker's own default is 4 seats, but the arena always seats 6.
  # Every other arena domain's operational default equals the registry
  # value, so only poker needs an explicit override here.
  @default_player_counts @arena_domain_descriptors
                         |> Map.new(&{String.to_atom(&1.id), &1.default_player_count})
                         |> Map.put(:poker, 6)

  @start_delay_ms 3_000
  @tick_ms 60_000
  @retry_start_ms 30_000
  @resume_backoff_ms 5_000
  @max_resume_attempts 3
  @usage_snapshot_every 8

  ## Client API

  def start_link(opts) do
    domain = Keyword.fetch!(opts, :domain)
    name = Keyword.get(opts, :name, name(domain))

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  def child_spec(opts) do
    domain = Keyword.fetch!(opts, :domain)

    %{
      id: {__MODULE__, domain},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Registered name for a domain's arena process."
  @spec name(atom()) :: atom()
  def name(domain), do: :"lemon_sim_ui_arena_#{domain}"

  @doc "All domains the arena system knows how to run."
  @spec domains() :: [atom()]
  def domains, do: @domains

  @doc "Sim-id prefix used by `SimManager.generate_id/1` for a domain."
  @spec sim_prefix(atom()) :: String.t()
  def sim_prefix(domain), do: Map.fetch!(@sim_prefixes, domain)

  @doc "Default seat count the arena configures for a domain absent explicit config."
  @spec default_player_count(atom()) :: pos_integer()
  def default_player_count(domain), do: Map.fetch!(@default_player_counts, domain)

  @doc "PubSub topic receiving `:arena_league_updated` events for a domain."
  @spec league_topic(atom()) :: String.t()
  def league_topic(domain), do: "arena:#{domain}:league"

  @doc "Returns the sim id of the domain's game currently on air, or nil."
  @spec current_sim_id(atom() | GenServer.server()) :: String.t() | nil
  def current_sim_id(domain) when domain in @domains do
    current_sim_id(name(domain))
  end

  def current_sim_id(server) do
    GenServer.call(server, :current_sim_id)
  catch
    :exit, _ -> nil
  end

  @doc "Operational status snapshot for a domain's arena."
  @spec status(atom() | GenServer.server()) :: map()
  def status(domain) when domain in @domains, do: status(name(domain))

  def status(server) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{enabled: false, error: :unavailable}
  end

  @doc "League directory for a domain (readable without the server)."
  @spec league_dir(atom()) :: String.t()
  def league_dir(domain) do
    domain
    |> domain_config([])
    |> Keyword.get(:league_dir)
    |> Kernel.||(default_league_dir(domain))
  end

  @doc "Domains with an enabled arena configuration."
  @spec enabled_domains() :: [atom()]
  def enabled_domains do
    Enum.filter(@domains, fn domain ->
      config = domain_config(domain, [])
      Keyword.get(config, :enabled, false) and Keyword.get(config, :models, []) != []
    end)
  end

  defp domain_config(domain, opts) do
    :lemon_sim_ui
    |> Application.get_env(:arenas, [])
    |> Keyword.get(domain, [])
    |> Keyword.merge(opts)
  end

  ## Server

  @impl true
  def init(opts) do
    domain = Keyword.fetch!(opts, :domain)
    config = domain_config(domain, opts)

    state = %{
      domain: domain,
      enabled: Keyword.get(config, :enabled, false),
      models: Keyword.get(config, :models, []),
      player_count:
        Keyword.get(config, :player_count, Map.fetch!(@default_player_counts, domain)),
      game_delay_ms: Keyword.get(config, :game_delay_ms, 15_000),
      max_game_records: Keyword.get(config, :max_game_records, 1_000),
      league_dir: Keyword.get(config, :league_dir) || default_league_dir(domain),
      retry_start_ms: Keyword.get(config, :retry_start_ms, @retry_start_ms),
      resume_backoff_ms: Keyword.get(config, :resume_backoff_ms, @resume_backoff_ms),
      deps: build_deps(Keyword.get(config, :deps, %{})),
      current: nil,
      next_game_timer: nil
    }

    if state.enabled and state.models != [] do
      LemonCore.Bus.subscribe(SimManager.lobby_topic())

      Process.send_after(
        self(),
        :ensure_game,
        Keyword.get(config, :start_delay_ms, @start_delay_ms)
      )

      :timer.send_interval(Keyword.get(config, :tick_ms, @tick_ms), :tick)

      Logger.info(
        "[Arena:#{domain}] enabled with #{length(state.models)} models, league at #{state.league_dir}"
      )
    else
      if state.enabled do
        Logger.warning("[Arena:#{domain}] enabled but no models configured; arena stays idle")
      end
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:current_sim_id, _from, state) do
    {:reply, state.current && state.current.sim_id, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      domain: state.domain,
      enabled: state.enabled,
      models: state.models,
      player_count: state.player_count,
      league_dir: state.league_dir,
      current_sim_id: state.current && state.current.sim_id,
      current_status: state.current && state.current.status,
      current_seed: state.current && state.current.plan && state.current.plan.seed
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:ensure_game, state) do
    {:noreply, ensure_game(%{state | next_game_timer: nil})}
  end

  def handle_info(:tick, %{enabled: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    cond do
      state.current == nil and state.next_game_timer == nil ->
        {:noreply, ensure_game(state)}

      state.current != nil and state.current.status == :running and
          state.current.sim_id not in state.deps.list_running.() ->
        {:noreply, handle_disappeared(state)}

      state.current != nil and state.current.status == :mark_pending and
          state.current.sim_id not in state.deps.list_running.() ->
        {:noreply, complete_pending_record_marker(state)}

      state.current != nil and state.current.status == :recorded and
          state.next_game_timer == nil ->
        {:noreply, ensure_game(state)}

      true ->
        {:noreply, snapshot_usage(state)}
    end
  end

  def handle_info(%LemonCore.Event{type: :sim_world_updated, meta: meta} = event, state) do
    sim_id = meta[:sim_id] || meta["sim_id"]

    if state.current != nil and state.current.sim_id == sim_id and
         state.current.status == :running do
      world = world_from_event(event, sim_id, state)

      if world && MapHelpers.get_key(world, :status) == "game_over" do
        {:noreply, finalize_game(state, world)}
      else
        {:noreply, maybe_snapshot_usage(state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, state) do
    cond do
      state.current != nil and state.current.status == :running and
          state.current.sim_id not in state.deps.list_running.() ->
        {:noreply, handle_disappeared(state)}

      state.current != nil and state.current.status == :mark_pending and
          state.current.sim_id not in state.deps.list_running.() ->
        {:noreply, complete_pending_record_marker(state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:resume, sim_id}, state) do
    current = state.current

    cond do
      current == nil or current.sim_id != sim_id or current.status != :resuming ->
        {:noreply, state}

      true ->
        case state.deps.resume_sim.(sim_id) do
          {:ok, _} ->
            Logger.info(
              "[Arena:#{state.domain}] resumed #{sim_id} (attempt #{current.resume_attempts})"
            )

            {:noreply, put_in(state.current.status, :running)}

          {:error, :already_running} ->
            {:noreply, put_in(state.current.status, :running)}

          {:error, :game_over} ->
            case state.deps.get_state.(sim_id) do
              %{world: world} -> {:noreply, finalize_game(state, world)}
              _ -> {:noreply, abandon_game(state, :missing_final_state)}
            end

          {:error, {:not_resumable, reason}} ->
            {:noreply, abandon_game(state, {:not_resumable, reason})}

          {:error, :turn_budget_exhausted} ->
            {:noreply, abandon_game(state, :turn_budget_exhausted)}

          {:error, reason} ->
            retry_or_abandon(state, {:resume_failed, reason})
        end
    end
  end

  def handle_info({:retry_abandon, sim_id, reason}, state) do
    if state.current != nil and state.current.sim_id == sim_id and
         state.current.status == :abandoning do
      {:noreply, abandon_game(state, reason)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:retry_record, sim_id}, state) do
    if state.current != nil and state.current.sim_id == sim_id and
         state.current.status == :record_pending do
      {:noreply, finalize_game(state, state.current.record_world)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:retry_existing_record, sim_id}, state) do
    if state.current != nil and state.current.sim_id == sim_id and
         state.current.status == :reconcile_pending do
      {:noreply, reconcile_or_record(state, state.current.record_world)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:retry_record_marker, sim_id}, state) do
    current = state.current

    if current && current.sim_id == sim_id && current.status == :mark_pending do
      {:noreply, complete_pending_record_marker(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Game lifecycle

  defp ensure_game(%{enabled: false} = state), do: state
  defp ensure_game(%{models: []} = state), do: state

  defp ensure_game(state) do
    prefix = sim_prefix(state.domain)

    cond do
      state.current != nil and
          state.current.status in [
            :running,
            :resuming,
            :record_pending,
            :reconcile_pending,
            :mark_pending,
            :abandoning
          ] ->
        state

      true ->
        case next_unrecorded_terminal(state, prefix) do
          nil ->
            case Enum.find(state.deps.list_running.(), fn sim_id ->
                   String.starts_with?(sim_id, prefix) and
                     arena_owned?(state.deps.get_state.(sim_id), state.domain)
                 end) do
              nil -> start_new_game(state)
              running_sim -> adopt_game(state, running_sim)
            end

          stored_state ->
            reconcile_terminal_game(state, stored_state)
        end
    end
  end

  defp next_unrecorded_terminal(state, prefix) do
    state.deps.list_states.()
    |> Enum.filter(fn
      %State{sim_id: sim_id, world: world} = stored_state ->
        String.starts_with?(sim_id, prefix) and
          arena_owned?(stored_state, state.domain) and
          MapHelpers.get_key(world, :status) == "game_over" and
          not league_recorded?(stored_state, state.domain)

      _ ->
        false
    end)
    |> Enum.sort_by(fn stored_state ->
      run = persisted_run(stored_state)
      MapHelpers.get_key(run, :finished_at_ms) || MapHelpers.get_key(run, :started_at_ms) || 0
    end)
    |> List.first()
  end

  defp reconcile_terminal_game(state, stored_state) do
    run = persisted_run(stored_state)
    seed = MapHelpers.get_key(run, :seed)
    start_opts = MapHelpers.get_key(run, :start_opts) || %{}
    rotation_index = MapHelpers.get_key(start_opts, :role_rotation_index)
    started_at_ms = MapHelpers.get_key(run, :started_at_ms)

    plan =
      if is_integer(seed), do: %{seed: seed, rotation_index: rotation_index}, else: nil

    Logger.warning(
      "[Arena:#{state.domain}] reconciling unrecorded terminal game #{stored_state.sim_id}"
    )

    current =
      stored_state.sim_id
      |> new_current(plan, started_at_ms)
      |> Map.put(:reconciling, true)

    reconcile_or_record(%{state | current: current}, stored_state.world)
  end

  defp reconcile_or_record(state, world) do
    current = state.current

    case state.deps.reconcile_record.(state.league_dir, current.sim_id) do
      {:ok, record, league} ->
        Logger.warning(
          "[Arena:#{state.domain}] recovered existing league record for #{current.sim_id}"
        )

        state
        |> Map.put(
          :current,
          Map.merge(current, %{
            status: :mark_pending,
            record: record,
            record_league: league
          })
        )
        |> complete_pending_record_marker()

      :missing ->
        finalize_game(state, world)

      {:error, reason} ->
        Logger.error(
          "[Arena:#{state.domain}] failed to reconcile existing record for #{current.sim_id}: #{inspect(reason)}"
        )

        Process.send_after(
          self(),
          {:retry_existing_record, current.sim_id},
          state.retry_start_ms
        )

        %{state | current: Map.merge(current, %{status: :reconcile_pending, record_world: world})}
    end
  end

  defp start_new_game(state) do
    games = League.load_games(state.league_dir)

    rotation_index =
      games
      |> Enum.map(& &1["rotation_index"])
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> length(games) - 1 end)
      |> Kernel.+(1)

    plan_opts =
      [player_count: state.player_count]
      |> then(fn opts ->
        if state.domain == :werewolf,
          do: Keyword.put(opts, :rotation_index, rotation_index),
          else: opts
      end)

    plan = League.plan_match(state.models, plan_opts)

    start_opts = [
      model_specs: plan.model_specs,
      player_count: plan.player_count,
      seed: plan.seed,
      arena_domain: to_string(state.domain),
      balanced_roles?: state.domain == :werewolf,
      role_rotation_index: rotation_index
    ]

    case state.deps.start_sim.(state.domain, start_opts) do
      {:ok, sim_id} ->
        LemonSim.Kernel.Bus.subscribe(sim_id)

        Logger.info(
          "[Arena:#{state.domain}] started #{sim_id} seed=#{plan.seed} " <>
            "models=#{Enum.join(plan.model_specs, ",")}"
        )

        %{state | current: new_current(sim_id, plan)}

      {:error, reason} ->
        Logger.error("[Arena:#{state.domain}] failed to start game: #{inspect(reason)}; retrying")
        schedule_next_game(state, state.retry_start_ms)
    end
  end

  defp adopt_game(state, sim_id) do
    LemonSim.Kernel.Bus.subscribe(sim_id)
    Logger.info("[Arena:#{state.domain}] adopted already-running #{sim_id}")

    run =
      case state.deps.get_state.(sim_id) do
        %{meta: meta} -> MapHelpers.get_key(meta, :run) || %{}
        _ -> %{}
      end

    seed = MapHelpers.get_key(run, :seed)
    start_opts = MapHelpers.get_key(run, :start_opts) || %{}
    rotation_index = MapHelpers.get_key(start_opts, :role_rotation_index)
    started_at_ms = MapHelpers.get_key(run, :started_at_ms)

    plan =
      if is_integer(seed), do: %{seed: seed, rotation_index: rotation_index}, else: nil

    %{state | current: new_current(sim_id, plan, started_at_ms)}
  end

  defp new_current(sim_id, plan, started_at_ms \\ nil) do
    %{
      sim_id: sim_id,
      plan: plan,
      started_at_ms:
        if(is_integer(started_at_ms),
          do: started_at_ms,
          else: System.system_time(:millisecond)
        ),
      usage: nil,
      updates_seen: 0,
      resume_attempts: 0,
      reconciling: false,
      status: :running
    }
  end

  defp handle_disappeared(state) do
    sim_id = state.current.sim_id

    case state.deps.get_state.(sim_id) do
      %{world: world} = stored_state ->
        cond do
          MapHelpers.get_key(world, :status) == "game_over" ->
            finalize_game(state, world)

          persisted_run_resumable?(stored_state) ->
            begin_resume(state, :runner_exited)

          true ->
            abandon_game(state, {:not_resumable, persisted_run_status(stored_state)})
        end

      _ ->
        abandon_game(state, :state_lost)
    end
  end

  defp begin_resume(state, reason) do
    attempts = state.current.resume_attempts + 1

    if attempts > @max_resume_attempts do
      abandon_game(state, {:resume_exhausted, reason})
    else
      delay = state.resume_backoff_ms * attempts

      Logger.warning(
        "[Arena:#{state.domain}] #{state.current.sim_id} died mid-game (#{inspect(reason)}); " <>
          "resume attempt #{attempts}/#{@max_resume_attempts} in #{delay}ms"
      )

      Process.send_after(self(), {:resume, state.current.sim_id}, delay)
      %{state | current: %{state.current | status: :resuming, resume_attempts: attempts}}
    end
  end

  defp persisted_run_resumable?(state) do
    run = state |> Map.get(:meta, %{}) |> MapHelpers.get_key(:run) || %{}
    Map.get(run, :resumable, Map.get(run, "resumable", true)) != false
  end

  defp persisted_run_status(state) do
    state
    |> Map.get(:meta, %{})
    |> MapHelpers.get_key(:run)
    |> Kernel.||(%{})
    |> MapHelpers.get_key(:status)
    |> Kernel.||("unknown")
  end

  defp retry_or_abandon(state, reason) do
    if state.current.resume_attempts >= @max_resume_attempts do
      {:noreply, abandon_game(state, reason)}
    else
      {:noreply, begin_resume(%{state | current: %{state.current | status: :running}}, reason)}
    end
  end

  defp abandon_game(state, reason) do
    Logger.error("[Arena:#{state.domain}] abandoning #{state.current.sim_id}: #{inspect(reason)}")

    case state.deps.abandon_sim.(state.current.sim_id, reason) do
      result when result in [:ok, {:error, :not_found}] ->
        LemonSim.Kernel.Bus.unsubscribe(state.current.sim_id)
        schedule_next_game(%{state | current: nil}, state.retry_start_ms)

      {:error, persist_reason} ->
        Logger.error(
          "[Arena:#{state.domain}] failed to persist abandonment: #{inspect(persist_reason)}"
        )

        Process.send_after(
          self(),
          {:retry_abandon, state.current.sim_id, reason},
          state.retry_start_ms
        )

        put_in(state.current.status, :abandoning)
    end
  end

  defp finalize_game(state, world) do
    current = state.current
    usage = state.deps.usage.(current.sim_id) || current.usage

    record =
      League.game_record(league_adapter!(state.domain), world,
        game_id: current.sim_id,
        recorded_at: recorded_at(state, current.sim_id),
        seed: current.plan && current.plan.seed,
        rotation_index: current.plan && current.plan.rotation_index,
        duration_ms: game_duration_ms(state, current),
        usage: usage
      )

    case state.deps.record_game.(state.league_dir, record, state.max_game_records) do
      {:ok, league} ->
        state
        |> Map.put(
          :current,
          Map.merge(current, %{
            status: :mark_pending,
            record: record,
            record_league: league
          })
        )
        |> complete_pending_record_marker()

      {:error, reason} ->
        Logger.error(
          "[Arena:#{state.domain}] failed to record #{current.sim_id}: #{inspect(reason)}"
        )

        Process.send_after(self(), {:retry_record, current.sim_id}, state.retry_start_ms)

        %{state | current: Map.merge(current, %{status: :record_pending, record_world: world})}
    end
  end

  defp complete_pending_record_marker(state) do
    current = state.current

    case persist_record_marker(state, current.sim_id) do
      :ok ->
        complete_recording(state, current.record, current.record_league)

      {:error, :runner_still_running} ->
        Process.send_after(
          self(),
          {:retry_record_marker, current.sim_id},
          state.retry_start_ms
        )

        state

      {:error, reason} ->
        Logger.error(
          "[Arena:#{state.domain}] failed to persist league marker for #{current.sim_id}: #{inspect(reason)}"
        )

        Process.send_after(
          self(),
          {:retry_record_marker, current.sim_id},
          state.retry_start_ms
        )

        state
    end
  end

  defp complete_recording(state, record, league) do
    current = state.current

    Logger.info(
      "[Arena:#{state.domain}] recorded #{current.sim_id}: winner=#{record["winner"]} " <>
        "rounds=#{record["rounds"]} games=#{league["game_count"]}"
    )

    LemonCore.Bus.broadcast(
      league_topic(state.domain),
      LemonCore.Event.new(
        :arena_league_updated,
        %{game_id: current.sim_id},
        %{domain: state.domain}
      )
    )

    LemonSim.Kernel.Bus.unsubscribe(current.sim_id)

    delay = if current.reconciling, do: 0, else: state.game_delay_ms

    recorded_current =
      current
      |> Map.drop([:record_world, :record, :record_league])
      |> Map.put(:status, :recorded)

    state
    |> Map.put(:current, recorded_current)
    |> schedule_next_game(delay)
  end

  defp persist_record_marker(state, sim_id) do
    if sim_id in state.deps.list_running.() do
      {:error, :runner_still_running}
    else
      case state.deps.get_state.(sim_id) do
        %State{} = stored_state ->
          if league_recorded?(stored_state, state.domain) do
            :ok
          else
            run =
              stored_state
              |> persisted_run()
              |> Map.merge(%{
                arena_league_recorded_domain: to_string(state.domain),
                arena_league_recorded_at_ms: System.system_time(:millisecond)
              })

            marked_state = %{
              stored_state
              | meta: Map.put(stored_state.meta || %{}, :run, run),
                version: stored_state.version + 1
            }

            state.deps.put_state.(marked_state)
          end

        nil ->
          :ok

        _ ->
          {:error, :invalid_persisted_state}
      end
    end
  end

  defp league_recorded?(stored_state, domain) do
    MapHelpers.get_key(persisted_run(stored_state), :arena_league_recorded_domain) ==
      to_string(domain)
  end

  defp arena_owned?(stored_state, domain) do
    MapHelpers.get_key(persisted_run(stored_state), :arena_domain) == to_string(domain)
  end

  defp recorded_at(state, sim_id) do
    with %State{} = stored_state <- state.deps.get_state.(sim_id),
         finished_at_ms when is_integer(finished_at_ms) <-
           MapHelpers.get_key(persisted_run(stored_state), :finished_at_ms),
         {:ok, timestamp} <- DateTime.from_unix(finished_at_ms, :millisecond) do
      timestamp |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    else
      _ -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  defp game_duration_ms(state, current) do
    finished_at_ms =
      with %State{} = stored_state <- state.deps.get_state.(current.sim_id) do
        MapHelpers.get_key(persisted_run(stored_state), :finished_at_ms)
      end

    end_time =
      if is_integer(finished_at_ms),
        do: finished_at_ms,
        else: System.system_time(:millisecond)

    max(end_time - current.started_at_ms, 0)
  end

  defp persisted_run(%{meta: meta}) do
    meta |> Kernel.||(%{}) |> MapHelpers.get_key(:run) |> Kernel.||(%{})
  end

  defp persisted_run(_), do: %{}

  defp league_adapter!(domain) do
    case LemonSim.Bench.League.Registry.fetch(domain) do
      {:ok, adapter} -> adapter
      :error -> raise ArgumentError, "no league adapter registered for #{domain}"
    end
  end

  defp safe_record_game(league_dir, record, max_game_records) do
    {:ok, elem(League.record_game!(league_dir, record, max_game_records: max_game_records), 1)}
  rescue
    error -> {:error, error}
  end

  defp safe_reconcile_record(league_dir, sim_id) do
    case Enum.find(League.load_games(league_dir), &(&1["game_id"] == sim_id)) do
      nil ->
        :missing

      record ->
        {:ok, league} = League.recompute!(league_dir)
        {:ok, record, league}
    end
  rescue
    error -> {:error, error}
  end

  defp schedule_next_game(%{next_game_timer: timer} = state, delay_ms) do
    if timer, do: Process.cancel_timer(timer)
    %{state | next_game_timer: Process.send_after(self(), :ensure_game, delay_ms)}
  end

  ## Usage snapshots

  defp maybe_snapshot_usage(state) do
    updates_seen = state.current.updates_seen + 1
    state = put_in(state.current.updates_seen, updates_seen)

    if rem(updates_seen, @usage_snapshot_every) == 0 do
      snapshot_usage(state)
    else
      state
    end
  end

  defp snapshot_usage(%{current: nil} = state), do: state

  defp snapshot_usage(state) do
    case state.deps.usage.(state.current.sim_id) do
      usage when is_map(usage) -> put_in(state.current.usage, usage)
      _ -> state
    end
  end

  ## Helpers

  defp world_from_event(%LemonCore.Event{payload: payload}, sim_id, state) do
    case payload do
      %{state: %{world: world}} -> world
      %{"state" => %{"world" => world}} -> world
      _ -> fetch_world(sim_id, state)
    end
  end

  defp fetch_world(sim_id, state) do
    case state.deps.get_state.(sim_id) do
      %{world: world} -> world
      _ -> nil
    end
  end

  defp build_deps(overrides) do
    Map.merge(
      %{
        start_sim: &SimManager.start_sim/2,
        resume_sim: &SimManager.resume_sim/1,
        abandon_sim: &SimManager.abandon_sim/2,
        usage: &SimManager.usage/1,
        list_running: &SimManager.list_running/0,
        get_state: &LemonSim.Kernel.Store.get_state/1,
        list_states: &LemonSim.Kernel.Store.list_states/0,
        put_state: &LemonSim.Kernel.Store.put_state/1,
        record_game: &safe_record_game/3,
        reconcile_record: &safe_reconcile_record/2
      },
      overrides
    )
  end

  defp default_league_dir(domain) do
    Path.join(:code.priv_dir(:lemon_sim), "game_logs/#{domain}_league")
  end
end
