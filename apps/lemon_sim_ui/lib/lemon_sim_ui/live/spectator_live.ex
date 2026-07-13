defmodule LemonSimUi.SpectatorLive do
  @moduledoc """
  Read-only spectator view for watching live AI games.

  Provides a clean, entertainment-focused interface without admin controls,
  raw state dumps, or operational noise. Shows the game board, character
  profiles, and narrative events in real-time for supported domains.
  """

  use LemonSimUi, :live_view

  alias LemonSim.Bench.Domains
  alias LemonSimUi.{ArtifactReader, SimHelpers, SimManager, WerewolfPlayback}
  alias LemonSim.Kernel.{Bus, Event, State, Store}

  alias LemonSimUi.Live.Components.{
    WerewolfBoard,
    VendingBenchBoard,
    TcgShopBoard,
    SpaceStationBoard,
    StockMarketBoard,
    SurvivorBoard,
    PokerBoard,
    RunLog,
    SpectatorChrome
  }

  @vending_bench_artifact_registry Path.join(
                                     System.tmp_dir!(),
                                     "lemon_vending_bench_artifact_registry.json"
                                   )
  @vending_bench_artifact_refresh_ms 5_000
  @usage_refresh_ms 5_000

  # `LemonSim.Bench.Domains.arena_domains/0` covers the five always-on league
  # domains; vending_bench and tcg_shop have no league adapter (not part of
  # the arena) but spectator_live still renders them via their own board
  # components (see `render_board/1` below, the actual board registration
  # point). `domain_registration_test.exs` checks this list stays a superset
  # of the arena ids and stays in sync with `render_board/1`'s case clauses.
  @supported_domains Enum.map(Domains.arena_domains(), &String.to_atom(&1.id)) ++
                       [:vending_bench, :tcg_shop]

  @doc false
  @spec supported_domains() :: [atom()]
  def supported_domains, do: @supported_domains

  # Sim-id prefixes used by SimManager.generate_id/1 / domain_from_sim_id/1,
  # kept here so the "find the next active game" auto-advance logic can match
  # a running sim's domain without touching SimManager. Derived from the
  # same arena registry `LemonSimUi.Arena` uses.
  @domain_sim_id_prefix Map.new(
                          Domains.arena_domains(),
                          &{String.to_atom(&1.id), &1.sim_id_prefix}
                        )

  @impl true
  def mount(%{"sim_id" => sim_id}, _session, socket) do
    {state, artifact_dir} = load_state(sim_id)

    case state do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Simulation not found: #{sim_id}")
         |> assign(
           sim_id: sim_id,
           state: nil,
           domain_type: nil,
           supported: false,
           playback: nil,
           playback_timer_ref: nil,
           artifact_dir: nil,
           usage: nil,
           usage_timer_ref: nil,
           artifact_timer_ref: nil,
           runner_running: false,
           running: false,
           page_title: "Not Found"
         )}

      state ->
        domain_type = SimHelpers.infer_domain_type(state)
        supported = domain_type in @supported_domains

        if connected?(socket) && supported do
          LemonCore.Bus.subscribe(SimManager.lobby_topic())
          Bus.subscribe(sim_id)
        end

        running =
          sim_id in LemonSimUi.SimManager.list_running() or
            (is_binary(artifact_dir) and artifact_running?(state))

        socket =
          socket
          |> assign(
            sim_id: sim_id,
            state: state,
            domain_type: domain_type,
            supported: supported,
            playback: if(domain_type == :werewolf, do: WerewolfPlayback.new(state), else: nil),
            playback_timer_ref: nil,
            artifact_dir: artifact_dir,
            usage: current_usage(sim_id, artifact_dir),
            usage_timer_ref: nil,
            artifact_timer_ref: nil,
            runner_running: running,
            running: running,
            game_over_redirect: false,
            page_title: "Watch: #{sim_id}"
          )
          |> maybe_schedule_artifact_refresh()
          |> maybe_schedule_usage_refresh()

        {:ok, socket}
    end
  end

  @impl true
  def handle_info(
        %LemonCore.Event{type: :sim_world_updated, meta: %{sim_id: sim_id}} = event,
        socket
      ) do
    if socket.assigns[:state] && socket.assigns.sim_id == sim_id do
      case payload_state(event) || Store.get_state(sim_id) do
        nil ->
          {:noreply, socket}

        updated ->
          running = sim_id in LemonSimUi.SimManager.list_running()

          socket =
            socket
            |> assign(runner_running: running)
            |> assign_usage()
            |> queue_werewolf_state(updated)

          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    runner_running = socket.assigns.sim_id in LemonSimUi.SimManager.list_running()

    socket =
      socket
      |> assign(runner_running: runner_running)
      |> sync_broadcast_running()
      |> assign_usage()

    {:noreply, maybe_complete_broadcast(socket)}
  end

  def handle_info({:werewolf_playback_tick, ref}, socket) do
    if socket.assigns[:playback_timer_ref] == ref and socket.assigns[:playback] do
      {playback, _hold_ms} =
        WerewolfPlayback.advance(socket.assigns.playback, System.monotonic_time(:millisecond))

      socket =
        socket
        |> assign(
          state: playback.display_state,
          playback: playback,
          playback_timer_ref: nil
        )
        |> sync_broadcast_running()
        |> maybe_schedule_playback()
        |> maybe_complete_broadcast()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:vending_bench_artifact_refresh, ref}, socket) do
    if socket.assigns[:artifact_timer_ref] == ref and socket.assigns[:artifact_dir] do
      state =
        load_artifact_state_from_dir(socket.assigns.sim_id, socket.assigns.artifact_dir) ||
          socket.assigns.state

      socket =
        socket
        |> assign(
          state: state,
          usage: current_usage(socket.assigns.sim_id, socket.assigns.artifact_dir),
          running:
            socket.assigns.sim_id in LemonSimUi.SimManager.list_running() or
              artifact_running?(state),
          artifact_timer_ref: nil
        )
        |> maybe_schedule_artifact_refresh()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:usage_refresh, ref}, socket) do
    if socket.assigns[:usage_timer_ref] == ref do
      socket =
        socket
        |> assign(usage_timer_ref: nil)
        |> assign_usage()
        |> maybe_schedule_usage_refresh()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen text-slate-200">
      <%= cond do %>
        <% is_nil(@state) -> %>
          <.not_found sim_id={@sim_id} />
        <% !@supported -> %>
          <.not_supported sim_id={@sim_id} domain_type={@domain_type} />
        <% true -> %>
          <%= case @domain_type do %>
            <% :vending_bench -> %>
              <.vending_spectator_view
                state={@state}
                sim_id={@sim_id}
                running={@running}
                usage={@usage}
              />
            <% :tcg_shop -> %>
              <.tcg_shop_spectator_view
                state={@state}
                sim_id={@sim_id}
                running={@running}
                usage={@usage}
              />
            <% :space_station -> %>
              <.space_station_spectator_view
                state={@state}
                sim_id={@sim_id}
                running={@running}
                usage={@usage}
              />
            <% :stock_market -> %>
              <.stock_market_spectator_view
                state={@state}
                sim_id={@sim_id}
                running={@running}
                usage={@usage}
              />
            <% :survivor -> %>
              <.survivor_spectator_view
                state={@state}
                sim_id={@sim_id}
                running={@running}
                usage={@usage}
              />
            <% :poker -> %>
              <.poker_spectator_view
                state={@state}
                sim_id={@sim_id}
                running={@running}
                usage={@usage}
              />
            <% _ -> %>
              <.spectator_view
                state={@state}
                sim_id={@sim_id}
                running={@running}
                runner_running={@runner_running}
                usage={@usage}
              />
          <% end %>
          <div
            :if={@game_over_redirect}
            role="status"
            aria-live="polite"
            class="fixed inset-x-4 bottom-4 z-50 mx-auto flex max-w-xl flex-wrap items-center justify-between gap-3 rounded-2xl border border-stone-100/15 bg-[#11151a]/95 px-5 py-4 shadow-2xl shadow-black/60"
          >
            <div>
              <p class="font-semibold text-white">Broadcast complete</p>
              <p class="text-sm text-stone-400">Waiting for the next arena match.</p>
            </div>
            <.link navigate={~p"/"} class="inline-flex min-h-11 items-center rounded-full border border-stone-500/40 px-4 text-sm font-semibold text-stone-200 hover:border-amber-300/50 hover:text-amber-200">
              Back to lobby
            </.link>
          </div>
      <% end %>
    </div>
    """
  end

  # -- Not found --

  attr(:sim_id, :string, required: true)

  defp not_found(assigns) do
    ~H"""
    <div class="flex items-center justify-center h-screen">
      <div class="text-center glass-panel p-12 rounded-2xl max-w-md">
        <div class="text-6xl mb-6 opacity-50">&#x1F50D;</div>
        <h2 class="text-2xl font-bold text-white mb-3">Simulation Not Found</h2>
        <p class="text-slate-400 font-mono text-sm">
          No active simulation with ID <span class="text-cyan-400">{@sim_id}</span>
        </p>
        <a href="/" class="inline-block mt-6 glass-button px-6 py-2 rounded-lg text-sm">
          Back to Dashboard
        </a>
      </div>
    </div>
    """
  end

  # -- Not supported --

  attr(:sim_id, :string, required: true)
  attr(:domain_type, :atom, required: true)

  defp not_supported(assigns) do
    ~H"""
    <div class="flex items-center justify-center h-screen">
      <div class="text-center glass-panel p-12 rounded-2xl max-w-md">
        <div class="text-6xl mb-6 opacity-50">&#x1F3AE;</div>
        <h2 class="text-2xl font-bold text-white mb-3">Spectator Mode Unavailable</h2>
        <p class="text-slate-400 font-mono text-sm mb-2">
          <span class="text-cyan-400">{@sim_id}</span> is a
          <span class="text-fuchsia-400">{SimHelpers.domain_label(@domain_type)}</span> simulation.
        </p>
        <p class="text-slate-500 text-sm">
          Spectator mode is currently available for Werewolf, VendingBench, TCG Shop, Space
          Station, Stock Market, Survivor, and Poker games.
        </p>
        <a href="/" class="inline-block mt-6 glass-button px-6 py-2 rounded-lg text-sm">
          Back to Dashboard
        </a>
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)
  attr(:usage, :map, default: nil)

  defp vending_spectator_view(assigns) do
    world = vending_display_world(assigns.state.world)
    day_number = LemonCore.MapHelpers.get_key(world, :day_number) || 1
    max_days = LemonCore.MapHelpers.get_key(world, :max_days) || 30
    phase = LemonCore.MapHelpers.get_key(world, :phase) || "operating"

    assigns =
      assigns
      |> assign(:day_number, day_number)
      |> assign(:max_days, max_days)
      |> assign(:phase, phase)

    ~H"""
    <div class="flex flex-col min-h-screen bg-[#0a0f0d] text-slate-200">
      <SpectatorChrome.page_header
        sim_id={@sim_id}
        border_class="border-emerald-900/60"
        bg_class="bg-slate-950/70"
        hover_class="hover:text-emerald-400"
        running={@running}
      >
        <:meta>
          <SpectatorChrome.meta_line
            label="VendingBench"
            label_class="text-emerald-400"
            progress={"Day #{@day_number}/#{@max_days}"}
            phase={format_phase(@phase)}
          />
        </:meta>
      </SpectatorChrome.page_header>

      <div class="flex-1 overflow-y-auto overflow-x-hidden" style="scrollbar-gutter: stable;">
        <.render_board domain={:vending_bench} world={@state.world} />
        <.usage_panel usage={@usage} />
        <RunLog.render state={@state} running={@running} />
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)
  attr(:usage, :map, default: nil)

  defp tcg_shop_spectator_view(assigns) do
    day_number = LemonCore.MapHelpers.get_key(assigns.state.world, :day_number) || 1
    max_days = LemonCore.MapHelpers.get_key(assigns.state.world, :max_days) || 14
    phase = LemonCore.MapHelpers.get_key(assigns.state.world, :phase) || "operator_turn"

    assigns =
      assigns
      |> assign(:day_number, day_number)
      |> assign(:max_days, max_days)
      |> assign(:phase, phase)

    ~H"""
    <div class="flex flex-col min-h-screen bg-[#100d08] text-slate-200">
      <SpectatorChrome.page_header
        sim_id={@sim_id}
        border_class="border-amber-900/60"
        bg_class="bg-slate-950/75"
        hover_class="hover:text-amber-300"
        running={@running}
      >
        <:meta>
          <SpectatorChrome.meta_line
            label="TCG Shop"
            label_class="text-amber-300"
            progress={"Day #{@day_number}/#{@max_days}"}
            phase={format_phase(@phase)}
          />
        </:meta>
      </SpectatorChrome.page_header>

      <div class="flex-1 overflow-y-auto overflow-x-hidden p-4" style="scrollbar-gutter: stable;">
        <.render_board domain={:tcg_shop} world={@state.world} />
        <.usage_panel usage={@usage} />
        <RunLog.render state={@state} running={@running} />
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)
  attr(:usage, :map, default: nil)

  defp space_station_spectator_view(assigns) do
    world = assigns.state.world
    round = LemonCore.MapHelpers.get_key(world, :round) || 1
    max_rounds = LemonCore.MapHelpers.get_key(world, :max_rounds) || 8
    phase = LemonCore.MapHelpers.get_key(world, :phase) || "action"
    status = LemonCore.MapHelpers.get_key(world, :status) || "in_progress"
    winner = LemonCore.MapHelpers.get_key(world, :winner)

    assigns =
      assigns
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:phase, phase)
      |> assign(:game_status, status)
      |> assign(:winner, winner)

    ~H"""
    <div class="flex flex-col h-screen overflow-hidden bg-[#050b14] text-slate-200">
      <SpectatorChrome.page_header
        sim_id={@sim_id}
        border_class="border-cyan-900/50"
        bg_class="bg-slate-950/70"
        hover_class="hover:text-cyan-400"
        league_path="/arena/space_station/leaderboard"
        winner={@winner}
        running={@running}
        show_stopped={@game_status != "game_over"}
      >
        <:meta>
          <SpectatorChrome.meta_line
            label="Space Station"
            label_class="text-cyan-400"
            progress={"Round #{@round}/#{@max_rounds}"}
            phase={format_phase(@phase)}
          />
        </:meta>
      </SpectatorChrome.page_header>

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex-1 overflow-hidden">
          <.render_board domain={:space_station} world={@state.world} />
        </div>

        <.usage_panel usage={@usage} />

        <SpectatorChrome.live_feed_panel
          events={@state.recent_events}
          wrapper_class="flex-shrink-0 border-t border-glass-border bg-slate-950/60 h-48 overflow-hidden"
        />
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)
  attr(:usage, :map, default: nil)

  defp stock_market_spectator_view(assigns) do
    world = assigns.state.world
    round = LemonCore.MapHelpers.get_key(world, :round) || 1
    max_rounds = LemonCore.MapHelpers.get_key(world, :max_rounds) || 10
    phase = LemonCore.MapHelpers.get_key(world, :phase) || "discussion"
    status = LemonCore.MapHelpers.get_key(world, :status) || "in_progress"
    winner = LemonCore.MapHelpers.get_key(world, :winner)

    assigns =
      assigns
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:phase, phase)
      |> assign(:game_status, status)
      |> assign(:winner, winner)

    ~H"""
    <div class="flex flex-col h-screen overflow-hidden bg-[#0a0e1a] text-slate-200">
      <SpectatorChrome.page_header
        sim_id={@sim_id}
        border_class="border-emerald-900/50"
        bg_class="bg-slate-950/70"
        hover_class="hover:text-emerald-400"
        league_path="/arena/stock_market/leaderboard"
        winner={@winner}
        running={@running}
        show_stopped={@game_status != "game_over"}
      >
        <:meta>
          <SpectatorChrome.meta_line
            label="Stock Market"
            label_class="text-emerald-400"
            progress={"Round #{@round}/#{@max_rounds}"}
            phase={format_phase(@phase)}
          />
        </:meta>
      </SpectatorChrome.page_header>

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex-1 overflow-hidden">
          <.render_board domain={:stock_market} world={@state.world} />
        </div>

        <.usage_panel usage={@usage} />

        <SpectatorChrome.live_feed_panel
          events={@state.recent_events}
          wrapper_class="flex-shrink-0 border-t border-glass-border bg-slate-950/60 h-48 overflow-hidden"
        />
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)
  attr(:usage, :map, default: nil)

  defp survivor_spectator_view(assigns) do
    world = assigns.state.world
    episode = LemonCore.MapHelpers.get_key(world, :episode) || 1
    phase = LemonCore.MapHelpers.get_key(world, :phase) || "challenge"
    status = LemonCore.MapHelpers.get_key(world, :status) || "in_progress"
    winner = LemonCore.MapHelpers.get_key(world, :winner)

    assigns =
      assigns
      |> assign(:episode, episode)
      |> assign(:phase, phase)
      |> assign(:game_status, status)
      |> assign(:winner, winner)

    ~H"""
    <div class="flex flex-col h-screen overflow-hidden bg-[#0a0805] text-slate-200">
      <SpectatorChrome.page_header
        sim_id={@sim_id}
        border_class="border-amber-900/50"
        bg_class="bg-slate-950/70"
        hover_class="hover:text-amber-300"
        league_path="/arena/survivor/leaderboard"
        winner={@winner}
        running={@running}
        show_stopped={@game_status != "game_over"}
      >
        <:meta>
          <SpectatorChrome.meta_line
            label="Survivor"
            label_class="text-amber-400"
            progress={"Episode #{@episode}"}
            phase={format_phase(@phase)}
          />
        </:meta>
      </SpectatorChrome.page_header>

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex-1 overflow-hidden">
          <.render_board domain={:survivor} world={@state.world} />
        </div>

        <.usage_panel usage={@usage} />

        <SpectatorChrome.live_feed_panel
          events={@state.recent_events}
          wrapper_class="flex-shrink-0 border-t border-glass-border bg-slate-950/60 h-48 overflow-hidden"
        />
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)
  attr(:usage, :map, default: nil)

  defp poker_spectator_view(assigns) do
    world = assigns.state.world
    table = LemonCore.MapHelpers.get_key(world, :table)
    hand = table && LemonCore.MapHelpers.get_key(table, :hand)
    street = hand && LemonCore.MapHelpers.get_key(hand, :street)
    completed_hands = LemonCore.MapHelpers.get_key(world, :completed_hands) || 0
    max_hands = LemonCore.MapHelpers.get_key(world, :max_hands) || 1
    status = LemonCore.MapHelpers.get_key(world, :status) || "in_progress"
    winner = LemonCore.MapHelpers.get_key(world, :winner)

    hand_label =
      if status == "game_over" do
        "Complete"
      else
        "Hand #{completed_hands + 1}/#{max_hands}"
      end

    assigns =
      assigns
      |> assign(:hand_label, hand_label)
      |> assign(:street, street)
      |> assign(:game_status, status)
      |> assign(:winner, winner)

    ~H"""
    <div class="flex flex-col min-h-screen bg-[#05130d] text-slate-200">
      <SpectatorChrome.page_header
        sim_id={@sim_id}
        border_class="border-emerald-900/50"
        bg_class="bg-slate-950/70"
        hover_class="hover:text-emerald-400"
        league_path="/arena/poker/leaderboard"
        winner={@winner}
        running={@running}
        show_stopped={@game_status != "game_over"}
      >
        <:meta>
          <SpectatorChrome.meta_line label="Poker" label_class="text-emerald-400" progress={@hand_label}>
            <:extra :if={@street}>
              <span class="text-slate-600">|</span>
              <span class="capitalize">{format_phase(to_string(@street))}</span>
            </:extra>
          </SpectatorChrome.meta_line>
        </:meta>
      </SpectatorChrome.page_header>

      <div class="flex-1 overflow-y-auto overflow-x-hidden" style="scrollbar-gutter: stable;">
        <.render_board domain={:poker} world={@state.world} />
        <.usage_panel usage={@usage} />

        <SpectatorChrome.live_feed_panel
          events={@state.recent_events}
          wrapper_class="border-t border-glass-border bg-slate-950/60"
          body_class="h-48"
        />
      </div>
    </div>
    """
  end

  # -- Main spectator view --

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)
  attr(:runner_running, :boolean, required: true)
  attr(:usage, :map, default: nil)

  defp spectator_view(assigns) do
    world = assigns.state.world
    phase = LemonCore.MapHelpers.get_key(world, :phase) || "unknown"
    day_number = LemonCore.MapHelpers.get_key(world, :day_number) || 1
    status = LemonCore.MapHelpers.get_key(world, :status) || "in_progress"
    winner = LemonCore.MapHelpers.get_key(world, :winner)

    assigns =
      assigns
      |> assign(:phase, phase)
      |> assign(:day_number, day_number)
      |> assign(:game_status, status)
      |> assign(:winner, winner)

    ~H"""
    <a
      href="#werewolf-story"
      class="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[100] focus:rounded-lg focus:bg-slate-950 focus:px-4 focus:py-3 focus:text-white"
    >
      Skip to live story
    </a>
    <div class="min-h-screen bg-[#080a0d] text-stone-100">
      <header class="relative isolate overflow-hidden border-b border-amber-100/10 bg-[#0d1014]">
        <img
          src={if String.contains?(@phase, "night") || @phase == "wolf_discussion", do: "/assets/werewolf/night_bg.png", else: "/assets/werewolf/day_bg.png"}
          alt=""
          aria-hidden="true"
          class="absolute inset-0 -z-20 h-full w-full object-cover opacity-20"
        />
        <div class="absolute inset-0 -z-10 bg-gradient-to-r from-[#090b0f] via-[#090b0f]/95 to-[#090b0f]/70"></div>

        <div class="mx-auto flex max-w-[90rem] flex-col gap-5 px-4 py-5 sm:px-6 lg:flex-row lg:items-center lg:justify-between lg:px-8">
          <div class="flex items-start gap-4">
            <.link
              navigate={~p"/"}
              class="inline-flex min-h-11 items-center rounded-full border border-stone-500/30 bg-black/20 px-4 text-sm font-semibold text-stone-200 transition hover:border-amber-300/50 hover:text-amber-200"
            >
              Lobby
            </.link>
            <div>
              <p class="mb-1 text-xs font-bold uppercase tracking-[0.22em] text-amber-300/80">
                LemonSim live arena
              </p>
              <h1 class="font-display text-3xl font-semibold tracking-tight text-white sm:text-4xl">
                Werewolf
              </h1>
              <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-stone-400">
                <span>Match <code class="text-stone-300">{@sim_id}</code></span>
                <span aria-hidden="true">·</span>
                <span class="inline-flex items-center gap-1.5 text-violet-200">
                  <span aria-hidden="true">◉</span> Omniscient broadcast
                </span>
              </div>
            </div>
          </div>

          <nav aria-label="Broadcast navigation" class="flex flex-wrap items-center gap-3">
            <.link
              navigate={~p"/arena/werewolf/leaderboard"}
              class="inline-flex min-h-11 items-center rounded-full border border-stone-500/30 bg-black/20 px-4 text-sm font-semibold text-stone-200 transition hover:border-amber-300/50 hover:text-amber-200"
            >
              League standings
            </.link>
            <div
              role="status"
              aria-live="polite"
              aria-atomic="true"
              class={[
                "inline-flex min-h-11 items-center gap-2 rounded-full border px-4 text-sm font-bold",
                cond do
                  @runner_running -> "border-red-400/35 bg-red-950/40 text-red-200"
                  @running -> "border-amber-300/35 bg-amber-950/40 text-amber-100"
                  true -> "border-stone-500/30 bg-stone-900/60 text-stone-300"
                end
              ]}
            >
              <span
                aria-hidden="true"
                class={[
                  "h-2.5 w-2.5 rounded-full",
                  cond do
                    @runner_running -> "animate-pulse bg-red-400"
                    @running -> "bg-amber-300"
                    true -> "bg-stone-500"
                  end
                ]}
              ></span>
              <%= cond do %>
                <% @runner_running -> %> LIVE
                <% @running -> %> PLAYBACK
                <% true -> %> STOPPED
              <% end %>
              <span class="font-normal text-current/70">
                · Day {@day_number} · {format_phase(@phase)}
              </span>
            </div>
          </nav>
        </div>
      </header>

      <main id="werewolf-game" class="mx-auto max-w-[90rem] px-3 py-4 sm:px-6 sm:py-7 lg:px-8">
        <section
          aria-label="Werewolf game broadcast"
          class="overflow-hidden rounded-[2rem] border border-stone-100/10 bg-[#0d1014] shadow-2xl shadow-black/40"
        >
          <.render_board domain={:werewolf} world={@state.world} running={@running} />
        </section>

        <details class="group mt-5 rounded-2xl border border-stone-100/10 bg-[#0d1014]">
          <summary class="flex min-h-12 cursor-pointer items-center justify-between px-5 py-3 text-sm font-semibold text-stone-300 hover:text-white">
            Run details
            <span aria-hidden="true" class="transition group-open:rotate-180">⌄</span>
          </summary>
          <div class="border-t border-stone-100/10 pb-4">
            <.usage_panel usage={@usage} />
            <SpectatorChrome.live_feed_panel
              events={@state.recent_events}
              wrapper_class="border-t border-glass-border bg-slate-950/60"
              body_class="h-64"
            />
          </div>
        </details>
      </main>
    </div>
    """
  end

  attr(:usage, :map, default: nil)

  defp usage_panel(%{usage: nil} = assigns), do: ~H""

  defp usage_panel(assigns) do
    totals = usage_value(assigns.usage, :totals) || %{}
    actors = usage_value(assigns.usage, :actors) || %{}

    assigns =
      assigns
      |> assign(:totals, totals)
      |> assign(:actors, Enum.sort_by(actors, fn {actor_id, _usage} -> actor_id end))

    ~H"""
    <section id="usage-panel" class="mx-4 my-4 glass-panel rounded-xl border border-glass-border p-4">
      <div class="flex flex-col md:flex-row md:items-start md:justify-between gap-4 mb-4">
        <div>
          <h2 class="text-sm font-bold uppercase tracking-widest text-cyan-300">Usage</h2>
          <p class="text-xs font-mono text-slate-500 mt-1">
            {ArtifactReader.format_integer(ArtifactReader.total_tokens(@totals))} tokens
          </p>
        </div>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-right">
          <div>
            <div class="text-[10px] uppercase tracking-widest text-slate-500 font-bold">Input</div>
            <div class="text-sm font-mono text-slate-200">{ArtifactReader.format_integer(usage_value(@totals, :input_tokens) || 0)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-widest text-slate-500 font-bold">Output</div>
            <div class="text-sm font-mono text-slate-200">{ArtifactReader.format_integer(usage_value(@totals, :output_tokens) || 0)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-widest text-slate-500 font-bold">Decisions</div>
            <div class="text-sm font-mono text-slate-200">{ArtifactReader.format_integer(usage_value(@totals, :decisions) || 0)}</div>
          </div>
          <div>
            <div class="text-[10px] uppercase tracking-widest text-slate-500 font-bold">Cost</div>
            <div class="text-sm font-mono text-slate-200">{ArtifactReader.format_cost(usage_value(@totals, :cost_usd))}</div>
          </div>
        </div>
      </div>

      <div :if={@actors != []} class="overflow-x-auto">
        <table class="min-w-full text-xs">
          <thead class="text-slate-500 uppercase tracking-widest font-mono">
            <tr>
              <th class="py-2 pr-4 text-left">Actor</th>
              <th class="py-2 pr-4 text-left">Model</th>
              <th class="py-2 pr-4 text-right">Input</th>
              <th class="py-2 pr-4 text-right">Output</th>
              <th class="py-2 pr-4 text-right">Tokens</th>
              <th class="py-2 pr-4 text-right">Cost</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-glass-border">
            <%= for {actor_id, actor_usage} <- @actors do %>
              <tr>
                <td class="py-2 pr-4 font-bold text-white">{actor_id}</td>
                <td class="py-2 pr-4 font-mono text-slate-400">{usage_value(actor_usage, :model_id) || "unknown"}</td>
                <td class="py-2 pr-4 text-right font-mono text-slate-300">{ArtifactReader.format_integer(usage_value(actor_usage, :input_tokens) || 0)}</td>
                <td class="py-2 pr-4 text-right font-mono text-slate-300">{ArtifactReader.format_integer(usage_value(actor_usage, :output_tokens) || 0)}</td>
                <td class="py-2 pr-4 text-right font-mono text-slate-300">{ArtifactReader.format_integer(ArtifactReader.total_tokens(actor_usage))}</td>
                <td class="py-2 pr-4 text-right font-mono text-slate-300">{ArtifactReader.format_cost(usage_value(actor_usage, :cost_usd))}</td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # -- Board dispatch --

  # Registration point: maps a supported domain to its board component.
  # Every board shares the `render(world:, interactive:)` signature, so this
  # is the one place a new domain needs a case clause added. Unlike
  # `example_module`/`scorecard_module`/`league_adapter`, a domain's
  # lemon_sim_ui board component isn't modeled in `LemonSim.Bench.Domains`
  # (it's UI-only), so this stays a hardcoded case rather than a derived
  # lookup; `domain_registration_test.exs` checks it stays in sync with
  # `@supported_domains` via `rendered_board_domains/0` below.
  @rendered_board_domains [
    :vending_bench,
    :tcg_shop,
    :space_station,
    :stock_market,
    :survivor,
    :poker,
    :werewolf
  ]

  @doc false
  @spec rendered_board_domains() :: [atom()]
  def rendered_board_domains, do: @rendered_board_domains

  attr(:domain, :atom, required: true)
  attr(:world, :map, required: true)
  attr(:running, :boolean, default: true)

  defp render_board(assigns) do
    ~H"""
    <%= case @domain do %>
      <% :vending_bench -> %>
        <VendingBenchBoard.render world={@world} interactive={false} />
      <% :tcg_shop -> %>
        <TcgShopBoard.render world={@world} interactive={false} />
      <% :space_station -> %>
        <SpaceStationBoard.render world={@world} interactive={false} />
      <% :stock_market -> %>
        <StockMarketBoard.render world={@world} interactive={false} />
      <% :survivor -> %>
        <SurvivorBoard.render world={@world} interactive={false} />
      <% :poker -> %>
        <PokerBoard.render world={@world} interactive={false} />
      <% :werewolf -> %>
        <WerewolfBoard.render world={@world} interactive={false} running={@running} />
    <% end %>
    """
  end

  # -- Helpers --

  defp format_phase(phase) when is_binary(phase) do
    phase
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_phase(phase), do: to_string(phase)

  defp usage_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp usage_value(_map, _key), do: nil

  defp vending_display_world(world) do
    case {LemonCore.MapHelpers.get_key(world, :mode),
          LemonCore.MapHelpers.get_key(world, :arena_agents)} do
      {"vending_bench_arena", [leader | _]} ->
        case {LemonCore.MapHelpers.get_key(world, :machine),
              LemonCore.MapHelpers.get_key(leader, :world)} do
          {nil, leader_world} when is_map(leader_world) ->
            leader_world

          {%{} = machine, leader_world} when map_size(machine) == 0 and is_map(leader_world) ->
            leader_world

          _ ->
            world
        end

      _ ->
        world
    end
  end

  defp queue_werewolf_state(socket, updated_state) do
    if socket.assigns.domain_type == :werewolf do
      playback =
        socket.assigns.playback
        |> Kernel.||(WerewolfPlayback.new(socket.assigns.state))
        |> WerewolfPlayback.enqueue(updated_state)

      socket
      |> assign(playback: playback)
      |> sync_broadcast_running()
      |> maybe_schedule_playback()
    else
      assign(socket,
        state: updated_state,
        running: socket.assigns[:runner_running] || false
      )
    end
  end

  defp sync_broadcast_running(socket) do
    playback_pending? =
      socket.assigns[:domain_type] == :werewolf and socket.assigns[:playback] &&
        WerewolfPlayback.queue_depth(socket.assigns.playback) > 0

    assign(socket,
      running: (socket.assigns[:runner_running] || false) or playback_pending?
    )
  end

  defp maybe_complete_broadcast(socket) do
    if !socket.assigns[:running] && socket.assigns[:state] do
      status = LemonCore.MapHelpers.get_key(socket.assigns.state.world, :status)

      if status == "game_over" do
        case find_active_sim(socket.assigns.sim_id, socket.assigns[:domain_type]) do
          nil -> assign(socket, game_over_redirect: true)
          new_sim_id -> push_navigate(socket, to: ~p"/watch/#{new_sim_id}")
        end
      else
        socket
      end
    else
      socket
    end
  end

  defp maybe_schedule_playback(socket) do
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

  defp maybe_schedule_usage_refresh(socket) do
    cond do
      not connected?(socket) ->
        socket

      not socket.assigns[:supported] ->
        socket

      socket.assigns[:usage_timer_ref] != nil ->
        socket

      true ->
        ref = make_ref()
        Process.send_after(self(), {:usage_refresh, ref}, @usage_refresh_ms)
        assign(socket, usage_timer_ref: ref)
    end
  end

  defp assign_usage(socket) do
    assign(socket, usage: current_usage(socket.assigns.sim_id, socket.assigns[:artifact_dir]))
  end

  defp current_usage(sim_id, artifact_dir) do
    SimManager.usage(sim_id) || ArtifactReader.read_usage(artifact_dir)
  end

  # Finds another running sim in the same domain as `exclude_sim_id` to
  # auto-navigate to once the current game is over. Matches by sim-id prefix
  # (see SimManager.generate_id/1 / domain_from_sim_id/1) rather than
  # re-inferring the domain from world shape, since the prior game's world may
  # already be in a terminal/atypical shape.
  defp find_active_sim(exclude_sim_id, domain_type) do
    case Map.get(@domain_sim_id_prefix, domain_type) do
      nil ->
        nil

      prefix ->
        LemonSimUi.SimManager.list_running()
        |> Enum.find(fn sim_id ->
          sim_id != exclude_sim_id and String.starts_with?(sim_id, prefix)
        end)
    end
  end

  defp load_state(sim_id) do
    case load_artifact_state(sim_id) do
      {%State{}, _artifact_dir} = artifact_state ->
        artifact_state

      _ ->
        case Store.get_state(sim_id) do
          nil -> {nil, nil}
          %State{} = state -> {state, nil}
        end
    end
  end

  defp load_artifact_state(sim_id) do
    with artifact_dir when is_binary(artifact_dir) <- artifact_dir_for_sim(sim_id),
         %State{} = state <- load_artifact_state_from_dir(sim_id, artifact_dir) do
      {state, artifact_dir}
    else
      _ -> {nil, nil}
    end
  end

  defp artifact_dir_for_sim(sim_id) do
    with {:ok, body} <- File.read(@vending_bench_artifact_registry),
         {:ok, registry} when is_map(registry) <- Jason.decode(body),
         artifact_dir when is_binary(artifact_dir) <- Map.get(registry, sim_id),
         true <- File.exists?(Path.join(artifact_dir, "final_world.json")) do
      artifact_dir
    else
      _ -> nil
    end
  end

  defp load_artifact_state_from_dir(sim_id, artifact_dir) do
    with {:ok, body} <- File.read(Path.join(artifact_dir, "final_world.json")),
         {:ok, world} when is_map(world) <- Jason.decode(body) do
      State.new(
        sim_id: sim_id,
        world: world,
        recent_events: recent_artifact_events(artifact_dir),
        meta: %{artifact_dir: artifact_dir}
      )
    else
      _ -> nil
    end
  end

  defp recent_artifact_events(artifact_dir) do
    event_path =
      ["events.jsonl", "arena_events.jsonl"]
      |> Enum.map(&Path.join(artifact_dir, &1))
      |> Enum.find(&File.exists?/1)

    case event_path && File.read(event_path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.take(-25)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, event} -> [Event.new(event)]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp maybe_schedule_artifact_refresh(socket) do
    if connected?(socket) && socket.assigns[:artifact_dir] &&
         artifact_running?(socket.assigns.state) do
      ref = make_ref()

      Process.send_after(
        self(),
        {:vending_bench_artifact_refresh, ref},
        @vending_bench_artifact_refresh_ms
      )

      assign(socket, artifact_timer_ref: ref)
    else
      socket
    end
  end

  defp artifact_running?(%State{} = state) do
    LemonCore.MapHelpers.get_key(state.world, :status) == "in_progress"
  end

  defp artifact_running?(_state), do: false

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
end
