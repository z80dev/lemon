defmodule LemonSimUi.SimManager do
  @moduledoc """
  GenServer managing running simulation processes.

  Bridges the UI with LemonSim.Runner by spawning tasks under a
  DynamicSupervisor and providing start/stop/list operations.
  """

  use GenServer

  alias LemonCore.MapHelpers
  alias LemonSim.{Runner, State, Store}
  alias LemonSim.Examples.{TicTacToe, Skirmish}

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

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{runners: %{}, human_players: %{}}}
  end

  @impl true
  def handle_call({:start_sim, domain, opts}, _from, state) do
    sim_id = Keyword.get(opts, :sim_id, generate_id(domain))
    human_player = Keyword.get(opts, :human_player)

    case build_initial_state(domain, sim_id, opts) do
      {:ok, initial_state, modules, run_opts} ->
        :ok = Store.put_state(initial_state)
        broadcast_lobby()

        task_ref = start_runner(initial_state, modules, run_opts, human_player)

        runners = Map.put(state.runners, sim_id, %{ref: task_ref, domain: domain})

        human_players =
          if human_player do
            Map.put(state.human_players, sim_id, human_player)
          else
            state.human_players
          end

        {:reply, {:ok, sim_id}, %{state | runners: runners, human_players: human_players}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {sim_id, _} =
      Enum.find(state.runners, {nil, nil}, fn {_id, %{ref: ref}} -> ref == pid end)

    if sim_id do
      runners = Map.delete(state.runners, sim_id)
      human_players = Map.delete(state.human_players, sim_id)
      broadcast_lobby()
      {:noreply, %{state | runners: runners, human_players: human_players}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private helpers ---

  defp build_initial_state(:tic_tac_toe, sim_id, opts) do
    max_turns = Keyword.get(opts, :max_turns, 20)

    initial_state = %{TicTacToe.initial_state() | sim_id: sim_id}
    modules = TicTacToe.modules()

    run_opts =
      TicTacToe.default_opts(opts)
      |> Keyword.put(:driver_max_turns, max_turns)
      |> Keyword.put(:persist?, true)
      |> Keyword.put(:on_before_step, nil)
      |> Keyword.put(:on_after_step, &on_after_step/2)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(:skirmish, sim_id, opts) do
    max_turns = Keyword.get(opts, :max_turns, 24)
    rng_seed = Keyword.get(opts, :rng_seed, :rand.uniform(1000))

    initial_state = %{Skirmish.initial_state() | sim_id: sim_id}
    initial_state = State.put_world(initial_state, %{rng_seed: rng_seed})

    modules = Skirmish.modules()

    run_opts =
      Skirmish.default_opts(opts)
      |> Keyword.put(:driver_max_turns, max_turns)
      |> Keyword.put(:persist?, true)
      |> Keyword.put(:on_before_step, nil)
      |> Keyword.put(:on_after_step, &on_after_step/2)

    {:ok, initial_state, modules, run_opts}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp build_initial_state(domain, _sim_id, _opts) do
    {:error, {:unknown_domain, domain}}
  end

  defp start_runner(initial_state, modules, run_opts, human_player) do
    manager_pid = self()

    pid =
      spawn_link(fn ->
        Process.monitor(manager_pid)

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
    do_ai_loop(state, modules, opts, terminal?, max_turns, 0)
  end

  defp do_ai_loop(state, _modules, _opts, _terminal?, max_turns, turn)
       when turn >= max_turns do
    Store.put_state(state)
    broadcast_update(state.sim_id)
  end

  defp do_ai_loop(state, modules, opts, terminal?, max_turns, turn) do
    if terminal?.(state) do
      Store.put_state(state)
      broadcast_update(state.sim_id)
    else
      case Runner.step(state, modules, opts) do
        {:ok, result} ->
          Store.put_state(result.state)
          broadcast_update(result.state.sim_id)
          Process.sleep(500)
          do_ai_loop(result.state, modules, opts, terminal?, max_turns, turn + 1)

        {:error, _reason} ->
          Store.put_state(state)
          broadcast_update(state.sim_id)
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
    broadcast_update(state.sim_id)
  end

  defp do_interactive_loop(state, modules, opts, terminal?, max_turns, turn, human_team) do
    if terminal?.(state) do
      Store.put_state(state)
      broadcast_update(state.sim_id)
    else
      if is_human_turn?(state, human_team) do
        # Wait for human move
        broadcast_update(state.sim_id)

        receive do
          {:human_move, event} ->
            updater = Map.get(modules, :updater)

            case Runner.ingest_events(state, [event], updater, opts) do
              {:ok, next_state, _signal} ->
                Store.put_state(next_state)
                broadcast_update(next_state.sim_id)

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
            broadcast_update(state.sim_id)
        end
      else
        case Runner.step(state, modules, opts) do
          {:ok, result} ->
            Store.put_state(result.state)
            broadcast_update(result.state.sim_id)
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

          {:error, _reason} ->
            Store.put_state(state)
            broadcast_update(state.sim_id)
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
    broadcast_update(next_state.sim_id)
  end

  defp on_after_step(_turn, _result), do: :ok

  defp broadcast_update(sim_id) do
    LemonSim.Bus.broadcast_world_update(sim_id, %{})
    broadcast_lobby()
  end

  defp broadcast_lobby do
    event = LemonCore.Event.new(:sim_lobby_changed, %{})
    LemonCore.Bus.broadcast(@lobby_topic, event)
  end

  defp generate_id(:tic_tac_toe), do: "ttt_#{random_hex(4)}"
  defp generate_id(:skirmish), do: "skm_#{random_hex(4)}"
  defp generate_id(_), do: "sim_#{random_hex(4)}"

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end
end
