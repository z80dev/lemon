defmodule LemonSimUi.SimDashboardLive do
  @moduledoc """
  Protected operator control room for monitoring and controlling LemonSim simulations.

  Shows a sidebar listing all known simulations with their domain type and
  live/stopped status. Selecting a sim renders the appropriate game board
  (TicTacToe, Skirmish, Werewolf, StockMarket, Survivor, SpaceStation,
  Auction, Diplomacy, DungeonCrawl, Courtroom, StartupIncubator,
  IntelNetwork, Legislature, Pandemic, MurderMystery, or SupplyChain) alongside an event log, agent
  strategy history, and a memory/data-bank viewer.

  The overview promotes Werewolf broadcast status, public-preview links,
  automation ownership, and recent runs. A launch form supports configurable
  domains, player counts, model assignments, and optional human participation.
  Real-time updates are delivered via `LemonCore.Bus` pub/sub.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{Arena, SimHelpers, SimManager, WerewolfPlayback}
  alias LemonSim.Kernel.{Store, Bus}
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
       sidebar_open: true,
       selected_sim: nil,
       subscribed_sim_id: nil,
       playback: nil,
       playback_timer_ref: nil,
       domain_type: nil,
       show_new_sim_form: false,
       new_sim_domain: "werewolf",
       new_player_count: 6,
       seat_providers: %{},
       seat_models: %{},
       human_player: nil,
       auto_loop_status: SimManager.auto_loop_status(),
       werewolf_arena_status: Arena.status(:werewolf),
       page_title: "LemonSim Control Room"
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
         |> push_patch(to: ~p"/admin")}

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
       page_title: "LemonSim Control Room"
     )}
  end

  @impl true
  def handle_event("select_sim", %{"sim_id" => sim_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/sims/#{sim_id}")}
  end

  def handle_event("go_home", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin")}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  def handle_event("toggle_new_sim_form", _params, socket) do
    {:noreply, assign(socket, show_new_sim_form: !socket.assigns.show_new_sim_form)}
  end

  def handle_event("change_domain", params, socket) do
    domain = params["domain"] || socket.assigns.new_sim_domain
    min_p = min_players(domain)
    max_p = max_players(domain)

    {player_count, seat_providers, seat_models} =
      if params["domain"] && params["domain"] != socket.assigns.new_sim_domain do
        # Domain changed — reset to defaults
        {default_player_count(String.to_existing_atom(domain)), %{}, %{}}
      else
        pc =
          parse_int(params["player_count"], socket.assigns.new_player_count)
          |> max(min_p)
          |> min(max_p)

        old_providers = socket.assigns.seat_providers
        old_models = socket.assigns.seat_models

        {sp, sm} =
          Enum.reduce(1..pc, {old_providers, old_models}, fn seat, {pacc, macc} ->
            new_provider =
              case params["provider_#{seat}"] do
                nil -> Map.get(pacc, seat)
                val -> String.to_existing_atom(val)
              end

            old_provider = Map.get(pacc, seat)
            provider_changed = new_provider != nil and new_provider != old_provider

            pacc = if new_provider, do: Map.put(pacc, seat, new_provider), else: pacc

            macc =
              if provider_changed do
                # Provider changed — reset model to default for new provider
                Map.delete(macc, seat)
              else
                case params["model_#{seat}"] do
                  nil -> macc
                  val -> Map.put(macc, seat, val)
                end
              end

            {pacc, macc}
          end)

        {pc, sp, sm}
      end

    {:noreply,
     assign(socket,
       new_sim_domain: domain,
       new_player_count: player_count,
       seat_providers: seat_providers,
       seat_models: seat_models
     )}
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

          [
            player_count: player_count,
            model_specs: build_model_specs(params, player_count)
          ]
          |> maybe_put_sim_id(params["sim_id"])

        domain when domain in [:stock_market, :survivor, :space_station] ->
          player_count = parse_int(params["player_count"], default_player_count(domain))

          [
            player_count: player_count,
            model_specs: build_model_specs(params, player_count)
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
               :tcg_shop,
               :vending_bench
             ] ->
          player_count = parse_int(params["player_count"], default_player_count(domain))

          [
            player_count: player_count,
            model_specs: build_model_specs(params, player_count)
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
           |> push_patch(to: ~p"/admin/sims/#{sim_id}")}

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

  def handle_event("resume_sim", %{"sim_id" => sim_id}, socket) do
    if resume_supported?(socket.assigns.domain_type) do
      try do
        case SimManager.resume_sim(sim_id) do
          {:ok, _} ->
            {:noreply, assign(socket, running: SimManager.list_running())}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to resume: #{inspect(reason)}")}
        end
      catch
        kind, reason ->
          require Logger
          Logger.error("resume_sim #{kind}: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Failed to resume: #{inspect(reason)}")}
      end
    else
      {:noreply,
       put_flash(socket, :error, "Resume is currently supported only for werewolf sims")}
    end
  end

  def handle_event("refresh_sims", _params, socket) do
    {:noreply,
     assign(socket,
       sims: build_sim_list(),
       running: SimManager.list_running(),
       werewolf_arena_status: Arena.status(:werewolf)
     )}
  end

  def handle_event("toggle_auto_loop", %{"domain" => domain_str}, socket) do
    domain = String.to_existing_atom(domain_str)
    current = socket.assigns.auto_loop_status

    if domain == :werewolf and Map.get(socket.assigns.werewolf_arena_status, :enabled, false) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "The configured Werewolf arena already owns continuous broadcasts"
       )}
    else
      if Map.has_key?(current, domain) do
        SimManager.disable_auto_loop(domain)
      else
        default_opts = [player_count: default_player_count(domain)]
        SimManager.enable_auto_loop(domain, default_opts)
      end

      {:noreply, assign(socket, auto_loop_status: SimManager.auto_loop_status())}
    end
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
    {:noreply,
     assign(socket,
       sims: build_sim_list(),
       running: SimManager.list_running(),
       auto_loop_status: SimManager.auto_loop_status(),
       werewolf_arena_status: Arena.status(:werewolf)
     )}
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
    <div class="flex h-screen overflow-hidden bg-[#080a0d] text-stone-200">
      <!-- Sidebar toggle button (visible when sidebar is closed) -->
      <button
        :if={!@sidebar_open}
        phx-click="toggle_sidebar"
        class="fixed left-3 top-3 z-50 flex h-11 w-11 items-center justify-center rounded-xl border border-white/10 bg-[#11141a]/95 text-stone-300 shadow-xl transition hover:border-amber-200/30 hover:text-white"
        title="Show sidebar"
        aria-label="Show control room navigation"
      >
        <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M3 5a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zM3 10a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zM3 15a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1z" clip-rule="evenodd" />
        </svg>
      </button>

      <button
        :if={@sidebar_open}
        phx-click="toggle_sidebar"
        class="fixed inset-0 z-30 bg-black/70 backdrop-blur-sm lg:hidden"
        aria-label="Close control room navigation"
      ></button>

      <!-- Sidebar -->
      <aside
        :if={@sidebar_open}
        class="fixed inset-y-0 left-0 z-40 flex w-[min(18rem,88vw)] flex-shrink-0 flex-col border-r border-white/10 bg-[#0d1015]/98 shadow-2xl shadow-black/50 backdrop-blur-xl lg:relative lg:z-10 lg:w-64"
      >
        <div class="flex items-center gap-3 border-b border-white/10 px-4 py-4">
          <img src="/assets/werewolf/moon.png" alt="" aria-hidden="true" class="h-9 w-9 rounded-full border border-amber-100/20 object-cover" />
          <div class="flex-1 min-w-0">
            <button phx-click="go_home" class="text-left text-base font-bold tracking-tight text-white transition hover:text-amber-100">
              Control Room
            </button>
            <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-stone-500">
              {length(@running)} running · {length(@sims)} stored
            </p>
          </div>
          <button
            phx-click="toggle_sidebar"
            class="flex h-9 w-9 items-center justify-center rounded-lg text-stone-500 transition hover:bg-white/5 hover:text-white"
            title="Hide sidebar"
            aria-label="Hide control room navigation"
          >
            <svg xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M12.707 5.293a1 1 0 010 1.414L9.414 10l3.293 3.293a1 1 0 01-1.414 1.414l-4-4a1 1 0 010-1.414l4-4a1 1 0 011.414 0z" clip-rule="evenodd" />
            </svg>
          </button>
        </div>

        <div class="space-y-2 border-b border-white/10 px-3 py-3">
          <button phx-click="toggle_new_sim_form" class="inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-amber-100 px-3 text-sm font-bold text-stone-950 transition hover:bg-white">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M10 3a1 1 0 011 1v5h5a1 1 0 110 2h-5v5a1 1 0 11-2 0v-5H4a1 1 0 110-2h5V4a1 1 0 011-1z" clip-rule="evenodd" />
            </svg>
            Launch match
          </button>

          <a
            href={~p"/"}
            target="_blank"
            rel="noopener"
            class="inline-flex min-h-10 w-full items-center justify-center gap-2 rounded-xl border border-white/10 bg-white/[0.035] px-3 text-xs font-semibold text-stone-300 transition hover:border-white/20 hover:text-white"
          >
            Open public lobby <span aria-hidden="true">↗</span>
          </a>

          <%!-- Auto-loop controls --%>
          <div class="mt-2 pt-2 border-t border-glass-border/50">
            <div class="mb-1.5 text-[9px] font-bold uppercase tracking-[0.18em] text-violet-300">Broadcast automation</div>
            <div class="space-y-1">
              <% werewolf_loop = Map.get(@auto_loop_status, :werewolf) %>
              <% arena_enabled = Map.get(@werewolf_arena_status, :enabled, false) %>
              <button
                phx-click="toggle_auto_loop"
                phx-value-domain="werewolf"
                disabled={arena_enabled}
                class={[
                  "w-full text-left text-[11px] px-2.5 py-1.5 rounded border transition-all flex items-center justify-between",
                  cond do
                    arena_enabled ->
                      "cursor-not-allowed border-violet-500/30 bg-violet-900/20 text-violet-300"

                    werewolf_loop ->
                      "bg-emerald-900/30 border-emerald-500/30 text-emerald-400"

                    true ->
                      "bg-slate-800/30 border-glass-border text-slate-500 hover:text-slate-300"
                  end
                ]}
              >
                <span class="font-mono">Werewolf</span>
                <span class="text-[9px] font-bold uppercase">
                  <%= cond do %>
                    <% arena_enabled -> %> ARENA
                    <% werewolf_loop -> %> ON ({werewolf_loop.game_count})
                    <% true -> %> OFF
                  <% end %>
                </span>
              </button>
            </div>
          </div>
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

        <div class="border-t border-white/10 p-3">
          <.form for={%{}} action={~p"/admin/logout"} method="post">
            <button
              type="submit"
              class="inline-flex min-h-10 w-full items-center justify-center rounded-xl border border-white/10 bg-white/[0.025] px-3 text-xs font-semibold text-stone-400 transition hover:border-red-300/20 hover:bg-red-500/5 hover:text-red-100"
            >
              Sign out of admin
            </button>
          </.form>
        </div>
      </aside>

      <!-- Main content -->
      <main class="flex-1 overflow-y-auto relative">
        <div class="fixed top-4 right-4 z-[60] max-w-sm">
          <.flash_group flash={@flash} />
        </div>
        <!-- New Sim Form Modal -->
        <div :if={@show_new_sim_form} class="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-3 backdrop-blur-lg transition-all sm:p-5">
          <div class="max-h-[calc(100vh-1.5rem)] w-full max-w-3xl overflow-y-auto rounded-2xl border border-white/10 bg-[#11141a] shadow-2xl shadow-black/60 animate-[fade-in-up_0.3s_ease-out] sm:max-h-[calc(100vh-2.5rem)]">
            <div class="sticky top-0 z-10 flex items-center justify-between border-b border-white/10 bg-[#11141a]/95 p-5 backdrop-blur-xl">
              <div>
                <p class="text-[10px] font-bold uppercase tracking-[0.2em] text-amber-300/75">Private operator action</p>
                <h2 class="mt-1 text-xl font-bold text-white">
                  Launch a simulation
                </h2>
              </div>
              <button phx-click="toggle_new_sim_form" class="flex h-11 w-11 items-center justify-center rounded-full text-stone-400 transition hover:bg-white/5 hover:text-white" aria-label="Close launch form">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
                </svg>
              </button>
            </div>

            <form id="new-sim-form" phx-change="change_domain" phx-submit="start_sim" class="space-y-5 p-5 sm:p-6">
              <div class="space-y-4">
                <.select
                  name="domain"
                  label="Domain Protocol"
                  value={@new_sim_domain}
                  options={[{"Tic Tac Toe", "tic_tac_toe"}, {"Skirmish", "skirmish"}, {"Werewolf", "werewolf"}, {"Stock Market", "stock_market"}, {"Survivor", "survivor"}, {"Space Station", "space_station"}, {"Auction", "auction"}, {"Diplomacy", "diplomacy"}, {"Dungeon Crawl", "dungeon_crawl"}, {"Courtroom", "courtroom"}, {"Startup Incubator", "startup_incubator"}, {"Intel Network", "intel_network"}, {"Legislature", "legislature"}, {"Pandemic", "pandemic"}, {"Murder Mystery", "murder_mystery"}, {"Supply Chain", "supply_chain"}, {"Vending Bench", "vending_bench"}, {"TCG Shop", "tcg_shop"}]}
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
                      <%= if @new_sim_domain in ~w(werewolf stock_market survivor space_station auction diplomacy courtroom startup_incubator intel_network legislature pandemic murder_mystery supply_chain vending_bench tcg_shop) do %>
                        <.input name="player_count" label={player_count_label(@new_sim_domain)} type="number" value={@new_player_count} min={min_players(@new_sim_domain)} max={max_players(@new_sim_domain)} />
                        <div class="mt-3 pt-3 border-t border-glass-border/50">
                          <div class="text-[10px] font-mono uppercase tracking-widest text-fuchsia-400 font-bold mb-2">Model Assignment</div>
                          <p class="text-[10px] text-slate-500 mb-3">Assign AI models to player seats.</p>
                          <%= for seat <- 1..@new_player_count do %>
                            <% seat_provider = Map.get(@seat_providers, seat, default_provider()) %>
                            <% seat_model = Map.get(@seat_models, seat, default_model_for_provider(seat_provider)) %>
                            <div class="flex items-center gap-2 mb-1.5">
                              <span class="text-[10px] text-slate-500 font-mono w-6 shrink-0">P{seat}</span>
                              <.select
                                name={"provider_#{seat}"}
                                label=""
                                value={to_string(seat_provider)}
                                options={provider_options()}
                                class="text-xs! py-1!"
                              />
                              <.select
                                name={"model_#{seat}"}
                                label=""
                                value={seat_model}
                                options={model_options_for_provider(seat_provider)}
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

        <!-- Operator overview -->
        <div :if={is_nil(@selected_sim) && @live_action == :index} class="min-h-full bg-[#080a0d]">
          <% active_sims = Enum.filter(@sims, fn sim -> sim.sim_id in @running end) %>
          <% active_werewolf = Enum.find(active_sims, &(&1.domain_type == :werewolf)) %>
          <% werewolf_loop = Map.get(@auto_loop_status, :werewolf) %>
          <% werewolf_arena_enabled = Map.get(@werewolf_arena_status, :enabled, false) %>

          <header class="border-b border-white/10 bg-[#0d1015]">
            <div class="mx-auto flex max-w-7xl flex-col justify-between gap-6 px-5 py-7 sm:px-8 lg:flex-row lg:items-end lg:px-10">
              <div>
                <div class="mb-3 flex flex-wrap items-center gap-2">
                  <span class="rounded-full border border-amber-200/20 bg-amber-200/10 px-3 py-1 text-[10px] font-bold uppercase tracking-[0.18em] text-amber-100">
                    Private admin
                  </span>
                  <span class="inline-flex items-center gap-2 rounded-full border border-emerald-300/15 bg-emerald-300/5 px-3 py-1 text-[10px] font-bold uppercase tracking-[0.18em] text-emerald-200">
                    <span class="h-1.5 w-1.5 rounded-full bg-emerald-300"></span> System ready
                  </span>
                </div>
                <h1 class="font-display text-4xl font-semibold tracking-tight text-white sm:text-5xl">
                  Werewolf Control Room
                </h1>
                <p class="mt-3 max-w-2xl text-sm leading-6 text-stone-400">
                  Launch matches, monitor the broadcast, and move between the private operator view and the public spectator experience.
                </p>
              </div>
              <div class="flex flex-col gap-3 sm:flex-row">
                <a href={~p"/"} target="_blank" rel="noopener" class="public-secondary-cta">
                  View public lobby <span aria-hidden="true">↗</span>
                </a>
                <button phx-click="toggle_new_sim_form" class="public-primary-cta">
                  Launch Werewolf match <span aria-hidden="true">+</span>
                </button>
              </div>
            </div>
          </header>

          <main class="mx-auto max-w-7xl space-y-6 px-5 py-7 sm:px-8 lg:px-10 lg:py-10">
            <div class="grid gap-6 xl:grid-cols-[minmax(0,1.45fr)_minmax(19rem,0.55fr)]">
              <section class="overflow-hidden rounded-3xl border border-white/10 bg-[#11141a]">
                <div class="flex flex-col justify-between gap-5 border-b border-white/10 p-5 sm:flex-row sm:items-center sm:p-6">
                  <div>
                    <p class="text-[10px] font-bold uppercase tracking-[0.2em] text-red-300">Public broadcast</p>
                    <h2 class="mt-2 text-2xl font-semibold text-white">
                      {if active_werewolf, do: "A village is live", else: "No Werewolf match is running"}
                    </h2>
                  </div>
                  <span class={[
                    "inline-flex w-fit items-center gap-2 rounded-full border px-3 py-1.5 text-[10px] font-bold uppercase tracking-[0.18em]",
                    if(active_werewolf,
                      do: "border-red-300/20 bg-red-950/40 text-red-100",
                      else: "border-stone-500/20 bg-stone-900 text-stone-400"
                    )
                  ]}>
                    <span class={[
                      "h-2 w-2 rounded-full",
                      if(active_werewolf, do: "animate-pulse bg-red-400", else: "bg-stone-600")
                    ]}></span>
                    {if active_werewolf, do: "On air", else: "Off air"}
                  </span>
                </div>

                <%= if active_werewolf do %>
                  <div class="p-5 sm:p-6">
                    <div class="grid gap-5 md:grid-cols-[1fr_auto] md:items-center">
                      <div class="min-w-0">
                        <p class="truncate font-mono text-xs text-stone-500">{active_werewolf.sim_id}</p>
                        <p class="mt-3 text-lg font-semibold text-stone-100">{active_werewolf.world_summary}</p>
                        <div class="mt-4 flex flex-wrap gap-2 text-xs text-stone-400">
                          <span class="rounded-lg border border-white/10 bg-black/20 px-2.5 py-1.5">
                            Version {active_werewolf.version}
                          </span>
                          <span class="rounded-lg border border-white/10 bg-black/20 px-2.5 py-1.5">
                            {active_werewolf.event_count} recent events
                          </span>
                        </div>
                      </div>
                      <div class="flex flex-col gap-2 sm:flex-row md:flex-col">
                        <button
                          phx-click="select_sim"
                          phx-value-sim_id={active_werewolf.sim_id}
                          class="inline-flex min-h-11 items-center justify-center rounded-xl bg-amber-100 px-4 text-sm font-bold text-stone-950 transition hover:bg-white"
                        >
                          Manage match
                        </button>
                        <a
                          href={~p"/watch/#{active_werewolf.sim_id}"}
                          target="_blank"
                          rel="noopener"
                          class="inline-flex min-h-11 items-center justify-center rounded-xl border border-white/10 bg-white/[0.035] px-4 text-sm font-semibold text-stone-200 transition hover:border-white/20 hover:text-white"
                        >
                          Open broadcast ↗
                        </a>
                      </div>
                    </div>
                  </div>
                <% else %>
                  <div class="grid gap-6 p-5 sm:p-6 md:grid-cols-[1fr_auto] md:items-center">
                    <p class="max-w-2xl text-sm leading-6 text-stone-400">
                      Start a one-off show match with a custom lineup, or enable continuous rotation so the public arena automatically advances from game to game.
                    </p>
                    <button phx-click="toggle_new_sim_form" class="public-secondary-cta">
                      Configure a match
                    </button>
                  </div>
                <% end %>

                <div class="flex flex-col justify-between gap-4 border-t border-white/10 bg-black/15 p-5 sm:flex-row sm:items-center sm:px-6">
                  <div>
                    <p class="text-sm font-semibold text-white">
                      {if werewolf_arena_enabled, do: "Always-on arena", else: "Continuous Werewolf rotation"}
                    </p>
                    <p class="mt-1 text-xs text-stone-500">
                      {if werewolf_arena_enabled,
                        do: "Configured at startup with seeded lineups and persistent league scoring.",
                        else: "Starts a new broadcast after each completed match."}
                    </p>
                  </div>
                  <button
                    phx-click="toggle_auto_loop"
                    phx-value-domain="werewolf"
                    disabled={werewolf_arena_enabled}
                    class={[
                      "inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border px-4 text-xs font-bold uppercase tracking-[0.15em] transition",
                      cond do
                        werewolf_arena_enabled ->
                          "cursor-not-allowed border-violet-300/20 bg-violet-300/10 text-violet-100"

                        werewolf_loop ->
                          "border-emerald-300/25 bg-emerald-300/10 text-emerald-100 hover:bg-emerald-300/15"

                        true ->
                          "border-white/10 bg-white/[0.035] text-stone-300 hover:border-white/20 hover:text-white"
                      end
                    ]}
                  >
                    <span class={[
                      "h-2 w-2 rounded-full",
                      cond do
                        werewolf_arena_enabled -> "bg-violet-300"
                        werewolf_loop -> "bg-emerald-300"
                        true -> "bg-stone-600"
                      end
                    ]}></span>
                    <%= cond do %>
                      <% werewolf_arena_enabled -> %> Configured
                      <% werewolf_loop -> %> Running · game {werewolf_loop.game_count}
                      <% true -> %> Turn on
                    <% end %>
                  </button>
                </div>
              </section>

              <aside class="rounded-3xl border border-white/10 bg-[#11141a] p-5 sm:p-6">
                <p class="text-[10px] font-bold uppercase tracking-[0.2em] text-violet-300">At a glance</p>
                <dl class="mt-5 divide-y divide-white/10">
                  <div class="flex items-center justify-between gap-4 py-4 first:pt-0">
                    <dt class="text-sm text-stone-400">Running now</dt>
                    <dd class="text-2xl font-semibold text-white">{length(active_sims)}</dd>
                  </div>
                  <div class="flex items-center justify-between gap-4 py-4">
                    <dt class="text-sm text-stone-400">Werewolf on air</dt>
                    <dd class={if(active_werewolf, do: "font-semibold text-emerald-200", else: "font-semibold text-stone-500")}>
                      {if active_werewolf, do: "Yes", else: "No"}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-4 py-4">
                    <dt class="text-sm text-stone-400">Stored simulations</dt>
                    <dd class="font-semibold text-stone-200">{length(@sims)}</dd>
                  </div>
                  <div class="flex items-center justify-between gap-4 py-4 last:pb-0">
                    <dt class="text-sm text-stone-400">Admin access</dt>
                    <dd class="font-semibold text-amber-100">Protected</dd>
                  </div>
                </dl>
              </aside>
            </div>

            <section class="rounded-3xl border border-white/10 bg-[#11141a] p-5 sm:p-6">
              <div class="flex flex-col justify-between gap-3 sm:flex-row sm:items-end">
                <div>
                  <p class="text-[10px] font-bold uppercase tracking-[0.2em] text-stone-500">Operations history</p>
                  <h2 class="mt-2 text-xl font-semibold text-white">Recent simulations</h2>
                </div>
                <span class="text-xs text-stone-500">Select a run for controls, telemetry, and the full board.</span>
              </div>

              <%= if @sims == [] do %>
                <div class="mt-6 rounded-2xl border border-dashed border-white/10 px-5 py-10 text-center">
                  <p class="text-sm text-stone-400">No simulations have been stored yet.</p>
                </div>
              <% else %>
                <div class="mt-6 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
                  <button
                    :for={sim <- Enum.take(@sims, 9)}
                    phx-click="select_sim"
                    phx-value-sim_id={sim.sim_id}
                    class="group rounded-2xl border border-white/10 bg-black/15 p-4 text-left transition hover:border-amber-200/20 hover:bg-white/[0.035]"
                  >
                    <div class="flex items-center justify-between gap-3">
                      <span class={[
                        "rounded-full border px-2 py-1 text-[9px] font-bold uppercase tracking-wider",
                        SimHelpers.domain_badge_color(sim.domain_type)
                      ]}>
                        {SimHelpers.domain_label(sim.domain_type)}
                      </span>
                      <span class={[
                        "h-2 w-2 rounded-full",
                        if(sim.sim_id in @running, do: "animate-pulse bg-emerald-300", else: "bg-stone-600")
                      ]}></span>
                    </div>
                    <p class="mt-4 truncate font-mono text-xs font-semibold text-stone-200 group-hover:text-white">{sim.sim_id}</p>
                    <p class="mt-2 truncate text-xs text-stone-500">{sim.world_summary}</p>
                  </button>
                </div>
              <% end %>
            </section>
          </main>
        </div>

        <!-- Sim detail view -->
        <div :if={@selected_sim} class="p-6 md:p-8">
          <!-- Header -->
          <div class="relative mb-8 flex flex-col justify-between gap-5 border-b border-glass-border pb-4 lg:flex-row lg:items-center">
            <div class="absolute bottom-[-1px] left-0 right-0 h-px bg-gradient-to-r from-cyan-500 via-transparent to-transparent opacity-50"></div>
            <div>
              <div class="flex flex-wrap items-center gap-3 sm:gap-4">
                <h1 class="break-all text-2xl font-extrabold tracking-tight text-white sm:text-4xl">{@selected_sim.sim_id}</h1>
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
            <div class="flex flex-wrap justify-end gap-3">
              <a
                :if={public_watch_supported?(@domain_type)}
                href={~p"/watch/#{@selected_sim.sim_id}"}
                target="_blank"
                rel="noopener"
                class="inline-flex min-h-11 items-center justify-center rounded-xl border border-white/10 bg-white/[0.035] px-4 text-sm font-semibold text-stone-200 transition hover:border-amber-200/25 hover:text-white"
              >
                Public view ↗
              </a>
              <.button
                :if={@selected_sim.sim_id in @running}
                phx-click="stop_sim"
                phx-value-sim_id={@selected_sim.sim_id}
                class="bg-red-500/10 hover:bg-red-500/20 text-red-500 border border-red-500/30 transition-all font-bold tracking-widest uppercase px-5 py-2.5 rounded shadow-neon-red"
              >
                Stop run
              </.button>
              <.button
                :if={resume_supported?(@domain_type) and @selected_sim.sim_id not in @running and Map.get((@selected_sim && @selected_sim.world) || %{}, :status, Map.get((@selected_sim && @selected_sim.world) || %{}, "status")) == "in_progress"}
                phx-click="resume_sim"
                phx-value-sim_id={@selected_sim.sim_id}
                class="bg-amber-500/10 hover:bg-amber-500/20 text-amber-400 border border-amber-500/30 transition-all font-bold tracking-widest uppercase px-5 py-2.5 rounded shadow-neon-amber"
              >
                Resume Sim
              </.button>
            </div>
          </div>

          <!-- Runner errors banner -->
          <% runner_errors = Map.get((@selected_sim && @selected_sim.world) || %{}, :runner_errors) || Map.get((@selected_sim && @selected_sim.world) || %{}, "runner_errors") || [] %>
          <div :if={runner_errors != []} class="glass-card rounded-lg border border-red-500/30 bg-red-950/20 p-3 mb-4">
            <details>
              <summary class="text-xs font-bold text-red-400 uppercase tracking-widest cursor-pointer hover:text-red-300 flex items-center gap-2">
                <span>Runner Errors ({length(runner_errors)})</span>
                <span class="text-red-500/50 font-normal normal-case tracking-normal">click to expand</span>
              </summary>
              <div class="mt-2 space-y-1 max-h-48 overflow-y-auto">
                <%= for err <- Enum.reverse(runner_errors) do %>
                  <div class="text-[11px] font-mono text-red-300/80 bg-red-950/40 rounded px-2 py-1">
                    <span class="text-red-500/60">{Map.get(err, :at, Map.get(err, "at", ""))}</span>
                    <span class="text-amber-400/70 ml-1">turn={Map.get(err, :turn, Map.get(err, "turn", "?"))}</span>
                    <span class="text-cyan-400/70 ml-1">phase={Map.get(err, :phase, Map.get(err, "phase", "?"))}</span>
                    <span class="text-fuchsia-400/70 ml-1">actor={Map.get(err, :actor, Map.get(err, "actor", "?"))}</span>
                    <br/><span class="text-red-300">{Map.get(err, :message, Map.get(err, "message", ""))}</span>
                  </div>
                <% end %>
              </div>
            </details>
          </div>

          <!-- Board + details layout -->
          <div class="grid grid-cols-1 xl:grid-cols-12 gap-6 items-start">
            <!-- Left: Visual board -->
            <% full_width_board = @domain_type in [:werewolf, :stock_market, :survivor, :space_station, :auction, :diplomacy, :dungeon_crawl, :courtroom, :startup_incubator, :intel_network, :legislature, :pandemic, :murder_mystery, :supply_chain, :vending_bench, :tcg_shop] %>
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
                  <% :tcg_shop -> %>
                    <LemonSimUi.Live.Components.TcgShopBoard.render
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

  defp resume_supported?(:werewolf), do: true
  defp resume_supported?(_domain), do: false

  defp public_watch_supported?(domain) do
    domain in LemonSimUi.SpectatorLive.supported_domains()
  end

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
      %LemonSim.Kernel.State{} = state ->
        state

      %{} = state_map ->
        LemonSim.Kernel.State.new(state_map)

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
  defp player_count_label("tcg_shop"), do: "Operator (1)"
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
  defp min_players("tcg_shop"), do: 1
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
  defp max_players("tcg_shop"), do: 1
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
  defp default_player_count(:tcg_shop), do: 1
  defp default_player_count(_), do: 6

  # -- Model helpers --

  @default_provider :"openai-codex"
  @default_model_id "gpt-5.3-codex-spark"

  defp default_provider, do: @default_provider

  defp provider_options do
    Ai.Models.get_providers()
    |> Enum.map(fn provider ->
      {provider_display_name(provider), to_string(provider)}
    end)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp model_options_for_provider(provider) do
    Ai.Models.get_models(provider)
    |> Enum.map(fn model -> {model.name, model.id} end)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp default_model_for_provider(provider) do
    if provider == @default_provider do
      @default_model_id
    else
      case Ai.Models.get_models(provider) do
        [first | _] -> first.id
        [] -> ""
      end
    end
  end

  defp build_model_specs(params, player_count) do
    for seat <- 1..player_count do
      provider = params["provider_#{seat}"] || to_string(@default_provider)
      model_id = params["model_#{seat}"] || @default_model_id
      "#{provider}:#{model_id}"
    end
  end

  defp provider_display_name(provider) do
    provider
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
