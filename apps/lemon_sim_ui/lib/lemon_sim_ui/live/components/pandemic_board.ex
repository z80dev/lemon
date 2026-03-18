defmodule LemonSimUi.Live.Components.PandemicBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    regions = MapHelpers.get_key(world, :regions) || %{}
    travel_routes = MapHelpers.get_key(world, :travel_routes) || %{}
    players = MapHelpers.get_key(world, :players) || %{}
    phase = MapHelpers.get_key(world, :phase) || "intelligence"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 12
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || []
    resource_pool = MapHelpers.get_key(world, :resource_pool) || %{}
    disease = MapHelpers.get_key(world, :disease) || %{}
    public_stats = MapHelpers.get_key(world, :public_stats) || %{}
    comm_history = MapHelpers.get_key(world, :comm_history) || []
    hoarding_log = MapHelpers.get_key(world, :hoarding_log) || []
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)

    # Region grid layout: 2 rows x 3 columns
    # Row 1: northvale, central_hub, highland
    # Row 2: westport, southshore, eastlands
    region_grid = [
      ["northvale", "central_hub", "highland"],
      ["westport", "southshore", "eastlands"]
    ]

    # Build sorted governor list with region stats
    sorted_governors =
      players
      |> Enum.map(fn {gov_id, gov_data} ->
        gov_id_str = to_string(gov_id)
        region_id = get_val(gov_data, :region, gov_id_str)
        region = Map.get(regions, region_id, %{})
        pop = get_val(region, :population, 1)
        dead = get_val(region, :dead, 0)
        infected = get_val(region, :infected, 0)
        death_rate = if pop > 0, do: Float.round(dead / pop * 100, 2), else: 0.0
        {gov_id_str, gov_data, region_id, dead, infected, death_rate}
      end)
      |> Enum.sort_by(fn {_, _, _, _, _, rate} -> rate end)

    # Total stats
    total_pop = Enum.sum(Enum.map(regions, fn {_, r} -> get_val(r, :population, 0) end))
    total_dead = Enum.sum(Enum.map(regions, fn {_, r} -> get_val(r, :dead, 0) end))
    total_infected = Enum.sum(Enum.map(regions, fn {_, r} -> get_val(r, :infected, 0) end))
    death_threshold = trunc(total_pop * 0.10)
    global_death_rate = if total_pop > 0, do: Float.round(total_dead / total_pop * 100, 2), else: 0.0

    # Active governor info
    active_governor_data =
      if active_actor_id do
        gid_str = to_string(active_actor_id)
        Map.get(players, active_actor_id) || Map.get(players, gid_str, %{})
      else
        %{}
      end

    active_governor_region = get_val(active_governor_data, :region, "")

    # Recent comms (last 8)
    recent_comms =
      comm_history
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    # Pool counts
    pool_vaccines = get_val(resource_pool, :vaccines, 0)
    pool_funding = get_val(resource_pool, :funding, 0)
    pool_medical = get_val(resource_pool, :medical_teams, 0)

    # Research progress
    research_progress = get_val(disease, :research_progress, 0)

    # Phase done count
    phase_done = MapHelpers.get_key(world, :phase_done) || MapSet.new()

    done_count =
      cond do
        is_struct(phase_done, MapSet) -> MapSet.size(phase_done)
        is_list(phase_done) -> length(phase_done)
        is_map(phase_done) -> map_size(phase_done)
        true -> 0
      end

    total_players =
      players
      |> Enum.count(fn {_gid, gd} -> get_val(gd, :status, "active") == "active" end)

    assigns =
      assigns
      |> assign(:regions, regions)
      |> assign(:travel_routes, travel_routes)
      |> assign(:players, players)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:active_governor_region, active_governor_region)
      |> assign(:turn_order, turn_order)
      |> assign(:resource_pool, resource_pool)
      |> assign(:pool_vaccines, pool_vaccines)
      |> assign(:pool_funding, pool_funding)
      |> assign(:pool_medical, pool_medical)
      |> assign(:disease, disease)
      |> assign(:research_progress, research_progress)
      |> assign(:public_stats, public_stats)
      |> assign(:comm_history, comm_history)
      |> assign(:recent_comms, recent_comms)
      |> assign(:hoarding_log, hoarding_log)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:region_grid, region_grid)
      |> assign(:sorted_governors, sorted_governors)
      |> assign(:total_pop, total_pop)
      |> assign(:total_dead, total_dead)
      |> assign(:total_infected, total_infected)
      |> assign(:death_threshold, death_threshold)
      |> assign(:global_death_rate, global_death_rate)
      |> assign(:done_count, done_count)
      |> assign(:total_players, total_players)

    ~H"""
    <div class="relative w-full font-sans" style="background: #060d0d; color: #e8f5f5; min-height: 640px;">
      <style>
        /* ── Infection Pulse ── */
        @keyframes pan-infection-pulse {
          0%, 100% { filter: brightness(1); }
          50% { filter: brightness(1.2); }
        }
        .pan-infected-high { animation: pan-infection-pulse 1.5s ease-in-out infinite; }

        /* ── Spread Wave ── */
        @keyframes pan-spread {
          0% { opacity: 0.3; transform: scale(0.95); }
          50% { opacity: 0.8; transform: scale(1.05); }
          100% { opacity: 0.3; transform: scale(0.95); }
        }
        .pan-spread-active { animation: pan-spread 3s ease-in-out infinite; }

        /* ── Quarantine Shimmer ── */
        @keyframes pan-quarantine-shimmer {
          0%, 100% { box-shadow: 0 0 8px 2px rgba(26, 188, 156, 0.2); }
          50% { box-shadow: 0 0 20px 6px rgba(26, 188, 156, 0.5); }
        }
        .pan-quarantine-active { animation: pan-quarantine-shimmer 2s ease-in-out infinite; }

        /* ── Crisis Alert ── */
        @keyframes pan-crisis-flash {
          0%, 100% { border-color: rgba(192, 57, 43, 0.3); }
          50% { border-color: rgba(192, 57, 43, 0.9); }
        }
        .pan-crisis { animation: pan-crisis-flash 1s ease-in-out infinite; }

        /* ── Scanline ── */
        @keyframes pan-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .pan-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(26, 188, 156, 0.1), transparent);
          animation: pan-scanline 5s linear infinite;
          pointer-events: none;
        }

        /* ── Victory/Defeat Entrance ── */
        @keyframes pan-outcome-enter {
          from { opacity: 0; transform: scale(0.8) translateY(20px); }
          to { opacity: 1; transform: scale(1) translateY(0); }
        }
        .pan-outcome { animation: pan-outcome-enter 0.8s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

        /* ── Phase Breathe ── */
        @keyframes pan-phase-breathe {
          0%, 100% { opacity: 0.6; }
          50% { opacity: 1; }
        }
        .pan-phase-active { animation: pan-phase-breathe 2s ease-in-out infinite; }

        /* ── Neon glows ── */
        .pan-neon-teal { text-shadow: 0 0 8px rgba(26, 188, 156, 0.5); }
        .pan-neon-red { text-shadow: 0 0 8px rgba(192, 57, 43, 0.6); }
        .pan-neon-amber { text-shadow: 0 0 8px rgba(243, 156, 18, 0.5); }
        .pan-neon-green { text-shadow: 0 0 8px rgba(39, 174, 96, 0.5); }
      </style>

      <%!-- ═══════════════ STATUS BAR ═══════════════ --%>
      <div class="relative overflow-hidden pan-scanline" style="background: linear-gradient(90deg, rgba(26, 188, 156, 0.06), rgba(6, 13, 13, 0.95), rgba(192, 57, 43, 0.06)); border-bottom: 1px solid rgba(26, 188, 156, 0.12);">
        <div class="relative px-4 py-2.5 flex items-center justify-between">
          <%!-- Left: Game Identity --%>
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 rounded-full bg-teal-400 pan-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.25em] uppercase" style="color: #1abc9c;">PANDEMIC RESPONSE</span>
            </div>
            <div class="h-4 w-px" style="background: rgba(26,188,156,0.15);"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-mono text-gray-500">RND</span>
              <span class="text-sm font-black text-white tabular-nums">{@round}</span>
              <span class="text-[10px] text-gray-600">/ {@max_rounds}</span>
            </div>
          </div>

          <%!-- Center: Phase Badge --%>
          <div class="flex items-center gap-2">
            <div class={[
              "px-3 py-1 rounded-full border text-[10px] font-bold tracking-wider uppercase",
              pan_phase_badge_class(@phase)
            ]}>
              {pan_phase_label(@phase)}
            </div>
            <div class="text-[10px] text-gray-500 tabular-nums">
              {@done_count}/{@total_players} done
            </div>
          </div>

          <%!-- Right: Global stats + threshold --%>
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] text-gray-500">INFECTED:</span>
              <span class="text-[11px] font-bold tabular-nums" style="color: #e67e22;">{format_stat(@total_infected)}</span>
            </div>
            <div class="h-4 w-px" style="background: rgba(26,188,156,0.12);"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] text-gray-500">DEAD:</span>
              <span class={[
                "text-[11px] font-bold tabular-nums",
                if(@total_dead >= @death_threshold, do: "pan-neon-red", else: "")
              ]} style={"color: #{if @total_dead >= @death_threshold, do: "#c0392b", else: "#7f8c8d"};"}>
                {format_stat(@total_dead)}
              </span>
              <span class="text-[9px] text-gray-600">/ {format_stat(@death_threshold)}</span>
            </div>
            <div class="h-4 w-px" style="background: rgba(26,188,156,0.12);"></div>
            <div class="flex items-center gap-1">
              <span class="text-[10px] text-gray-500">DEATH RATE:</span>
              <span class={[
                "text-[11px] font-bold",
                rate_color_class(@global_death_rate)
              ]}>{@global_death_rate}%</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ MAIN CONTENT ═══════════════ --%>
      <div class="flex" style="min-height: 560px;">

        <%!-- ──── LEFT: REGION MAP + CONNECTIONS ──── --%>
        <div class="flex-1 p-4 overflow-y-auto">

          <%!-- Map Header --%>
          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full" style="background: rgba(26,188,156,0.7);"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(26,188,156,0.5);">REGIONAL OUTBREAK MAP</span>
            <div class="flex-1 h-px" style="background: linear-gradient(to right, rgba(26,188,156,0.2), transparent);"></div>
          </div>

          <%!-- Region Grid --%>
          <div class="relative rounded-xl overflow-hidden" style="background: linear-gradient(135deg, rgba(10, 20, 20, 0.8), rgba(6, 13, 13, 0.95)); border: 1px solid rgba(26, 188, 156, 0.08);">
            <div class="relative p-4">
              <div class="grid grid-cols-3 gap-3">
                <%= for row <- @region_grid, region_id <- row do %>
                  <% region = Map.get(@regions, region_id, %{}) %>
                  <% pop = get_val(region, :population, 1) %>
                  <% infected = get_val(region, :infected, 0) %>
                  <% dead = get_val(region, :dead, 0) %>
                  <% recovered = get_val(region, :recovered, 0) %>
                  <% hospitals = get_val(region, :hospitals, 1) %>
                  <% quarantined = get_val(region, :quarantined, false) %>
                  <% vaccinated = get_val(region, :vaccinated, 0) %>
                  <% infection_rate = if pop > 0, do: Float.round(infected / pop * 100, 1), else: 0.0 %>
                  <% sev_color = infection_severity_color(infection_rate) %>
                  <% is_active = to_string(@active_governor_region) == region_id %>

                  <%!-- Find governor for this region --%>
                  <% governor_id = Enum.find_value(@players, nil, fn {gid, gdata} ->
                    if to_string(get_val(gdata, :region, "")) == region_id, do: gid, else: nil
                  end) %>

                  <div class={[
                    "relative rounded-lg p-3 border transition-all",
                    if(quarantined, do: "pan-quarantine-active", else: ""),
                    if(is_active, do: "ring-1", else: ""),
                    if(infection_rate >= 15.0, do: "pan-crisis", else: "")
                  ]} style={"background: rgba(6, 13, 13, 0.8); border-color: #{sev_color}33; #{if is_active, do: "ring-color: #{governor_color(to_string(governor_id || ""))};", else: ""}"}>

                    <%!-- Region Name + Quarantine badge --%>
                    <div class="flex items-start justify-between mb-1.5">
                      <span class="text-[11px] font-black uppercase tracking-wider" style={"color: #{sev_color};"}>
                        {region_id}
                      </span>
                      <div class="flex items-center gap-1">
                        <span :if={quarantined} class="text-[8px] font-bold px-1 py-0.5 rounded" style="background: rgba(26,188,156,0.15); color: #1abc9c;">QUARANTINE</span>
                        <span class="text-[8px]" style="color: #3d6666;">H:{hospitals}</span>
                      </div>
                    </div>

                    <%!-- Infection bar --%>
                    <div class="w-full rounded-full mb-1.5" style="background: rgba(30,30,30,0.8); height: 4px;">
                      <div class="rounded-full h-full" style={"width: #{min(infection_rate / 30.0 * 100, 100)}%; background: #{sev_color}; opacity: 0.85;"}></div>
                    </div>

                    <%!-- Stats grid --%>
                    <div class="grid grid-cols-2 gap-x-2 gap-y-0.5">
                      <div class="text-[9px]" style="color: #e67e22;">
                        <span style="color: #3d6666;">INFECT</span> {format_stat(infected)}
                      </div>
                      <div class="text-[9px]" style="color: #7f8c8d;">
                        <span style="color: #3d6666;">DEAD</span> {format_stat(dead)}
                      </div>
                      <div class="text-[9px]" style="color: #27ae60;">
                        <span style="color: #3d6666;">RECOV</span> {format_stat(recovered)}
                      </div>
                      <div class="text-[9px]" style="color: #1abc9c;">
                        <span style="color: #3d6666;">VAX</span> {format_stat(vaccinated)}
                      </div>
                    </div>

                    <%!-- Rate badge --%>
                    <div class="mt-1 text-right">
                      <span class="text-[10px] font-bold" style={"color: #{sev_color};"}>
                        {infection_rate}%
                      </span>
                    </div>

                    <%!-- Governor badge --%>
                    <div :if={governor_id} class="mt-1 pt-1" style="border-top: 1px solid rgba(26,188,156,0.08);">
                      <span class="text-[8px]" style={"color: #{governor_color(to_string(governor_id))};"}>
                        {format_governor_name(to_string(governor_id))}
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- ── Resource Pool ── --%>
          <div class="mt-4 rounded-lg p-3" style="background: rgba(10, 20, 20, 0.9); border: 1px solid rgba(26, 188, 156, 0.1);">
            <div class="flex items-center gap-2 mb-2">
              <div class="w-1 h-1 rounded-full" style="background: rgba(26,188,156,0.7);"></div>
              <span class="text-[10px] font-bold tracking-[0.15em] uppercase" style="color: rgba(26,188,156,0.5);">SHARED RESOURCE POOL</span>
            </div>
            <div class="grid grid-cols-3 gap-3">
              <div class="rounded p-2" style="background: rgba(39, 174, 96, 0.06); border: 1px solid rgba(39, 174, 96, 0.12);">
                <div class="text-[9px] mb-1" style="color: #3d6666;">VACCINES</div>
                <div class="text-base font-black tabular-nums" style="color: #27ae60;">{format_stat(@pool_vaccines)}</div>
              </div>
              <div class="rounded p-2" style="background: rgba(243, 156, 18, 0.06); border: 1px solid rgba(243, 156, 18, 0.12);">
                <div class="text-[9px] mb-1" style="color: #3d6666;">FUNDING</div>
                <div class="text-base font-black tabular-nums" style="color: #f39c12;">{@pool_funding}</div>
              </div>
              <div class="rounded p-2" style="background: rgba(26, 188, 156, 0.06); border: 1px solid rgba(26, 188, 156, 0.12);">
                <div class="text-[9px] mb-1" style="color: #3d6666;">MED TEAMS</div>
                <div class="text-base font-black tabular-nums" style="color: #1abc9c;">{@pool_medical}</div>
              </div>
            </div>
          </div>

          <%!-- ── Research Progress ── --%>
          <div class="mt-3 rounded-lg p-3" style="background: rgba(10, 20, 20, 0.9); border: 1px solid rgba(26, 188, 156, 0.08);">
            <div class="flex items-center justify-between mb-1.5">
              <span class="text-[10px] font-bold tracking-[0.15em] uppercase" style="color: rgba(26,188,156,0.4);">RESEARCH PROGRESS</span>
              <span class="text-[11px] font-black" style="color: #1abc9c;">{@research_progress} pts</span>
            </div>
            <div class="w-full rounded-full" style="background: rgba(20,40,40,0.8); height: 6px;">
              <div class="rounded-full h-full" style={"width: #{min(@research_progress / 100.0 * 100, 100)}%; background: linear-gradient(90deg, #1abc9c, #27ae60);"}></div>
            </div>
          </div>

        </div>

        <%!-- ──── RIGHT: GOVERNOR PANEL + COMMS ──── --%>
        <div class="w-72 border-l p-3 flex flex-col gap-3 overflow-y-auto" style="border-color: rgba(26, 188, 156, 0.08); min-height: 560px;">

          <%!-- Governor Status --%>
          <div>
            <div class="flex items-center gap-2 mb-2">
              <span class="text-[10px] font-bold tracking-[0.15em] uppercase" style="color: rgba(26,188,156,0.4);">GOVERNORS</span>
            </div>

            <div class="flex flex-col gap-1.5">
              <%= for {gov_id_str, gov_data, region_id, dead, infected, death_rate} <- @sorted_governors do %>
                <% resources = get_val(gov_data, :resources, %{}) %>
                <% vaccines = get_val(resources, :vaccines, 0) %>
                <% funding = get_val(resources, :funding, 0) %>
                <% medical = get_val(resources, :medical_teams, 0) %>
                <% is_active = to_string(@active_actor_id) == gov_id_str %>
                <% color = governor_color(gov_id_str) %>

                <div class={[
                  "rounded-lg p-2.5 transition-all",
                  if(is_active, do: "ring-1", else: "")
                ]} style={"background: rgba(10,20,20,0.8); border: 1px solid #{color}22; #{if is_active, do: "ring-color: #{color}; box-shadow: 0 0 12px #{color}22;", else: ""}"}>
                  <div class="flex items-center justify-between mb-1">
                    <div class="flex items-center gap-1.5">
                      <div class="w-2 h-2 rounded-full" style={"background: #{color}; #{if is_active, do: "box-shadow: 0 0 6px #{color};", else: ""}"} ></div>
                      <span class="text-[10px] font-bold" style={"color: #{color};"}>
                        {format_governor_name(gov_id_str)}
                      </span>
                    </div>
                    <span class="text-[9px]" style="color: #3d6666;">{region_id}</span>
                  </div>

                  <%!-- Death rate bar --%>
                  <div class="w-full rounded-full mb-1" style="background: rgba(20,30,30,0.8); height: 3px;">
                    <div class="rounded-full h-full" style={"width: #{min(death_rate / 10.0 * 100, 100)}%; background: #{rate_color(death_rate)};"}></div>
                  </div>

                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span class="text-[8px]" style="color: #e67e22;">INF:{format_stat(infected)}</span>
                      <span class="text-[8px]" style="color: #7f8c8d;">DEAD:{format_stat(dead)}</span>
                    </div>
                    <span class="text-[9px] font-bold" style={"color: #{rate_color(death_rate)};"}>
                      {death_rate}%
                    </span>
                  </div>

                  <%!-- Resources mini --%>
                  <div class="mt-1 flex items-center gap-1.5">
                    <span class="text-[8px]" style="color: #27ae60;">V:{format_stat(vaccines)}</span>
                    <span class="text-[8px]" style="color: #f39c12;">F:{funding}</span>
                    <span class="text-[8px]" style="color: #1abc9c;">M:{medical}</span>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Recent Communications --%>
          <div>
            <div class="flex items-center gap-2 mb-2">
              <span class="text-[10px] font-bold tracking-[0.15em] uppercase" style="color: rgba(26,188,156,0.4);">COMMS LOG</span>
              <span class="text-[9px]" style="color: #3d6666;">({length(@comm_history)} total)</span>
            </div>

            <div class="rounded-lg p-2" style="background: rgba(8, 16, 16, 0.9); border: 1px solid rgba(26,188,156,0.06);">
              <%= if @recent_comms == [] do %>
                <div class="text-[10px] text-center py-2" style="color: #3d6666;">No communications yet</div>
              <% else %>
                <%= for msg <- @recent_comms do %>
                  <% from_id = to_string(get_val(msg, :from, get_val(msg, "from", "?"))) %>
                  <% to_id = to_string(get_val(msg, :to, get_val(msg, "to", "?"))) %>
                  <% type = get_val(msg, :type, get_val(msg, "type", "data")) %>
                  <% type_label = if type == "help_request", do: "HELP", else: "DATA" %>
                  <% type_color = if type == "help_request", do: "#e67e22", else: "#1abc9c" %>

                  <div class="flex items-center gap-1.5 py-1 border-b last:border-0" style="border-color: rgba(26,188,156,0.06);">
                    <span class="text-[8px] font-bold px-1 rounded" style={"background: #{type_color}22; color: #{type_color};"}>
                      {type_label}
                    </span>
                    <span class="text-[8px] font-semibold" style={"color: #{governor_color(from_id)};"}>
                      {format_governor_name(from_id)}
                    </span>
                    <span class="text-[8px]" style="color: #3d6666;">&#x2192;</span>
                    <span class="text-[8px] font-semibold" style={"color: #{governor_color(to_id)};"}>
                      {format_governor_name(to_id)}
                    </span>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>

          <%!-- Hoarding Incidents --%>
          <div :if={@hoarding_log != []}>
            <div class="flex items-center gap-2 mb-2">
              <span class="text-[10px] font-bold tracking-[0.15em] uppercase" style="color: rgba(192,57,43,0.7);">HOARDING INCIDENTS</span>
            </div>
            <div class="rounded-lg p-2" style="background: rgba(192, 57, 43, 0.06); border: 1px solid rgba(192, 57, 43, 0.15);">
              <%= for incident <- Enum.take(@hoarding_log, -5) do %>
                <% gov = to_string(get_val(incident, :governor, get_val(incident, "governor", "?"))) %>
                <% irnd = get_val(incident, :round, get_val(incident, "round", "?")) %>
                <div class="text-[9px] py-0.5" style="color: #c0392b;">
                  R{irnd}: {format_governor_name(gov)} hoarded supplies
                </div>
              <% end %>
            </div>
          </div>

        </div>
      </div>

      <%!-- ═══════════════ OUTCOME OVERLAY ═══════════════ --%>
      <div :if={@game_status in ["won", "lost"]} class="absolute inset-0 flex items-center justify-center" style="background: rgba(6, 13, 13, 0.85); z-index: 50;">
        <div class="pan-outcome rounded-2xl p-8 text-center max-w-md" style={"background: rgba(10, 20, 20, 0.98); border: 2px solid #{if @game_status == "won", do: "#27ae60", else: "#c0392b"};"}>
          <div class="text-4xl font-black mb-2" style={"color: #{if @game_status == "won", do: "#27ae60", else: "#c0392b"};"}>
            {if @game_status == "won", do: "TEAM VICTORY", else: "TEAM DEFEAT"}
          </div>
          <div class="text-sm mb-4" style="color: #7fb3b3;">
            {if @game_status == "won",
              do: "The team successfully contained the pandemic!",
              else: "The pandemic overwhelmed global defenses."}
          </div>
          <div class="grid grid-cols-2 gap-4 mt-4">
            <div class="rounded p-3" style="background: rgba(127, 140, 141, 0.08);">
              <div class="text-xs mb-1" style="color: #3d6666;">TOTAL DEATHS</div>
              <div class="text-xl font-black" style={"color: #{if @game_status == "won", do: "#27ae60", else: "#c0392b"};"}>
                {format_stat(@total_dead)}
              </div>
            </div>
            <div class="rounded p-3" style="background: rgba(127, 140, 141, 0.08);">
              <div class="text-xs mb-1" style="color: #3d6666;">DEATH RATE</div>
              <div class="text-xl font-black" style={"color: #{if @game_status == "won", do: "#27ae60", else: "#c0392b"};"}>
                {@global_death_rate}%
              </div>
            </div>
          </div>
        </div>
      </div>

    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helper functions
  # ---------------------------------------------------------------------------

  defp pan_phase_label("intelligence"), do: "INTELLIGENCE"
  defp pan_phase_label("communication"), do: "COMMUNICATION"
  defp pan_phase_label("resource_allocation"), do: "ALLOCATION"
  defp pan_phase_label("local_action"), do: "LOCAL ACTION"
  defp pan_phase_label(other), do: String.upcase(to_string(other))

  defp pan_phase_badge_class("intelligence"),
    do: "border-blue-700/40 text-blue-400 bg-blue-900/20"

  defp pan_phase_badge_class("communication"),
    do: "border-purple-700/40 text-purple-400 bg-purple-900/20"

  defp pan_phase_badge_class("resource_allocation"),
    do: "border-amber-700/40 text-amber-400 bg-amber-900/20"

  defp pan_phase_badge_class("local_action"),
    do: "border-teal-700/40 text-teal-400 bg-teal-900/20"

  defp pan_phase_badge_class(_), do: "border-gray-700/40 text-gray-400 bg-gray-900/20"

  defp rate_color_class(rate) when rate >= 5.0, do: "pan-neon-red"
  defp rate_color_class(rate) when rate >= 1.0, do: "pan-neon-amber"
  defp rate_color_class(_), do: "pan-neon-green"

  defp rate_color(rate) when rate >= 10.0, do: "#c0392b"
  defp rate_color(rate) when rate >= 5.0, do: "#e67e22"
  defp rate_color(rate) when rate >= 1.0, do: "#f39c12"
  defp rate_color(_), do: "#27ae60"

  defp infection_severity_color(rate) when rate >= 15.0, do: "#c0392b"
  defp infection_severity_color(rate) when rate >= 5.0, do: "#e67e22"
  defp infection_severity_color(rate) when rate >= 1.0, do: "#f39c12"
  defp infection_severity_color(_), do: "#27ae60"

  @governor_colors [
    "#3498db",
    "#9b59b6",
    "#1abc9c",
    "#e74c3c",
    "#f39c12",
    "#e91e63"
  ]

  defp governor_color("governor_1"), do: Enum.at(@governor_colors, 0)
  defp governor_color("governor_2"), do: Enum.at(@governor_colors, 1)
  defp governor_color("governor_3"), do: Enum.at(@governor_colors, 2)
  defp governor_color("governor_4"), do: Enum.at(@governor_colors, 3)
  defp governor_color("governor_5"), do: Enum.at(@governor_colors, 4)
  defp governor_color("governor_6"), do: Enum.at(@governor_colors, 5)
  defp governor_color(_), do: "#7fb3b3"

  defp format_governor_name("governor_" <> n), do: "Governor #{n}"
  defp format_governor_name(name) when is_binary(name), do: name
  defp format_governor_name(_), do: "?"

  defp format_stat(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_stat(n) when is_integer(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_stat(n) when is_number(n), do: to_string(trunc(n))
  defp format_stat(nil), do: "0"
  defp format_stat(other), do: to_string(other)

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        try do
          Map.get(map, String.to_existing_atom(key), default)
        rescue
          ArgumentError -> default
        end

      val ->
        val
    end
  end

  defp get_val(_, _, default), do: default
end
