defmodule LemonSimUi.ArenaLeaderboardLive do
  @moduledoc """
  Public league leaderboard for an always-on arena domain.

  Renders the domain's standings from `league.json`: Bradley-Terry ratings
  per model, per-role records for team games (or stat leaders for ranked /
  role-less games), and the most recent games. Live-updates whenever the
  arena records a game.
  """

  use LemonSimUi, :live_view

  alias LemonSim.Bench.League
  alias LemonSimUi.{Arena, ArenaDomains}

  @impl true
  def mount(%{"domain" => slug}, _session, socket) do
    case ArenaDomains.domain_atom(slug) do
      {:ok, domain} ->
        if connected?(socket) do
          LemonCore.Bus.subscribe(Arena.league_topic(domain))
        end

        theme = ArenaDomains.get(domain)

        {:ok,
         socket
         |> assign(
           domain: domain,
           theme: theme,
           page_title: "#{theme.title} League — Leaderboard"
         )
         |> load_league()}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Unknown arena")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :arena_league_updated}, socket) do
    {:noreply, load_league(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_league(socket) do
    league =
      case League.load(Arena.league_dir(socket.assigns.domain)) do
        {:ok, league} -> league
        {:error, _reason} -> nil
      end

    assign(socket, league: league)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen text-slate-200">
      <header class="border-b border-glass-border bg-slate-900/60 backdrop-blur-md">
        <div class="max-w-6xl mx-auto px-6 py-6 flex items-start justify-between gap-4">
          <div>
            <div class="flex items-center gap-3 mb-1">
              <span class="text-3xl">{@theme.icon}</span>
              <h1 class="text-3xl font-extrabold text-white tracking-tight text-glow-cyan">
                {@theme.title} League
              </h1>
            </div>
            <p class="text-sm text-slate-400 font-mono ml-12">{@theme.tagline}</p>
          </div>
          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/arena/#{@domain}"}
              class="glass-button px-4 py-2 rounded-lg text-sm font-mono flex items-center gap-2"
            >
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
            <span class="text-4xl">{@theme.icon}</span>
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
            <span
              :if={@league["rating_status"] == "provisional"}
              class="rounded-full border border-amber-500/30 bg-amber-500/10 px-2 py-0.5 text-[10px] uppercase tracking-wider text-amber-300"
            >
              Provisional — incomplete role rotation
            </span>
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
                  <th :if={role_adjusted?(@league)} class="py-2 pr-4 text-right">Role-adjusted</th>
                  <th :if={values?(@league) && !ranked?(@league)} class="py-2 pr-4 text-right">Role score</th>
                  <th :if={ranked?(@league)} class="py-2 text-right">Mean value</th>
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
                  <td :if={role_adjusted?(@league)} class="py-2.5 pr-4 text-right text-violet-300">
                    {format_percent(row["role_adjusted_win_rate"])}
                  </td>
                  <td :if={values?(@league) && !ranked?(@league)} class="py-2.5 pr-4 text-right">
                    {format_value(row["value_mean"])}
                  </td>
                  <td :if={ranked?(@league)} class="py-2.5 text-right">
                    {format_value(row["value_mean"])}
                  </td>
                </tr>
              </tbody>
            </table>
          </section>

          <%!-- Role specialists (team games with roles) --%>
          <%= if @theme.roles != [] do %>
            <h2 class="text-lg font-bold text-white mb-4">Role Specialists</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-5 mb-10">
              <section
                :for={{role_key, role_label, icon, metric_key, metric_label} <- @theme.roles}
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
                          <th class="py-1.5 text-right">{metric_label}</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={row <- rows} class="border-b border-slate-800/60">
                          <td class="py-2 pr-3 text-white">{row["model"]}</td>
                          <td class="py-2 pr-3 text-right">{row["seats"]}</td>
                          <td class="py-2 pr-3 text-right text-cyan-300">
                            {format_percent(row["win_rate"])}
                          </td>
                          <td class="py-2 text-right">{row["metrics"][metric_key] || 0}</td>
                        </tr>
                      </tbody>
                    </table>
                <% end %>
              </section>
            </div>
          <% end %>

          <%!-- Stat leaders (games without fixed roles) --%>
          <%= if @theme.roles == [] and @theme.stats != [] do %>
            <h2 class="text-lg font-bold text-white mb-4">Stat Leaders</h2>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-5 mb-10">
              <section
                :for={{metric_key, label, icon} <- @theme.stats}
                class="glass-panel rounded-xl border border-glass-border p-5"
              >
                <div class="flex items-center gap-2 mb-4">
                  <span class="text-xl">{icon}</span>
                  <h3 class="text-base font-bold text-white">{label}</h3>
                </div>
                <%= case stat_rows(@league, metric_key) do %>
                  <% [] -> %>
                    <p class="text-xs text-slate-500 font-mono">Nothing recorded yet.</p>
                  <% rows -> %>
                    <table class="w-full text-xs font-mono">
                      <tbody>
                        <tr :for={row <- rows} class="border-b border-slate-800/60">
                          <td class="py-2 pr-3 text-white">{row["model"]}</td>
                          <td class="py-2 text-right text-cyan-300">
                            {row["metrics"][metric_key] || 0}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                <% end %>
              </section>
            </div>
          <% end %>

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
                  {ArenaDomains.winner_label(@domain, game["winner"])}
                </span>
              </div>
              <div class="text-[11px] font-mono text-slate-400 mb-2">
                {game["rounds"]} rounds &middot; {game["seat_count"]} players
              </div>
              <div :if={game["winning_models"] != []} class="text-[11px] font-mono">
                <span class="text-amber-300">★</span>
                <span class="text-slate-300">{Enum.join(game["winning_models"] || [], ", ")}</span>
              </div>
            </div>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  defp ranked?(league), do: league["mode"] == "ranked"
  defp role_adjusted?(league), do: map_size(league["role_win_baselines"] || %{}) > 0

  defp values?(league) do
    Enum.any?(league["models"] || [], &is_number(&1["value_mean"]))
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

  defp stat_rows(league, metric_key) do
    league
    |> Map.get("models", [])
    |> Enum.filter(fn row -> (row["metrics"][metric_key] || 0) > 0 end)
    |> Enum.sort_by(fn row -> {-(row["metrics"][metric_key] || 0), row["model"]} end)
    |> Enum.take(5)
  end

  defp format_rating(nil), do: "unrated"
  defp format_rating(value), do: :erlang.float_to_binary(value / 1, decimals: 0)

  defp format_percent(nil), do: "-"
  defp format_percent(value), do: "#{round(value * 100)}%"

  defp format_value(nil), do: "-"
  defp format_value(value), do: :erlang.float_to_binary(value / 1, decimals: 0)

  defp winner_badge_class(winner) when winner in ["werewolves", "saboteur"],
    do: "bg-red-500/10 text-red-400 border-red-500/30"

  defp winner_badge_class(_), do: "bg-emerald-500/10 text-emerald-300 border-emerald-500/30"
end
