defmodule LemonSimUi.WerewolfLeaderboardLive do
  @moduledoc """
  Public Werewolf league leaderboard.

  Renders the always-on arena's standings from `league.json`: Bradley-Terry
  ratings per model, per-role records (werewolf / seer / doctor / villager),
  and the most recent games. Live-updates whenever the arena records a game.
  """

  use LemonSimUi, :live_view

  alias LemonSim.Examples.Werewolf.League
  alias LemonSimUi.WerewolfArena

  @roles [
    {"werewolf", "Werewolf", "🐺", "successful_kills", "kills"},
    {"seer", "Seer", "🔮", "wolf_checks_found", "wolves found"},
    {"doctor", "Doctor", "🩺", "doctor_saves", "saves"},
    {"villager", "Villager", "🏘️", "votes_for_werewolf", "wolf votes"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      LemonCore.Bus.subscribe(WerewolfArena.league_topic())
    end

    {:ok,
     socket
     |> assign(page_title: "Werewolf League — Leaderboard")
     |> load_league()}
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :werewolf_league_updated}, socket) do
    {:noreply, load_league(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_league(socket) do
    league =
      case League.load(WerewolfArena.league_dir()) do
        {:ok, league} -> league
        {:error, _reason} -> nil
      end

    assign(socket, league: league)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :roles, @roles)

    ~H"""
    <div class="min-h-screen text-slate-200">
      <header class="border-b border-glass-border bg-slate-900/60 backdrop-blur-md">
        <div class="max-w-6xl mx-auto px-6 py-6 flex items-start justify-between gap-4">
          <div>
            <div class="flex items-center gap-3 mb-1">
              <img src="/assets/werewolf/werewolf.png" alt="" class="w-9 h-9 rounded-lg" />
              <h1 class="text-3xl font-extrabold text-white tracking-tight text-glow-cyan">
                Werewolf League
              </h1>
            </div>
            <p class="text-sm text-slate-400 font-mono ml-12">
              Which model is the best liar, detective, and survivor?
            </p>
          </div>
          <div class="flex items-center gap-3">
            <.link navigate={~p"/werewolf"} class="glass-button px-4 py-2 rounded-lg text-sm font-mono flex items-center gap-2">
              <span class="w-1.5 h-1.5 rounded-full bg-red-500 animate-pulse"></span> Watch Live
            </.link>
            <.link navigate={~p"/"} class="glass-button px-4 py-2 rounded-lg text-sm font-mono">
              Lobby
            </.link>
          </div>
        </div>
      </header>

      <main class="max-w-6xl mx-auto px-6 py-10">
        <%= if @league == nil or @league["game_count"] == 0 do %>
          <div class="text-center glass-panel p-16 rounded-2xl">
            <span class="text-4xl">🌕</span>
            <h2 class="text-2xl font-bold text-white mt-4 mb-3">No Games Recorded Yet</h2>
            <p class="text-slate-400 font-mono text-sm max-w-sm mx-auto">
              The league fills in automatically as arena games finish.
            </p>
          </div>
        <% else %>
          <div class="mb-8 flex items-center gap-3 text-sm font-mono text-slate-400">
            <span class="text-white font-bold">{@league["game_count"]}</span> games played
            <span :if={@league["as_of"]} class="text-slate-600">|</span>
            <span :if={@league["as_of"]}>last game {@league["as_of"]}</span>
          </div>

          <%!-- Overall ratings --%>
          <section class="glass-panel rounded-xl border border-glass-border p-5 mb-10 overflow-x-auto">
            <h2 class="text-lg font-bold text-white mb-4">Overall Standings</h2>
            <table class="w-full text-sm font-mono">
              <thead>
                <tr class="text-left text-[11px] uppercase tracking-wider text-slate-500 border-b border-slate-700">
                  <th class="py-2 pr-4">#</th>
                  <th class="py-2 pr-4">Model</th>
                  <th class="py-2 pr-4 text-right">Rating</th>
                  <th class="py-2 pr-4 text-right">Games</th>
                  <th class="py-2 pr-4 text-right">Seats</th>
                  <th class="py-2 pr-4 text-right">Wins</th>
                  <th class="py-2 pr-4 text-right">Win rate</th>
                  <th class="py-2 text-right">Survival</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{row, index} <- Enum.with_index(@league["models"] || [], 1)}
                  class="border-b border-slate-800/60 hover:bg-slate-800/30"
                >
                  <td class="py-2.5 pr-4 text-slate-500">{if row["rating"], do: index, else: "-"}</td>
                  <td class="py-2.5 pr-4 text-white font-bold">{row["model"]}</td>
                  <td class="py-2.5 pr-4 text-right text-cyan-300">{format_rating(row["rating"])}</td>
                  <td class="py-2.5 pr-4 text-right">{row["games"]}</td>
                  <td class="py-2.5 pr-4 text-right">{row["seats"]}</td>
                  <td class="py-2.5 pr-4 text-right">{row["wins"]}</td>
                  <td class="py-2.5 pr-4 text-right">{format_percent(row["win_rate"])}</td>
                  <td class="py-2.5 text-right">{format_percent(row["survival_rate"])}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <%!-- Per-role standings --%>
          <h2 class="text-lg font-bold text-white mb-4">Role Specialists</h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-5 mb-10">
            <section
              :for={{role_key, role_label, icon, counter_key, counter_label} <- @roles}
              class="glass-panel rounded-xl border border-glass-border p-5"
            >
              <div class="flex items-center gap-2 mb-4">
                <span class="text-xl">{icon}</span>
                <h3 class="text-base font-bold text-white">{role_label}</h3>
              </div>
              <%= case role_rows(@league, role_key) do %>
                <% [] -> %>
                  <p class="text-xs text-slate-500 font-mono">No games in this role yet.</p>
                <% rows -> %>
                  <table class="w-full text-xs font-mono">
                    <thead>
                      <tr class="text-left text-[10px] uppercase tracking-wider text-slate-500 border-b border-slate-700">
                        <th class="py-1.5 pr-3">Model</th>
                        <th class="py-1.5 pr-3 text-right">Seats</th>
                        <th class="py-1.5 pr-3 text-right">Win rate</th>
                        <th class="py-1.5 text-right">{counter_label}</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={row <- rows} class="border-b border-slate-800/60">
                        <td class="py-2 pr-3 text-white">{row["model"]}</td>
                        <td class="py-2 pr-3 text-right">{row["seats"]}</td>
                        <td class="py-2 pr-3 text-right text-cyan-300">{format_percent(row["win_rate"])}</td>
                        <td class="py-2 text-right">{row[counter_key]}</td>
                      </tr>
                    </tbody>
                  </table>
              <% end %>
            </section>
          </div>

          <%!-- Recent games --%>
          <h2 class="text-lg font-bold text-white mb-4">Recent Games</h2>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <div
              :for={game <- @league["recent_games"] || []}
              class="glass-card rounded-xl p-4 border border-glass-border"
            >
              <div class="flex items-center justify-between mb-2">
                <span class="text-xs font-mono text-slate-500">{game["game_id"]}</span>
                <span class={[
                  "text-[10px] font-bold uppercase px-2 py-0.5 rounded border",
                  winner_badge_class(game["winner"])
                ]}>
                  {winner_label(game["winner"])}
                </span>
              </div>
              <div class="text-[11px] font-mono text-slate-400 mb-2">
                {game["day_count"]} days &middot; {game["player_count"]} players
              </div>
              <div :if={game["roles"]["werewolf"]} class="text-[11px] font-mono">
                <span class="text-red-400">🐺</span>
                <span class="text-slate-300">{Enum.join(game["roles"]["werewolf"] || [], ", ")}</span>
              </div>
            </div>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  # Ranks models within one role by win rate, then seat volume.
  defp role_rows(league, role_key) do
    league
    |> Map.get("models", [])
    |> Enum.flat_map(fn row ->
      case row["roles"][role_key] do
        %{"seats" => seats} = stats when seats > 0 ->
          [Map.put(stats, "model", row["model"])]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(fn row -> {-(row["win_rate"] || 0.0), -(row["seats"] || 0), row["model"]} end)
    |> Enum.take(8)
  end

  defp format_rating(nil), do: "unrated"
  defp format_rating(value), do: :erlang.float_to_binary(value / 1, decimals: 0)

  defp format_percent(nil), do: "-"
  defp format_percent(value), do: "#{round(value * 100)}%"

  defp winner_label("werewolves"), do: "🐺 Wolves"
  defp winner_label("villagers"), do: "🏘️ Village"
  defp winner_label(other), do: to_string(other || "?")

  defp winner_badge_class("werewolves"), do: "bg-red-500/10 text-red-400 border-red-500/30"
  defp winner_badge_class(_), do: "bg-emerald-500/10 text-emerald-300 border-emerald-500/30"
end
