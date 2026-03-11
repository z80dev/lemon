defmodule LemonSimUi.SimDashboardLive do
  use LemonSimUi, :live_view

  alias LemonSimUi.{SimHelpers, SimManager}
  alias LemonSim.{Store, Bus}
  alias LemonSim.Examples.Skirmish

  alias LemonSimUi.Live.Components.{
    TicTacToeBoard,
    SkirmishBoard,
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
       domain_type: nil,
       show_new_sim_form: false,
       new_sim_domain: "tic_tac_toe",
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

    case Store.get_state(sim_id) do
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

  def handle_event("change_domain", %{"domain" => domain}, socket) do
    {:noreply, assign(socket, new_sim_domain: domain)}
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
      end

    case SimManager.start_sim(domain, opts) do
      {:ok, sim_id} ->
        {:noreply,
         socket
         |> assign(show_new_sim_form: false, human_player: opts[:human_player])
         |> push_patch(to: ~p"/sims/#{sim_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start sim: #{inspect(reason)}")}
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
  def handle_info(%LemonCore.Event{type: :sim_world_updated, meta: %{sim_id: sim_id}}, socket) do
    if socket.assigns[:selected_sim] && socket.assigns.selected_sim.sim_id == sim_id do
      case Store.get_state(sim_id) do
        nil ->
          {:noreply, socket}

        updated ->
          {:noreply, assign(socket, selected_sim: updated)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    {:noreply, assign(socket, sims: build_sim_list(), running: SimManager.list_running())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <!-- Sidebar -->
      <aside class="w-80 bg-gray-900 border-r border-gray-800 flex flex-col flex-shrink-0 shadow-lg z-10">
        <div class="p-6 border-b border-gray-800 flex items-center gap-3">
          <div class="w-8 h-8 rounded bg-gradient-to-br from-yellow-400 to-orange-500 flex items-center justify-center text-gray-900 font-bold text-lg">
            L
          </div>
          <div>
            <button phx-click="go_home" class="text-xl font-bold text-white hover:text-yellow-400 transition tracking-tight">
              LemonSim
            </button>
            <p class="text-xs text-gray-400 mt-0.5">{length(@sims)} simulations active</p>
          </div>
        </div>

        <div class="p-4 border-b border-gray-800/50">
          <button phx-click="toggle_new_sim_form" class="w-full bg-blue-600 hover:bg-blue-500 text-white font-medium py-2.5 px-4 rounded-lg transition-all shadow-sm flex items-center justify-center gap-2">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M10 3a1 1 0 011 1v5h5a1 1 0 110 2h-5v5a1 1 0 11-2 0v-5H4a1 1 0 110-2h5V4a1 1 0 011-1z" clip-rule="evenodd" />
            </svg>
            New Simulation
          </button>
        </div>

        <nav class="flex-1 overflow-y-auto p-3 space-y-1.5 custom-scrollbar">
          <%= for sim <- @sims do %>
            <button
              phx-click="select_sim"
              phx-value-sim_id={sim.sim_id}
              class={[
                "w-full text-left p-3 rounded-xl transition-all border border-transparent group relative overflow-hidden",
                if(@selected_sim && @selected_sim.sim_id == sim.sim_id,
                  do: "bg-gray-800 border-gray-700 shadow-md",
                  else: "hover:bg-gray-800/50 hover:border-gray-800"
                )
              ]}
            >
              <div class="flex items-center justify-between mb-2">
                <span class="font-mono text-xs font-semibold text-gray-200 truncate pr-2">{sim.sim_id}</span>
                <span class={[
                  "text-[10px] font-medium px-2 py-0.5 rounded-full whitespace-nowrap",
                  SimHelpers.domain_badge_color(sim.domain_type)
                ]}>
                  {SimHelpers.domain_label(sim.domain_type)}
                </span>
              </div>
              <div class="flex items-center justify-between mt-1.5">
                <span class={[
                  "text-xs font-medium flex items-center gap-1.5", 
                  SimHelpers.status_color(sim.status)
                ]}>
                  <%= if sim.sim_id in @running do %>
                    <span class="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse"></span>
                    Active
                  <% else %>
                    <span class="w-1.5 h-1.5 rounded-full bg-gray-500"></span>
                    {sim.status}
                  <% end %>
                </span>
                <span class="text-[10px] font-mono text-gray-500 bg-gray-950 px-1.5 py-0.5 rounded">v{sim.version}</span>
              </div>
              
              <div class="mt-2 text-xs text-gray-400 truncate opacity-80 group-hover:opacity-100 transition-opacity">
                {sim.world_summary}
              </div>
              
              <%= if @selected_sim && @selected_sim.sim_id == sim.sim_id do %>
                <div class="absolute left-0 top-0 bottom-0 w-1 bg-blue-500 rounded-l-xl"></div>
              <% end %>
            </button>
          <% end %>
        </nav>
      </aside>

      <!-- Main content -->
      <main class="flex-1 overflow-y-auto bg-gray-950">
        <!-- New Sim Form Modal -->
        <div :if={@show_new_sim_form} class="fixed inset-0 bg-black/80 backdrop-blur-sm z-50 flex items-center justify-center p-4">
          <div class="bg-gray-900 border border-gray-700 rounded-2xl w-full max-w-md shadow-2xl overflow-hidden">
            <div class="bg-gray-800/50 p-5 border-b border-gray-800 flex items-center justify-between">
              <h2 class="text-xl font-bold text-white flex items-center gap-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 text-blue-500" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M10 3a1 1 0 011 1v5h5a1 1 0 110 2h-5v5a1 1 0 11-2 0v-5H4a1 1 0 110-2h5V4a1 1 0 011-1z" clip-rule="evenodd" />
                </svg>
                New Simulation
              </h2>
              <button phx-click="toggle_new_sim_form" class="text-gray-500 hover:text-white transition-colors w-8 h-8 flex items-center justify-center rounded-full hover:bg-gray-800">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
                </svg>
              </button>
            </div>

            <form phx-submit="start_sim" class="p-6 space-y-5">
              <div class="space-y-4">
                <.select
                  name="domain"
                  label="Domain"
                  value={@new_sim_domain}
                  options={[{"Tic Tac Toe", "tic_tac_toe"}, {"Skirmish", "skirmish"}]}
                  phx-change="change_domain"
                />

                <.input name="sim_id" label="Sim ID (leave blank for auto)" value="" placeholder="auto-generated" />

                <div class="p-4 bg-gray-950/50 rounded-lg border border-gray-800/50 space-y-4">
                  <h4 class="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-2">Domain Settings</h4>
                  <%= if @new_sim_domain == "tic_tac_toe" do %>
                    <.select
                      name="human_player"
                      label="Player Mode"
                      value=""
                      options={[{"AI vs AI", ""}, {"Play as X", "X"}, {"Play as O", "O"}]}
                    />
                    <.input name="max_turns" label="Max Turns" type="number" value="20" />
                  <% else %>
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
                  <% end %>
                </div>
              </div>

              <input type="hidden" name="domain" value={@new_sim_domain} />

              <div class="flex gap-3 pt-2">
                <button type="submit" class="flex-1 bg-blue-600 hover:bg-blue-500 text-white font-medium py-2.5 px-4 rounded-lg transition-all shadow-sm">
                  Start Simulation
                </button>
                <button type="button" phx-click="toggle_new_sim_form" class="flex-1 bg-gray-800 hover:bg-gray-700 text-gray-300 font-medium py-2.5 px-4 rounded-lg transition-all">
                  Cancel
                </button>
              </div>
            </form>
          </div>
        </div>

        <!-- Empty state -->
        <div :if={is_nil(@selected_sim) && @live_action == :index} class="flex items-center justify-center h-full">
          <div class="text-center bg-gray-900/50 p-12 rounded-2xl border border-gray-800/50 shadow-xl max-w-md w-full">
            <div class="w-24 h-24 bg-gray-800 rounded-full flex items-center justify-center mx-auto mb-6 shadow-inner border border-gray-700">
              <span class="text-5xl opacity-80">&#x1F3AE;</span>
            </div>
            <h2 class="text-2xl font-bold text-white tracking-tight mb-2">Welcome to LemonSim</h2>
            <p class="text-gray-400 mb-8 leading-relaxed">Select an active simulation from the sidebar or start a new one to begin analyzing agent behavior.</p>
            <button phx-click="toggle_new_sim_form" class="bg-blue-600 hover:bg-blue-500 text-white font-medium py-2.5 px-6 rounded-lg transition-all shadow-sm shadow-blue-900/50 inline-flex items-center gap-2">
              Start New Simulation
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M10.293 3.293a1 1 0 011.414 0l6 6a1 1 0 010 1.414l-6 6a1 1 0 01-1.414-1.414L14.586 11H3a1 1 0 110-2h11.586l-4.293-4.293a1 1 0 010-1.414z" clip-rule="evenodd" />
              </svg>
            </button>
          </div>
        </div>

        <!-- Sim detail view -->
        <div :if={@selected_sim} class="p-6">
          <!-- Header -->
          <div class="flex items-center justify-between mb-8 pb-4 border-b border-gray-800">
            <div>
              <div class="flex items-center gap-3">
                <h1 class="text-3xl font-bold text-white tracking-tight">{@selected_sim.sim_id}</h1>
                <span class={[
                  "text-xs px-2.5 py-1 rounded-full font-medium shadow-sm",
                  SimHelpers.domain_badge_color(@domain_type)
                ]}>
                  {SimHelpers.domain_label(@domain_type)}
                </span>
                <span :if={@selected_sim.sim_id in @running} class="text-xs font-semibold px-2 py-1 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 flex items-center gap-1.5">
                  <span class="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse inline-block"></span>
                  Running
                </span>
              </div>
              <p class="text-sm text-gray-400 mt-2 flex items-center gap-2">
                <span class="bg-gray-800 px-2 py-0.5 rounded text-gray-300">v{@selected_sim.version}</span>
                <span class="text-gray-600">&bull;</span>
                <span>{length(@selected_sim.recent_events)} events</span>
              </p>
            </div>
            <div class="flex gap-3">
              <.button
                :if={@selected_sim.sim_id in @running}
                phx-click="stop_sim"
                phx-value-sim_id={@selected_sim.sim_id}
                class="bg-red-500/10 hover:bg-red-500/20 text-red-500 border border-red-500/20 transition-all font-medium px-4 py-2 rounded-lg"
              >
                Stop Simulation
              </.button>
            </div>
          </div>

          <!-- Board + details layout -->
          <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
            <!-- Left: Visual board -->
            <div class="bg-gray-900 rounded-xl p-6 border border-gray-800 shadow-sm flex flex-col h-full">
              <h3 class="text-sm font-semibold text-gray-400 mb-4 uppercase tracking-wider flex items-center gap-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z" clip-rule="evenodd" />
                </svg>
                Simulation View
              </h3>
              <div class="flex-1 flex items-center justify-center bg-gray-950/50 rounded-lg border border-gray-800/50 p-4">
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
                  <% _ -> %>
                    <div class="text-center text-gray-500">
                      <p>Unknown domain type</p>
                      <pre class="text-xs mt-4 text-left overflow-auto max-h-96">{inspect(@selected_sim.world, pretty: true, limit: :infinity)}</pre>
                    </div>
                <% end %>
              </div>
            </div>

            <!-- Right: Event log + Plan history + Memory -->
            <div class="space-y-6">
              <div class="bg-gray-900 rounded-xl border border-gray-800 shadow-sm overflow-hidden flex flex-col h-96">
                <div class="p-4 border-b border-gray-800 bg-gray-900/80">
                  <h3 class="text-sm font-semibold text-gray-400 uppercase tracking-wider flex items-center gap-2">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                      <path fill-rule="evenodd" d="M3 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1z" clip-rule="evenodd" />
                    </svg>
                    Event Log
                  </h3>
                </div>
                <div class="p-0 flex-1 overflow-hidden">
                  <EventLog.render events={@selected_sim.recent_events} />
                </div>
              </div>

              <div class="bg-gray-900 rounded-xl border border-gray-800 shadow-sm overflow-hidden flex flex-col h-80">
                <div class="p-4 border-b border-gray-800 bg-gray-900/80">
                  <h3 class="text-sm font-semibold text-gray-400 uppercase tracking-wider flex items-center gap-2">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm1-12a1 1 0 10-2 0v4a1 1 0 00.293.707l2.828 2.829a1 1 0 101.415-1.415L11 9.586V6z" clip-rule="evenodd" />
                    </svg>
                    Agent Plans
                  </h3>
                </div>
                <div class="p-0 flex-1 overflow-hidden">
                  <PlanHistory.render plan_history={@selected_sim.plan_history} />
                </div>
              </div>

              <div class="bg-gray-900 rounded-xl border border-gray-800 shadow-sm overflow-hidden flex flex-col h-80">
                <div class="p-4 border-b border-gray-800 bg-gray-900/80">
                  <h3 class="text-sm font-semibold text-gray-400 uppercase tracking-wider flex items-center gap-2">
                    <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                      <path d="M9 2a1 1 0 000 2h2a1 1 0 100-2H9z" />
                      <path fill-rule="evenodd" d="M4 5a2 2 0 012-2 3 3 0 003 3h2a3 3 0 003-3 2 2 0 012 2v11a2 2 0 01-2 2H6a2 2 0 01-2-2V5zm3 4a1 1 0 000 2h.01a1 1 0 100-2H7zm3 0a1 1 0 000 2h3a1 1 0 100-2h-3zm-3 4a1 1 0 100 2h.01a1 1 0 100-2H7zm3 0a1 1 0 100 2h3a1 1 0 100-2h-3z" clip-rule="evenodd" />
                    </svg>
                    Agent Memory
                  </h3>
                </div>
                <div class="p-0 flex-1 overflow-hidden">
                  <MemoryViewer.render sim_id={@selected_sim.sim_id} />
                </div>
              </div>

              <!-- Raw world state (collapsed) -->
              <details class="bg-gray-900 rounded-xl border border-gray-800 shadow-sm group">
                <summary class="p-4 text-sm font-semibold text-gray-400 cursor-pointer hover:text-white hover:bg-gray-800/50 transition-colors uppercase tracking-wider flex items-center gap-2">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 transform group-open:rotate-90 transition-transform" viewBox="0 0 20 20" fill="currentColor">
                    <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
                  </svg>
                  Raw State Dump
                </summary>
                <div class="border-t border-gray-800 p-4 bg-gray-950/50">
                  <pre class="text-xs text-gray-500 overflow-auto max-h-96 custom-scrollbar">{inspect(@selected_sim.world, pretty: true, limit: :infinity)}</pre>
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
end
