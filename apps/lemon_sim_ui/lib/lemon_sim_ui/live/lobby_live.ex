defmodule LemonSimUi.LobbyLive do
  @moduledoc """
  Public lobby page listing active simulations.

  Visitors see all currently running games and can click through to
  spectate via `/watch/:sim_id`. Updates in real-time via the lobby
  pub/sub topic.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{SimHelpers, SimManager, VendingBenchLauncher}
  alias LemonSim.Kernel.{Event, State, Store}

  @vending_bench_artifact_registry Path.join(
                                     System.tmp_dir!(),
                                     "lemon_vending_bench_artifact_registry.json"
                                   )
  @vending_bench_artifact_refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      LemonCore.Bus.subscribe(SimManager.lobby_topic())

      Process.send_after(
        self(),
        :vending_bench_artifact_refresh,
        @vending_bench_artifact_refresh_ms
      )
    end

    {:ok,
     assign(socket,
       sims: build_lobby_list(),
       page_title: "LemonSim — Live Games",
       public_vending_launcher?: VendingBenchLauncher.enabled?(),
       vending_model_presets: VendingBenchLauncher.presets()
     )}
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    {:noreply, assign(socket, sims: build_lobby_list())}
  end

  def handle_info(:vending_bench_artifact_refresh, socket) do
    if connected?(socket) do
      Process.send_after(
        self(),
        :vending_bench_artifact_refresh,
        @vending_bench_artifact_refresh_ms
      )
    end

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
          <div class="flex items-start justify-between gap-4">
            <div>
              <div class="flex items-center gap-3 mb-1">
                <div class="w-9 h-9 rounded-lg shadow-neon-blue bg-gradient-to-br from-blue-500 to-cyan-400 flex items-center justify-center font-bold text-lg text-white">
                  L
                </div>
                <h1 class="text-3xl font-extrabold text-white tracking-tight text-glow-cyan">LemonSim</h1>
              </div>
              <p class="text-sm text-slate-400 font-mono ml-12">Watch AI agents play games in real-time</p>
            </div>
            <.link navigate={~p"/leaderboards"} class="glass-button px-4 py-2 rounded-lg text-sm font-mono">
              Leaderboards
            </.link>
          </div>
        </div>
      </header>

      <%!-- Content --%>
      <main class="max-w-5xl mx-auto px-6 py-10">
        <%= if @public_vending_launcher? do %>
          <section class="glass-panel rounded-xl border border-glass-border p-5 mb-8">
            <div class="flex flex-col md:flex-row md:items-end md:justify-between gap-5">
              <div>
                <div class="flex items-center gap-2 mb-2">
                  <span class="text-[10px] font-bold uppercase px-2 py-1 rounded border bg-amber-500/10 text-amber-300 border-amber-500/30">
                    Vending Bench
                  </span>
                  <span class="text-xs text-slate-500 font-mono">30 day run</span>
                </div>
                <h2 class="text-xl font-bold text-white">Start a New Run</h2>
                <p class="text-sm text-slate-400 font-mono mt-1">
                  Launches an operator and physical worker with the selected model.
                </p>
              </div>

              <div class="w-full md:w-auto grid grid-cols-1 sm:grid-cols-2 gap-3">
                <%= for preset <- @vending_model_presets do %>
                  <a
                    href={~p"/vending_bench/start/#{preset.id}"}
                    class="block rounded-lg border border-slate-700 bg-slate-950/50 p-3 hover:border-cyan-500/50 hover:bg-cyan-500/10 transition-colors"
                  >
                    <div class="flex items-center justify-between gap-3 mb-3">
                      <div>
                        <div class="text-sm font-bold text-white">{preset.label}</div>
                        <div class="text-[11px] text-slate-500 font-mono">{preset.detail}</div>
                      </div>
                      <span class="w-3 h-3 rounded-full border border-cyan-400 bg-cyan-400"></span>
                    </div>
                    <div class="rounded bg-cyan-500 px-4 py-2 text-center text-sm font-bold text-slate-950 hover:bg-cyan-400">
                      Start Run
                    </div>
                  </a>
                <% end %>
              </div>
            </div>
          </section>
        <% end %>

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
                  <span class={[
                    "text-[11px] font-bold tracking-widest uppercase px-2.5 py-1 rounded-sm border flex items-center gap-1.5",
                    status_badge_class(sim.status)
                  ]}>
                    <span class={[
                      "w-1.5 h-1.5 rounded-full",
                      if(sim.status == "in_progress",
                        do: "bg-red-500 animate-pulse shadow-[0_0_6px_rgba(239,68,68,0.8)]",
                        else: "bg-emerald-400"
                      )
                    ]}></span>
                    {status_badge_label(sim.status)}
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

    managed_states =
      Store.list_states()
      |> Enum.filter(fn state -> state.sim_id in running end)

    artifact_states =
      vending_bench_artifact_states()
      |> Enum.reject(fn state -> state.sim_id in running end)

    (managed_states ++ artifact_states)
    |> Enum.map(fn state ->
      summary = SimHelpers.sim_summary(state)
      players = LemonCore.MapHelpers.get_key(state.world, :players)
      arena_agents = LemonCore.MapHelpers.get_key(state.world, :arena_agents)

      player_count =
        case {players, arena_agents} do
          {_, agents} when is_list(agents) -> length(agents)
          {m, _} when is_map(m) -> map_size(m)
          _ -> nil
        end

      Map.put(summary, :player_count, player_count)
    end)
    |> Enum.sort_by(& &1.last_activity, :desc)
  end

  defp vending_bench_artifact_states do
    @vending_bench_artifact_registry
    |> read_registry()
    |> Enum.flat_map(fn {sim_id, artifact_dir} ->
      case load_artifact_state(sim_id, artifact_dir) do
        %State{} = state -> [state]
        nil -> []
      end
    end)
  end

  defp read_registry(path) do
    with {:ok, body} <- File.read(path),
         {:ok, registry} when is_map(registry) <- Jason.decode(body) do
      registry
    else
      _ -> %{}
    end
  end

  defp load_artifact_state(sim_id, artifact_dir) when is_binary(artifact_dir) do
    with {:ok, body} <- File.read(Path.join(artifact_dir, "final_world.json")),
         {:ok, world} when is_map(world) <- Jason.decode(body),
         status when status in ["in_progress", "complete"] <-
           LemonCore.MapHelpers.get_key(world, :status) do
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

  defp load_artifact_state(_sim_id, _artifact_dir), do: nil

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

  defp status_badge_label("complete"), do: "REPLAY"
  defp status_badge_label(_status), do: "LIVE"

  defp status_badge_class("complete"),
    do: "bg-emerald-500/10 text-emerald-300 border-emerald-500/30"

  defp status_badge_class(_status),
    do: "bg-red-500/10 text-red-400 border-red-500/30"
end
