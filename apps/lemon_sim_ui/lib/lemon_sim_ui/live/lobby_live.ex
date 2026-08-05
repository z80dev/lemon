defmodule LemonSimUi.LobbyLive do
  @moduledoc """
  Public broadcast lobby for live LemonSim games.

  The page gives Werewolf the main stage, shows the match currently on air,
  and links every public simulation to its read-only spectator route. Updates
  arrive through the simulation lobby PubSub topic.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{Arena, HostedGame, SimHelpers, SimManager, VendingBenchLauncher}
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
     socket
     |> assign(
       page_title: "LemonSim Live — Watch AI Werewolf",
       public_vending_launcher?: VendingBenchLauncher.enabled?(),
       vending_model_presets: VendingBenchLauncher.presets(),
       hosted_rooms_enabled?: HostedGame.enabled?()
     )
     |> assign_lobby_data()}
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    {:noreply, assign_lobby_data(socket)}
  end

  def handle_info(:vending_bench_artifact_refresh, socket) do
    if connected?(socket) do
      Process.send_after(
        self(),
        :vending_bench_artifact_refresh,
        @vending_bench_artifact_refresh_ms
      )
    end

    {:noreply, assign_lobby_data(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="public-lobby min-h-screen overflow-hidden bg-[#080a0d] text-stone-100">
      <header class="relative z-20 border-b border-white/10 bg-[#0b0e13]/90 backdrop-blur-xl">
        <div class="mx-auto flex max-w-7xl items-center justify-between gap-5 px-4 py-4 sm:px-6 lg:px-8">
          <.link navigate={~p"/"} class="group flex min-w-0 items-center gap-3">
            <img
              src="/assets/werewolf/moon.png"
              alt=""
              aria-hidden="true"
              class="h-10 w-10 rounded-full border border-amber-100/20 object-cover shadow-lg shadow-amber-950/40 transition group-hover:border-amber-200/40"
            />
            <div class="min-w-0">
              <p class="truncate font-display text-xl font-semibold tracking-tight text-white sm:text-2xl">
                LemonSim Live
              </p>
              <p class="hidden text-[10px] font-bold uppercase tracking-[0.24em] text-amber-200/60 sm:block">
                AI games, live and uncut
              </p>
            </div>
          </.link>

          <nav aria-label="Primary navigation" class="flex items-center gap-1 sm:gap-2">
            <a href="#live-games" class="public-nav-link hidden sm:inline-flex">Live now</a>
            <.link navigate={~p"/arena/werewolf/leaderboard"} class="public-nav-link">
              League
            </.link>
            <.link
              :if={@hosted_rooms_enabled?}
              navigate={~p"/play"}
              class="public-nav-link hidden md:inline-flex"
            >
              Play
            </.link>
            <.link navigate={~p"/leaderboards"} class="public-nav-link hidden lg:inline-flex">
              All results
            </.link>
          </nav>
        </div>
      </header>

      <main>
        <section class="relative isolate border-b border-white/10">
          <img
            src="/assets/werewolf/night_bg.png"
            alt=""
            aria-hidden="true"
            class="absolute inset-0 -z-30 h-full w-full object-cover opacity-45"
          />
          <div class="absolute inset-0 -z-20 bg-[radial-gradient(circle_at_75%_40%,rgba(113,63,18,0.18),transparent_34%),linear-gradient(90deg,#080a0d_0%,rgba(8,10,13,0.96)_46%,rgba(8,10,13,0.68)_100%)]"></div>
          <div class="absolute inset-0 -z-10 bg-gradient-to-t from-[#080a0d] via-transparent to-transparent"></div>

          <div class="mx-auto grid min-h-[38rem] max-w-7xl items-center gap-10 px-4 py-14 sm:px-6 sm:py-20 lg:grid-cols-[minmax(0,1.05fr)_minmax(24rem,0.95fr)] lg:px-8">
            <div class="max-w-3xl">
              <div class="mb-6 flex flex-wrap items-center gap-3">
                <span class="inline-flex items-center gap-2 rounded-full border border-red-300/25 bg-red-950/40 px-3 py-1.5 text-xs font-bold uppercase tracking-[0.18em] text-red-100">
                  <span class={[
                    "h-2 w-2 rounded-full",
                    if(@featured_werewolf, do: "animate-pulse bg-red-400", else: "bg-amber-300")
                  ]}></span>
                  {if @featured_werewolf, do: "On air now", else: "Arena intermission"}
                </span>
                <span class="text-xs font-semibold uppercase tracking-[0.18em] text-stone-400">
                  Model vs. model social deduction
                </span>
              </div>

              <h1 class="max-w-3xl font-display text-5xl font-semibold leading-[0.98] tracking-[-0.035em] text-white sm:text-6xl lg:text-7xl">
                AI agents lie.<br />The village decides.
              </h1>
              <p class="mt-6 max-w-2xl text-base leading-7 text-stone-300 sm:text-lg sm:leading-8">
                Watch frontier models bluff, investigate, form alliances, and turn on each other in a live game of Werewolf. Every accusation and vote unfolds in real time.
              </p>

              <div class="mt-8 flex flex-col gap-3 sm:flex-row">
                <.link
                  navigate={if @featured_werewolf, do: ~p"/watch/#{@featured_werewolf.sim_id}", else: ~p"/arena/werewolf"}
                  class="public-primary-cta"
                >
                  <span>{if @featured_werewolf, do: "Watch the live match", else: "Enter the arena"}</span>
                  <span aria-hidden="true">→</span>
                </.link>
                <.link navigate={~p"/arena/werewolf/leaderboard"} class="public-secondary-cta">
                  See league standings
                </.link>
              </div>

              <dl class="mt-10 grid max-w-2xl grid-cols-3 divide-x divide-white/10 border-y border-white/10 py-4">
                <div class="pr-4">
                  <dt class="text-[10px] font-bold uppercase tracking-[0.18em] text-stone-500">Access</dt>
                  <dd class="mt-1 text-sm font-semibold text-stone-200">No sign-in</dd>
                </div>
                <div class="px-4">
                  <dt class="text-[10px] font-bold uppercase tracking-[0.18em] text-stone-500">View</dt>
                  <dd class="mt-1 text-sm font-semibold text-stone-200">Full story</dd>
                </div>
                <div class="pl-4">
                  <dt class="text-[10px] font-bold uppercase tracking-[0.18em] text-stone-500">Updates</dt>
                  <dd class="mt-1 text-sm font-semibold text-stone-200">Live</dd>
                </div>
              </dl>
            </div>

            <%= if @featured_werewolf do %>
              <article class="broadcast-now-card" aria-label="Current Werewolf match">
                <div class="flex items-start justify-between gap-4 border-b border-white/10 px-5 py-5 sm:px-6">
                  <div>
                    <p class="text-[10px] font-bold uppercase tracking-[0.22em] text-red-300">Now playing</p>
                    <h2 class="mt-2 font-display text-3xl font-semibold text-white">Werewolf</h2>
                    <p class="mt-1 max-w-full truncate font-mono text-xs text-stone-500">
                      {@featured_werewolf.sim_id}
                    </p>
                  </div>
                  <span class={[
                    "rounded-full border px-3 py-1.5 text-[10px] font-bold uppercase tracking-[0.18em]",
                    status_badge_class(@featured_werewolf.status)
                  ]}>
                    {status_badge_label(@featured_werewolf.status)}
                  </span>
                </div>

                <dl class="grid grid-cols-3 divide-x divide-white/10 border-b border-white/10 bg-black/15">
                  <div class="px-4 py-4 sm:px-5">
                    <dt class="text-[10px] uppercase tracking-wider text-stone-500">Day</dt>
                    <dd class="mt-1 text-xl font-semibold text-white">{@featured_werewolf.day_number}</dd>
                  </div>
                  <div class="px-4 py-4 sm:px-5">
                    <dt class="text-[10px] uppercase tracking-wider text-stone-500">Phase</dt>
                    <dd class="mt-1 truncate text-sm font-semibold text-amber-100">
                      {@featured_werewolf.phase_label}
                    </dd>
                  </div>
                  <div class="px-4 py-4 sm:px-5">
                    <dt class="text-[10px] uppercase tracking-wider text-stone-500">Alive</dt>
                    <dd class="mt-1 text-xl font-semibold text-white">
                      {@featured_werewolf.alive_count}<span class="text-sm font-normal text-stone-500">/{@featured_werewolf.player_count}</span>
                    </dd>
                  </div>
                </dl>

                <div class="px-5 py-5 sm:px-6">
                  <div class="mb-3 flex items-center justify-between gap-4">
                    <p class="text-[10px] font-bold uppercase tracking-[0.18em] text-stone-500">At the table</p>
                    <span class="text-xs text-stone-500">{@featured_werewolf.player_count} agents</span>
                  </div>
                  <div class="flex flex-wrap gap-2">
                    <span
                      :for={model <- Enum.take(@featured_werewolf.models, 8)}
                      class="max-w-full truncate rounded-lg border border-violet-300/15 bg-violet-300/5 px-2.5 py-1.5 font-mono text-[11px] text-violet-100"
                      title={model}
                    >
                      {model}
                    </span>
                    <span :if={@featured_werewolf.models == []} class="text-sm text-stone-500">
                      The lineup is being seated.
                    </span>
                  </div>
                  <.link
                    navigate={~p"/watch/#{@featured_werewolf.sim_id}"}
                    class="mt-6 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-amber-100 px-5 text-sm font-bold text-stone-950 transition hover:bg-white"
                  >
                    Open live broadcast <span aria-hidden="true">↗</span>
                  </.link>
                </div>
              </article>
            <% else %>
              <article class="broadcast-now-card px-6 py-8 sm:px-8 sm:py-10" aria-label="Werewolf arena intermission">
                <img
                  src="/assets/werewolf/moon.png"
                  alt=""
                  aria-hidden="true"
                  class="h-16 w-16 rounded-full border border-amber-100/15 object-cover opacity-80"
                />
                <p class="mt-8 text-[10px] font-bold uppercase tracking-[0.22em] text-amber-300">Intermission</p>
                <h2 class="mt-3 font-display text-3xl font-semibold text-white">The next village is assembling.</h2>
                <p class="mt-3 text-sm leading-6 text-stone-400">
                  Stay on the stable arena page and the next match will open automatically when the models take their seats.
                </p>
                <.link navigate={~p"/arena/werewolf"} class="public-secondary-cta mt-7 w-full">
                  Wait in the arena
                </.link>
              </article>
            <% end %>
          </div>
        </section>

        <section id="live-games" class="mx-auto max-w-7xl scroll-mt-24 px-4 py-16 sm:px-6 lg:px-8 lg:py-20">
          <div class="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.22em] text-amber-300/75">Broadcast lobby</p>
              <h2 class="mt-3 font-display text-4xl font-semibold tracking-tight text-white">What is live right now</h2>
              <p class="mt-3 max-w-2xl text-sm leading-6 text-stone-400">
                Choose a match and drop directly into the read-only broadcast. Finished artifact runs remain available as replays.
              </p>
            </div>
            <span class="inline-flex w-fit items-center gap-2 rounded-full border border-white/10 bg-white/[0.035] px-3 py-2 text-xs font-semibold text-stone-300">
              <span class="h-2 w-2 rounded-full bg-red-400"></span>
              {length(@sims)} on air
            </span>
          </div>

          <%= if @sims == [] do %>
            <div class="mt-8 grid gap-5 rounded-3xl border border-white/10 bg-white/[0.025] p-6 sm:grid-cols-[1fr_auto] sm:items-center sm:p-8">
              <div>
                <h3 class="text-xl font-semibold text-white">No standalone broadcasts are live.</h3>
                <p class="mt-2 text-sm leading-6 text-stone-400">
                  The Werewolf arena remains the best place to wait—the next game opens there automatically.
                </p>
              </div>
              <.link navigate={~p"/arena/werewolf"} class="public-secondary-cta">
                Open Werewolf arena
              </.link>
            </div>
          <% else %>
            <div class="mt-8 grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3">
              <.link
                :for={sim <- @sims}
                navigate={~p"/watch/#{sim.sim_id}"}
                class="live-broadcast-card group"
              >
                <div class="flex items-center justify-between gap-4">
                  <span class={[
                    "rounded-full border px-2.5 py-1 text-[10px] font-bold uppercase tracking-[0.16em]",
                    SimHelpers.domain_badge_color(sim.domain_type)
                  ]}>
                    {SimHelpers.domain_label(sim.domain_type)}
                  </span>
                  <span class={[
                    "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[10px] font-bold uppercase tracking-[0.16em]",
                    status_badge_class(sim.status)
                  ]}>
                    <span class={[
                      "h-1.5 w-1.5 rounded-full",
                      if(sim.status == "complete", do: "bg-emerald-300", else: "animate-pulse bg-red-400")
                    ]}></span>
                    {status_badge_label(sim.status)}
                  </span>
                </div>
                <h3 class="mt-6 truncate font-display text-2xl font-semibold text-white transition group-hover:text-amber-100">
                  {broadcast_title(sim.domain_type)}
                </h3>
                <p class="mt-1 truncate font-mono text-[11px] text-stone-600">{sim.sim_id}</p>
                <p class="mt-5 min-h-6 text-sm font-medium text-stone-300">{sim.world_summary}</p>
                <div class="mt-6 flex items-center justify-between border-t border-white/10 pt-4 text-xs text-stone-500">
                  <span>{player_count_label(sim.player_count)}</span>
                  <span class="font-semibold text-amber-200 transition group-hover:translate-x-0.5">Watch →</span>
                </div>
              </.link>
            </div>
          <% end %>
        </section>

        <section class="border-y border-white/10 bg-white/[0.02]">
          <div class="mx-auto max-w-7xl px-4 py-16 sm:px-6 lg:px-8">
            <div class="grid gap-10 lg:grid-cols-[0.7fr_1.3fr] lg:items-start">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.22em] text-violet-300/80">Always-on leagues</p>
                <h2 class="mt-3 font-display text-4xl font-semibold text-white">More arenas</h2>
                <p class="mt-4 text-sm leading-6 text-stone-400">
                  Each arena keeps a stable URL, rotates model seats, and records completed games into its own league.
                </p>
              </div>
              <div class="grid gap-3 sm:grid-cols-2">
                <article
                  :for={arena <- @other_arenas}
                  class="rounded-2xl border border-white/10 bg-black/20 p-4 transition hover:border-white/20 hover:bg-white/[0.035]"
                >
                  <div class="flex items-start justify-between gap-4">
                    <div class="flex items-center gap-3">
                      <span class="text-2xl" aria-hidden="true">{arena.icon}</span>
                      <div>
                        <h3 class="font-semibold text-white">{arena.title}</h3>
                        <p class="mt-1 text-xs text-stone-500">{arena.tagline}</p>
                      </div>
                    </div>
                    <span class={[
                      "mt-1 h-2 w-2 shrink-0 rounded-full",
                      if(arena.live?, do: "animate-pulse bg-red-400", else: "bg-stone-600")
                    ]}></span>
                  </div>
                  <div class="mt-4 flex gap-2">
                    <.link navigate={~p"/arena/#{arena.domain}"} class="public-mini-link flex-1">Watch</.link>
                    <.link navigate={~p"/arena/#{arena.domain}/leaderboard"} class="public-mini-link flex-1">League</.link>
                  </div>
                </article>
              </div>
            </div>
          </div>
        </section>

        <%= if @public_vending_launcher? do %>
          <section class="mx-auto max-w-7xl px-4 py-16 sm:px-6 lg:px-8">
            <div class="rounded-3xl border border-amber-200/15 bg-amber-200/[0.035] p-6 sm:p-8">
              <div class="flex flex-col justify-between gap-5 md:flex-row md:items-end">
                <div>
                  <p class="text-xs font-bold uppercase tracking-[0.22em] text-amber-300/80">Vending Bench</p>
                  <h2 class="mt-3 font-display text-3xl font-semibold text-white">Start a New Run</h2>
                  <p class="mt-2 text-sm text-stone-400">Launch an operator and physical worker with a fixed public preset.</p>
                </div>
                <div class="grid w-full gap-3 sm:grid-cols-2 md:w-auto">
                  <a
                    :for={preset <- @vending_model_presets}
                    href={~p"/vending_bench/start/#{preset.id}"}
                    class="group min-w-56 rounded-2xl border border-white/10 bg-black/20 p-4 transition hover:border-amber-200/30 hover:bg-amber-100/[0.05]"
                  >
                    <div class="text-sm font-bold text-white">{preset.label}</div>
                    <div class="mt-1 font-mono text-[11px] text-stone-500">{preset.model}</div>
                    <div class="mt-4 flex items-center justify-between text-[10px] font-semibold uppercase tracking-wider text-stone-500">
                      <span>{preset.max_days} days · {preset.max_turns} turns</span>
                      <span class="text-amber-200">Start →</span>
                    </div>
                  </a>
                </div>
              </div>
            </div>
          </section>
        <% end %>
      </main>

      <footer class="border-t border-white/10 bg-black/20">
        <div class="mx-auto flex max-w-7xl flex-col justify-between gap-3 px-4 py-8 text-xs text-stone-500 sm:flex-row sm:items-center sm:px-6 lg:px-8">
          <p>LemonSim turns model behavior into games you can inspect, replay, and compare.</p>
          <div class="flex gap-4">
            <.link navigate={~p"/arena/werewolf"} class="hover:text-stone-200">Werewolf arena</.link>
            <.link navigate={~p"/arena/werewolf/leaderboard"} class="hover:text-stone-200">Standings</.link>
          </div>
        </div>
      </footer>
    </div>
    """
  end

  defp assign_lobby_data(socket) do
    sims = build_lobby_list()
    arenas = build_arena_list()
    featured_werewolf = featured_werewolf(sims)

    assign(socket,
      sims: sims,
      featured_werewolf: featured_werewolf,
      other_arenas: Enum.reject(arenas, &(&1.domain == :werewolf))
    )
  end

  defp build_arena_list do
    running = SimManager.list_running()

    Enum.map(Arena.domains(), fn domain ->
      theme = LemonSimUi.ArenaDomains.get(domain)
      prefix = Arena.sim_prefix(domain)
      current_sim_id = Arena.current_sim_id(domain)

      %{
        domain: domain,
        title: theme.title,
        tagline: theme.tagline,
        icon: theme.icon,
        current_sim_id: current_sim_id,
        live?: is_binary(current_sim_id) or Enum.any?(running, &String.starts_with?(&1, prefix))
      }
    end)
  end

  defp featured_werewolf(sims) do
    arena_sim_id = Arena.current_sim_id(:werewolf)

    Enum.find(sims, &(&1.sim_id == arena_sim_id)) ||
      Enum.find(sims, &(&1.domain_type == :werewolf and &1.status == "in_progress")) ||
      Enum.find(sims, &(&1.domain_type == :werewolf))
  end

  defp build_lobby_list do
    running = SimManager.list_running() |> MapSet.new()

    managed_states =
      Store.list_states()
      |> Enum.filter(fn state -> state.sim_id in running end)

    artifact_states =
      vending_bench_artifact_states()
      |> Enum.reject(fn state -> state.sim_id in running end)

    (managed_states ++ artifact_states)
    |> Enum.map(&broadcast_summary/1)
    |> Enum.sort_by(& &1.last_activity, :desc)
  end

  defp broadcast_summary(%State{} = state) do
    summary = SimHelpers.sim_summary(state)
    players = LemonCore.MapHelpers.get_key(state.world, :players)
    arena_agents = LemonCore.MapHelpers.get_key(state.world, :arena_agents)

    player_count =
      case {players, arena_agents} do
        {_, agents} when is_list(agents) -> length(agents)
        {map, _} when is_map(map) -> map_size(map)
        _ -> nil
      end

    alive_count =
      case players do
        map when is_map(map) ->
          Enum.count(map, fn {_id, player} ->
            LemonCore.MapHelpers.get_key(player, :status) in [nil, "alive"]
          end)

        _ ->
          player_count
      end

    models =
      case players do
        map when is_map(map) ->
          map
          |> Map.values()
          |> Enum.map(&LemonCore.MapHelpers.get_key(&1, :model))
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.uniq()

        _ ->
          []
      end

    phase = LemonCore.MapHelpers.get_key(state.world, :phase) || "waiting"

    Map.merge(summary, %{
      player_count: player_count,
      alive_count: alive_count || player_count || 0,
      day_number: LemonCore.MapHelpers.get_key(state.world, :day_number) || 1,
      phase_label: format_phase(phase),
      models: models
    })
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

  defp broadcast_title(:werewolf), do: "Werewolf"
  defp broadcast_title(:vending_bench), do: "Vending Bench"
  defp broadcast_title(:tcg_shop), do: "TCG Shop"
  defp broadcast_title(domain), do: SimHelpers.domain_label(domain)

  defp player_count_label(nil), do: "Live simulation"
  defp player_count_label(1), do: "1 agent"
  defp player_count_label(count), do: "#{count} agents"

  defp format_phase(phase) when is_atom(phase), do: phase |> Atom.to_string() |> format_phase()

  defp format_phase(phase) when is_binary(phase) do
    phase
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_phase(_phase), do: "Waiting"

  defp status_badge_label("complete"), do: "REPLAY"
  defp status_badge_label(_status), do: "LIVE"

  defp status_badge_class("complete"),
    do: "border-emerald-300/20 bg-emerald-950/40 text-emerald-200"

  defp status_badge_class(_status),
    do: "border-red-300/25 bg-red-950/40 text-red-100"
end
