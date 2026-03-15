defmodule LemonSimUi.Live.Components.SpaceStationBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    players = MapHelpers.get_key(world, :players) || %{}
    systems = MapHelpers.get_key(world, :systems) || %{}
    phase = MapHelpers.get_key(world, :phase) || "action"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 8
    active_actor = MapHelpers.get_key(world, :active_actor_id)
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    action_log = MapHelpers.get_key(world, :action_log) || %{}
    action_history = MapHelpers.get_key(world, :action_history) || []
    location_log = MapHelpers.get_key(world, :location_log) || []
    round_reports = MapHelpers.get_key(world, :round_reports) || []
    discussion_transcript = MapHelpers.get_key(world, :discussion_transcript) || []
    discussion_round = MapHelpers.get_key(world, :discussion_round) || 0
    discussion_round_limit = MapHelpers.get_key(world, :discussion_round_limit) || 3
    votes = MapHelpers.get_key(world, :votes) || %{}
    vote_history = MapHelpers.get_key(world, :vote_history) || []
    emergency_meeting_available = MapHelpers.get_key(world, :emergency_meeting_available) || false
    emergency_meeting_called = MapHelpers.get_key(world, :emergency_meeting_called) || false
    captain_lock = MapHelpers.get_key(world, :captain_lock)
    scan_results = MapHelpers.get_key(world, :scan_results) || %{}
    elimination_log = MapHelpers.get_key(world, :elimination_log) || []
    traits = MapHelpers.get_key(world, :traits) || %{}
    connections = MapHelpers.get_key(world, :connections) || []
    journals = MapHelpers.get_key(world, :journals) || %{}
    active_crisis = MapHelpers.get_key(world, :active_crisis)
    clues = MapHelpers.get_key(world, :clues) || %{}
    accusations = MapHelpers.get_key(world, :accusations) || []

    sorted_players = Enum.sort_by(players, fn {id, _p} -> id end)

    alive_players =
      sorted_players
      |> Enum.filter(fn {_id, p} -> get_val(p, :status, "alive") == "alive" end)

    ejected_players =
      sorted_players
      |> Enum.filter(fn {_id, p} -> get_val(p, :status, "alive") == "ejected" end)

    # System health calculations
    system_list =
      systems
      |> Enum.sort_by(fn {id, _s} -> id end)
      |> Enum.map(fn {id, sys} ->
        health = get_val(sys, :health, 100)
        name = get_val(sys, :name, id)
        decay = get_val(sys, :decay_rate, 0)
        {id, name, health, decay}
      end)

    min_health =
      case system_list do
        [] -> 100
        list -> list |> Enum.map(fn {_, _, h, _} -> h end) |> Enum.min()
      end

    threat = threat_level(min_health)

    # Vote tally
    vote_tally =
      votes
      |> Enum.reject(fn {_voter, target} -> target == "skip" end)
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    skip_count = votes |> Enum.count(fn {_voter, target} -> target == "skip" end)

    # Latest round report
    latest_report =
      case round_reports do
        [] -> nil
        reports -> List.last(reports)
      end

    # System changes from latest report
    system_changes =
      if latest_report do
        get_val(latest_report, :system_changes, %{})
      else
        %{}
      end

    # Visible visits from latest report
    visible_visits =
      if latest_report do
        get_val(latest_report, :visible_visits, [])
      else
        []
      end

    # Unseen players
    unseen_players =
      if latest_report do
        get_val(latest_report, :unseen_players, [])
      else
        []
      end

    # Critical systems from latest report
    critical_systems =
      if latest_report do
        get_val(latest_report, :critical_systems, [])
      else
        system_list |> Enum.filter(fn {_, _, h, _} -> h < 30 end) |> Enum.map(fn {id, _, _, _} -> id end)
      end

    any_critical = critical_systems != []

    # Latest ejection for dramatic sequence
    latest_ejection =
      case elimination_log do
        [] -> nil
        log -> List.last(log)
      end

    show_ejection =
      latest_ejection != nil and
        get_val(latest_ejection, :round, 0) == round and
        phase == "action"

    rounds_remaining = max(0, max_rounds - round + 1)

    assigns =
      assigns
      |> assign(:players, players)
      |> assign(:sorted_players, sorted_players)
      |> assign(:alive_players, alive_players)
      |> assign(:ejected_players, ejected_players)
      |> assign(:systems, systems)
      |> assign(:system_list, system_list)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:rounds_remaining, rounds_remaining)
      |> assign(:active_actor, active_actor)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:action_log, action_log)
      |> assign(:action_history, action_history)
      |> assign(:location_log, location_log)
      |> assign(:discussion_transcript, discussion_transcript)
      |> assign(:discussion_round, discussion_round)
      |> assign(:discussion_round_limit, discussion_round_limit)
      |> assign(:votes, votes)
      |> assign(:vote_tally, vote_tally)
      |> assign(:skip_count, skip_count)
      |> assign(:vote_history, vote_history)
      |> assign(:emergency_meeting_available, emergency_meeting_available)
      |> assign(:emergency_meeting_called, emergency_meeting_called)
      |> assign(:captain_lock, captain_lock)
      |> assign(:scan_results, scan_results)
      |> assign(:elimination_log, elimination_log)
      |> assign(:threat, threat)
      |> assign(:min_health, min_health)
      |> assign(:any_critical, any_critical)
      |> assign(:critical_systems, critical_systems)
      |> assign(:system_changes, system_changes)
      |> assign(:visible_visits, visible_visits)
      |> assign(:unseen_players, unseen_players)
      |> assign(:latest_ejection, latest_ejection)
      |> assign(:show_ejection, show_ejection)
      |> assign(:traits, traits)
      |> assign(:connections, connections)
      |> assign(:journals, journals)
      |> assign(:recent_journals, recent_journals(journals))
      |> assign(:active_crisis, active_crisis)
      |> assign(:clues, clues)
      |> assign(:accusations, accusations)

    ~H"""
    <div class="ss-board relative font-sans w-full min-h-[700px] flex flex-col rounded-xl overflow-hidden">
      <style>
        /* ── Base Station Aesthetic ─────────────────────────────── */
        .ss-board {
          background: linear-gradient(170deg, #030712 0%, #0a0f1e 40%, #0f172a 100%);
          color: #e2e8f0;
        }

        /* Starfield background */
        .ss-starfield {
          position: absolute;
          inset: 0;
          overflow: hidden;
          pointer-events: none;
          z-index: 0;
        }
        .ss-starfield::before {
          content: '';
          position: absolute;
          width: 200%;
          height: 200%;
          top: -50%;
          left: -50%;
          background-image:
            radial-gradient(1px 1px at 10% 20%, rgba(255,255,255,0.6), transparent),
            radial-gradient(1px 1px at 30% 65%, rgba(255,255,255,0.4), transparent),
            radial-gradient(1.5px 1.5px at 50% 10%, rgba(255,255,255,0.7), transparent),
            radial-gradient(1px 1px at 70% 40%, rgba(255,255,255,0.3), transparent),
            radial-gradient(1px 1px at 85% 80%, rgba(255,255,255,0.5), transparent),
            radial-gradient(1.5px 1.5px at 15% 85%, rgba(255,255,255,0.6), transparent),
            radial-gradient(1px 1px at 45% 50%, rgba(255,255,255,0.4), transparent),
            radial-gradient(1px 1px at 60% 25%, rgba(255,255,255,0.3), transparent),
            radial-gradient(1px 1px at 90% 15%, rgba(255,255,255,0.5), transparent),
            radial-gradient(1.5px 1.5px at 25% 45%, rgba(255,255,255,0.6), transparent),
            radial-gradient(1px 1px at 75% 70%, rgba(255,255,255,0.4), transparent),
            radial-gradient(1px 1px at 5% 55%, rgba(255,255,255,0.3), transparent),
            radial-gradient(1px 1px at 55% 90%, rgba(255,255,255,0.5), transparent),
            radial-gradient(1px 1px at 95% 50%, rgba(255,255,255,0.4), transparent),
            radial-gradient(1.5px 1.5px at 40% 35%, rgba(255,255,255,0.7), transparent),
            radial-gradient(1px 1px at 80% 5%, rgba(255,255,255,0.3), transparent),
            radial-gradient(1px 1px at 35% 95%, rgba(255,255,255,0.4), transparent),
            radial-gradient(1px 1px at 65% 60%, rgba(255,255,255,0.5), transparent);
          animation: ss-drift 120s linear infinite;
        }
        @keyframes ss-drift {
          0% { transform: translate(0, 0); }
          100% { transform: translate(-5%, -3%); }
        }

        /* Scan line overlay */
        .ss-scanlines {
          position: absolute;
          inset: 0;
          pointer-events: none;
          z-index: 1;
          background: repeating-linear-gradient(
            0deg,
            transparent,
            transparent 2px,
            rgba(6, 182, 212, 0.015) 2px,
            rgba(6, 182, 212, 0.015) 4px
          );
        }

        /* ── System Health Gauges ──────────────────────────────── */
        @keyframes ss-gauge-fill {
          from { width: 0%; }
        }
        .ss-gauge-bar {
          animation: ss-gauge-fill 1s ease-out;
          transition: width 0.8s ease-in-out, background-color 0.5s ease;
        }

        @keyframes ss-critical-pulse {
          0%, 100% { opacity: 1; box-shadow: 0 0 8px rgba(239, 68, 68, 0.4); }
          50% { opacity: 0.7; box-shadow: 0 0 20px rgba(239, 68, 68, 0.8); }
        }
        .ss-critical { animation: ss-critical-pulse 1s ease-in-out infinite; }

        @keyframes ss-critical-border {
          0%, 100% { border-color: rgba(239, 68, 68, 0.3); }
          50% { border-color: rgba(239, 68, 68, 0.8); }
        }
        .ss-critical-border { animation: ss-critical-border 1s ease-in-out infinite; }

        @keyframes ss-warning-flash {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.3; }
        }
        .ss-warning-flash { animation: ss-warning-flash 0.8s ease-in-out infinite; }

        /* ── Crew & Role Effects ───────────────────────────────── */
        @keyframes ss-active-glow {
          0%, 100% { box-shadow: 0 0 10px rgba(6, 182, 212, 0.4), 0 0 20px rgba(6, 182, 212, 0.15); }
          50% { box-shadow: 0 0 18px rgba(6, 182, 212, 0.7), 0 0 35px rgba(6, 182, 212, 0.3); }
        }
        .ss-active-crew { animation: ss-active-glow 2s ease-in-out infinite; }

        @keyframes ss-saboteur-aura {
          0%, 100% { box-shadow: inset 0 0 15px rgba(239, 68, 68, 0.1), 0 0 5px rgba(239, 68, 68, 0.15); }
          50% { box-shadow: inset 0 0 25px rgba(239, 68, 68, 0.2), 0 0 10px rgba(239, 68, 68, 0.25); }
        }
        .ss-saboteur-aura { animation: ss-saboteur-aura 3s ease-in-out infinite; }

        @keyframes ss-scanner-sweep {
          0% { background-position: -200% 0; }
          100% { background-position: 200% 0; }
        }
        .ss-scanner-sweep {
          background: linear-gradient(90deg, transparent 0%, rgba(168, 85, 247, 0.15) 50%, transparent 100%);
          background-size: 200% 100%;
          animation: ss-scanner-sweep 3s ease-in-out infinite;
        }

        /* Captain lock shield */
        @keyframes ss-shield-pulse {
          0%, 100% { box-shadow: 0 0 8px rgba(234, 179, 8, 0.3); }
          50% { box-shadow: 0 0 16px rgba(234, 179, 8, 0.6); }
        }
        .ss-shield { animation: ss-shield-pulse 2s ease-in-out infinite; }

        /* ── Ejection Sequence ─────────────────────────────────── */
        @keyframes ss-airlock-open {
          0% { transform: translateX(0) scale(1); opacity: 1; }
          30% { transform: translateX(0) scale(1.05); opacity: 1; }
          100% { transform: translateX(200px) scale(0.3); opacity: 0; }
        }
        .ss-ejecting { animation: ss-airlock-open 2s cubic-bezier(0.25, 0.1, 0.25, 1) forwards; }

        @keyframes ss-airlock-flash {
          0%, 30% { background: rgba(239, 68, 68, 0.3); }
          50% { background: rgba(239, 68, 68, 0.6); }
          70%, 100% { background: rgba(0, 0, 0, 0.8); }
        }
        .ss-airlock-bg { animation: ss-airlock-flash 2s ease-out forwards; }

        /* ── Emergency Klaxon ──────────────────────────────────── */
        @keyframes ss-klaxon {
          0%, 100% { background-color: rgba(220, 38, 38, 0.1); border-color: rgba(220, 38, 38, 0.4); }
          25% { background-color: rgba(220, 38, 38, 0.3); border-color: rgba(220, 38, 38, 0.8); }
          50% { background-color: rgba(220, 38, 38, 0.1); border-color: rgba(220, 38, 38, 0.4); }
          75% { background-color: rgba(220, 38, 38, 0.25); border-color: rgba(220, 38, 38, 0.7); }
        }
        .ss-klaxon { animation: ss-klaxon 1.5s ease-in-out infinite; }

        /* ── Vote Reveal ───────────────────────────────────────── */
        @keyframes ss-vote-flip {
          0% { transform: rotateY(90deg); opacity: 0; }
          100% { transform: rotateY(0deg); opacity: 1; }
        }
        .ss-vote-reveal {
          animation: ss-vote-flip 0.5s ease-out forwards;
          animation-delay: var(--delay, 0s);
          opacity: 0;
        }

        /* ── Game Over Effects ─────────────────────────────────── */
        @keyframes ss-station-destroy {
          0% { text-shadow: 0 0 10px rgba(239, 68, 68, 0.5); }
          25% { text-shadow: 0 0 30px rgba(239, 68, 68, 0.8), 0 0 60px rgba(249, 115, 22, 0.5); }
          50% { text-shadow: 0 0 20px rgba(249, 115, 22, 0.6); }
          75% { text-shadow: 0 0 40px rgba(239, 68, 68, 0.9), 0 0 80px rgba(249, 115, 22, 0.6); }
          100% { text-shadow: 0 0 10px rgba(239, 68, 68, 0.5); }
        }
        .ss-destroy-text { animation: ss-station-destroy 2s ease-in-out infinite; }

        @keyframes ss-crew-wins {
          0%, 100% { text-shadow: 0 0 15px rgba(16, 185, 129, 0.5), 0 0 30px rgba(6, 182, 212, 0.3); }
          50% { text-shadow: 0 0 30px rgba(16, 185, 129, 0.8), 0 0 60px rgba(6, 182, 212, 0.5); }
        }
        .ss-crew-wins-text { animation: ss-crew-wins 2s ease-in-out infinite; }

        @keyframes ss-fade-in-up {
          from { opacity: 0; transform: translateY(12px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .ss-fade-in { animation: ss-fade-in-up 0.4s ease-out forwards; opacity: 0; }

        /* ── Discussion bubbles ────────────────────────────────── */
        .ss-speech-bubble {
          position: relative;
          border-radius: 10px;
          padding: 8px 12px;
        }
        .ss-speech-bubble::before {
          content: '';
          position: absolute;
          left: -6px;
          top: 12px;
          width: 0;
          height: 0;
          border-top: 5px solid transparent;
          border-bottom: 5px solid transparent;
          border-right: 6px solid rgba(255,255,255,0.08);
        }

        /* ── Station Schematic ─────────────────────────────────── */
        .ss-room {
          transition: all 0.3s ease;
          position: relative;
        }
        .ss-room::after {
          content: '';
          position: absolute;
          inset: 0;
          border-radius: inherit;
          opacity: 0;
          transition: opacity 0.3s ease;
        }
        .ss-room-critical::after {
          background: rgba(239, 68, 68, 0.1);
          opacity: 1;
        }

        /* ── Holographic effect ────────────────────────────────── */
        .ss-holo {
          background: linear-gradient(135deg, rgba(6, 182, 212, 0.05) 0%, transparent 50%, rgba(6, 182, 212, 0.05) 100%);
          border: 1px solid rgba(6, 182, 212, 0.15);
        }

        /* ── Classified overlay ────────────────────────────────── */
        .ss-classified {
          position: relative;
        }
        .ss-classified::after {
          content: 'CLASSIFIED';
          position: absolute;
          top: 50%;
          left: 50%;
          transform: translate(-50%, -50%) rotate(-15deg);
          font-size: 7px;
          font-weight: 800;
          letter-spacing: 2px;
          color: rgba(239, 68, 68, 0.25);
          pointer-events: none;
          white-space: nowrap;
        }

        /* ── Threat level indicator ────────────────────────────── */
        @keyframes ss-threat-pulse {
          0%, 100% { opacity: 0.8; }
          50% { opacity: 1; }
        }
        .ss-threat-active { animation: ss-threat-pulse 1s ease-in-out infinite; }

        /* ── Location token animation ──────────────────────────── */
        @keyframes ss-token-arrive {
          from { transform: scale(0) rotate(-180deg); opacity: 0; }
          to { transform: scale(1) rotate(0deg); opacity: 1; }
        }
        .ss-token { animation: ss-token-arrive 0.4s cubic-bezier(0.34, 1.56, 0.64, 1) forwards; }
      </style>

      <%!-- Starfield Background --%>
      <div class="ss-starfield"></div>
      <div class="ss-scanlines"></div>

      <%!-- Content Layer --%>
      <div class="relative z-10 flex flex-col h-full">

        <%!-- ═══════════════ TOP BAR ═══════════════ --%>
        <div class={[
          "flex items-center justify-between px-4 py-2.5 border-b",
          if(@any_critical or @emergency_meeting_called, do: "ss-klaxon", else: "border-cyan-900/30 bg-gray-900/60")
        ]}>
          <%!-- Left: Round counter --%>
          <div class="flex items-center gap-4">
            <div class="flex items-center gap-2">
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-gray-500">Round</span>
              <span class="text-lg font-black text-white tabular-nums">{@round}</span>
              <span class="text-gray-600 text-sm">/</span>
              <span class="text-sm text-gray-400 tabular-nums">{@max_rounds}</span>
            </div>
            <div class="h-5 w-px bg-gray-700/50"></div>
            <div class="flex items-center gap-1.5">
              <span class={[
                "text-[10px] font-bold tracking-[0.15em] uppercase",
                if(@rounds_remaining <= 2, do: "text-red-400 ss-warning-flash", else: "text-amber-400/70")
              ]}>
                {@rounds_remaining} rounds remaining
              </span>
            </div>
          </div>

          <%!-- Center: Phase indicator --%>
          <div class="flex items-center gap-3">
            <div class={[
              "px-4 py-1 rounded-full text-xs font-bold tracking-wider uppercase border",
              phase_badge_classes(@phase, @emergency_meeting_called)
            ]}>
              <span :if={@emergency_meeting_called} class="mr-1.5 ss-warning-flash">!!!</span>
              {phase_label(@phase)}
              <span :if={@emergency_meeting_called} class="ml-1 text-[9px]">(EMERGENCY)</span>
            </div>
            <div :if={@phase == "discussion"} class="text-[10px] text-gray-500 tabular-nums">
              {@discussion_round}/{@discussion_round_limit}
            </div>
          </div>

          <%!-- Right: DEFCON threat level --%>
          <div class="flex items-center gap-3">
            <div class={[
              "px-3 py-1 rounded border text-[10px] font-black tracking-[0.2em] uppercase ss-threat-active",
              threat_classes(@threat)
            ]}>
              {threat_label(@threat)}
            </div>
            <div class="flex items-center gap-1.5">
              <div class={[
                "w-2 h-2 rounded-full",
                if(@game_status == "in_progress", do: "bg-emerald-500 animate-pulse", else: "bg-gray-600")
              ]}></div>
              <span class="text-[10px] text-gray-500 uppercase tracking-wider">
                {if @game_status == "in_progress", do: "ONLINE", else: "OFFLINE"}
              </span>
            </div>
          </div>
        </div>

        <%!-- ═══════════════ CRISIS BANNER ═══════════════ --%>
        <div :if={@active_crisis != nil and @game_status == "in_progress"} class="ss-fade-in mx-4 mb-2 rounded-lg border border-amber-600/40 bg-amber-950/30 px-4 py-2.5">
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-1.5">
              <span class="text-amber-400 ss-warning-flash text-sm">!!!</span>
              <span class="text-[10px] font-black tracking-[0.2em] uppercase text-amber-400">
                {get_val(@active_crisis, :name, "CRISIS")}
              </span>
            </div>
            <span class="text-xs text-amber-200/80">
              {get_val(@active_crisis, :description, "")}
            </span>
          </div>
        </div>

        <%!-- ═══════════════ MAIN CONTENT ═══════════════ --%>
        <div class="flex flex-1 min-h-0">

          <%!-- ──── LEFT PANEL: Crew Roster ──── --%>
          <div class="w-52 flex-shrink-0 border-r border-cyan-900/20 bg-gray-900/30 p-3 overflow-y-auto">
            <div class="flex items-center gap-2 mb-3 px-1">
              <div class="w-1.5 h-1.5 rounded-full bg-cyan-500"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/70">Crew Manifest</span>
            </div>

            <div class="space-y-2">
              <%= for {pid, pdata} <- @sorted_players do %>
                <% p_name = get_val(pdata, :name, pid) %>
                <% p_role = get_val(pdata, :role, "crew") %>
                <% p_status = get_val(pdata, :status, "alive") %>
                <% is_active = pid == @active_actor %>
                <% is_ejected = p_status == "ejected" %>
                <% is_saboteur = p_role == "saboteur" %>
                <div class={[
                  "relative rounded-lg border p-2.5 transition-all",
                  if(is_ejected, do: "opacity-40 border-gray-800/50 bg-gray-900/30", else: ""),
                  if(is_active and not is_ejected, do: "ss-active-crew border-cyan-500/40 bg-cyan-950/20", else: ""),
                  if(is_saboteur and not is_ejected, do: "ss-saboteur-aura", else: ""),
                  if(not is_active and not is_ejected and not is_saboteur, do: "border-gray-800/40 bg-gray-900/20 hover:bg-gray-800/30", else: ""),
                  if(not is_active and not is_ejected and is_saboteur, do: "border-red-900/20", else: "")
                ]}>
                  <div class="flex items-center gap-2">
                    <%!-- Role icon --%>
                    <div class={[
                      "w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold border flex-shrink-0",
                      if(is_ejected, do: "bg-gray-800 border-gray-700 text-gray-500", else: role_icon_classes(p_role))
                    ]}>
                      <span :if={not is_ejected}>{role_icon(p_role)}</span>
                      <span :if={is_ejected} class="text-[10px]">X</span>
                    </div>
                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-1.5">
                        <span class={[
                          "text-xs font-semibold truncate",
                          if(is_ejected, do: "text-gray-600 line-through", else: "text-gray-200")
                        ]}>
                          {p_name}
                        </span>
                        <span :if={is_active and not is_ejected} class="w-1 h-1 rounded-full bg-cyan-400 animate-pulse flex-shrink-0"></span>
                      </div>

                      <%!-- Role display (classified for spectator mode) --%>
                      <div :if={not is_ejected} class="mt-0.5">
                        <div class={[
                          "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[9px] font-bold uppercase tracking-wider",
                          role_badge_classes(p_role),
                          if(p_role == "saboteur", do: "ss-classified", else: "")
                        ]}>
                          {role_label(p_role)}
                        </div>
                      </div>

                      <%!-- Revealed role for ejected --%>
                      <div :if={is_ejected} class="mt-0.5">
                        <span class={[
                          "text-[9px] font-bold uppercase tracking-wider px-1.5 py-0.5 rounded",
                          if(is_saboteur, do: "bg-red-900/40 text-red-400", else: "bg-gray-800 text-gray-500")
                        ]}>
                          {role_label(p_role)} (revealed)
                        </span>
                      </div>
                    </div>
                  </div>

                  <%!-- Active indicator text --%>
                  <div :if={is_active and not is_ejected} class="mt-1.5 text-[9px] text-cyan-400/60 font-mono">
                    Currently acting...
                  </div>

                  <%!-- Trait badges --%>
                  <% player_traits = Map.get(@traits, p_name, Map.get(@traits, pid, [])) %>
                  <div :if={player_traits != [] and not is_ejected} class="mt-1.5 flex flex-wrap gap-1">
                    <%= for trait <- player_traits do %>
                      <span class="inline-block px-1.5 py-0.5 rounded-full text-[8px] font-bold tracking-wide bg-teal-900/40 text-teal-300 border border-teal-700/30">
                        {trait}
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Scan results (spectator visible) --%>
            <div :if={@scan_results != %{}} class="mt-4 pt-3 border-t border-purple-900/30">
              <div class="flex items-center gap-2 mb-2 px-1">
                <div class="w-1.5 h-1.5 rounded-full bg-purple-500"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-purple-400/70">Scan Intel</span>
              </div>
              <div class="space-y-1 ss-scanner-sweep rounded-lg p-2">
                <%= for {target, result} <- @scan_results do %>
                  <div class="flex items-center justify-between text-[10px]">
                    <span class="text-purple-300">{player_name(target, @players)}</span>
                    <span class={[
                      "font-bold px-1.5 py-0.5 rounded",
                      if(result == "suspicious" or result == "saboteur", do: "bg-red-900/40 text-red-400", else: "bg-emerald-900/40 text-emerald-400")
                    ]}>
                      {result}
                    </span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- ──── CENTER PANEL ──── --%>
          <div class="flex-1 flex flex-col min-w-0 p-4 overflow-y-auto">

            <%!-- System Health Dashboard --%>
            <div class="mb-4">
              <div class="flex items-center gap-2 mb-2.5">
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/60">System Status</span>
                <div :if={@any_critical} class="flex items-center gap-1 ss-warning-flash">
                  <span class="text-red-400 text-[10px] font-bold tracking-wider">CRITICAL</span>
                </div>
              </div>

              <div class="grid grid-cols-2 gap-3">
                <%= for {sys_id, sys_name, health, decay} <- @system_list do %>
                  <% is_crit = health < 30 %>
                  <% is_locked = @captain_lock == sys_id %>
                  <% change = get_sys_change(@system_changes, sys_id) %>
                  <div class={[
                    "relative rounded-lg border p-3 ss-holo",
                    if(is_crit, do: "ss-critical-border", else: ""),
                    if(is_locked, do: "ss-shield", else: "")
                  ]}>
                    <%!-- Captain lock overlay --%>
                    <div :if={is_locked} class="absolute top-1.5 right-1.5 flex items-center gap-1">
                      <span class="text-amber-400 text-[10px]" title="Captain's Lock">
                        <svg xmlns="http://www.w3.org/2000/svg" class="w-3.5 h-3.5" viewBox="0 0 20 20" fill="currentColor">
                          <path fill-rule="evenodd" d="M5 9V7a5 5 0 0110 0v2a2 2 0 012 2v5a2 2 0 01-2 2H5a2 2 0 01-2-2v-5a2 2 0 012-2zm8-2v2H7V7a3 3 0 016 0z" clip-rule="evenodd" />
                        </svg>
                      </span>
                    </div>

                    <div class="flex items-center justify-between mb-1.5">
                      <div class="flex items-center gap-2">
                        <span class={[
                          "text-lg",
                          system_icon_color(health)
                        ]}>
                          {system_icon(sys_id)}
                        </span>
                        <div>
                          <div class="text-xs font-bold text-gray-200">{sys_name}</div>
                          <div class="text-[9px] text-gray-500 tabular-nums">
                            Decay: -{decay}/rd
                          </div>
                        </div>
                      </div>
                      <div class="text-right">
                        <div class={[
                          "text-lg font-black tabular-nums",
                          system_health_color(health)
                        ]}>
                          {health}%
                        </div>
                        <div :if={change != 0} class={[
                          "text-[10px] font-bold tabular-nums",
                          if(change > 0, do: "text-emerald-400", else: "text-red-400")
                        ]}>
                          {if change > 0, do: "+", else: ""}{change}
                        </div>
                      </div>
                    </div>

                    <%!-- Health bar --%>
                    <div class="w-full h-2.5 rounded-full bg-gray-800/80 overflow-hidden border border-gray-700/30">
                      <div
                        class={[
                          "h-full rounded-full ss-gauge-bar",
                          if(is_crit, do: "ss-critical", else: ""),
                          system_bar_color(health)
                        ]}
                        style={"width: #{max(0, min(100, health))}%"}
                      ></div>
                    </div>

                    <%!-- Critical warning --%>
                    <div :if={is_crit} class="mt-1.5 flex items-center gap-1 ss-warning-flash">
                      <span class="text-red-400 text-[9px] font-bold tracking-wider uppercase">System Failure Imminent</span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Phase-specific content area --%>
            <div class="flex-1 min-h-0">

              <%!-- ═══ ACTION PHASE: Station Map ═══ --%>
              <div :if={@phase == "action" and @game_status == "in_progress"} class="ss-fade-in">
                <div class="flex items-center gap-2 mb-3">
                  <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/60">Station Schematic</span>
                </div>

                <%!-- Station map with 4 rooms in a cross layout --%>
                <div class="relative bg-gray-900/40 rounded-xl border border-cyan-900/20 p-6">
                  <%!-- Central hub --%>
                  <div class="flex items-center justify-center mb-4">
                    <div class="w-16 h-16 rounded-full border-2 border-cyan-800/30 bg-cyan-950/20 flex items-center justify-center">
                      <span class="text-[9px] font-bold text-cyan-500/60 tracking-wider uppercase">Hub</span>
                    </div>
                  </div>

                  <%!-- Systems as rooms around the hub --%>
                  <div class="grid grid-cols-2 gap-4">
                    <%= for {sys_id, sys_name, health, _decay} <- @system_list do %>
                      <% is_crit = health < 30 %>
                      <% players_here = location_log_for_system(@location_log, sys_id) %>
                      <% is_locked = @captain_lock == sys_id %>
                      <div class={[
                        "ss-room rounded-lg border p-3",
                        if(is_crit, do: "ss-room-critical border-red-800/40 bg-red-950/10", else: "border-gray-700/30 bg-gray-800/20"),
                        if(is_locked, do: "ring-1 ring-amber-500/30", else: "")
                      ]}>
                        <div class="flex items-center justify-between mb-2">
                          <div class="flex items-center gap-1.5">
                            <span class="text-sm">{system_icon(sys_id)}</span>
                            <span class="text-[10px] font-bold text-gray-300">{sys_name}</span>
                          </div>
                          <span class={["text-[10px] font-bold tabular-nums", system_health_color(health)]}>
                            {health}%
                          </span>
                        </div>

                        <%!-- Player tokens in this room --%>
                        <div class="flex flex-wrap gap-1 min-h-[24px]">
                          <%= for player_id <- players_here do %>
                            <div class={[
                              "ss-token px-1.5 py-0.5 rounded text-[9px] font-bold",
                              crew_token_classes(player_id, @players)
                            ]}>
                              {player_name(player_id, @players)}
                            </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Unseen players (vented) --%>
                  <div :if={@unseen_players != []} class="mt-3 text-center">
                    <span class="text-[10px] text-red-400/60 font-mono tracking-wider">
                      Unseen: <%= for _p <- @unseen_players do %><span class="mx-0.5 text-red-400 font-bold">???</span><% end %>
                    </span>
                  </div>
                </div>

                <%!-- Current round actions --%>
                <div :if={@action_log != %{}} class="mt-3">
                  <div class="text-[10px] font-bold tracking-[0.15em] uppercase text-gray-500 mb-1.5">Actions This Round</div>
                  <div class="space-y-1">
                    <%= for {pid, action} <- @action_log do %>
                      <div class="flex items-center gap-2 px-2 py-1 rounded bg-gray-800/30 border border-gray-700/20 text-[10px]">
                        <span class="font-bold text-gray-300">{player_name(pid, @players)}</span>
                        <span class="text-gray-500">{format_action(action)}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- ═══ DISCUSSION PHASE ═══ --%>
              <div :if={@phase == "discussion" and @game_status == "in_progress"} class="ss-fade-in flex flex-col h-full">
                <div class="flex items-center justify-between mb-3">
                  <div class="flex items-center gap-2">
                    <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/60">Emergency Briefing</span>
                    <span class="text-[9px] text-gray-500 tabular-nums">({@discussion_round}/{@discussion_round_limit})</span>
                  </div>
                </div>

                <div class="flex-1 overflow-y-auto space-y-2.5 pr-1" style="mask-image: linear-gradient(to bottom, transparent 0%, black 3%, black 95%, transparent 100%); -webkit-mask-image: linear-gradient(to bottom, transparent 0%, black 3%, black 95%, transparent 100%);">
                  <%= for {entry, idx} <- Enum.with_index(@discussion_transcript) do %>
                    <% speaker = get_val(entry, :player, "unknown") %>
                    <% statement = get_val(entry, :statement, "") %>
                    <% entry_type = get_val(entry, :type, "statement") %>
                    <% target = get_val(entry, :target, nil) %>
                    <div class="ss-fade-in flex gap-2.5" style={"animation-delay: #{idx * 50}ms"}>
                      <div class={[
                        "w-6 h-6 rounded-full flex items-center justify-center text-[9px] font-bold flex-shrink-0 mt-1",
                        speaker_avatar_classes(speaker, @players)
                      ]}>
                        {String.first(player_name(speaker, @players))}
                      </div>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2 mb-0.5">
                          <span class="text-[10px] font-bold text-gray-300">{player_name(speaker, @players)}</span>
                          <span :if={get_player_role(speaker, @players) != nil} class={[
                            "text-[8px] font-bold uppercase tracking-wider px-1 py-0.5 rounded",
                            role_badge_classes(get_player_role(speaker, @players))
                          ]}>
                            {role_label(get_player_role(speaker, @players))}
                          </span>
                          <span :if={entry_type == "question"} class="text-[8px] font-bold uppercase tracking-wider px-1.5 py-0.5 rounded bg-yellow-900/40 text-yellow-300 border border-yellow-700/30">
                            QUESTION
                          </span>
                          <span :if={entry_type == "accusation"} class="text-[8px] font-bold uppercase tracking-wider px-1.5 py-0.5 rounded bg-red-900/40 text-red-300 border border-red-700/30">
                            ACCUSATION
                          </span>
                        </div>
                        <div :if={entry_type == "question" and target != nil} class="text-[9px] text-yellow-400/70 mb-0.5">
                          directed at {player_name(target, @players)}
                        </div>
                        <div :if={entry_type == "accusation" and target != nil} class="text-[9px] text-red-400/70 mb-0.5">
                          accusing {player_name(target, @players)}
                        </div>
                        <div class={[
                          "ss-speech-bubble text-xs leading-relaxed",
                          case entry_type do
                            "accusation" -> "bg-red-950/30 border border-red-800/30 text-red-200"
                            "question" -> "bg-yellow-950/30 border border-yellow-800/30 text-yellow-200"
                            _ -> "bg-white/[0.04] border border-white/[0.06] text-gray-300"
                          end
                        ]}>
                          {statement}
                        </div>
                      </div>
                    </div>
                  <% end %>

                  <div :if={@discussion_transcript == []} class="text-center py-8 text-gray-500 text-sm">
                    Waiting for discussion to begin...
                  </div>
                </div>
              </div>

              <%!-- ═══ VOTING PHASE ═══ --%>
              <div :if={@phase == "voting" and @game_status == "in_progress"} class="ss-fade-in">
                <div class="flex items-center gap-2 mb-3">
                  <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-red-400/80">Emergency Vote</span>
                </div>

                <div class="space-y-2">
                  <%!-- Individual votes with staggered reveal --%>
                  <%= for {{voter_id, target_id}, idx} <- Enum.with_index(@votes) do %>
                    <div
                      class="ss-vote-reveal flex items-center justify-between px-3 py-2 rounded-lg border border-gray-700/30 bg-gray-800/30"
                      style={"--delay: #{idx * 0.15}s"}
                    >
                      <div class="flex items-center gap-2">
                        <div class={[
                          "w-5 h-5 rounded-full flex items-center justify-center text-[8px] font-bold",
                          speaker_avatar_classes(voter_id, @players)
                        ]}>
                          {String.first(player_name(voter_id, @players))}
                        </div>
                        <span class="text-xs text-gray-300 font-semibold">{player_name(voter_id, @players)}</span>
                      </div>
                      <div class="flex items-center gap-1.5">
                        <svg xmlns="http://www.w3.org/2000/svg" class="w-3 h-3 text-gray-600" viewBox="0 0 20 20" fill="currentColor">
                          <path fill-rule="evenodd" d="M10.293 3.293a1 1 0 011.414 0l6 6a1 1 0 010 1.414l-6 6a1 1 0 01-1.414-1.414L14.586 11H3a1 1 0 110-2h11.586l-4.293-4.293a1 1 0 010-1.414z" clip-rule="evenodd" />
                        </svg>
                        <span class={[
                          "text-xs font-bold px-2 py-0.5 rounded",
                          if(target_id == "skip", do: "bg-gray-700/50 text-gray-400", else: "bg-red-900/30 text-red-300")
                        ]}>
                          {if target_id == "skip", do: "SKIP", else: player_name(target_id, @players)}
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>

                <%!-- Vote tally --%>
                <div :if={@vote_tally != %{} or @skip_count > 0} class="mt-4 pt-3 border-t border-gray-700/30">
                  <div class="text-[10px] font-bold tracking-[0.15em] uppercase text-gray-500 mb-2">Vote Tally</div>
                  <div class="space-y-1.5">
                    <%= for {target, count} <- Enum.sort_by(@vote_tally, fn {_t, c} -> -c end) do %>
                      <% alive_count = length(@alive_players) %>
                      <% pct = if alive_count > 0, do: round(count / alive_count * 100), else: 0 %>
                      <div class="flex items-center gap-2">
                        <span class="text-xs font-bold text-red-300 w-24 truncate">{player_name(target, @players)}</span>
                        <div class="flex-1 h-2 rounded-full bg-gray-800/60 overflow-hidden">
                          <div class="h-full rounded-full bg-red-500/70 ss-gauge-bar" style={"width: #{pct}%"}></div>
                        </div>
                        <span class="text-[10px] font-bold text-gray-400 tabular-nums w-6 text-right">{count}</span>
                      </div>
                    <% end %>
                    <div :if={@skip_count > 0} class="flex items-center gap-2">
                      <span class="text-xs font-bold text-gray-400 w-24">Skip</span>
                      <div class="flex-1 h-2 rounded-full bg-gray-800/60 overflow-hidden">
                        <% alive_count = length(@alive_players) %>
                        <% skip_pct = if alive_count > 0, do: round(@skip_count / alive_count * 100), else: 0 %>
                        <div class="h-full rounded-full bg-gray-500/50 ss-gauge-bar" style={"width: #{skip_pct}%"}></div>
                      </div>
                      <span class="text-[10px] font-bold text-gray-500 tabular-nums w-6 text-right">{@skip_count}</span>
                    </div>
                  </div>

                  <div :if={@vote_tally != %{}} class="mt-2 text-[10px] text-gray-500 text-center">
                    <% {top_target, top_votes} = @vote_tally |> Enum.max_by(fn {_t, c} -> c end, fn -> {"none", 0} end) %>
                    <% majority = div(length(@alive_players), 2) + 1 %>
                    <span :if={top_votes >= majority} class="text-red-400 font-bold ss-warning-flash">
                      MAJORITY REACHED - {player_name(top_target, @players)} will be ejected
                    </span>
                    <span :if={top_votes < majority} class="text-gray-500">
                      Majority required: {majority} votes
                    </span>
                  </div>
                </div>

                <div :if={@votes == %{}} class="text-center py-8 text-gray-500 text-sm">
                  Waiting for crew to cast votes...
                </div>
              </div>

              <%!-- ═══ GAME OVER ═══ --%>
              <div :if={@game_status == "game_over"} class="flex items-center justify-center h-full">
                <div class="text-center p-8 space-y-5">
                  <%!-- Crew wins --%>
                  <div :if={@winner == "crew"}>
                    <div class="text-5xl font-black tracking-tight text-emerald-400 ss-crew-wins-text mb-3">
                      CREW SURVIVES
                    </div>
                    <div class="text-lg text-cyan-300/80">
                      The saboteur has been defeated. The station is secure.
                    </div>
                  </div>

                  <%!-- Saboteur wins --%>
                  <div :if={@winner == "saboteur"}>
                    <div class="text-5xl font-black tracking-tight text-red-500 ss-destroy-text mb-3">
                      STATION DESTROYED
                    </div>
                    <div class="text-lg text-orange-300/80">
                      The saboteur succeeded. All systems have failed.
                    </div>
                  </div>

                  <%!-- Stats --%>
                  <div class="flex justify-center gap-8 mt-6">
                    <div class="text-center">
                      <div class="text-3xl font-bold text-white">{@round}</div>
                      <div class="text-[10px] uppercase tracking-wider text-gray-500 mt-1">Rounds Lasted</div>
                    </div>
                    <div class="text-center">
                      <div class="text-3xl font-bold text-white">{length(@ejected_players)}</div>
                      <div class="text-[10px] uppercase tracking-wider text-gray-500 mt-1">Ejected</div>
                    </div>
                    <div class="text-center">
                      <div class="text-3xl font-bold text-white">{@min_health}%</div>
                      <div class="text-[10px] uppercase tracking-wider text-gray-500 mt-1">Lowest System</div>
                    </div>
                  </div>

                  <%!-- Crew reveal --%>
                  <div class="mt-6 pt-4 border-t border-gray-700/30">
                    <div class="text-[10px] uppercase tracking-wider text-gray-500 mb-3">Crew Roles Revealed</div>
                    <div class="flex flex-wrap justify-center gap-2">
                      <%= for {pid, pdata} <- @sorted_players do %>
                        <% p_role = get_val(pdata, :role, "crew") %>
                        <div class={[
                          "px-3 py-1.5 rounded-lg border text-xs font-bold",
                          if(p_role == "saboteur",
                            do: "bg-red-950/40 border-red-700/40 text-red-300",
                            else: "bg-gray-800/40 border-gray-700/40 text-gray-300"
                          )
                        ]}>
                          <span>{get_val(pdata, :name, pid)}</span>
                          <span class={["ml-1.5", role_color_text(p_role)]}>{role_label(p_role)}</span>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <div class={[
                    "w-64 h-1 rounded-full mx-auto mt-4",
                    if(@winner == "crew",
                      do: "bg-gradient-to-r from-transparent via-emerald-500 to-transparent",
                      else: "bg-gradient-to-r from-transparent via-red-500 to-transparent"
                    )
                  ]}></div>
                </div>
              </div>
            </div>
          </div>

          <%!-- ──── RIGHT PANEL ──── --%>
          <div class="w-48 flex-shrink-0 border-l border-cyan-900/20 bg-gray-900/30 p-3 overflow-y-auto space-y-4">

            <%!-- Location Tracker --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-1">
                <div class="w-1.5 h-1.5 rounded-full bg-cyan-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-cyan-400/50">Locations</span>
              </div>
              <div class="space-y-1">
                <%= for visit <- @visible_visits do %>
                  <% v_player = get_visit_player(visit) %>
                  <% v_system = get_visit_system(visit) %>
                  <div class="flex items-center justify-between px-2 py-1 rounded bg-gray-800/30 border border-gray-700/20 text-[10px]">
                    <span class="font-semibold text-gray-300 truncate">{player_name(v_player, @players)}</span>
                    <span class="text-cyan-400/70 font-mono">{system_short_name(v_system, @systems)}</span>
                  </div>
                <% end %>
                <%= for _p <- @unseen_players do %>
                  <div class="flex items-center justify-between px-2 py-1 rounded bg-red-950/20 border border-red-800/20 text-[10px]">
                    <span class="font-bold text-red-400">???</span>
                    <span class="text-red-400/50 font-mono">UNKNOWN</span>
                  </div>
                <% end %>
                <div :if={@visible_visits == [] and @unseen_players == []} class="text-[10px] text-gray-600 px-2 py-1">
                  No location data yet
                </div>
              </div>
            </div>

            <%!-- System Changes --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-1">
                <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">Sys Changes</span>
              </div>
              <div class="space-y-1">
                <%= for {sys_id, sys_name, _health, _decay} <- @system_list do %>
                  <% change = get_sys_change(@system_changes, sys_id) %>
                  <div :if={change != 0} class="flex items-center justify-between px-2 py-1 rounded bg-gray-800/30 border border-gray-700/20 text-[10px]">
                    <span class="text-gray-400">{sys_name}</span>
                    <span class={[
                      "font-bold tabular-nums",
                      if(change > 0, do: "text-emerald-400", else: "text-red-400")
                    ]}>
                      {if change > 0, do: "+", else: ""}{change}
                    </span>
                  </div>
                <% end %>
                <div :if={Enum.all?(@system_list, fn {sid, _, _, _} -> get_sys_change(@system_changes, sid) == 0 end)} class="text-[10px] text-gray-600 px-2 py-1">
                  No changes this round
                </div>
              </div>
            </div>

            <%!-- Elimination Log --%>
            <div>
              <div class="flex items-center gap-2 mb-2 px-1">
                <div class="w-1.5 h-1.5 rounded-full bg-red-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-red-400/50">Ejection Log</span>
              </div>
              <div class="space-y-1.5">
                <%= for entry <- @elimination_log do %>
                  <% e_player = get_val(entry, :player, "unknown") %>
                  <% e_role = get_val(entry, :role, "unknown") %>
                  <% e_reason = get_val(entry, :reason, "") %>
                  <% e_round = get_val(entry, :round, 0) %>
                  <div class="px-2 py-1.5 rounded border border-gray-700/20 bg-gray-800/20">
                    <div class="flex items-center justify-between">
                      <span class="text-[10px] font-bold text-gray-300">{player_name(e_player, @players)}</span>
                      <span class={[
                        "text-[9px] font-bold px-1 py-0.5 rounded",
                        if(e_role == "saboteur", do: "bg-red-900/40 text-red-400", else: "bg-gray-700/50 text-gray-400")
                      ]}>
                        {role_label(e_role)}
                      </span>
                    </div>
                    <div class="text-[9px] text-gray-500 mt-0.5">
                      Round {e_round} - {e_reason}
                    </div>
                  </div>
                <% end %>
                <div :if={@elimination_log == []} class="text-[10px] text-gray-600 px-2 py-1">
                  No ejections yet
                </div>
              </div>
            </div>

            <%!-- Emergency Meeting Status --%>
            <div class="pt-2 border-t border-gray-700/20">
              <div class={[
                "px-3 py-2 rounded-lg border text-center",
                if(@emergency_meeting_available,
                  do: "border-red-700/30 bg-red-950/20",
                  else: "border-gray-800/30 bg-gray-900/20 opacity-50"
                )
              ]}>
                <div class="text-[9px] font-bold tracking-wider uppercase mb-1 text-gray-400">Emergency Meeting</div>
                <div class={[
                  "text-[10px] font-bold",
                  if(@emergency_meeting_available, do: "text-red-400", else: "text-gray-600")
                ]}>
                  {if @emergency_meeting_available, do: "AVAILABLE", else: "USED"}
                </div>
              </div>
            </div>

            <%!-- Vote History --%>
            <div :if={@vote_history != []}>
              <div class="flex items-center gap-2 mb-2 px-1">
                <div class="w-1.5 h-1.5 rounded-full bg-gray-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-gray-500">Vote History</span>
              </div>
              <div class="space-y-1">
                <%= for {past_vote, idx} <- Enum.with_index(@vote_history) do %>
                  <details class="group">
                    <summary class="cursor-pointer px-2 py-1 rounded bg-gray-800/20 border border-gray-700/20 text-[10px] text-gray-400 hover:text-gray-300 transition-colors flex items-center gap-1">
                      <svg xmlns="http://www.w3.org/2000/svg" class="w-2.5 h-2.5 transform group-open:rotate-90 transition-transform" viewBox="0 0 20 20" fill="currentColor">
                        <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
                      </svg>
                      Round {idx + 1} Votes
                    </summary>
                    <div class="mt-1 pl-2 space-y-0.5">
                      <%= for {voter, target} <- past_vote do %>
                        <div class="text-[9px] text-gray-500">
                          <span class="font-semibold text-gray-400">{player_name(voter, @players)}</span>
                          &rarr;
                          <span class={if(target == "skip", do: "text-gray-500", else: "text-red-400/70")}>
                            {if target == "skip", do: "skip", else: player_name(target, @players)}
                          </span>
                        </div>
                      <% end %>
                    </div>
                  </details>
                <% end %>
              </div>
            </div>

            <%!-- Agent Journals --%>
            <div :if={@recent_journals != []}>
              <div class="flex items-center gap-2 mb-2 px-1">
                <div class="w-1.5 h-1.5 rounded-full bg-teal-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-teal-400/50">Agent Thoughts</span>
              </div>
              <div class="space-y-1.5">
                <%= for {j_player, j_round, j_phase, j_thought} <- @recent_journals do %>
                  <div class="px-2 py-1.5 rounded border border-teal-800/20 bg-teal-950/10">
                    <div class="flex items-center justify-between mb-0.5">
                      <span class="text-[10px] font-bold text-teal-300">{j_player}</span>
                      <span class="text-[8px] text-gray-500 tabular-nums">R{j_round} {j_phase}</span>
                    </div>
                    <div class="text-[9px] text-gray-400 leading-snug italic">
                      {truncate_thought(j_thought, 120)}
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Backstory Connections --%>
            <div :if={@connections != []}>
              <div class="flex items-center gap-2 mb-2 px-1">
                <div class="w-1.5 h-1.5 rounded-full bg-indigo-500/70"></div>
                <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-indigo-400/50">Connections</span>
              </div>
              <div class="space-y-1.5">
                <%= for conn <- @connections do %>
                  <% conn_players = get_val(conn, :players, []) %>
                  <% conn_type = get_val(conn, :type, "") %>
                  <% conn_desc = get_val(conn, :description, "") %>
                  <div class="px-2 py-1.5 rounded border border-indigo-800/20 bg-indigo-950/10">
                    <div class="flex items-center gap-1 mb-0.5">
                      <span class="text-[10px] font-bold text-indigo-300">{Enum.join(conn_players, " & ")}</span>
                    </div>
                    <div class="text-[8px] font-bold uppercase tracking-wider text-indigo-400/60 mb-0.5">
                      {format_connection_type(conn_type)}
                    </div>
                    <div :if={conn_desc != ""} class="text-[9px] text-gray-400 leading-snug">
                      {truncate_thought(conn_desc, 100)}
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ EJECTION OVERLAY ═══════════════ --%>
      <div
        :if={@show_ejection and @latest_ejection}
        class="absolute inset-0 z-50 flex items-center justify-center ss-airlock-bg rounded-xl"
      >
        <div class="text-center space-y-4">
          <div class="ss-ejecting inline-block">
            <div class={[
              "w-20 h-20 rounded-full flex items-center justify-center text-3xl font-black border-4",
              if(get_val(@latest_ejection, :role, "") == "saboteur",
                do: "bg-red-900/60 border-red-500 text-red-300",
                else: "bg-gray-800/60 border-gray-500 text-gray-300"
              )
            ]}>
              {String.first(player_name(get_val(@latest_ejection, :player, "?"), @players))}
            </div>
          </div>
          <div class="ss-fade-in" style="animation-delay: 1.5s">
            <div class="text-2xl font-black text-white tracking-tight">
              {player_name(get_val(@latest_ejection, :player, "Unknown"), @players)} was ejected.
            </div>
            <div class={[
              "text-lg font-bold mt-2",
              if(get_val(@latest_ejection, :role, "") == "saboteur", do: "text-red-400", else: "text-cyan-400")
            ]}>
              They were <span class="uppercase">{role_label(get_val(@latest_ejection, :role, "unknown"))}</span>.
            </div>
            <div :if={get_val(@latest_ejection, :role, "") == "saboteur"} class="text-emerald-400 text-sm mt-1">
              The saboteur has been found!
            </div>
            <div :if={get_val(@latest_ejection, :role, "") != "saboteur"} class="text-red-400/70 text-sm mt-1">
              An innocent crew member was lost.
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Flexible Key Access ──────────────────────────────────────────

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, default)
  end

  defp get_val(_, _, default), do: default

  # ── Player Helpers ───────────────────────────────────────────────

  defp player_name(id, players) when is_map(players) do
    case Map.get(players, id) do
      nil ->
        case Map.get(players, to_string(id)) do
          nil -> to_string(id)
          p -> get_val(p, :name, to_string(id))
        end

      p ->
        get_val(p, :name, to_string(id))
    end
  end

  defp player_name(id, _), do: to_string(id)

  defp get_player_role(id, players) when is_map(players) do
    case Map.get(players, id) || Map.get(players, to_string(id)) do
      nil -> nil
      p -> get_val(p, :role, nil)
    end
  end

  defp get_player_role(_, _), do: nil

  # ── System Health Helpers ────────────────────────────────────────

  defp system_health_color(health) when health >= 70, do: "text-emerald-400"
  defp system_health_color(health) when health >= 50, do: "text-emerald-300"
  defp system_health_color(health) when health >= 30, do: "text-amber-400"
  defp system_health_color(health) when health >= 15, do: "text-orange-400"
  defp system_health_color(_), do: "text-red-400"

  defp system_bar_color(health) when health >= 70, do: "bg-emerald-500"
  defp system_bar_color(health) when health >= 50, do: "bg-emerald-400"
  defp system_bar_color(health) when health >= 30, do: "bg-amber-500"
  defp system_bar_color(health) when health >= 15, do: "bg-orange-500"
  defp system_bar_color(_), do: "bg-red-500"

  defp system_icon_color(health) when health >= 50, do: "text-emerald-400"
  defp system_icon_color(health) when health >= 30, do: "text-amber-400"
  defp system_icon_color(_), do: "text-red-400 ss-warning-flash"

  defp system_icon("o2"), do: "O2"
  defp system_icon("power"), do: "PW"
  defp system_icon("hull"), do: "HL"
  defp system_icon("comms"), do: "CM"
  defp system_icon(id), do: String.upcase(String.slice(to_string(id), 0, 2))

  defp system_short_name(sys_id, systems) when is_map(systems) do
    case Map.get(systems, sys_id) || Map.get(systems, to_string(sys_id)) do
      nil -> to_string(sys_id)
      sys -> get_val(sys, :name, to_string(sys_id))
    end
  end

  defp system_short_name(sys_id, _), do: to_string(sys_id)

  # ── Phase Helpers ────────────────────────────────────────────────

  defp phase_label("action"), do: "ACTION PHASE"
  defp phase_label("discussion"), do: "DISCUSSION"
  defp phase_label("voting"), do: "EMERGENCY VOTE"
  defp phase_label("game_over"), do: "GAME OVER"
  defp phase_label(other), do: String.upcase(to_string(other))

  defp phase_badge_classes("action", _), do: "bg-cyan-900/40 text-cyan-300 border-cyan-700/40"
  defp phase_badge_classes("discussion", false), do: "bg-amber-900/40 text-amber-300 border-amber-700/40"
  defp phase_badge_classes("discussion", true), do: "bg-red-900/50 text-red-300 border-red-600/50 ss-klaxon"
  defp phase_badge_classes("voting", _), do: "bg-red-900/40 text-red-300 border-red-700/40"
  defp phase_badge_classes("game_over", _), do: "bg-gray-800/40 text-gray-300 border-gray-600/40"
  defp phase_badge_classes(_, _), do: "bg-gray-800/40 text-gray-400 border-gray-700/40"

  # ── Role Helpers ─────────────────────────────────────────────────

  defp role_label("engineer"), do: "Engineer"
  defp role_label("captain"), do: "Captain"
  defp role_label("crew"), do: "Crew"
  defp role_label("saboteur"), do: "Saboteur"
  defp role_label(other) when is_binary(other), do: String.capitalize(other)
  defp role_label(_), do: "Unknown"

  defp role_icon("engineer"), do: "E"
  defp role_icon("captain"), do: "C"
  defp role_icon("crew"), do: "R"
  defp role_icon("saboteur"), do: "S"
  defp role_icon(_), do: "?"

  defp role_icon_classes("captain"), do: "bg-amber-500/80 border-amber-400 text-amber-950"
  defp role_icon_classes("engineer"), do: "bg-purple-500/80 border-purple-400 text-white"
  defp role_icon_classes("saboteur"), do: "bg-red-500/60 border-red-400 text-white"
  defp role_icon_classes("crew"), do: "bg-cyan-500/70 border-cyan-400 text-cyan-950"
  defp role_icon_classes(_), do: "bg-gray-500/70 border-gray-400 text-white"

  defp role_badge_classes("captain"), do: "bg-amber-900/40 text-amber-400"
  defp role_badge_classes("engineer"), do: "bg-purple-900/40 text-purple-400"
  defp role_badge_classes("saboteur"), do: "bg-red-900/30 text-red-400"
  defp role_badge_classes("crew"), do: "bg-cyan-900/30 text-cyan-400/70"
  defp role_badge_classes(_), do: "bg-gray-800/40 text-gray-500"

  defp role_color_text("captain"), do: "text-amber-400"
  defp role_color_text("engineer"), do: "text-purple-400"
  defp role_color_text("saboteur"), do: "text-red-400"
  defp role_color_text("crew"), do: "text-cyan-400"
  defp role_color_text(_), do: "text-gray-400"

  # ── Threat Level ─────────────────────────────────────────────────

  defp threat_level(min_health) when min_health >= 70, do: :green
  defp threat_level(min_health) when min_health >= 50, do: :elevated
  defp threat_level(min_health) when min_health >= 30, do: :high
  defp threat_level(min_health) when min_health >= 15, do: :severe
  defp threat_level(_), do: :critical

  defp threat_label(:green), do: "DEFCON 5"
  defp threat_label(:elevated), do: "DEFCON 4"
  defp threat_label(:high), do: "DEFCON 3"
  defp threat_label(:severe), do: "DEFCON 2"
  defp threat_label(:critical), do: "DEFCON 1"

  defp threat_classes(:green), do: "bg-emerald-950/40 text-emerald-400 border-emerald-700/30"
  defp threat_classes(:elevated), do: "bg-cyan-950/40 text-cyan-400 border-cyan-700/30"
  defp threat_classes(:high), do: "bg-amber-950/40 text-amber-400 border-amber-700/30"
  defp threat_classes(:severe), do: "bg-orange-950/40 text-orange-400 border-orange-700/30"
  defp threat_classes(:critical), do: "bg-red-950/50 text-red-400 border-red-600/40"

  # ── Location Log Helpers ─────────────────────────────────────────

  defp location_log_for_system(location_log, sys_id) when is_list(location_log) do
    location_log
    |> Enum.filter(fn entry -> get_visit_system(entry) == sys_id end)
    |> Enum.map(fn entry -> get_visit_player(entry) end)
    |> Enum.uniq()
  end

  defp location_log_for_system(_, _), do: []

  defp get_visit_player({player_id, _system_id}), do: player_id

  defp get_visit_player(entry) when is_map(entry) do
    get_val(entry, :player, get_val(entry, :player_id, "unknown"))
  end

  defp get_visit_player(entry) when is_list(entry) do
    case entry do
      [player_id | _] -> player_id
      _ -> "unknown"
    end
  end

  defp get_visit_player(_), do: "unknown"

  defp get_visit_system({_player_id, system_id}), do: system_id

  defp get_visit_system(entry) when is_map(entry) do
    get_val(entry, :system, get_val(entry, :system_id, "unknown"))
  end

  defp get_visit_system(entry) when is_list(entry) do
    case entry do
      [_, system_id | _] -> system_id
      _ -> "unknown"
    end
  end

  defp get_visit_system(_), do: "unknown"

  # ── System Change Helpers ────────────────────────────────────────

  defp get_sys_change(changes, sys_id) when is_map(changes) do
    case Map.get(changes, sys_id) || Map.get(changes, to_string(sys_id)) do
      nil -> 0
      val when is_number(val) -> val
      _ -> 0
    end
  end

  defp get_sys_change(_, _), do: 0

  # ── Action Formatting ────────────────────────────────────────────

  defp format_action(action) when is_binary(action), do: action
  defp format_action(action) when is_map(action) do
    type = get_val(action, :type, get_val(action, :action, "unknown"))
    target = get_val(action, :target, get_val(action, :system, nil))
    if target, do: "#{type} -> #{target}", else: to_string(type)
  end
  defp format_action(action), do: inspect(action)

  # ── Crew Token Classes ──────────────────────────────────────────

  defp crew_token_classes(player_id, players) when is_map(players) do
    role = get_player_role(player_id, players)

    case role do
      "captain" -> "bg-amber-900/50 text-amber-300 border border-amber-700/30"
      "engineer" -> "bg-purple-900/50 text-purple-300 border border-purple-700/30"
      "saboteur" -> "bg-red-900/30 text-red-300 border border-red-700/20"
      _ -> "bg-cyan-900/40 text-cyan-300 border border-cyan-700/20"
    end
  end

  defp crew_token_classes(_, _), do: "bg-gray-800/50 text-gray-300 border border-gray-700/30"

  # ── Speaker Avatar Classes ──────────────────────────────────────

  defp speaker_avatar_classes(speaker_id, players) when is_map(players) do
    role = get_player_role(speaker_id, players)

    case role do
      "captain" -> "bg-amber-500/80 text-amber-950"
      "engineer" -> "bg-purple-500/80 text-white"
      "saboteur" -> "bg-red-500/60 text-white"
      "crew" -> "bg-cyan-500/70 text-cyan-950"
      _ -> "bg-gray-600 text-white"
    end
  end

  defp speaker_avatar_classes(_, _), do: "bg-gray-600 text-white"

  # ── Journal Helpers ────────────────────────────────────────────

  defp recent_journals(journals) when is_map(journals) do
    journals
    |> Enum.flat_map(fn {player_name, entries} ->
      entries
      |> List.wrap()
      |> Enum.take(-3)
      |> Enum.map(fn entry ->
        {to_string(player_name),
         get_val(entry, :round, 0),
         get_val(entry, :phase, ""),
         get_val(entry, :thought, "")}
      end)
    end)
    |> Enum.sort_by(fn {_name, round, _phase, _thought} -> round end, :desc)
    |> Enum.take(12)
  end

  defp recent_journals(_), do: []

  defp truncate_thought(text, max_len) when is_binary(text) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end

  defp truncate_thought(_, _), do: ""

  # ── Connection Helpers ─────────────────────────────────────────

  defp format_connection_type(type) when is_binary(type) do
    type
    |> String.replace("_", " ")
  end

  defp format_connection_type(_), do: ""
end
