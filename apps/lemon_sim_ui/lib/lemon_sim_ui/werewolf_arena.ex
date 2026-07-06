defmodule LemonSimUi.WerewolfArena do
  @moduledoc """
  Always-on Werewolf arena: keeps one league game running at all times and
  records every finished game into the persistent league standings.

  Each game samples a randomized model lineup from the configured pool
  (`LemonSim.Examples.Werewolf.League.plan_match/2`), so which model plays
  which role varies game to game while staying reproducible per recorded seed.

  The arena is resilient by construction:

    * finished games (world status `game_over`) are recorded into the league
      and a fresh game starts after a short intermission;
    * games that die mid-flight (runner crash, step-retry exhaustion) are
      resumed via `SimManager.resume_sim/1` with backoff, then abandoned and
      replaced after `#{3}` failed attempts;
    * a watchdog tick re-checks the world every minute, so a missed PubSub
      message can never permanently stall the arena;
    * if this process itself restarts, it adopts any werewolf game that is
      still running instead of double-starting.

  Configuration lives under `config :lemon_sim_ui, :werewolf_arena` —
  `enabled`, `models` (list of `provider:model` specs), `player_count`,
  `game_delay_ms`, and `league_dir`. Runtime env wiring: `WEREWOLF_ARENA_*`
  plus `WEREWOLF_LEAGUE_DIR` (see `config/runtime.exs`).
  """

  use GenServer

  require Logger

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.Werewolf.League
  alias LemonSimUi.SimManager

  @league_topic "werewolf:league"
  @start_delay_ms 3_000
  @tick_ms 60_000
  @retry_start_ms 30_000
  @resume_backoff_ms 5_000
  @max_resume_attempts 3
  @usage_snapshot_every 8

  ## Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "PubSub topic that receives `:werewolf_league_updated` events."
  @spec league_topic() :: String.t()
  def league_topic, do: @league_topic

  @doc "Returns the sim id of the game currently on air, or nil."
  @spec current_sim_id(GenServer.server()) :: String.t() | nil
  def current_sim_id(server \\ __MODULE__) do
    GenServer.call(server, :current_sim_id)
  catch
    :exit, _ -> nil
  end

  @doc "Operational status snapshot (enabled flag, current game, league dir)."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{enabled: false, error: :unavailable}
  end

  @doc "League directory currently in use (readable without the server)."
  @spec league_dir() :: String.t()
  def league_dir do
    config = Application.get_env(:lemon_sim_ui, :werewolf_arena, [])
    Keyword.get(config, :league_dir) || default_league_dir()
  end

  ## Server

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:lemon_sim_ui, :werewolf_arena, []), opts)

    state = %{
      enabled: Keyword.get(config, :enabled, false),
      models: Keyword.get(config, :models, []),
      player_count: Keyword.get(config, :player_count, 6),
      game_delay_ms: Keyword.get(config, :game_delay_ms, 15_000),
      league_dir: Keyword.get(config, :league_dir) || default_league_dir(),
      retry_start_ms: Keyword.get(config, :retry_start_ms, @retry_start_ms),
      resume_backoff_ms: Keyword.get(config, :resume_backoff_ms, @resume_backoff_ms),
      deps: build_deps(Keyword.get(config, :deps, %{})),
      current: nil,
      next_game_timer: nil
    }

    if state.enabled and state.models != [] do
      LemonCore.Bus.subscribe(SimManager.lobby_topic())
      Process.send_after(self(), :ensure_game, Keyword.get(config, :start_delay_ms, @start_delay_ms))
      :timer.send_interval(Keyword.get(config, :tick_ms, @tick_ms), :tick)
      Logger.info("[WerewolfArena] enabled with #{length(state.models)} models, league at #{state.league_dir}")
    else
      if state.enabled do
        Logger.warning("[WerewolfArena] enabled but no models configured; arena stays idle")
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

      state.current != nil and state.current.status == :recorded and
          state.next_game_timer == nil ->
        {:noreply, ensure_game(state)}

      true ->
        {:noreply, snapshot_usage(state)}
    end
  end

  def handle_info(%LemonCore.Event{type: :sim_world_updated, meta: meta} = event, state) do
    sim_id = meta[:sim_id] || meta["sim_id"]

    if state.current && state.current.sim_id == sim_id and state.current.status == :running do
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
    if state.current && state.current.status == :running and
         state.current.sim_id not in state.deps.list_running.() do
      {:noreply, handle_disappeared(state)}
    else
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
            Logger.info("[WerewolfArena] resumed #{sim_id} (attempt #{current.resume_attempts})")
            {:noreply, put_in(state.current.status, :running)}

          {:error, :game_over} ->
            case state.deps.get_state.(sim_id) do
              %{world: world} -> {:noreply, finalize_game(state, world)}
              _ -> {:noreply, abandon_game(state, :missing_final_state)}
            end

          {:error, reason} ->
            retry_or_abandon(state, {:resume_failed, reason})
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Game lifecycle

  defp ensure_game(%{enabled: false} = state), do: state
  defp ensure_game(%{models: []} = state), do: state

  defp ensure_game(state) do
    running_werewolf =
      state.deps.list_running.()
      |> Enum.find(&String.starts_with?(&1, "ww_"))

    cond do
      state.current != nil and state.current.status in [:running, :resuming] ->
        state

      running_werewolf != nil ->
        adopt_game(state, running_werewolf)

      true ->
        start_new_game(state)
    end
  end

  defp start_new_game(state) do
    plan = League.plan_match(state.models, player_count: state.player_count)

    start_opts = [
      model_specs: plan.model_specs,
      player_count: plan.player_count,
      seed: plan.seed
    ]

    case state.deps.start_sim.(:werewolf, start_opts) do
      {:ok, sim_id} ->
        LemonSim.Kernel.Bus.subscribe(sim_id)

        Logger.info(
          "[WerewolfArena] started #{sim_id} seed=#{plan.seed} models=#{Enum.join(plan.model_specs, ",")}"
        )

        %{state | current: new_current(sim_id, plan)}

      {:error, reason} ->
        Logger.error("[WerewolfArena] failed to start game: #{inspect(reason)}; retrying")
        schedule_next_game(state, state.retry_start_ms)
    end
  end

  defp adopt_game(state, sim_id) do
    LemonSim.Kernel.Bus.subscribe(sim_id)
    Logger.info("[WerewolfArena] adopted already-running #{sim_id}")
    %{state | current: new_current(sim_id, nil)}
  end

  defp new_current(sim_id, plan) do
    %{
      sim_id: sim_id,
      plan: plan,
      started_at_ms: System.monotonic_time(:millisecond),
      usage: nil,
      updates_seen: 0,
      resume_attempts: 0,
      status: :running
    }
  end

  defp handle_disappeared(state) do
    sim_id = state.current.sim_id

    case state.deps.get_state.(sim_id) do
      %{world: world} = _stored ->
        if MapHelpers.get_key(world, :status) == "game_over" do
          finalize_game(state, world)
        else
          begin_resume(state, :runner_exited)
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
        "[WerewolfArena] #{state.current.sim_id} died mid-game (#{inspect(reason)}); " <>
          "resume attempt #{attempts}/#{@max_resume_attempts} in #{delay}ms"
      )

      Process.send_after(self(), {:resume, state.current.sim_id}, delay)
      %{state | current: %{state.current | status: :resuming, resume_attempts: attempts}}
    end
  end

  defp retry_or_abandon(state, reason) do
    if state.current.resume_attempts >= @max_resume_attempts do
      {:noreply, abandon_game(state, reason)}
    else
      {:noreply, begin_resume(%{state | current: %{state.current | status: :running}}, reason)}
    end
  end

  defp abandon_game(state, reason) do
    Logger.error("[WerewolfArena] abandoning #{state.current.sim_id}: #{inspect(reason)}")
    LemonSim.Kernel.Bus.unsubscribe(state.current.sim_id)
    schedule_next_game(%{state | current: nil}, state.retry_start_ms)
  end

  defp finalize_game(state, world) do
    current = state.current
    usage = state.deps.usage.(current.sim_id) || current.usage

    record =
      League.game_record(world,
        game_id: current.sim_id,
        recorded_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        seed: current.plan && current.plan.seed,
        duration_ms: System.monotonic_time(:millisecond) - current.started_at_ms,
        usage: usage
      )

    case safe_record_game(state.league_dir, record) do
      {:ok, league} ->
        Logger.info(
          "[WerewolfArena] recorded #{current.sim_id}: winner=#{record["winner"]} " <>
            "days=#{record["day_count"]} games=#{league["game_count"]}"
        )

        LemonCore.Bus.broadcast(
          @league_topic,
          LemonCore.Event.new(:werewolf_league_updated, %{game_id: current.sim_id}, %{})
        )

      {:error, reason} ->
        Logger.error("[WerewolfArena] failed to record #{current.sim_id}: #{inspect(reason)}")
    end

    LemonSim.Kernel.Bus.unsubscribe(current.sim_id)

    state
    |> Map.put(:current, %{current | status: :recorded})
    |> schedule_next_game(state.game_delay_ms)
  end

  defp safe_record_game(league_dir, record) do
    {:ok, elem(League.record_game!(league_dir, record), 1)}
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
        usage: &SimManager.usage/1,
        list_running: &SimManager.list_running/0,
        get_state: &LemonSim.Kernel.Store.get_state/1
      },
      overrides
    )
  end

  defp default_league_dir do
    Path.join(:code.priv_dir(:lemon_sim), "game_logs/werewolf_league")
  end
end
