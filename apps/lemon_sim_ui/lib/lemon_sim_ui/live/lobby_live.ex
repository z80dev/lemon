defmodule LemonSimUi.LobbyLive do
  @moduledoc """
  Public lobby page listing active simulations.

  Visitors see all currently running games and can click through to
  spectate via `/watch/:sim_id`. Updates in real-time via the lobby
  pub/sub topic.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{SimHelpers, SimManager}
  alias LemonSim.Store

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      LemonCore.Bus.subscribe(SimManager.lobby_topic())
    end

    {:ok,
     assign(socket,
       sims: build_lobby_list(),
       page_title: "LemonSim — Live Games"
     )}
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    {:noreply, assign(socket, sims: build_lobby_list())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen text-slate-200">
      <%!-- Header --%>
      <header class="border-b border-glass-border bg-slate-900/60 backdrop-blur-md">
        <div class="max-w-5xl mx-auto px-6 py-6">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-lg shadow-neon-blue bg-gradient-to-br from-blue-500 to-cyan-400 flex items-center justify-center font-bold text-lg text-white">
              L
            </div>
            <h1 class="text-3xl font-extrabold text-white tracking-tight text-glow-cyan">LemonSim</h1>
          </div>
          <p class="text-sm text-slate-400 font-mono ml-12">Watch AI agents play games in real-time</p>
        </div>
      </header>

      <%!-- Content --%>
      <main class="max-w-5xl mx-auto px-6 py-10">
        <%= if @sims == [] do %>
          <div class="text-center glass-panel p-16 rounded-2xl">
            <div class="w-20 h-20 bg-slate-900/80 rounded-full flex items-center justify-center mx-auto mb-6 border border-slate-700">
              <span class="text-4xl opacity-50">&#x1F3AE;</span>
            </div>
            <h2 class="text-2xl font-bold text-white mb-3">No Games Currently Live</h2>
            <p class="text-slate-400 font-mono text-sm max-w-sm mx-auto">
              Check back soon — games start automatically and run around the clock.
            </p>
          </div>
        <% else %>
          <div class="mb-6 flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-red-500 animate-pulse shadow-[0_0_8px_rgba(239,68,68,0.8)]"></span>
            <span class="text-sm font-bold text-slate-300 uppercase tracking-widest">{length(@sims)} Live</span>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-5">
            <%= for sim <- @sims do %>
              <.link
                navigate={~p"/watch/#{sim.sim_id}"}
                class="glass-card rounded-xl p-5 border border-glass-border hover:border-cyan-500/40 hover:shadow-neon-blue transition-all group cursor-pointer block"
              >
                <div class="flex items-center justify-between mb-3">
                  <span class={[
                    "text-[10px] font-bold uppercase px-2 py-1 rounded border",
                    SimHelpers.domain_badge_color(sim.domain_type)
                  ]}>
                    {SimHelpers.domain_label(sim.domain_type)}
                  </span>
                  <span class="text-[11px] font-bold tracking-widest uppercase px-2.5 py-1 rounded-sm bg-red-500/10 text-red-400 border border-red-500/30 flex items-center gap-1.5">
                    <span class="w-1.5 h-1.5 rounded-full bg-red-500 animate-pulse shadow-[0_0_6px_rgba(239,68,68,0.8)]"></span>
                    LIVE
                  </span>
                </div>

                <h3 class="text-lg font-bold text-white mb-2 group-hover:text-cyan-300 transition-colors font-mono">{sim.sim_id}</h3>

                <div class="flex items-center gap-3 text-xs text-slate-400 font-mono">
                  <span>{sim.status}</span>
                  <%= if sim.player_count do %>
                    <span class="text-slate-600">|</span>
                    <span>{sim.player_count} players</span>
                  <% end %>
                </div>
              </.link>
            <% end %>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  # -- Private --

  defp build_lobby_list do
    running = SimManager.list_running() |> MapSet.new()

    Store.list_states()
    |> Enum.filter(fn state -> state.sim_id in running end)
    |> Enum.map(fn state ->
      summary = SimHelpers.sim_summary(state)
      players = LemonCore.MapHelpers.get_key(state.world, :players)

      player_count =
        case players do
          m when is_map(m) -> map_size(m)
          _ -> nil
        end

      Map.put(summary, :player_count, player_count)
    end)
    |> Enum.sort_by(& &1.last_activity, :desc)
  end
end
