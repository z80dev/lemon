defmodule LemonSimUi.SimDashboardLive do
  @moduledoc """
  LiveView dashboard for monitoring and controlling LemonSim simulations.

  Shows a sidebar listing all known simulations with their domain type and
  live/stopped status. Selecting a sim renders the appropriate game board
  (TicTacToe, Skirmish, Werewolf, StockMarket, Survivor, SpaceStation,
  Auction, Diplomacy, DungeonCrawl, Courtroom, StartupIncubator,
  IntelNetwork, Legislature, Pandemic, MurderMystery, or SupplyChain) alongside an event log, agent
  strategy history, and a memory/data-bank viewer.

  Also provides a "New Sim" form for launching simulations with configurable
  domains, player counts, model assignments, and optional human participation.
  Real-time updates are delivered via `LemonCore.Bus` pub/sub.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{SimHelpers, SimManager, WerewolfPlayback}
  alias LemonSim.{Store, Bus}
  alias LemonSim.Examples.Skirmish

  alias LemonSimUi.Live.Components.{
    TicTacToeBoard,
    SkirmishBoard,
    WerewolfBoard,
    StockMarketBoard,
    SurvivorBoard,
    SpaceStationBoard,
    AuctionBoard,
    DiplomacyBoard,
    DungeonCrawlBoard,
    CourtroomBoard,
    StartupIncubatorBoard,
    IntelNetworkBoard,
    LegislatureBoard,
    PandemicBoard,
    MurderMysteryBoard,
    SupplyChainBoard,
    VendingBenchBoard,
    EventLog,
    PlanHistory,
    MemoryViewer
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      LemonCore.Bus.subscribe(SimManager.lobby_topic())
    end

    sims = build_sim_list()
    running = SimManager.list_running()

    {:ok,
     assign(socket,
       sims: sims,
       running: running,
       selected_sim: nil,
       subscribed_sim_id: nil,
       playback: nil,
       playback_timer_ref: nil,
       domain_type: nil,
       show_new_sim_form: false,
       new_sim_domain: "tic_tac_toe",
       new_player_count: 6,
       human_player: nil,
       page_title: "LemonSim"
     )}
  end

  @impl true
  def handle_params(%{"sim_id" => sim_id}, _uri, socket) do
    # Unsubscribe from previous sim
    if socket.assigns[:subscribed_sim_id] do
      Bus.unsubscribe(socket.assigns.subscribed_sim_id)
    end

    state = get_state_with_retry(sim_id, 5)

    case state do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Sim not found: #{sim_id}")
         |> push_patch(to: ~p"/")}

      state ->
        if connected?(socket), do: Bus.subscribe(sim_id)
        domain_type = SimHelpers.infer_domain_type(state)

        {:noreply,
         assign(socket,
           selected_sim: state,
           subscribed_sim_id: sim_id,
           playback: if(domain_type == :werewolf, do: WerewolfPlayback.new(state), else: nil),
           playback_timer_ref: nil,
           domain_type: domain_type,
           page_title: "#{sim_id} - LemonSim"
         )}
    end
  end

  def handle_params(_params, _uri, socket) do
    if socket.assigns[:subscribed_sim_id] do
      Bus.unsubscribe(socket.assigns.subscribed_sim_id)
    end

    {:noreply,
     assign(socket,
       selected_sim: nil,
       subscribed_sim_id: nil,
       playback: nil,
       playback_timer_ref: nil,
       domain_type: nil,
       page_title: "LemonSim"
     )}
  end

  @impl true
  def handle_event("select_sim", %{"sim_id" => sim_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/sims/#{sim_id}")}
  end

  def handle_event("go_home", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/")}
  end

  def handle_event("toggle_new_sim_form", _params, socket) do
    {:noreply, assign(socket, show_new_sim_form: !socket.assigns.show_new_sim_form)}
  end

  def handle_event("change_domain", params, socket) do
    domain = params["domain"] || socket.assigns.new_sim_domain
    min_p = min_players(domain)
    max_p = max_players(domain)

    player_count =
      if params["domain"] && params["domain"] != socket.assigns.new_sim_domain do
        # Domain changed — reset to default for new domain
        default_player_count(String.to_existing_atom(domain))
      else
        parse_int(params["player_count"], socket.assigns.new_player_count)
        |> max(min_p)
        |> min(max_p)
      end

    {:noreply, assign(socket, new_sim_domain: domain, new_player_count: player_count)}
  end

  def handle_event("start_sim", params, socket) do
    domain = String.to_existing_atom(params["domain"] || "tic_tac_toe")

    opts =
      case domain do
        :tic_tac_toe ->
          [
            max_turns: parse_int(params["max_turns"], 20),
            human_player: parse_human_player(params["human_player"])
          ]
          |> maybe_put_sim_id(params["sim_id"])

        :skirmish ->
          squad = parse_squad(params["squad"])

          [
            max_turns: parse_int(params["max_turns"], 48),
            rng_seed: parse_int(params["rng_seed"], :rand.uniform(1000)),
            map_width: parse_int(params["map_width"], 10),
            map_height: parse_int(params["map_height"], 10),
            map_preset: parse_map_preset(params["map_preset"]),
            squad: squad,
            human_player: parse_human_player(params["human_player"])
          ]
          |> maybe_put_sim_id(params["sim_id"])

        :werewolf ->
          player_count = parse_int(params["player_count"], 6)

          model_specs =
            for seat <- 1..player_count do
              params["model_#{seat}"] || default_model_for_seat(seat)
            end

          [
            player_count: player_count,
            model_specs: model_specs
          ]
          |> maybe_put_sim_id(params["sim_id"])

        domain when domain in [:stock_market, :survivor, :space_station] ->
          player_count = parse_int(params["player_count"], default_player_count(domain))

          model_specs =
            for seat <- 1..player_count do
              params["model_#{seat}"] || default_model_for_seat(seat)
            end

          [
            player_count: player_count,
            model_specs: model_specs
          ]
          |> maybe_put_sim_id(params["sim_id"])

        domain
        when domain in [
               :auction,
               :diplomacy,
               :courtroom,
               :startup_incubator,
               :intel_network,
               :legislature,
               :pandemic,
               :murder_mystery,
               :supply_chain,
               :vending_bench
             ] ->
          player_count = parse_int(params["player_count"], default_player_count(domain))

          [
            player_count: player_count
          ]
          |> maybe_put_sim_id(params["sim_id"])

        :dungeon_crawl ->
          party_size = parse_int(params["party_size"], 4)

          [
            party_size: party_size
          ]
          |> maybe_put_sim_id(params["sim_id"])

        _ ->
          maybe_put_sim_id([], params["sim_id"])
      end

    try do
      case SimManager.start_sim(domain, opts) do
        {:ok, sim_id} ->
          {:noreply,
           socket
           |> assign(show_new_sim_form: false, human_player: opts[:human_player])
           |> push_patch(to: ~p"/sims/#{sim_id}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to start sim: #{inspect(reason)}")}
      end
    catch
      kind, reason ->
        require Logger
        Logger.error("start_sim #{kind}: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_sim", %{"sim_id" => sim_id}, socket) do
    SimManager.stop_sim(sim_id)
    {:noreply, socket}
  end

  def handle_event("refresh_sims", _params, socket) do
    {:noreply, assign(socket, sims: build_sim_list(), running: SimManager.list_running())}
  end

  # TicTacToe human move
  def handle_event("human_move", %{"row" => row, "col" => col}, socket) do
    state = socket.assigns.selected_sim

    if state do
      player = LemonCore.MapHelpers.get_key(state.world, :current_player)

      event =
        LemonSim.Examples.TicTacToe.Events.place_mark(
          player,
          String.to_integer(row),
          String.to_integer(col)
        )

      SimManager.submit_human_move(state.sim_id, event)
    end

    {:noreply, socket}
  end

  # Skirmish human move to position
  def handle_event("human_move_to", %{"x" => x, "y" => y}, socket) do
    state = socket.assigns.selected_sim

    if state do
      actor_id = LemonCore.MapHelpers.get_key(state.world, :active_actor_id)
      event = Skirmish.Events.move_requested(actor_id, String.to_integer(x), String.to_integer(y))
      SimManager.submit_human_move(state.sim_id, event)
    end

    {:noreply, socket}
  end

  # Skirmish human actions (end_turn, take_cover)
  def handle_event("human_action", %{"action" => "end_turn"}, socket) do
    state = socket.assigns.selected_sim

    if state do
      actor_id = LemonCore.MapHelpers.get_key(state.world, :active_actor_id)
      event = Skirmish.Events.end_turn_requested(actor_id)
      SimManager.submit_human_move(state.sim_id, event)
    end

    {:noreply, socket}
  end

  def handle_event("human_action", %{"action" => "take_cover"}, socket) do
    state = socket.assigns.selected_sim

    if state do
      actor_id = LemonCore.MapHelpers.get_key(state.world, :active_actor_id)
      event = Skirmish.Events.cover_requested(actor_id)
      SimManager.submit_human_move(state.sim_id, event)
    end

    {:noreply, socket}
  end

  def handle_event("human_action", %{"action" => "heal", "target" => target_id}, socket) do
    state = socket.assigns.selected_sim

    if state do
      actor_id = LemonCore.MapHelpers.get_key(state.world, :active_actor_id)

      event =
        LemonSim.Examples.Skirmish.Events.heal_requested(actor_id, target_id)

      SimManager.submit_human_move(state.sim_id, event)
    end

    {:noreply, socket}
  end

  def handle_event("human_action", %{"action" => "sprint"}, socket) do
    # Sprint mode - next tile click will be a sprint instead of move
    {:noreply, assign(socket, sprint_mode: true)}
  end

  def handle_event("human_attack", %{"target" => target_id}, socket) do
    state = socket.assigns.selected_sim

    if state do
      actor_id = LemonCore.MapHelpers.get_key(state.world, :active_actor_id)
      event = Skirmish.Events.attack_requested(actor_id, target_id)
      SimManager.submit_human_move(state.sim_id, event)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %LemonCore.Event{type: :sim_world_updated, meta: %{sim_id: sim_id}} = event,
        socket
      ) do
    if socket.assigns[:selected_sim] && socket.assigns.selected_sim.sim_id == sim_id do
      case payload_state(event) || Store.get_state(sim_id) do
        nil ->
          {:noreply, socket}

        updated ->
          socket =
            if socket.assigns.domain_type == :werewolf do
              queue_werewolf_selected_sim(socket, updated)
            else
              assign(socket, selected_sim: updated)
            end

          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    {:noreply, assign(socket, sims: build_sim_list(), running: SimManager.list_running())}
  end

  def handle_info({:werewolf_playback_tick, ref}, socket) do
    if socket.assigns[:playback_timer_ref] == ref and socket.assigns[:playback] do
      {playback, _hold_ms} =
        WerewolfPlayback.advance(socket.assigns.playback, System.monotonic_time(:millisecond))

      socket =
        socket
        |> assign(
          selected_sim: playback.display_state,
          playback: playback,
          playback_timer_ref: nil
        )
        |> maybe_schedule_werewolf_playback()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden text-slate-200">
      <!-- Sidebar -->
      <aside class="w-56 glass-panel flex flex-col flex-shrink-0 z-10 border-r border-glass-border">
        <div class="px-4 py-3 border-b border-glass-border flex items-center gap-2.5 bg-slate-900/30">
          <div class="w-7 h-7 rounded-lg shadow-neon-blue bg-gradient-to-br from-blue-500 to-cyan-400 flex items-center justify-center font-bold text-sm text-white">
            L
          </div>
          <div>
            <button phx-click="go_home" class="text-base font-bold text-white hover:text-cyan-400 transition tracking-tight text-glow-cyan">
              LemonSim
            </button>
            <p class="text-[10px] text-slate-400 font-mono">{length(@sims)} active</p>
          </div>
        </div>

        <div class="px-3 py-2.5 border-b border-glass-border bg-slate-900/20">
          <button phx-click="toggle_new_sim_form" class="w-full glass-button font-medium py-2 px-3 rounded-lg transition-all flex items-center justify-center gap-1.5 text-sm">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M10 3a1 1 0 011 1v5h5a1 1 0 110 2h-5v5a1 1 0 11-2 0v-5H4a1 1 0 110-2h5V4a1 1 0 011-1z" clip-rule="evenodd" />
            </svg>
            New Sim
          </button>
        </div>

        <nav class="flex-1 overflow-y-auto p-2 space-y-1.5 custom-scrollbar">
          <%= for sim <- @sims do %>
            <button
              phx-click="select_sim"
              phx-value-sim_id={sim.sim_id}
              class={[
                "w-full text-left px-2.5 py-2 rounded-lg transition-all border group relative overflow-hidden stagger-enter backdrop-blur-md",
                if(@selected_sim && @selected_sim.sim_id == sim.sim_id,
                  do: "bg-blue-900/40 border-cyan-500/50 shadow-neon-blue bg-gradient-to-r from-blue-900/50 to-transparent",
                  else: "bg-slate-800/20 border-glass-border hover:bg-slate-700/40 hover:border-slate-600/50"
                )
              ]}
            >
              <div class="flex items-center justify-between mb-1">
                <span class="font-mono text-[11px] font-semibold text-slate-100 truncate pr-1 group-hover:text-cyan-300 transition-colors">{sim.sim_id}</span>
                <span class={[
                  "text-[9px] font-medium px-1.5 py-0.5 rounded-full whitespace-nowrap border",
                  SimHelpers.domain_badge_color(sim.domain_type)
                ]}>
                  {SimHelpers.domain_label(sim.domain_type)}
                </span>
              </div>
              <div class="flex items-center justify-between">
                <span class={[
                  "text-[10px] font-medium flex items-center gap-1",
                  SimHelpers.status_color(sim.status)
                ]}>
                  <%= if sim.sim_id in @running do %>
                    <span class="w-1.5 h-1.5 rounded-full bg-cyan-400 animate-pulse shadow-[0_0_8px_rgba(6,182,212,0.8)]"></span>
                    <span class="text-cyan-400 drop-shadow-md">Active</span>
                  <% else %>
                    <span class="w-1.5 h-1.5 rounded-full bg-slate-500"></span>
                    {sim.status}
                  <% end %>
                </span>
                <span class="text-[9px] font-mono text-slate-500">v{sim.version}</span>
              </div>

              <%= if @selected_sim && @selected_sim.sim_id == sim.sim_id do %>
                <div class="absolute left-0 top-0 bottom-0 w-0.5 bg-cyan-400 shadow-[0_0_12px_rgba(6,182,212,1)] rounded-l-xl"></div>
              <% end %>
            </button>
          <% end %>
        </nav>
      </aside>

      <!-- Main content -->
      <main class="flex-1 overflow-y-auto relative">
        <div class="fixed top-4 right-4 z-[60] max-w-sm">
          <.flash_group flash={@flash} />
        </div>
        <!-- New Sim Form Modal -->
        <div :if={@show_new_sim_form} class="fixed inset-0 bg-slate-950/80 backdrop-blur-lg z-50 flex items-center justify-center p-4 transition-all">
          <div class="glass-panel border-cyan-500/20 rounded-2xl w-full max-w-md shadow-neon-blue overflow-hidden animate-[fade-in-up_0.3s_ease-out]">
            <div class="p-5 border-b border-glass-border flex items-center justify-between bg-slate-900/40">
              <h2 class="text-xl font-bold text-white flex items-center gap-2 text-glow-cyan">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 text-cyan-400" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M10 3a1 1 0 011 1v5h5a1 1 0 110 2h-5v5a1 1 0 11-2 0v-5H4a1 1 0 110-2h5V4a1 1 0 011-1z" clip-rule="evenodd" />
                </svg>
                Launch Simulation
              </h2>
              <button phx-click="toggle_new_sim_form" class="text-slate-400 hover:text-white transition-colors w-8 h-8 flex items-center justify-center rounded-full hover:bg-slate-800/50">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
                </svg>
              </button>
            </div>

            <form id="new-sim-form" phx-change="change_domain" phx-submit="start_sim" class="p-6 space-y-5 bg-slate-900/20">
              <div class="space-y-4">
                <.select
                  name="domain"
                  label="Domain Protocol"
                  value={@new_sim_domain}
                  options={[{"Tic Tac Toe", "tic_tac_toe"}, {"Skirmish", "skirmish"}, {"Werewolf", "werewolf"}, {"Stock Market", "stock_market"}, {"Survivor", "survivor"}, {"Space Station", "space_station"}, {"Auction", "auction"}, {"Diplomacy", "diplomacy"}, {"Dungeon Crawl", "dungeon_crawl"}, {"Courtroom", "courtroom"}, {"Startup Incubator", "startup_incubator"}, {"Intel Network", "intel_network"}, {"Legislature", "legislature"}, {"Pandemic", "pandemic"}, {"Murder Mystery", "murder_mystery"}, {"Supply Chain", "supply_chain"}, {"Vending Bench", "vending_bench"}]}
                  class="bg-slate-900/80 border-glass-border focus:border-cyan-500!"
                />

                <.input name="sim_id" label="Simulation Designation (leave blank for auto)" value="" placeholder="auto-generated" class="bg-slate-900/80 border-glass-border focus:border-cyan-500!" />

                <div class="p-4 bg-slate-900/50 rounded-lg border border-glass-border space-y-4 shadow-inner">
                  <h4 class="text-xs font-semibold text-cyan-500 uppercase tracking-widest mb-2 font-mono">Operations Matrix</h4>
                  <%= if @new_sim_domain == "tic_tac_toe" do %>
                    <.select
                      name="human_player"
                      label="Operator Role"
                      value=""
                      options={[{"AI vs AI (Observer)", ""}, {"Control X", "X"}, {"Control O", "O"}]}
                    />
                    <.input name="max_turns" label="Max Turns" type="number" value="20" />
                  <% else %>
                    <%= if @new_sim_domain == "skirmish" do %>
                      <.select
                        name="human_player"
                        label="Player Mode"
                        value=""
                        options={[{"AI vs AI", ""}, {"Play as Red", "red"}, {"Play as Blue", "blue"}]}
                      />
                      <.select
                        name="squad"
                        label="Squad Composition"
                        value="soldier,scout,medic"
                        options={[
                          {"Balanced (Soldier + Scout + Medic)", "soldier,scout,medic"},
                          {"Assault (Soldier + Heavy + Scout)", "soldier,heavy,scout"},
                          {"Sniper Team (Sniper + Soldier + Medic)", "sniper,soldier,medic"},
                          {"Rush (Scout + Scout + Soldier)", "scout,scout,soldier"},
                          {"Full Squad (5v5)", "soldier,scout,medic,heavy,sniper"}
                        ]}
                      />
                      <.select
                        name="map_preset"
                        label="Map Style"
                        value=""
                        options={[
                          {"Random (Procedural)", ""},
                          {"Arena (Open)", "arena"},
                          {"Fortress (Corridors)", "fortress"},
                          {"Wetlands (Water + Cover)", "wetlands"}
                        ]}
                      />
                      <div class="grid grid-cols-2 gap-3">
                        <.input name="map_width" label="Map Width" type="number" value="10" />
                        <.input name="map_height" label="Map Height" type="number" value="10" />
                      </div>
                      <.input name="max_turns" label="Max Turns" type="number" value="48" />
                      <.input name="rng_seed" label="RNG Seed" type="number" value="" placeholder="random" />
                    <% else %>
                      <%= if @new_sim_domain == "dungeon_crawl" do %>
                        <.select
                          name="party_size"
                          label="Party Size"
                          value="4"
                          options={[{"Full Party (4)", "4"}, {"Trio (3)", "3"}, {"Duo (2)", "2"}]}
                        />
                      <% else %>
                      <%= if @new_sim_domain in ~w(werewolf stock_market survivor space_station auction diplomacy courtroom startup_incubator intel_network legislature pandemic murder_mystery supply_chain vending_bench) do %>
                        <.input name="player_count" label={player_count_label(@new_sim_domain)} type="number" value={@new_player_count} min={min_players(@new_sim_domain)} max={max_players(@new_sim_domain)} />
                        <div class="mt-3 pt-3 border-t border-glass-border/50">
                          <div class="text-[10px] font-mono uppercase tracking-widest text-fuchsia-400 font-bold mb-2">Model Assignment</div>
                          <p class="text-[10px] text-slate-500 mb-3">Assign AI models to player seats.</p>
                          <%= for seat <- 1..@new_player_count do %>
                            <div class="flex items-center gap-2 mb-1.5">
                              <span class="text-[10px] text-slate-500 font-mono w-6 shrink-0">P{seat}</span>
                              <.select
                                name={"model_#{seat}"}
                                label=""
                                value={default_model_for_seat(seat)}
                                options={available_model_options()}
                                class="text-xs! py-1!"
                              />
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                      <% end %>
                    <% end %>
                  <% end %>
                </div>
              </div>


              <div class="flex gap-3 pt-2">
                <button type="submit" class="flex-1 glass-button font-medium py-3 px-4 rounded-lg">
                  INITIALIZE 
                </button>
                <button type="button" phx-click="toggle_new_sim_form" class="flex-1 bg-slate-800/80 hover:bg-slate-700 text-slate-300 font-medium py-3 px-4 rounded-lg transition-all border border-slate-700 border-b-2">
                  ABORT
                </button>
              </div>
            </form>
          </div>
        </div>

        <!-- Empty state -->
        <div :if={is_nil(@selected_sim) && @live_action == :index} class="flex items-center justify-center h-full p-6">
          <div class="text-center glass-panel p-12 rounded-2xl max-w-lg w-full relative overflow-hidden group">
            <div class="absolute inset-0 bg-blue-500/5 opacity-0 group-hover:opacity-100 transition-opacity duration-1000"></div>
            <div class="w-28 h-28 bg-slate-900/80 rounded-full flex items-center justify-center mx-auto mb-8 shadow-[0_0_30px_rgba(6,182,212,0.15)] border border-cyan-500/30">
              <span class="text-6xl text-cyan-400 drop-shadow-[0_0_15px_rgba(6,182,212,0.8)]">&#x26A1;</span>
            </div>
            <h2 class="text-3xl font-bold text-white tracking-tight mb-3 text-glow-cyan">SYSTEM STANDBY</h2>
            <p class="text-slate-400 mb-10 leading-relaxed font-mono text-sm max-w-sm mx-auto">Awaiting operation parameters. Connect to active simulation link or initialize new protocol.</p>
            <button phx-click="toggle_new_sim_form" class="glass-button font-semibold py-3 px-8 rounded-lg shadow-neon-blue inline-flex items-center gap-3 text-[15px] uppercase tracking-wider">
              Initialize Protocol
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M10.293 3.293a1 1 0 011.414 0l6 6a1 1 0 010 1.414l-6 6a1 1 0 01-1.414-1.414L14.586 11H3a1 1 0 110-2h11.586l-4.293-4.293a1 1 0 010-1.414z" clip-rule="evenodd" />
              </svg>
            </button>
          </div>
        </div>

        <!-- Sim detail view -->
        <div :if={@selected_sim} class="p-6 md:p-8">
          <!-- Header -->
          <div class="flex items-center justify-between mb-8 pb-4 border-b border-glass-border relative">
            <div class="absolute bottom-[-1px] left-0 right-0 h-px bg-gradient-to-r from-cyan-500 via-transparent to-transparent opacity-50"></div>
            <div>
              <div class="flex items-center gap-4">
                <h1 class="text-4xl font-extrabold text-white tracking-tight text-glow-blue">{@selected_sim.sim_id}</h1>
                <span class={[
                  "text-[10px] px-3 py-1.5 rounded bg-slate-800/80 font-mono tracking-widest uppercase border backdrop-blur-sm shadow-sm",
                  SimHelpers.domain_badge_color(@domain_type)
                ]}>
                  {SimHelpers.domain_label(@domain_type)}
                </span>
                <span :if={@selected_sim.sim_id in @running} class="text-[11px] font-bold tracking-widest uppercase px-3 py-1.5 rounded-sm bg-emerald-500/10 text-emerald-400 border border-emerald-500/30 flex items-center gap-2 shadow-[0_0_10px_rgba(16,185,129,0.2)]">
                  <span class="w-2 h-2 rounded-full bg-emerald-500 animate-pulse shadow-[0_0_8px_rgba(16,185,129,0.8)]"></span>
                  LIVE
                </span>
              </div>
              <p class="text-sm text-slate-400 mt-2.5 flex items-center gap-3 font-mono">
                <span class="bg-slate-900/60 border border-slate-700/50 px-2 py-0.5 rounded text-cyan-200 shadow-inner">Build <%= @selected_sim.version %></span>
                <span class="w-1 h-1 rounded-full bg-slate-600"></span>
                <span>{length(@selected_sim.recent_events)} telemetry packets</span>
              </p>
            </div>
            <div class="flex gap-3">
              <.button
                :if={@selected_sim.sim_id in @running}
                phx-click="stop_sim"
                phx-value-sim_id={@selected_sim.sim_id}
                class="bg-red-500/10 hover:bg-red-500/20 text-red-500 border border-red-500/30 transition-all font-bold tracking-widest uppercase px-5 py-2.5 rounded shadow-neon-red"
              >
                Abort Sim
              </.button>
            </div>
          </div>

          <!-- Board + details layout -->
          <div class="grid grid-cols-1 xl:grid-cols-12 gap-6 items-start">
            <!-- Left: Visual board -->
            <% full_width_board = @domain_type in [:werewolf, :stock_market, :survivor, :space_station, :auction, :diplomacy, :dungeon_crawl, :courtroom, :startup_incubator, :intel_network, :legislature, :pandemic, :murder_mystery, :supply_chain, :vending_bench] %>
            <div class={[
              "glass-card rounded-xl flex flex-col overflow-hidden",
              if(full_width_board, do: "xl:col-span-9 h-[calc(100vh-14rem)]", else: "xl:col-span-7 p-6 min-h-[500px]")
            ]}>
              <h3 :if={!full_width_board} class="text-xs font-bold text-cyan-400 mb-5 uppercase tracking-widest flex items-center gap-2 font-mono drop-shadow-md">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z" clip-rule="evenodd" />
                </svg>
                TACTICAL DISPLAY
              </h3>
              <div class={[
                "flex-1 flex relative overflow-hidden",
                if(full_width_board, do: "", else: "items-center justify-center bg-slate-950/60 rounded-lg border border-slate-800 shadow-inner p-4")
              ]}>
                <div :if={!full_width_board} class="absolute inset-0 bg-[linear-gradient(rgba(59,130,246,0.03)_1px,transparent_1px),linear-gradient(90deg,rgba(59,130,246,0.03)_1px,transparent_1px)] bg-[length:40px_40px] pointer-events-none"></div>
                <%= case @domain_type do %>
                  <% :tic_tac_toe -> %>
                    <TicTacToeBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :skirmish -> %>
                    <SkirmishBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :werewolf -> %>
                    <WerewolfBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :stock_market -> %>
                    <StockMarketBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :survivor -> %>
                    <SurvivorBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :space_station -> %>
                    <SpaceStationBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :auction -> %>
                    <AuctionBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :diplomacy -> %>
                    <DiplomacyBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :dungeon_crawl -> %>
                    <DungeonCrawlBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :courtroom -> %>
                    <CourtroomBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :startup_incubator -> %>
                    <StartupIncubatorBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :intel_network -> %>
                    <IntelNetworkBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :legislature -> %>
                    <LegislatureBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :pandemic -> %>
                    <PandemicBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :murder_mystery -> %>
                    <MurderMysteryBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :supply_chain -> %>
                    <SupplyChainBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% :vending_bench -> %>
                    <VendingBenchBoard.render
                      world={@selected_sim.world}
                      interactive={@human_player != nil && @selected_sim.sim_id in @running}
                    />
                  <% _ -> %>
                    <div class="text-center text-slate-500">
                      <p>UNRECOGNIZED DOMAIN</p>
                      <pre class="text-[10px] font-mono mt-4 text-left overflow-auto max-h-96 text-cyan-700">{inspect(@selected_sim.world, pretty: true, limit: :infinity)}</pre>
                    </div>
                <% end %>
              </div>
            </div>

            <!-- Right: Event log + Plan history + Memory -->
            <div class={[
              "space-y-6",
              if(full_width_board, do: "xl:col-span-3", else: "xl:col-span-5")
            ]}>
              <div class="glass-card rounded-xl overflow-hidden flex flex-col h-96">
                <div class="p-4 border-b border-glass-border bg-slate-900/60">
                  <h3 class="text-xs font-bold text-emerald-400 uppercase tracking-widest flex items-center gap-2 font-mono">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                      <path fill-rule="evenodd" d="M3 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1z" clip-rule="evenodd" />
                    </svg>
                    EVENT LOG
                  </h3>
                </div>
                <div class="p-0 flex-1 overflow-hidden bg-slate-950/40">
                  <EventLog.render events={@selected_sim.recent_events} />
                </div>
              </div>

              <div class="glass-card rounded-xl overflow-hidden flex flex-col h-80">
                <div class="p-4 border-b border-glass-border bg-slate-900/60">
                  <h3 class="text-xs font-bold text-blue-400 uppercase tracking-widest flex items-center gap-2 font-mono">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm1-12a1 1 0 10-2 0v4a1 1 0 00.293.707l2.828 2.829a1 1 0 101.415-1.415L11 9.586V6z" clip-rule="evenodd" />
                    </svg>
                    AGENT STRATEGY
                  </h3>
                </div>
                <div class="p-0 flex-1 overflow-hidden bg-slate-950/40">
                  <PlanHistory.render plan_history={@selected_sim.plan_history} />
                </div>
              </div>

              <div class="glass-card rounded-xl overflow-hidden flex flex-col h-80">
                <div class="p-4 border-b border-glass-border bg-slate-900/60">
                  <h3 class="text-xs font-bold text-purple-400 uppercase tracking-widest flex items-center gap-2 font-mono">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                      <path d="M9 2a1 1 0 000 2h2a1 1 0 100-2H9z" />
                      <path fill-rule="evenodd" d="M4 5a2 2 0 012-2 3 3 0 003 3h2a3 3 0 003-3 2 2 0 012 2v11a2 2 0 01-2 2H6a2 2 0 01-2-2V5zm3 4a1 1 0 000 2h.01a1 1 0 100-2H7zm3 0a1 1 0 000 2h3a1 1 0 100-2h-3zm-3 4a1 1 0 100 2h.01a1 1 0 100-2H7zm3 0a1 1 0 100 2h3a1 1 0 100-2h-3z" clip-rule="evenodd" />
                    </svg>
                    DATA BANKS
                  </h3>
                </div>
                <div class="p-0 flex-1 overflow-hidden bg-slate-950/40">
                  <MemoryViewer.render sim_id={@selected_sim.sim_id} />
                </div>
              </div>

              <!-- Raw world state (collapsed) -->
              <details class="glass-card rounded-xl group mt-4">
                <summary class="p-4 text-xs font-bold text-slate-500 cursor-pointer hover:text-cyan-300 transition-colors uppercase tracking-widest flex items-center gap-2 font-mono">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 transform group-open:rotate-90 transition-transform" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
                  </svg>
                  RAW_STATE_DUMP.json
                </summary>
                <div class="border-t border-glass-border p-4 bg-slate-950/80">
                  <pre class="text-[10px] text-slate-400 font-mono overflow-auto max-h-96 custom-scrollbar">{inspect(@selected_sim.world, pretty: true, limit: :infinity)}</pre>
                </div>
              </details>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # --- Private helpers ---

  defp get_state_with_retry(sim_id, 0), do: Store.get_state(sim_id)

  defp get_state_with_retry(sim_id, retries) do
    case Store.get_state(sim_id) do
      nil ->
        Process.sleep(100)
        get_state_with_retry(sim_id, retries - 1)

      state ->
        state
    end
  end

  defp build_sim_list do
    Store.list_states()
    |> Enum.map(&SimHelpers.sim_summary/1)
    |> Enum.sort_by(& &1.last_activity, :desc)
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default

  defp parse_human_player(nil), do: nil
  defp parse_human_player(""), do: nil
  defp parse_human_player(val), do: val

  defp parse_squad(nil), do: LemonSim.Examples.Skirmish.UnitClasses.default_squad()
  defp parse_squad(""), do: LemonSim.Examples.Skirmish.UnitClasses.default_squad()
  defp parse_squad(val) when is_binary(val), do: String.split(val, ",", trim: true)

  defp parse_map_preset(nil), do: nil
  defp parse_map_preset(""), do: nil
  defp parse_map_preset(val), do: String.to_existing_atom(val)

  defp maybe_put_sim_id(opts, nil), do: opts
  defp maybe_put_sim_id(opts, ""), do: opts
  defp maybe_put_sim_id(opts, sim_id), do: Keyword.put(opts, :sim_id, sim_id)

  defp queue_werewolf_selected_sim(socket, updated_state) do
    playback =
      socket.assigns.playback
      |> Kernel.||(WerewolfPlayback.new(socket.assigns.selected_sim))
      |> WerewolfPlayback.enqueue(updated_state)

    socket
    |> assign(playback: playback)
    |> maybe_schedule_werewolf_playback()
  end

  defp maybe_schedule_werewolf_playback(socket) do
    cond do
      is_nil(socket.assigns[:playback]) ->
        socket

      socket.assigns[:playback_timer_ref] != nil ->
        socket

      true ->
        case WerewolfPlayback.next_delay_ms(
               socket.assigns.playback,
               System.monotonic_time(:millisecond)
             ) do
          nil ->
            socket

          delay_ms ->
            ref = make_ref()
            Process.send_after(self(), {:werewolf_playback_tick, ref}, delay_ms)
            assign(socket, playback_timer_ref: ref)
        end
    end
  end

  defp payload_state(%LemonCore.Event{payload: payload}) when is_map(payload) do
    case Map.get(payload, :state, Map.get(payload, "state")) do
      %LemonSim.State{} = state ->
        state

      %{} = state_map ->
        LemonSim.State.new(state_map)

      _ ->
        nil
    end
  end

  defp payload_state(_event), do: nil

  # -- Game-specific form helpers --

  defp player_count_label("werewolf"), do: "Number of Players (5-8)"
  defp player_count_label("stock_market"), do: "Number of Traders (3-6)"
  defp player_count_label("survivor"), do: "Number of Contestants (6-8)"
  defp player_count_label("space_station"), do: "Number of Crew (5-7)"
  defp player_count_label("auction"), do: "Number of Bidders (4-6)"
  defp player_count_label("diplomacy"), do: "Number of Factions (4-6)"
  defp player_count_label("courtroom"), do: "Number of Jurors (3-5)"
  defp player_count_label("startup_incubator"), do: "Number of Founders (2-6)"
  defp player_count_label("intel_network"), do: "Number of Agents (6-8)"
  defp player_count_label("legislature"), do: "Number of Legislators (5-7)"
  defp player_count_label("pandemic"), do: "Number of Governors (4-6)"
  defp player_count_label("murder_mystery"), do: "Number of Guests (6)"
  defp player_count_label("supply_chain"), do: "Number of Tiers (4)"
  defp player_count_label("vending_bench"), do: "Operator (1)"
  defp player_count_label(_), do: "Number of Players"

  defp min_players("stock_market"), do: 3
  defp min_players("survivor"), do: 6
  defp min_players("space_station"), do: 5
  defp min_players("auction"), do: 4
  defp min_players("diplomacy"), do: 4
  defp min_players("courtroom"), do: 3
  defp min_players("startup_incubator"), do: 2
  defp min_players("intel_network"), do: 6
  defp min_players("legislature"), do: 5
  defp min_players("pandemic"), do: 4
  defp min_players("murder_mystery"), do: 6
  defp min_players("supply_chain"), do: 4
  defp min_players("vending_bench"), do: 1
  defp min_players(_), do: 5

  defp max_players("stock_market"), do: 6
  defp max_players("survivor"), do: 8
  defp max_players("space_station"), do: 7
  defp max_players("auction"), do: 6
  defp max_players("diplomacy"), do: 6
  defp max_players("courtroom"), do: 5
  defp max_players("startup_incubator"), do: 6
  defp max_players("intel_network"), do: 8
  defp max_players("legislature"), do: 7
  defp max_players("pandemic"), do: 6
  defp max_players("murder_mystery"), do: 6
  defp max_players("supply_chain"), do: 4
  defp max_players("vending_bench"), do: 1
  defp max_players(_), do: 8

  defp default_player_count(:stock_market), do: 4
  defp default_player_count(:survivor), do: 8
  defp default_player_count(:space_station), do: 6
  defp default_player_count(:auction), do: 4
  defp default_player_count(:diplomacy), do: 4
  defp default_player_count(:courtroom), do: 3
  defp default_player_count(:startup_incubator), do: 4
  defp default_player_count(:intel_network), do: 6
  defp default_player_count(:legislature), do: 5
  defp default_player_count(:pandemic), do: 4
  defp default_player_count(:murder_mystery), do: 6
  defp default_player_count(:supply_chain), do: 4
  defp default_player_count(:vending_bench), do: 1
  defp default_player_count(_), do: 6

  # -- Model helpers --

  defp available_model_options do
    [
      {"Gemini 3 Flash", "google_gemini_cli:gemini-3-flash-preview"},
      {"Gemini 3 Pro", "google_gemini_cli:gemini-3-pro-preview"},
      {"Gemini 2.5 Flash", "google_gemini_cli:gemini-2.5-flash"},
      {"Gemini 2.5 Pro", "google_gemini_cli:gemini-2.5-pro"},
      {"Claude Sonnet 4", "anthropic:claude-sonnet-4-20250514"},
      {"Claude Haiku 3.5", "anthropic:claude-haiku-4-5-20251001"},
      {"GPT-4o", "openai:gpt-4o"},
      {"GPT-5.1 Codex Mini", "openai-codex:gpt-5.1-codex-mini"},
      {"GPT-5.3 Codex Spark", "openai-codex:gpt-5.3-codex-spark"},
      {"GPT-5.3 Codex", "openai-codex:gpt-5.3-codex"},
      {"GPT-5.4", "openai-codex:gpt-5.4"},
      {"Kimi K2P5", "kimi:k2p5"},
      {"Z.ai GLM-5", "zai:glm-5"},
      {"DeepSeek V3", "deepseek:deepseek-chat"}
    ]
  end

  @default_model "openai-codex:gpt-5.3-codex-spark"

  defp default_model_for_seat(_seat), do: @default_model
end
