defmodule LemonSimUi.SpectatorLive do
  @moduledoc """
  Read-only spectator view for watching live AI werewolf games.

  Provides a clean, entertainment-focused interface without admin controls,
  raw state dumps, or operational noise. Shows the game board, character
  profiles, and narrative events in real-time.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{SimHelpers, WerewolfPlayback}
  alias LemonSim.{Store, Bus}

  alias LemonSimUi.Live.Components.{
    WerewolfBoard,
    EventLog
  }

  @impl true
  def mount(%{"sim_id" => sim_id}, _session, socket) do
    state = Store.get_state(sim_id)

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
           running: false,
           page_title: "Not Found"
         )}

      state ->
        domain_type = SimHelpers.infer_domain_type(state)
        supported = domain_type == :werewolf

        if connected?(socket) && supported do
          LemonCore.Bus.subscribe(LemonSimUi.SimManager.lobby_topic())
          Bus.subscribe(sim_id)
        end

        running = sim_id in LemonSimUi.SimManager.list_running()

        {:ok,
         assign(socket,
           sim_id: sim_id,
           state: state,
           domain_type: domain_type,
           supported: supported,
           playback: if(supported, do: WerewolfPlayback.new(state), else: nil),
           playback_timer_ref: nil,
           running: running,
           game_over_redirect: false,
           page_title: "Watch: #{sim_id}"
         )}
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
            |> assign(running: running)
            |> queue_werewolf_state(updated)

          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    running = socket.assigns.sim_id in LemonSimUi.SimManager.list_running()
    socket = assign(socket, running: running)

    # If current game is over and not running, look for a new active werewolf sim
    if !running && socket.assigns[:state] do
      status = LemonCore.MapHelpers.get_key(socket.assigns.state.world, :status)

      if status == "game_over" do
        case find_active_werewolf(socket.assigns.sim_id) do
          nil ->
            {:noreply, assign(socket, game_over_redirect: true)}

          new_sim_id ->
            {:noreply, push_navigate(socket, to: ~p"/watch/#{new_sim_id}")}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
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
        |> maybe_schedule_playback()

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
          <.spectator_view
            state={@state}
            sim_id={@sim_id}
            running={@running}
          />
          <div :if={@game_over_redirect} class="fixed inset-0 bg-slate-950/80 backdrop-blur-sm z-50 flex items-center justify-center">
            <div class="text-center glass-panel p-10 rounded-2xl max-w-md">
              <h2 class="text-2xl font-bold text-white mb-3">Game Over</h2>
              <p class="text-slate-400 font-mono text-sm mb-6">Next game starting soon...</p>
              <a href="/" class="glass-button px-6 py-2 rounded-lg text-sm inline-block">
                Back to Lobby
              </a>
            </div>
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
          Spectator mode is currently only available for Werewolf games.
        </p>
        <a href="/" class="inline-block mt-6 glass-button px-6 py-2 rounded-lg text-sm">
          Back to Dashboard
        </a>
      </div>
    </div>
    """
  end

  # -- Main spectator view --

  attr(:state, :map, required: true)
  attr(:sim_id, :string, required: true)
  attr(:running, :boolean, required: true)

  defp spectator_view(assigns) do
    world = assigns.state.world
    phase = LemonCore.MapHelpers.get_key(world, :phase) || "unknown"
    day_number = LemonCore.MapHelpers.get_key(world, :day_number) || 1
    status = LemonCore.MapHelpers.get_key(world, :status) || "in_progress"
    winner = LemonCore.MapHelpers.get_key(world, :winner)
    character_profiles = LemonCore.MapHelpers.get_key(world, :character_profiles) || %{}
    players = LemonCore.MapHelpers.get_key(world, :players) || %{}

    assigns =
      assigns
      |> assign(:phase, phase)
      |> assign(:day_number, day_number)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:character_profiles, character_profiles)
      |> assign(:players, players)

    ~H"""
    <div class="flex flex-col h-screen overflow-hidden">
      <%!-- Header bar --%>
      <header class="flex items-center justify-between px-6 py-3 border-b border-glass-border bg-slate-900/60 backdrop-blur-md flex-shrink-0">
        <div class="flex items-center gap-4">
          <a href="/" class="text-slate-500 hover:text-cyan-400 transition-colors" title="Back to dashboard">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
              <path fill-rule="evenodd" d="M9.707 16.707a1 1 0 01-1.414 0l-6-6a1 1 0 010-1.414l6-6a1 1 0 011.414 1.414L5.414 9H17a1 1 0 110 2H5.414l4.293 4.293a1 1 0 010 1.414z" clip-rule="evenodd" />
            </svg>
          </a>
          <div>
            <h1 class="text-xl font-bold text-white tracking-tight">{@sim_id}</h1>
            <div class="flex items-center gap-2 text-xs font-mono text-slate-400">
              <span class="text-fuchsia-400">Werewolf</span>
              <span class="text-slate-600">|</span>
              <span>Day {@day_number}</span>
              <span class="text-slate-600">|</span>
              <span class="capitalize">{format_phase(@phase)}</span>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <%= if @winner do %>
            <span class="text-sm font-bold px-3 py-1.5 rounded bg-amber-500/10 text-amber-400 border border-amber-500/30">
              Winner: {@winner}
            </span>
          <% end %>
          <span :if={@running} class="text-[11px] font-bold tracking-widest uppercase px-3 py-1.5 rounded-sm bg-red-500/10 text-red-400 border border-red-500/30 flex items-center gap-2 shadow-[0_0_10px_rgba(239,68,68,0.2)]">
            <span class="w-2 h-2 rounded-full bg-red-500 animate-pulse shadow-[0_0_8px_rgba(239,68,68,0.8)]"></span>
            LIVE
          </span>
          <span :if={!@running && !@winner} class="text-[11px] font-mono text-slate-500 px-3 py-1.5 rounded border border-slate-700">
            STOPPED
          </span>
        </div>
      </header>

      <%!-- Main content --%>
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Game board (full width) --%>
        <div class="flex-1 overflow-hidden">
          <WerewolfBoard.render
            world={@state.world}
            interactive={false}
          />
        </div>

        <%!-- Character bio strip --%>
        <div :if={map_size(@character_profiles) > 0} class="flex-shrink-0 border-t border-glass-border bg-slate-900/40 backdrop-blur-md">
          <div class="px-4 py-2">
            <div class="text-[9px] font-mono uppercase tracking-widest text-fuchsia-400 font-bold mb-2 flex items-center gap-1.5">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
                <path d="M9 6a3 3 0 11-6 0 3 3 0 016 0zM17 6a3 3 0 11-6 0 3 3 0 016 0zM12.93 17c.046-.327.07-.66.07-1a6.97 6.97 0 00-1.5-4.33A5 5 0 0119 16v1h-6.07zM6 11a5 5 0 015 5v1H1v-1a5 5 0 015-5z" />
              </svg>
              VILLAGERS
            </div>
            <div class="flex gap-3 overflow-x-auto pb-2 custom-scrollbar">
              <%= for {player_id, player} <- Enum.sort_by(@players, fn {id, _} -> id end) do %>
                <% profile = Map.get(@character_profiles, player_id, %{}) %>
                <% player_status = LemonCore.MapHelpers.get_key(player, :status) || "alive" %>
                <% role = LemonCore.MapHelpers.get_key(player, :role) || "unknown" %>
                <div class={[
                  "flex-shrink-0 w-52 rounded-lg border p-3 transition-all",
                  if(player_status == "dead",
                    do: "bg-black/30 border-white/5 opacity-60",
                    else: "bg-white/3 border-white/8 hover:bg-white/5"
                  )
                ]}>
                  <div class="flex items-center justify-between mb-1.5">
                    <span class="text-[11px] font-bold text-slate-200 truncate">
                      {Map.get(profile, "full_name", player_id)}
                    </span>
                    <span class={[
                      "text-[8px] font-bold uppercase px-1.5 py-0.5 rounded-full border",
                      status_badge(player_status, role)
                    ]}>
                      {if player_status == "dead", do: "Dead", else: "Alive"}
                    </span>
                  </div>
                  <div :if={Map.get(profile, "occupation")} class="text-[9px] text-fuchsia-400/80 font-mono mb-1">
                    {Map.get(profile, "occupation")}
                  </div>
                  <div :if={Map.get(profile, "personality")} class="text-[9px] text-slate-400 leading-relaxed line-clamp-2">
                    {Map.get(profile, "personality")}
                  </div>
                  <div :if={player_status == "dead"} class="text-[8px] text-red-400/70 font-mono mt-1">
                    Was: {role}
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Narrative event log --%>
        <div class="flex-shrink-0 border-t border-glass-border bg-slate-950/60 h-48 overflow-hidden">
          <div class="px-4 py-2 border-b border-glass-border bg-slate-900/40">
            <h3 class="text-[9px] font-mono uppercase tracking-widest text-emerald-400 font-bold flex items-center gap-1.5">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M3 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1z" clip-rule="evenodd" />
              </svg>
              LIVE FEED
            </h3>
          </div>
          <div class="p-0 h-36 overflow-hidden">
            <EventLog.render events={@state.recent_events} />
          </div>
        </div>
      </div>
    </div>
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

  defp status_badge("dead", _role), do: "bg-red-900/40 text-red-400 border-red-500/30"
  defp status_badge(_, _), do: "bg-emerald-900/40 text-emerald-400 border-emerald-500/30"

  defp queue_werewolf_state(socket, updated_state) do
    if socket.assigns.supported do
      playback =
        socket.assigns.playback
        |> Kernel.||(WerewolfPlayback.new(socket.assigns.state))
        |> WerewolfPlayback.enqueue(updated_state)

      socket
      |> assign(playback: playback)
      |> maybe_schedule_playback()
    else
      assign(socket, state: updated_state)
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

  defp find_active_werewolf(exclude_sim_id) do
    running_ids = LemonSimUi.SimManager.list_running()

    Enum.find_value(running_ids, fn sim_id ->
      if sim_id != exclude_sim_id do
        case Store.get_state(sim_id) do
          %{world: world} ->
            domain = SimHelpers.infer_domain_type(%LemonSim.State{world: world, sim_id: sim_id})
            if domain == :werewolf, do: sim_id

          _ ->
            nil
        end
      end
    end)
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
end
