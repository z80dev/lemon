defmodule LemonSimUi.LeaderboardLive do
  @moduledoc """
  Public suite leaderboard page backed by benchmark artifacts.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.ArtifactReader

  @impl true
  def mount(_params, _session, socket) do
    # Scan artifacts only on the connected mount; the disconnected HTTP
    # render would otherwise pay the full disk scan a second time.
    connected? = connected?(socket)
    suites = if connected?, do: ArtifactReader.list_suites(), else: []

    {:ok,
     assign(socket,
       suites: suites,
       loading: not connected?,
       page_title: "LemonSim — Leaderboards"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    suites = socket.assigns.suites

    selected =
      case params["suite"] do
        id when is_binary(id) -> Enum.find(suites, &(&1.id == id))
        _ -> nil
      end

    {:noreply, assign(socket, selected_suite: selected || List.first(suites))}
  end

  @impl true
  def handle_event("select_suite", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.suites, &(&1.id == id)) do
      {:noreply, push_patch(socket, to: ~p"/leaderboards?#{[suite: id]}")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen text-slate-200">
      <header class="border-b border-glass-border bg-slate-900/60 backdrop-blur-md">
        <div class="max-w-6xl mx-auto px-6 py-6">
          <div class="flex items-center justify-between gap-4">
            <div>
              <div class="flex items-center gap-3 mb-1">
                <.link navigate={~p"/"} class="w-9 h-9 rounded-lg shadow-neon-blue bg-gradient-to-br from-blue-500 to-cyan-400 flex items-center justify-center font-bold text-lg text-white">
                  L
                </.link>
                <h1 class="text-3xl font-extrabold text-white tracking-tight text-glow-cyan">Leaderboards</h1>
              </div>
              <p class="text-sm text-slate-400 font-mono ml-12">Verified LemonSim benchmark suites</p>
            </div>
            <.link navigate={~p"/"} class="glass-button px-4 py-2 rounded-lg text-sm font-mono">
              Lobby
            </.link>
          </div>
        </div>
      </header>

      <main class="max-w-6xl mx-auto px-6 py-8">
        <%= if @suites == [] do %>
          <div class="text-center glass-panel p-12 rounded-2xl">
            <%= if @loading do %>
              <p class="text-slate-400 font-mono text-sm">Loading suites…</p>
            <% else %>
              <h2 class="text-xl font-bold text-white mb-3">No Suites Found</h2>
              <p class="text-slate-400 font-mono text-sm">
                Add suite artifacts under configured <span class="text-cyan-300">:suite_roots</span>.
              </p>
            <% end %>
          </div>
        <% else %>
          <div class="grid grid-cols-1 lg:grid-cols-[20rem_1fr] gap-6">
            <aside class="space-y-3">
              <div class="text-xs font-bold uppercase tracking-widest text-slate-500">Suites</div>
              <%= for suite <- @suites do %>
                <button
                  type="button"
                  phx-click="select_suite"
                  phx-value-id={suite.id}
                  class={[
                    "w-full text-left glass-card rounded-lg border p-4 transition-colors",
                    if(@selected_suite && @selected_suite.id == suite.id,
                      do: "border-cyan-500/60 bg-cyan-500/10",
                      else: "border-glass-border hover:border-cyan-500/40"
                    )
                  ]}
                >
                  <div class="flex items-center justify-between gap-3 mb-2">
                    <span class="text-sm font-bold text-white">{suite.scenario}</span>
                    <span class="text-[10px] font-bold uppercase px-2 py-1 rounded border border-slate-700 text-slate-400">
                      {suite.preset}
                    </span>
                  </div>
                  <div class="text-xs text-slate-400 font-mono mb-2">{suite.created_at}</div>
                  <div class="text-xs text-slate-500 font-mono truncate">
                    {Enum.join(suite.competitors, ", ")}
                  </div>
                </button>
              <% end %>
            </aside>

            <section>
              <.suite_detail suite={@selected_suite} />
            </section>
          </div>
        <% end %>
      </main>
    </div>
    """
  end

  attr(:suite, :any, required: true)

  defp suite_detail(%{suite: nil} = assigns) do
    ~H"""
    <div class="glass-panel rounded-xl border border-glass-border p-8 text-center text-slate-400">
      Select a suite.
    </div>
    """
  end

  defp suite_detail(assigns) do
    suite = assigns.suite.suite
    spec = suite["spec"] || %{}
    metric = suite["primary_metric"] || %{}
    direction = metric["direction"] || "maximize"

    assigns =
      assigns
      |> assign(:spec, spec)
      |> assign(:metric, metric)
      |> assign(:direction, direction)
      |> assign(:rankings, suite["rankings"] || [])
      |> assign(:failures, suite["failures"] || [])

    ~H"""
    <div class="glass-panel rounded-xl border border-glass-border overflow-hidden">
      <div class="p-5 border-b border-glass-border">
        <div class="flex flex-col md:flex-row md:items-start md:justify-between gap-4">
          <div>
            <div class="flex items-center gap-2 mb-2">
              <span class="text-[10px] font-bold uppercase px-2 py-1 rounded border bg-cyan-500/10 text-cyan-300 border-cyan-500/30">
                {@suite.scenario}
              </span>
              <span class="text-[10px] font-bold uppercase px-2 py-1 rounded border border-slate-700 text-slate-400">
                {@suite.preset}
              </span>
            </div>
            <h2 class="text-xl font-bold text-white">
              {Map.get(@metric, "name", "metric")}
              <span class="text-sm text-slate-400 font-mono">
                ({direction_label(@direction)})
              </span>
            </h2>
            <p class="text-xs text-slate-500 font-mono mt-1">
              Seeds: {Enum.join(Map.get(@spec, "seeds", []), ", ")}
            </p>
          </div>
          <div class="text-xs text-slate-500 font-mono md:text-right">
            <div>{@suite.created_at}</div>
            <div class="truncate max-w-md">{@suite.dir_label}</div>
          </div>
        </div>
      </div>

      <div class="overflow-x-auto">
        <table class="min-w-full text-sm">
          <thead class="bg-slate-950/60 text-slate-400 font-mono text-xs uppercase">
            <tr>
              <th class="px-4 py-3 text-right">Rank</th>
              <th class="px-4 py-3 text-left">Competitor</th>
              <th class="px-4 py-3 text-right">Mean</th>
              <th class="px-4 py-3 text-left">Per Seed</th>
              <th class="px-4 py-3 text-left">Verification</th>
              <th class="px-4 py-3 text-right">Tokens</th>
              <th class="px-4 py-3 text-right">Cost</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-glass-border">
            <%= for ranking <- @rankings do %>
              <% usage = Map.get(ranking, "usage_totals", %{}) %>
              <tr>
                <td class="px-4 py-3 text-right text-slate-400 font-mono">{ranking["rank"]}</td>
                <td class="px-4 py-3 font-bold text-white">{ranking["competitor"]}</td>
                <td class="px-4 py-3 text-right font-mono text-cyan-300">{format_metric_summary(ranking)}</td>
                <td class="px-4 py-3 text-xs font-mono text-slate-400">{format_seed_values(ranking["values_by_seed"] || %{})}</td>
                <td class="px-4 py-3 text-xs font-mono text-slate-400">
                  {verification_label(ranking)}
                </td>
                <td class="px-4 py-3 text-right font-mono text-slate-300">
                  {ArtifactReader.format_integer(ArtifactReader.total_tokens(usage))}
                </td>
                <td class="px-4 py-3 text-right font-mono text-slate-300">
                  {ArtifactReader.format_cost(usage["cost_usd"])}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div :if={@failures != []} class="border-t border-glass-border p-5">
        <h3 class="text-sm font-bold uppercase tracking-widest text-red-300 mb-3">Reported Not Ranked</h3>
        <div class="overflow-x-auto">
          <table class="min-w-full text-sm">
            <thead class="text-xs uppercase text-slate-500 font-mono">
              <tr>
                <th class="py-2 pr-4 text-left">Competitor</th>
                <th class="py-2 pr-4 text-left">Seed</th>
                <th class="py-2 pr-4 text-left">Error</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-glass-border">
              <%= for failure <- @failures do %>
                <tr>
                  <td class="py-2 pr-4 text-white">{failure["competitor"]}</td>
                  <td class="py-2 pr-4 font-mono text-slate-400">{failure["seed"]}</td>
                  <td class="py-2 pr-4 font-mono text-xs text-red-200">{failure["error"]}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp direction_label("maximize"), do: "maximize ↑"
  defp direction_label("minimize"), do: "minimize ↓"
  defp direction_label(direction), do: direction

  defp verification_label(ranking) do
    included = ranking["included_runs"] || 0
    failed = ranking["failed_runs"] || 0

    case failed do
      0 -> "#{included} verified"
      _ -> "#{included} verified / #{failed} failed"
    end
  end

  defp format_metric_summary(ranking), do: LemonSim.Bench.Suite.format_metric_summary(ranking)

  defp format_seed_values(values) do
    values
    |> Enum.sort_by(fn {seed, _value} -> parse_seed(seed) end)
    |> Enum.map(fn {seed, value} -> "#{seed}: #{ArtifactReader.format_number(value)}" end)
    |> Enum.join(", ")
  end

  defp parse_seed(seed) when is_integer(seed), do: seed

  defp parse_seed(seed) when is_binary(seed) do
    case Integer.parse(seed) do
      {value, ""} -> value
      _ -> seed
    end
  end

  defp parse_seed(seed), do: seed
end
