defmodule LemonSimUi.Live.Components.SurvivorBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    players = MapHelpers.get_key(world, :players) || %{}
    tribes = MapHelpers.get_key(world, :tribes) || %{}
    phase = MapHelpers.get_key(world, :phase) || "challenge"
    episode = MapHelpers.get_key(world, :episode) || 1
    merged = MapHelpers.get_key(world, :merged) || false
    merge_tribe_name = MapHelpers.get_key(world, :merge_tribe_name) || "Merged Tribe"
    active_actor = MapHelpers.get_key(world, :active_actor_id)
    challenge_choices = MapHelpers.get_key(world, :challenge_choices) || %{}
    challenge_winner = MapHelpers.get_key(world, :challenge_winner)
    challenge_history = MapHelpers.get_key(world, :challenge_history) || []
    losing_tribe = MapHelpers.get_key(world, :losing_tribe)
    immune_player = MapHelpers.get_key(world, :immune_player)
    whisper_log = MapHelpers.get_key(world, :whisper_log) || []
    whisper_graph = MapHelpers.get_key(world, :whisper_graph) || []
    statements = MapHelpers.get_key(world, :statements) || []
    votes = MapHelpers.get_key(world, :votes) || %{}
    vote_history = MapHelpers.get_key(world, :vote_history) || []
    idol_played_by = MapHelpers.get_key(world, :idol_played_by)
    idol_history = MapHelpers.get_key(world, :idol_history) || []
    elimination_log = MapHelpers.get_key(world, :elimination_log) || []
    jury = MapHelpers.get_key(world, :jury) || []
    jury_votes = MapHelpers.get_key(world, :jury_votes) || %{}
    jury_statements = MapHelpers.get_key(world, :jury_statements) || []
    ftc_sub_phase = MapHelpers.get_key(world, :ftc_sub_phase)
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    traits = MapHelpers.get_key(world, :traits) || %{}
    connections = MapHelpers.get_key(world, :connections) || []
    journals = MapHelpers.get_key(world, :journals) || %{}

    sorted_players = Enum.sort_by(players, fn {id, _p} -> to_string(id) end)

    alive_players =
      sorted_players
      |> Enum.filter(fn {_id, p} -> get_val(p, :status, "alive") == "alive" end)

    eliminated_players =
      sorted_players
      |> Enum.filter(fn {_id, p} -> get_val(p, :status, "alive") == "eliminated" end)

    # Build tribe roster grouping
    tribe_names = tribes |> Map.keys() |> Enum.sort_by(&to_string/1)

    # Vote tally for current tribal council
    vote_tally =
      votes
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    # Whisper frequency for alliance detection
    whisper_pairs = build_whisper_pairs(whisper_graph)

    # Jury vote tally for FTC
    jury_vote_tally =
      jury_votes
      |> Enum.group_by(fn {_juror, finalist} -> finalist end)
      |> Enum.into(%{}, fn {finalist, jurors} -> {finalist, length(jurors)} end)

    # Finalists: alive players who aren't on the jury (at FTC)
    finalists =
      if phase == "final_tribal_council" do
        alive_players
        |> Enum.reject(fn {id, _p} -> to_string(id) in Enum.map(jury, &to_string/1) end)
      else
        []
      end

    assigns =
      assigns
      |> assign(:players, players)
      |> assign(:sorted_players, sorted_players)
      |> assign(:alive_players, alive_players)
      |> assign(:eliminated_players, eliminated_players)
      |> assign(:tribes, tribes)
      |> assign(:tribe_names, tribe_names)
      |> assign(:phase, phase)
      |> assign(:episode, episode)
      |> assign(:merged, merged)
      |> assign(:merge_tribe_name, merge_tribe_name)
      |> assign(:active_actor, active_actor)
      |> assign(:challenge_choices, challenge_choices)
      |> assign(:challenge_winner, challenge_winner)
      |> assign(:challenge_history, challenge_history)
      |> assign(:losing_tribe, losing_tribe)
      |> assign(:immune_player, immune_player)
      |> assign(:whisper_log, whisper_log)
      |> assign(:whisper_graph, whisper_graph)
      |> assign(:whisper_pairs, whisper_pairs)
      |> assign(:statements, statements)
      |> assign(:votes, votes)
      |> assign(:vote_tally, vote_tally)
      |> assign(:vote_history, vote_history)
      |> assign(:idol_played_by, idol_played_by)
      |> assign(:idol_history, idol_history)
      |> assign(:elimination_log, elimination_log)
      |> assign(:jury, jury)
      |> assign(:jury_votes, jury_votes)
      |> assign(:jury_vote_tally, jury_vote_tally)
      |> assign(:jury_statements, jury_statements)
      |> assign(:ftc_sub_phase, ftc_sub_phase)
      |> assign(:finalists, finalists)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:traits, traits)
      |> assign(:connections, connections)
      |> assign(:journals, journals)

    ~H"""
    <div class="relative font-sans w-full h-full flex flex-col overflow-hidden rounded-xl" style="min-height: 700px;">
      <style>
        /* ── Phase backgrounds ── */
        .sv-phase-challenge {
          background: linear-gradient(180deg, rgba(6,40,15,0.95) 0%, rgba(12,25,8,0.97) 50%, rgba(5,15,5,0.99) 100%);
        }
        .sv-phase-strategy {
          background: linear-gradient(180deg, rgba(30,20,8,0.95) 0%, rgba(18,12,5,0.97) 50%, rgba(10,8,3,0.99) 100%);
        }
        .sv-phase-tribal {
          background: linear-gradient(180deg, rgba(25,8,5,0.96) 0%, rgba(15,5,3,0.97) 50%, rgba(8,3,2,0.99) 100%);
        }
        .sv-phase-ftc {
          background: linear-gradient(180deg, rgba(20,5,30,0.96) 0%, rgba(12,3,18,0.97) 50%, rgba(6,2,10,0.99) 100%);
        }
        .sv-phase-gameover {
          background: linear-gradient(180deg, rgba(10,5,0,0.96) 0%, rgba(5,2,0,0.98) 100%);
        }

        /* ── Torch flame animation ── */
        @keyframes sv-flame {
          0%, 100% { text-shadow: 0 0 8px #f97316, 0 0 16px #ea580c, 0 0 24px #c2410c; transform: scaleY(1); }
          25% { text-shadow: 0 0 12px #f97316, 0 0 20px #ea580c, 0 0 32px #c2410c; transform: scaleY(1.08) scaleX(0.95); }
          50% { text-shadow: 0 0 6px #f97316, 0 0 14px #ea580c, 0 0 20px #c2410c; transform: scaleY(0.95) scaleX(1.05); }
          75% { text-shadow: 0 0 14px #f97316, 0 0 24px #ea580c, 0 0 36px #c2410c; transform: scaleY(1.05) scaleX(0.98); }
        }
        .sv-flame { animation: sv-flame 1.5s ease-in-out infinite; display: inline-block; }

        /* ── Active player glow ── */
        @keyframes sv-active-glow {
          0%, 100% { box-shadow: 0 0 8px rgba(249,115,22,0.4), 0 0 16px rgba(249,115,22,0.2); }
          50% { box-shadow: 0 0 16px rgba(249,115,22,0.7), 0 0 32px rgba(249,115,22,0.4); }
        }
        .sv-active { animation: sv-active-glow 2s ease-in-out infinite; }

        /* ── Immunity necklace glow ── */
        @keyframes sv-immunity-glow {
          0%, 100% { box-shadow: 0 0 6px rgba(234,179,8,0.5), 0 0 12px rgba(234,179,8,0.2); }
          50% { box-shadow: 0 0 14px rgba(234,179,8,0.8), 0 0 28px rgba(234,179,8,0.4); }
        }
        .sv-immune { animation: sv-immunity-glow 2.5s ease-in-out infinite; }

        /* ── Idol golden burst ── */
        @keyframes sv-idol-burst {
          0% { transform: scale(1); box-shadow: 0 0 20px rgba(234,179,8,0.9), 0 0 40px rgba(234,179,8,0.5); }
          50% { transform: scale(1.15); box-shadow: 0 0 40px rgba(234,179,8,1), 0 0 80px rgba(234,179,8,0.7); }
          100% { transform: scale(1); box-shadow: 0 0 20px rgba(234,179,8,0.9), 0 0 40px rgba(234,179,8,0.5); }
        }
        .sv-idol-burst { animation: sv-idol-burst 1.5s ease-in-out infinite; }

        /* ── Vote reveal flip ── */
        @keyframes sv-vote-flip {
          0% { transform: rotateY(90deg); opacity: 0; }
          60% { transform: rotateY(-10deg); opacity: 1; }
          100% { transform: rotateY(0deg); opacity: 1; }
        }
        .sv-vote-reveal { animation: sv-vote-flip 0.6s ease-out forwards; perspective: 600px; }

        /* Stagger vote reveals */
        .sv-vote-delay-1 { animation-delay: 0.3s; opacity: 0; }
        .sv-vote-delay-2 { animation-delay: 0.6s; opacity: 0; }
        .sv-vote-delay-3 { animation-delay: 0.9s; opacity: 0; }
        .sv-vote-delay-4 { animation-delay: 1.2s; opacity: 0; }
        .sv-vote-delay-5 { animation-delay: 1.5s; opacity: 0; }
        .sv-vote-delay-6 { animation-delay: 1.8s; opacity: 0; }
        .sv-vote-delay-7 { animation-delay: 2.1s; opacity: 0; }
        .sv-vote-delay-8 { animation-delay: 2.4s; opacity: 0; }

        /* ── Elimination torch snuff ── */
        @keyframes sv-torch-snuff {
          0% { opacity: 1; filter: brightness(1); }
          40% { opacity: 0.8; filter: brightness(1.3) saturate(1.5); }
          100% { opacity: 0.3; filter: brightness(0.3) grayscale(1); }
        }
        .sv-snuffed { animation: sv-torch-snuff 1.2s ease-in forwards; }

        /* ── Elimination red fade ── */
        @keyframes sv-elim-fade {
          0% { background-color: rgba(239,68,68,0.3); }
          100% { background-color: rgba(239,68,68,0.05); }
        }
        .sv-elim-flash { animation: sv-elim-fade 2s ease-out; }

        /* ── Whisper dotted line pulse ── */
        @keyframes sv-whisper-pulse {
          0%, 100% { opacity: 0.4; }
          50% { opacity: 1; }
        }
        .sv-whisper-line { animation: sv-whisper-pulse 2s ease-in-out infinite; }

        /* ── Firefly particles ── */
        @keyframes sv-firefly {
          0%, 100% { transform: translate(0, 0) scale(1); opacity: 0.3; }
          25% { transform: translate(15px, -20px) scale(1.3); opacity: 0.8; }
          50% { transform: translate(-10px, -35px) scale(0.8); opacity: 0.5; }
          75% { transform: translate(20px, -15px) scale(1.1); opacity: 0.9; }
        }
        .sv-firefly { animation: sv-firefly 8s ease-in-out infinite; position: absolute; pointer-events: none; }
        .sv-firefly-1 { animation-duration: 7s; animation-delay: 0s; }
        .sv-firefly-2 { animation-duration: 9s; animation-delay: 1.5s; }
        .sv-firefly-3 { animation-duration: 6s; animation-delay: 3s; }
        .sv-firefly-4 { animation-duration: 11s; animation-delay: 0.5s; }
        .sv-firefly-5 { animation-duration: 8s; animation-delay: 2s; }
        .sv-firefly-6 { animation-duration: 10s; animation-delay: 4s; }

        /* ── Jury seat glow ── */
        @keyframes sv-jury-glow {
          0%, 100% { box-shadow: 0 0 4px rgba(168,85,247,0.3); }
          50% { box-shadow: 0 0 10px rgba(168,85,247,0.6); }
        }
        .sv-jury-seat { animation: sv-jury-glow 3s ease-in-out infinite; }

        /* ── Victory fire ── */
        @keyframes sv-victory-fire {
          0%, 100% { text-shadow: 0 0 20px #f97316, 0 0 40px #ea580c, 0 0 60px #c2410c, 0 0 80px #9a3412; }
          50% { text-shadow: 0 0 30px #f97316, 0 0 60px #ea580c, 0 0 90px #c2410c, 0 0 120px #9a3412; }
        }
        .sv-victory-fire { animation: sv-victory-fire 2s ease-in-out infinite; }

        @keyframes sv-victory-pulse {
          0%, 100% { transform: scale(1); }
          50% { transform: scale(1.03); }
        }
        .sv-victory-pulse { animation: sv-victory-pulse 3s ease-in-out infinite; }

        /* ── Speech bubble ── */
        .sv-speech {
          position: relative;
          background: rgba(255,255,255,0.06);
          border: 1px solid rgba(255,255,255,0.08);
          border-radius: 10px;
          padding: 8px 12px;
        }
        .sv-speech::before {
          content: '';
          position: absolute;
          left: -7px;
          top: 12px;
          width: 0; height: 0;
          border-top: 5px solid transparent;
          border-bottom: 5px solid transparent;
          border-right: 7px solid rgba(255,255,255,0.08);
        }

        /* ── Phase transition cinematic ── */
        @keyframes sv-phase-enter {
          0% { opacity: 0; transform: translateY(-10px); filter: blur(4px); }
          100% { opacity: 1; transform: translateY(0); filter: blur(0); }
        }
        .sv-phase-enter { animation: sv-phase-enter 0.6s ease-out forwards; }

        /* ── Tribe banner ── */
        .sv-tribe-banner {
          position: relative;
          overflow: hidden;
        }
        .sv-tribe-banner::after {
          content: '';
          position: absolute;
          bottom: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, currentColor, transparent);
          opacity: 0.4;
        }

        /* ── Challenge badge bounce ── */
        @keyframes sv-badge-bounce {
          0%, 100% { transform: translateY(0); }
          50% { transform: translateY(-3px); }
        }
        .sv-badge-bounce { animation: sv-badge-bounce 2s ease-in-out infinite; }

        /* ── Scrollbar styling ── */
        .sv-scroll::-webkit-scrollbar { width: 4px; }
        .sv-scroll::-webkit-scrollbar-track { background: rgba(0,0,0,0.2); border-radius: 2px; }
        .sv-scroll::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.1); border-radius: 2px; }
        .sv-scroll::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.2); }
      </style>

      <%!-- Phase background layer --%>
      <div class="absolute inset-0 z-0">
        <div class={[
          "absolute inset-0 transition-all duration-1000",
          phase_bg_class(@phase)
        ]}></div>
        <%!-- Firefly particles --%>
        <div class="sv-firefly sv-firefly-1" style="left: 10%; bottom: 20%; width: 3px; height: 3px; background: radial-gradient(circle, #fbbf24, transparent); border-radius: 50%;"></div>
        <div class="sv-firefly sv-firefly-2" style="left: 30%; bottom: 40%; width: 2px; height: 2px; background: radial-gradient(circle, #f59e0b, transparent); border-radius: 50%;"></div>
        <div class="sv-firefly sv-firefly-3" style="left: 55%; bottom: 15%; width: 3px; height: 3px; background: radial-gradient(circle, #fbbf24, transparent); border-radius: 50%;"></div>
        <div class="sv-firefly sv-firefly-4" style="left: 75%; bottom: 55%; width: 2px; height: 2px; background: radial-gradient(circle, #f97316, transparent); border-radius: 50%;"></div>
        <div class="sv-firefly sv-firefly-5" style="left: 45%; bottom: 65%; width: 3px; height: 3px; background: radial-gradient(circle, #fbbf24, transparent); border-radius: 50%;"></div>
        <div class="sv-firefly sv-firefly-6" style="left: 85%; bottom: 30%; width: 2px; height: 2px; background: radial-gradient(circle, #f59e0b, transparent); border-radius: 50%;"></div>
      </div>

      <%!-- Main content --%>
      <div class="relative z-10 flex flex-col h-full">

        <%!-- ══════════════════════════════════════════════════════════════ --%>
        <%!-- TOP BAR: Episode, Phase, Immunity                           --%>
        <%!-- ══════════════════════════════════════════════════════════════ --%>
        <div class="flex items-center justify-between px-4 py-2.5 border-b border-white/5 bg-black/20 backdrop-blur-sm">
          <div class="flex items-center gap-3">
            <%!-- Torch icon --%>
            <div class="sv-flame text-xl leading-none select-none" style="transform-origin: bottom center;">
              &#x1F525;
            </div>
            <div>
              <div class="text-[9px] font-mono uppercase tracking-[0.2em] text-amber-600/70 font-bold leading-tight">
                Episode {@episode}
              </div>
              <div class={[
                "text-sm font-black tracking-tight leading-tight",
                phase_title_color(@phase)
              ]}>
                {phase_label(@phase)}
              </div>
            </div>
          </div>

          <%!-- Center: Status/Merge indicator --%>
          <div class="flex items-center gap-2">
            <div :if={@merged} class="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-purple-500/10 border border-purple-500/20">
              <div class="w-1.5 h-1.5 rounded-full bg-purple-400"></div>
              <span class="text-[10px] font-bold text-purple-300 uppercase tracking-wider">{@merge_tribe_name}</span>
            </div>
            <div :if={@game_status == "in_progress"} class="flex items-center gap-1.5 px-2 py-0.5 rounded bg-emerald-500/10 border border-emerald-500/20">
              <span class="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse"></span>
              <span class="text-[10px] text-emerald-400 font-medium">Live</span>
            </div>
          </div>

          <%!-- Right: Immunity indicator --%>
          <div class="flex items-center gap-2">
            <div :if={@immune_player} class="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-yellow-500/10 border border-yellow-500/20 sv-immune">
              <span class="text-yellow-400 text-sm">&#x1F3C6;</span>
              <span class="text-[10px] font-bold text-yellow-300">{player_name(@immune_player, @players)} - Immune</span>
            </div>
            <div :if={@idol_played_by} class="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-yellow-500/20 border border-yellow-500/30 sv-idol-burst">
              <span class="text-yellow-300 text-sm">&#x2728;</span>
              <span class="text-[10px] font-black text-yellow-200 uppercase">Idol Played!</span>
            </div>
          </div>
        </div>

        <%!-- ══════════════════════════════════════════════════════════════ --%>
        <%!-- MAIN LAYOUT: Left Panel | Center | Right Panel               --%>
        <%!-- ══════════════════════════════════════════════════════════════ --%>
        <div class="flex flex-1 overflow-hidden">

          <%!-- ──────────────────────────────────────────────────────────── --%>
          <%!-- LEFT PANEL: Tribe Rosters                                   --%>
          <%!-- ──────────────────────────────────────────────────────────── --%>
          <div class="w-52 flex-shrink-0 border-r border-white/5 overflow-y-auto sv-scroll bg-black/10">
            <div class="p-3 space-y-3">
              <%= if @merged do %>
                <%!-- Merged tribe --%>
                <div class="sv-tribe-banner text-purple-400">
                  <div class="flex items-center gap-2 px-2 py-1.5 rounded-t-lg bg-purple-500/10 border border-purple-500/20">
                    <div class="w-2 h-2 rounded-full bg-purple-400 shadow-[0_0_6px_rgba(168,85,247,0.5)]"></div>
                    <span class="text-[10px] font-black tracking-wider uppercase text-purple-300">{@merge_tribe_name}</span>
                  </div>
                </div>
                <div class="space-y-1">
                  <%= for {p_id, p_data} <- @alive_players do %>
                    <.player_card
                      player_id={p_id}
                      player={p_data}
                      active={p_id == @active_actor}
                      immune={is_immune?(p_id, @immune_player)}
                      jury_member={false}
                      tribe_color={tribe_color(get_val(p_data, :tribe, ""))}
                      all_players={@players}
                    />
                  <% end %>
                </div>
              <% else %>
                <%!-- Pre-merge: separate tribes --%>
                <%= for tribe_name <- @tribe_names do %>
                  <% tribe_member_ids = Map.get(@tribes, tribe_name, []) %>
                  <% tc = tribe_color(tribe_name) %>
                  <div>
                    <div class="sv-tribe-banner" style={"color: #{tc}"}>
                      <div class="flex items-center gap-2 px-2 py-1.5 rounded-t-lg border" style={"background: #{tc}10; border-color: #{tc}30"}>
                        <div class="w-2 h-2 rounded-full shadow-sm" style={"background: #{tc}; box-shadow: 0 0 6px #{tc}80"}></div>
                        <span class="text-[10px] font-black tracking-wider uppercase" style={"color: #{tc}"}>{tribe_name}</span>
                        <span class="text-[9px] text-white/30 ml-auto">{length(tribe_member_ids)}</span>
                      </div>
                    </div>
                    <div class="space-y-1 mt-1">
                      <%= for member_id <- tribe_member_ids do %>
                        <% p_data = Map.get(@players, member_id, %{}) %>
                        <.player_card
                          player_id={member_id}
                          player={p_data}
                          active={member_id == @active_actor}
                          immune={is_immune?(member_id, @immune_player)}
                          jury_member={to_string(member_id) in Enum.map(@jury, &to_string/1)}
                          tribe_color={tc}
                          all_players={@players}
                        />
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% end %>

              <%!-- Eliminated players --%>
              <div :if={@eliminated_players != []} class="mt-4 pt-3 border-t border-white/5">
                <div class="text-[9px] font-bold tracking-wider uppercase text-gray-600 px-1 mb-2">Eliminated</div>
                <div class="space-y-1">
                  <%= for {p_id, p_data} <- @eliminated_players do %>
                    <.player_card
                      player_id={p_id}
                      player={p_data}
                      active={false}
                      immune={false}
                      jury_member={to_string(p_id) in Enum.map(@jury, &to_string/1)}
                      tribe_color="#6b7280"
                      all_players={@players}
                    />
                  <% end %>
                </div>
              </div>
            </div>
          </div>

          <%!-- ──────────────────────────────────────────────────────────── --%>
          <%!-- CENTER PANEL: Main Game Area                                --%>
          <%!-- ──────────────────────────────────────────────────────────── --%>
          <div class="flex-1 overflow-y-auto sv-scroll">
            <div class="p-4 space-y-4 sv-phase-enter">

              <%!-- CHALLENGE PHASE --%>
              <div :if={@phase == "challenge"} class="space-y-4">
                <div class="text-center">
                  <div class="text-[10px] font-mono uppercase tracking-[0.3em] text-emerald-600/60 mb-1">Immunity Challenge</div>
                  <div class="text-xl font-black text-emerald-300 tracking-tight">Come On In, Guys!</div>
                </div>

                <%!-- Challenge strategy picks --%>
                <div :if={map_size(@challenge_choices) > 0} class="bg-black/20 rounded-xl border border-emerald-500/10 p-4">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-emerald-500/60 mb-3">Strategy Choices</div>
                  <div class="grid grid-cols-3 gap-3">
                    <%= for strat <- ["physical", "puzzle", "endurance"] do %>
                      <div class="text-center">
                        <div class={[
                          "inline-flex items-center justify-center w-12 h-12 rounded-full mb-2 sv-badge-bounce",
                          challenge_badge_class(strat)
                        ]}>
                          <span class="text-xl">{challenge_icon(strat)}</span>
                        </div>
                        <div class="text-[10px] font-bold uppercase tracking-wider text-white/60 mb-2">{strat}</div>
                        <div class="space-y-1">
                          <%= for {p_id, choice} <- @challenge_choices, to_string(choice) == strat do %>
                            <div class="text-[10px] px-2 py-0.5 rounded bg-white/5 text-white/70 truncate">
                              {player_name(p_id, @players)}
                            </div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Challenge winner announcement --%>
                <div :if={@challenge_winner} class="text-center p-4 rounded-xl bg-yellow-500/5 border border-yellow-500/20">
                  <div class="text-yellow-400 text-2xl mb-1">&#x1F3C6;</div>
                  <div class="text-[10px] font-mono uppercase tracking-[0.2em] text-yellow-600/60 mb-1">Challenge Winner</div>
                  <div class="text-lg font-black text-yellow-300">{format_winner(@challenge_winner)}</div>
                  <div :if={@losing_tribe} class="text-[11px] text-red-400/70 mt-2">
                    {format_winner(@losing_tribe)} heads to Tribal Council
                  </div>
                </div>
              </div>

              <%!-- STRATEGY PHASE --%>
              <div :if={@phase == "strategy"} class="space-y-4">
                <div class="text-center">
                  <div class="text-[10px] font-mono uppercase tracking-[0.3em] text-amber-600/60 mb-1">Camp Life</div>
                  <div class="text-xl font-black text-amber-200 tracking-tight">Strategy & Alliances</div>
                </div>

                <%!-- Whisper graph visualization --%>
                <div :if={@whisper_graph != []} class="bg-black/20 rounded-xl border border-amber-500/10 p-4">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-amber-500/60 mb-3">Whisper Network</div>
                  <div class="relative" style="min-height: 180px;">
                    <%!-- Player nodes in a circle --%>
                    <% alive_ids = Enum.map(@alive_players, fn {id, _} -> id end) %>
                    <% node_count = length(alive_ids) %>
                    <%= for {p_id, idx} <- Enum.with_index(alive_ids) do %>
                      <% angle = idx * 360 / max(node_count, 1) %>
                      <% rad = angle * :math.pi() / 180 %>
                      <% cx = 50 + 35 * :math.cos(rad) %>
                      <% cy = 50 + 35 * :math.sin(rad) %>
                      <div
                        class={[
                          "absolute flex items-center justify-center rounded-full text-[8px] font-bold border-2 z-10",
                          if(p_id == @active_actor, do: "sv-active border-amber-400 bg-amber-500/20 text-amber-200", else: "border-white/20 bg-black/40 text-white/60")
                        ]}
                        style={"left: #{cx}%; top: #{cy}%; width: 32px; height: 32px; transform: translate(-50%, -50%);"}
                        title={player_name(p_id, @players)}
                      >
                        {player_initials(p_id, @players)}
                      </div>
                    <% end %>
                    <%!-- Whisper connections as SVG lines --%>
                    <svg class="absolute inset-0 w-full h-full pointer-events-none" viewBox="0 0 100 100" preserveAspectRatio="none">
                      <%= for edge <- @whisper_graph do %>
                        <% from_id = get_val(edge, :from, nil) %>
                        <% to_id = get_val(edge, :to, nil) %>
                        <% from_idx = Enum.find_index(alive_ids, fn id -> to_string(id) == to_string(from_id) end) %>
                        <% to_idx = Enum.find_index(alive_ids, fn id -> to_string(id) == to_string(to_id) end) %>
                        <%= if from_idx && to_idx do %>
                          <% from_angle = from_idx * 360 / max(node_count, 1) * :math.pi() / 180 %>
                          <% to_angle = to_idx * 360 / max(node_count, 1) * :math.pi() / 180 %>
                          <% x1 = 50 + 35 * :math.cos(from_angle) %>
                          <% y1 = 50 + 35 * :math.sin(from_angle) %>
                          <% x2 = 50 + 35 * :math.cos(to_angle) %>
                          <% y2 = 50 + 35 * :math.sin(to_angle) %>
                          <line
                            x1={x1} y1={y1} x2={x2} y2={y2}
                            stroke="#f59e0b"
                            stroke-width="0.4"
                            stroke-dasharray="1.5,1"
                            opacity="0.5"
                            class="sv-whisper-line"
                          />
                        <% end %>
                      <% end %>
                    </svg>
                  </div>
                </div>

                <%!-- Public statements --%>
                <div :if={@statements != []} class="space-y-2">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-amber-500/60">Public Statements</div>
                  <div class="space-y-2 max-h-64 overflow-y-auto sv-scroll">
                    <%= for stmt <- Enum.take(@statements, -8) do %>
                      <% speaker = get_val(stmt, :player, "?") %>
                      <% text = get_val(stmt, :statement, "") %>
                      <div class="flex gap-2 items-start">
                        <div class="flex-shrink-0 w-7 h-7 rounded-full flex items-center justify-center text-[9px] font-bold border border-white/10 bg-white/5 text-white/60">
                          {player_initials(speaker, @players)}
                        </div>
                        <div class="sv-speech flex-1 text-[11px] text-white/70 leading-relaxed">
                          <span class="font-bold text-amber-300/80 text-[10px]">{player_name(speaker, @players)}</span>
                          <br />{text}
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Whisper log (private messages) --%>
                <div :if={@whisper_log != []} class="space-y-2">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-purple-400/60">Private Whispers</div>
                  <div class="space-y-1.5 max-h-48 overflow-y-auto sv-scroll">
                    <%= for whisper <- Enum.take(@whisper_log, -6) do %>
                      <% from = get_val(whisper, :from, "?") %>
                      <% to = get_val(whisper, :to, "?") %>
                      <% msg = get_val(whisper, :message, "") %>
                      <div class="flex items-start gap-2 pl-2 border-l-2 border-purple-500/20">
                        <div class="text-[10px]">
                          <span class="font-bold text-purple-300/80">{player_name(from, @players)}</span>
                          <span class="text-white/30 mx-1">&#x2192;</span>
                          <span class="font-bold text-purple-300/80">{player_name(to, @players)}</span>
                        </div>
                        <div class="text-[10px] text-white/40 italic flex-1">"{msg}"</div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- TRIBAL COUNCIL PHASE --%>
              <div :if={@phase == "tribal_council"} class="space-y-4">
                <div class="text-center">
                  <div class="sv-flame text-3xl mb-2" style="transform-origin: bottom center;">&#x1F525;</div>
                  <div class="text-[10px] font-mono uppercase tracking-[0.3em] text-orange-600/60 mb-1">Tribal Council</div>
                  <div class="text-xl font-black text-orange-300 tracking-tight" style="text-shadow: 0 0 20px rgba(249,115,22,0.3);">
                    The Tribe Has Spoken
                  </div>
                </div>

                <%!-- Idol play announcement --%>
                <div :if={@idol_played_by} class="text-center p-4 rounded-xl sv-idol-burst" style="background: radial-gradient(ellipse, rgba(234,179,8,0.15), transparent 70%); border: 1px solid rgba(234,179,8,0.3);">
                  <div class="text-3xl mb-1">&#x2728;</div>
                  <div class="text-[10px] font-mono uppercase tracking-[0.2em] text-yellow-500/60 mb-1">Hidden Immunity Idol</div>
                  <div class="text-lg font-black text-yellow-200">
                    {player_name(@idol_played_by, @players)} plays the idol!
                  </div>
                  <div class="text-[10px] text-yellow-400/60 mt-1">Any votes cast against them will not count.</div>
                </div>

                <%!-- Vote reveal area --%>
                <div :if={map_size(@votes) > 0} class="bg-black/30 rounded-xl border border-orange-500/10 p-4">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-orange-500/60 mb-3">Votes</div>
                  <div class="space-y-1.5">
                    <%= for {{voter_id, target_id}, idx} <- Enum.with_index(@votes) do %>
                      <div class={[
                        "flex items-center justify-between px-3 py-2 rounded-lg bg-white/[0.03] border border-white/5 sv-vote-reveal",
                        vote_delay_class(idx)
                      ]}>
                        <div class="flex items-center gap-2">
                          <div class="w-5 h-5 rounded-full bg-white/5 flex items-center justify-center text-[8px] font-bold text-white/40 border border-white/10">
                            {player_initials(voter_id, @players)}
                          </div>
                          <span class="text-[10px] text-white/50">{player_name(voter_id, @players)}</span>
                        </div>
                        <div class="flex items-center gap-2">
                          <span class="text-[10px] text-white/30">voted for</span>
                          <span class="text-[11px] font-bold text-red-400">{player_name(target_id, @players)}</span>
                        </div>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Vote tally --%>
                  <div :if={map_size(@vote_tally) > 0} class="mt-4 pt-3 border-t border-white/5">
                    <div class="text-[10px] font-bold tracking-wider uppercase text-orange-500/60 mb-2">Vote Tally</div>
                    <div class="space-y-2">
                      <%= for {target, count} <- Enum.sort_by(@vote_tally, fn {_, c} -> -c end) do %>
                        <div class="flex items-center gap-3">
                          <span class="text-[11px] font-bold text-white/70 w-24 truncate">{player_name(target, @players)}</span>
                          <div class="flex-1 flex items-center gap-1">
                            <%= for _i <- 1..count do %>
                              <div class="sv-flame text-sm" style="transform-origin: bottom center;">&#x1F525;</div>
                            <% end %>
                          </div>
                          <span class="text-[11px] font-bold text-red-400 tabular-nums">{count}</span>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%!-- Elimination announcement --%>
                <div :if={@elimination_log != []} class="mt-2">
                  <% latest_elim = List.last(@elimination_log) %>
                  <div :if={latest_elim && get_val(latest_elim, :episode, 0) == @episode} class="text-center p-4 rounded-xl sv-elim-flash" style="border: 1px solid rgba(239,68,68,0.2);">
                    <div class="text-2xl mb-2 sv-snuffed">&#x1F525;</div>
                    <div class="text-[10px] font-mono uppercase tracking-[0.2em] text-red-500/60 mb-1">Eliminated</div>
                    <div class="text-lg font-black text-red-400">
                      {player_name(get_val(latest_elim, :player, ""), @players)}
                    </div>
                    <div class="text-[10px] text-red-400/50 mt-1 italic">
                      {get_val(latest_elim, :reason, "The tribe has spoken.")}
                    </div>
                  </div>
                </div>
              </div>

              <%!-- FINAL TRIBAL COUNCIL --%>
              <div :if={@phase == "final_tribal_council"} class="space-y-4">
                <div class="text-center">
                  <div class="sv-flame text-3xl mb-2" style="transform-origin: bottom center;">&#x1F525;</div>
                  <div class="text-[10px] font-mono uppercase tracking-[0.3em] text-purple-500/60 mb-1">Final Tribal Council</div>
                  <div class="text-xl font-black text-purple-200 tracking-tight" style="text-shadow: 0 0 20px rgba(168,85,247,0.3);">
                    <%= case @ftc_sub_phase do %>
                      <% "jury_statements" -> %>Jury Addresses the Finalists
                      <% "finalist_pleas" -> %>Finalists Make Their Case
                      <% "jury_voting" -> %>The Jury Votes
                      <% _ -> %>Final Tribal Council
                    <% end %>
                  </div>
                </div>

                <%!-- Jury seating arrangement --%>
                <div class="bg-black/20 rounded-xl border border-purple-500/10 p-4">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-purple-500/60 mb-3">The Jury</div>
                  <div class="flex flex-wrap gap-2 justify-center">
                    <%= for juror_id <- @jury do %>
                      <div class={[
                        "flex flex-col items-center gap-1 px-3 py-2 rounded-lg border sv-jury-seat",
                        if(Map.has_key?(@jury_votes, juror_id) or Map.has_key?(@jury_votes, to_string(juror_id)),
                          do: "border-purple-400/30 bg-purple-500/10",
                          else: "border-white/10 bg-white/[0.03]"
                        )
                      ]}>
                        <div class="w-8 h-8 rounded-full flex items-center justify-center text-[10px] font-bold border border-purple-400/30 bg-purple-500/10 text-purple-300">
                          {player_initials(juror_id, @players)}
                        </div>
                        <span class="text-[9px] text-white/50 font-medium">{player_name(juror_id, @players)}</span>
                        <%= if jury_vote_for(juror_id, @jury_votes) do %>
                          <span class="text-[8px] text-purple-300 font-bold">&#x2192; {player_name(jury_vote_for(juror_id, @jury_votes), @players)}</span>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Finalists --%>
                <div :if={@finalists != []} class="bg-black/20 rounded-xl border border-amber-500/10 p-4">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-amber-500/60 mb-3">Finalists</div>
                  <div class="flex gap-4 justify-center">
                    <%= for {f_id, f_data} <- @finalists do %>
                      <div class="flex flex-col items-center gap-2 px-4 py-3 rounded-xl border border-amber-500/20 bg-amber-500/5">
                        <div class="w-12 h-12 rounded-full flex items-center justify-center text-lg font-black border-2 border-amber-400/40 bg-amber-500/10 text-amber-200">
                          {player_initials(f_id, @players)}
                        </div>
                        <span class="text-[11px] text-amber-200 font-bold">{player_name(f_id, @players)}</span>
                        <div :if={map_size(@jury_vote_tally) > 0} class="text-center">
                          <span class="text-lg font-black text-amber-300 tabular-nums">{Map.get(@jury_vote_tally, f_id, Map.get(@jury_vote_tally, to_string(f_id), 0))}</span>
                          <div class="text-[8px] text-amber-500/60 uppercase">votes</div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>

                <%!-- Jury statements --%>
                <div :if={@jury_statements != []} class="space-y-2">
                  <div class="text-[10px] font-bold tracking-wider uppercase text-purple-400/60">Jury Statements</div>
                  <div class="space-y-2 max-h-48 overflow-y-auto sv-scroll">
                    <%= for stmt <- @jury_statements do %>
                      <% speaker = get_val(stmt, :player, get_val(stmt, :juror, "?")) %>
                      <% text = get_val(stmt, :statement, get_val(stmt, :text, "")) %>
                      <div class="flex gap-2 items-start pl-2 border-l-2 border-purple-500/20">
                        <div class="flex-shrink-0 w-6 h-6 rounded-full flex items-center justify-center text-[8px] font-bold border border-purple-400/20 bg-purple-500/10 text-purple-300">
                          {player_initials(speaker, @players)}
                        </div>
                        <div class="text-[10px] text-white/60 leading-relaxed">
                          <span class="font-bold text-purple-300/80">{player_name(speaker, @players)}</span>:
                          {text}
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- GAME OVER --%>
              <div :if={@phase == "game_over" || @game_status == "game_over"} class="flex flex-col items-center justify-center py-8">
                <div class="sv-victory-pulse text-center">
                  <%!-- Torch ring --%>
                  <div class="flex justify-center gap-2 mb-4">
                    <span class="sv-flame text-2xl" style="animation-delay: 0s;">&#x1F525;</span>
                    <span class="sv-flame text-2xl" style="animation-delay: 0.3s;">&#x1F525;</span>
                    <span class="sv-flame text-2xl" style="animation-delay: 0.6s;">&#x1F525;</span>
                    <span class="sv-flame text-3xl" style="animation-delay: 0.15s;">&#x1F525;</span>
                    <span class="sv-flame text-2xl" style="animation-delay: 0.45s;">&#x1F525;</span>
                    <span class="sv-flame text-2xl" style="animation-delay: 0.75s;">&#x1F525;</span>
                    <span class="sv-flame text-2xl" style="animation-delay: 0.9s;">&#x1F525;</span>
                  </div>

                  <div class="text-[10px] font-mono uppercase tracking-[0.4em] text-amber-600/50 mb-2">The Sole Survivor</div>
                  <div :if={@winner} class="text-3xl font-black text-amber-200 sv-victory-fire mb-3">
                    {player_name(@winner, @players)}
                  </div>
                  <div :if={is_nil(@winner)} class="text-2xl font-black text-gray-400 mb-3">
                    Game Over
                  </div>

                  <%!-- Winner stats --%>
                  <div :if={@winner} class="flex justify-center gap-6 mt-4">
                    <div class="text-center px-4 py-2 rounded-lg bg-amber-500/5 border border-amber-500/10">
                      <div class="text-lg font-black text-amber-300 tabular-nums">{@episode}</div>
                      <div class="text-[8px] uppercase tracking-wider text-amber-500/50 font-bold">Episodes</div>
                    </div>
                    <div class="text-center px-4 py-2 rounded-lg bg-amber-500/5 border border-amber-500/10">
                      <div class="text-lg font-black text-amber-300 tabular-nums">{jury_votes_for_winner(@winner, @jury_vote_tally)}</div>
                      <div class="text-[8px] uppercase tracking-wider text-amber-500/50 font-bold">Jury Votes</div>
                    </div>
                    <div class="text-center px-4 py-2 rounded-lg bg-amber-500/5 border border-amber-500/10">
                      <div class="text-lg font-black text-amber-300 tabular-nums">{length(@elimination_log)}</div>
                      <div class="text-[8px] uppercase tracking-wider text-amber-500/50 font-bold">Eliminations</div>
                    </div>
                  </div>

                  <%!-- Decorative bottom line --%>
                  <div class="w-48 h-px mx-auto mt-6 bg-gradient-to-r from-transparent via-amber-500/40 to-transparent"></div>
                </div>
              </div>

              <%!-- Default: discussion feed for any phase --%>
              <div :if={@statements != [] && @phase not in ["game_over", "final_tribal_council"]} class="mt-4">
                <div class="text-[10px] font-bold tracking-wider uppercase text-white/30 mb-2">Discussion</div>
                <div class="space-y-2 max-h-56 overflow-y-auto sv-scroll">
                  <%= for stmt <- Enum.take(@statements, -10) do %>
                    <% speaker = get_val(stmt, :player, "?") %>
                    <% text = get_val(stmt, :statement, "") %>
                    <div class="flex gap-2 items-start">
                      <div class="flex-shrink-0 w-6 h-6 rounded-full flex items-center justify-center text-[8px] font-bold border border-white/10 bg-white/5 text-white/40">
                        {player_initials(speaker, @players)}
                      </div>
                      <div class="sv-speech flex-1 text-[10px] text-white/60 leading-relaxed">
                        <span class="font-bold text-white/40 text-[9px]">{player_name(speaker, @players)}</span>
                        <br />{text}
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

            </div>
          </div>

          <%!-- ──────────────────────────────────────────────────────────── --%>
          <%!-- RIGHT PANEL: Timeline, Alliances, History                   --%>
          <%!-- ──────────────────────────────────────────────────────────── --%>
          <div class="w-48 flex-shrink-0 border-l border-white/5 overflow-y-auto sv-scroll bg-black/10">
            <div class="p-3 space-y-4">

              <%!-- Elimination Timeline (Torch Snuff Log) --%>
              <div>
                <div class="text-[9px] font-bold tracking-wider uppercase text-red-500/60 mb-2 flex items-center gap-1.5">
                  <span>&#x1F525;</span> Torch Snuff Log
                </div>
                <div :if={@elimination_log == []} class="text-[10px] text-white/20 italic px-1">
                  No eliminations yet
                </div>
                <div class="space-y-1.5">
                  <%= for {elim, idx} <- Enum.with_index(@elimination_log) do %>
                    <% elim_player = get_val(elim, :player, "?") %>
                    <% elim_episode = get_val(elim, :episode, "?") %>
                    <% elim_reason = get_val(elim, :reason, "") %>
                    <div class={[
                      "flex items-start gap-2 px-2 py-1.5 rounded-lg border transition-all",
                      if(idx == length(@elimination_log) - 1,
                        do: "border-red-500/20 bg-red-500/5 sv-elim-flash",
                        else: "border-white/5 bg-white/[0.02]"
                      )
                    ]}>
                      <div class="flex-shrink-0 mt-0.5">
                        <div class={[
                          "text-sm",
                          if(idx == length(@elimination_log) - 1, do: "sv-snuffed", else: "opacity-30 grayscale")
                        ]}>
                          &#x1F525;
                        </div>
                      </div>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center justify-between">
                          <span class="text-[10px] font-bold text-red-400/80 truncate">{player_name(elim_player, @players)}</span>
                          <span class="text-[8px] text-white/20 font-mono ml-1">Ep.{elim_episode}</span>
                        </div>
                        <div :if={elim_reason != ""} class="text-[9px] text-white/25 truncate mt-0.5 italic">{elim_reason}</div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Alliance Tracker (from whisper patterns) --%>
              <div>
                <div class="text-[9px] font-bold tracking-wider uppercase text-purple-400/60 mb-2 flex items-center gap-1.5">
                  <span class="text-purple-400">&#x1F91D;</span> Alliance Tracker
                </div>
                <div :if={@whisper_pairs == []} class="text-[10px] text-white/20 italic px-1">
                  No alliances detected
                </div>
                <div class="space-y-1">
                  <%= for {pair, count} <- Enum.take(@whisper_pairs, 8) do %>
                    <% [p1, p2] = pair %>
                    <div class="flex items-center gap-1.5 px-2 py-1 rounded bg-purple-500/5 border border-purple-500/10">
                      <div class="flex-1 min-w-0 flex items-center gap-1">
                        <span class="text-[9px] font-bold text-purple-300/70 truncate">{player_name(p1, @players)}</span>
                        <span class="text-[8px] text-white/20">&#x2194;</span>
                        <span class="text-[9px] font-bold text-purple-300/70 truncate">{player_name(p2, @players)}</span>
                      </div>
                      <div class="flex gap-px flex-shrink-0">
                        <%= for _i <- 1..min(count, 5) do %>
                          <div class="w-1 h-1 rounded-full bg-purple-400/60"></div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Challenge Win History --%>
              <div>
                <div class="text-[9px] font-bold tracking-wider uppercase text-emerald-500/60 mb-2 flex items-center gap-1.5">
                  <span class="text-yellow-400">&#x1F3C6;</span> Challenge History
                </div>
                <div :if={@challenge_history == []} class="text-[10px] text-white/20 italic px-1">
                  No challenges yet
                </div>
                <div class="space-y-1">
                  <%= for {ch, idx} <- Enum.with_index(@challenge_history) do %>
                    <% ch_winner = get_val(ch, :winner, get_val(ch, :challenge_winner, "?")) %>
                    <% ch_episode = get_val(ch, :episode, idx + 1) %>
                    <div class="flex items-center justify-between px-2 py-1 rounded bg-emerald-500/5 border border-emerald-500/10">
                      <div class="flex items-center gap-1.5">
                        <span class="text-[8px] text-white/20 font-mono">Ep.{ch_episode}</span>
                        <span class="text-[10px] font-bold text-emerald-300/70 truncate">{format_winner(ch_winner)}</span>
                      </div>
                      <span class="text-yellow-400/50 text-[10px]">&#x1F3C6;</span>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Idol History --%>
              <div :if={@idol_history != []}>
                <div class="text-[9px] font-bold tracking-wider uppercase text-yellow-500/60 mb-2 flex items-center gap-1.5">
                  <span class="text-yellow-300">&#x2728;</span> Idol Plays
                </div>
                <div class="space-y-1">
                  <%= for idol_play <- @idol_history do %>
                    <% idol_player = get_val(idol_play, :player, get_val(idol_play, :played_by, "?")) %>
                    <% idol_ep = get_val(idol_play, :episode, "?") %>
                    <div class="flex items-center justify-between px-2 py-1 rounded bg-yellow-500/5 border border-yellow-500/10">
                      <span class="text-[10px] font-bold text-yellow-300/70 truncate">{player_name(idol_player, @players)}</span>
                      <span class="text-[8px] text-white/20 font-mono">Ep.{idol_ep}</span>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Vote History Summary --%>
              <div :if={@vote_history != []}>
                <div class="text-[9px] font-bold tracking-wider uppercase text-orange-500/60 mb-2 flex items-center gap-1.5">
                  <span class="text-orange-400">&#x2696;</span> Past Votes
                </div>
                <div class="space-y-1">
                  <%= for {past_vote, idx} <- Enum.with_index(@vote_history) do %>
                    <% top_target = past_vote |> Enum.group_by(fn {_v, t} -> t end) |> Enum.max_by(fn {_t, vs} -> length(vs) end, fn -> {nil, []} end) |> elem(0) %>
                    <div class="flex items-center justify-between px-2 py-1 rounded bg-orange-500/5 border border-orange-500/10">
                      <span class="text-[8px] text-white/20 font-mono">TC {idx + 1}</span>
                      <span :if={top_target} class="text-[9px] text-orange-300/60 truncate">
                        &#x2192; {player_name(top_target, @players)}
                      </span>
                      <span class="text-[8px] text-white/20">{map_size(past_vote)} votes</span>
                    </div>
                  <% end %>
                </div>
              </div>

            </div>
          </div>

          <%!-- ──────────────────────────────────────────────────────────── --%>
          <%!-- FAR-RIGHT PANEL: Agent Journals & Connections               --%>
          <%!-- ──────────────────────────────────────────────────────────── --%>
          <div :if={map_size(@journals) > 0 || @connections != []} class="w-44 flex-shrink-0 border-l border-white/5 overflow-y-auto sv-scroll bg-black/10">
            <div class="px-2 py-2">
              <%!-- Journal entries --%>
              <div :if={map_size(@journals) > 0}>
                <div class="flex items-center gap-1.5 mb-2">
                  <span class="text-[10px]">&#x1F4D6;</span>
                  <span class="text-[9px] font-mono uppercase tracking-[0.2em] text-amber-400/70 font-bold">Agent Journals</span>
                </div>

                <%= for {player_id, entries} <- Enum.sort_by(@journals, fn {k, _v} -> to_string(k) end) do %>
                  <% recent = Enum.take(entries, -3) %>
                  <details :if={is_list(entries) && length(entries) > 0} class="group mb-1.5">
                    <summary class="cursor-pointer flex items-center gap-1.5 px-1.5 py-1 rounded text-[10px] hover:bg-white/5 transition-colors">
                      <span class="text-amber-500/60 transition-transform group-open:rotate-90 text-[8px]">&#x25B6;</span>
                      <span class="font-bold text-amber-300/80">{player_name(player_id, @players)}</span>
                      <span class="text-slate-600 ml-auto">{length(entries)}</span>
                    </summary>
                    <div class="pl-3 mt-1 space-y-1 border-l border-amber-900/20 ml-2">
                      <%= for entry <- recent do %>
                        <div class="text-[9px] text-slate-500 leading-snug">
                          <span class="text-amber-500/50 font-mono">R{get_val(entry, :round, "?")}</span>
                          <span :if={get_val(entry, :phase, nil)} class="text-amber-600/40 font-mono">{get_val(entry, :phase, "")}</span>
                          <span class="text-slate-400/80 italic">{get_val(entry, :thought, "")}</span>
                        </div>
                      <% end %>
                      <div :if={length(entries) > 3} class="text-[8px] text-slate-600 italic">
                        +{length(entries) - 3} earlier thoughts
                      </div>
                    </div>
                  </details>
                <% end %>
              </div>

              <%!-- Backstory connections --%>
              <div :if={@connections != []} class={[if(map_size(@journals) > 0, do: "pt-2 border-t border-white/5 mt-2", else: "")]}>
                <div class="text-[9px] font-mono uppercase tracking-[0.2em] text-pink-400/60 font-bold mb-1.5 flex items-center gap-1">
                  <span>&#x1F517;</span> Connections
                </div>
                <%= for conn <- @connections do %>
                  <div class="text-[9px] text-slate-500 leading-snug mb-1 px-1">
                    <span class="text-pink-400/60">{connection_emoji(get_val(conn, :type, ""))}</span>
                    <% conn_players = get_val(conn, :players, []) %>
                    <span :if={is_list(conn_players) && length(conn_players) > 0} class="text-amber-300/60 font-bold">
                      {Enum.map_join(conn_players, " & ", &to_string/1)}
                    </span>
                    <span class="text-slate-400">{get_val(conn, :description, "")}</span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

        </div>
      </div>

      <%!-- ══════════════════════════════════════════════════════════════ --%>
      <%!-- VICTORY OVERLAY                                               --%>
      <%!-- ══════════════════════════════════════════════════════════════ --%>
      <div
        :if={@game_status == "game_over" && @winner}
        class="absolute inset-0 z-50 flex items-center justify-center backdrop-blur-sm"
        style="background: radial-gradient(ellipse at center, rgba(0,0,0,0.7) 0%, rgba(0,0,0,0.9) 100%);"
      >
        <div class="text-center sv-victory-pulse">
          <%!-- Fire ring --%>
          <div class="flex justify-center gap-3 mb-6">
            <%= for i <- 0..8 do %>
              <span class="sv-flame text-2xl" style={"animation-delay: #{i * 0.15}s; transform-origin: bottom center;"}>&#x1F525;</span>
            <% end %>
          </div>

          <div class="text-[11px] font-mono uppercase tracking-[0.5em] text-amber-600/50 mb-3">The Sole Survivor</div>
          <div class="text-4xl font-black text-amber-200 sv-victory-fire mb-2 px-8">
            {player_name(@winner, @players)}
          </div>

          <div class="flex justify-center gap-1 my-4">
            <%= for _i <- 1..3 do %>
              <div class="w-2 h-2 rounded-full bg-amber-500/30"></div>
            <% end %>
          </div>

          <div class="flex justify-center gap-8 mt-6">
            <div class="text-center">
              <div class="text-2xl font-black text-amber-300 tabular-nums">{@episode}</div>
              <div class="text-[9px] uppercase tracking-wider text-amber-500/40 font-bold mt-1">Episodes Survived</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-black text-amber-300 tabular-nums">{jury_votes_for_winner(@winner, @jury_vote_tally)}</div>
              <div class="text-[9px] uppercase tracking-wider text-amber-500/40 font-bold mt-1">Jury Votes Won</div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-black text-amber-300 tabular-nums">{length(@elimination_log)}</div>
              <div class="text-[9px] uppercase tracking-wider text-amber-500/40 font-bold mt-1">Players Eliminated</div>
            </div>
          </div>

          <div class="w-64 h-px mx-auto mt-8 bg-gradient-to-r from-transparent via-amber-500/30 to-transparent"></div>

          <%!-- Bottom fire ring --%>
          <div class="flex justify-center gap-3 mt-6">
            <%= for i <- 0..8 do %>
              <span class="sv-flame text-lg opacity-60" style={"animation-delay: #{i * 0.2}s; transform-origin: bottom center;"}>&#x1F525;</span>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Player Card Component ───────────────────────────────────────────

  attr :player_id, :any, required: true
  attr :player, :map, required: true
  attr :active, :boolean, default: false
  attr :immune, :boolean, default: false
  attr :jury_member, :boolean, default: false
  attr :tribe_color, :string, default: "#6b7280"
  attr :all_players, :map, default: %{}

  defp player_card(assigns) do
    player = assigns.player
    p_status = get_val(player, :status, "alive")
    is_eliminated = p_status == "eliminated"
    has_idol = get_val(player, :has_idol, false)
    model = get_val(player, :model, nil)
    player_traits = get_val(player, :traits, [])
    player_traits = if is_list(player_traits), do: player_traits, else: []

    assigns =
      assigns
      |> assign(:is_eliminated, is_eliminated)
      |> assign(:has_idol, has_idol)
      |> assign(:model_name, model)
      |> assign(:player_traits, player_traits)

    ~H"""
    <div class={[
      "px-2 py-1.5 rounded-lg border transition-all text-xs",
      if(@is_eliminated, do: "opacity-30 border-white/5 bg-white/[0.02]", else: ""),
      if(@active && !@is_eliminated, do: "sv-active border-orange-400/30 bg-orange-500/5", else: ""),
      if(!@active && !@is_eliminated, do: "border-white/5 bg-white/[0.03] hover:bg-white/[0.05]", else: "")
    ]}>
      <div class="flex items-center gap-1.5">
        <%!-- Avatar circle --%>
        <div class={[
          "w-6 h-6 rounded-full flex items-center justify-center text-[9px] font-bold border flex-shrink-0",
          if(@is_eliminated, do: "border-white/10 bg-white/5 text-white/20 line-through", else: ""),
          if(@immune && !@is_eliminated, do: "sv-immune border-yellow-400/50 bg-yellow-500/10 text-yellow-200", else: ""),
          if(!@is_eliminated && !@immune, do: "text-white/60", else: "")
        ]} style={if(!@is_eliminated && !@immune, do: "border-color: #{@tribe_color}40; background: #{@tribe_color}10", else: "")}>
          {player_initials(@player_id, @all_players)}
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between gap-1">
            <span class={[
              "font-semibold text-[10px] truncate leading-tight",
              if(@is_eliminated, do: "text-white/20 line-through", else: "text-white/70")
            ]}>
              {player_name(@player_id, @all_players)}
            </span>
            <div class="flex items-center gap-0.5 flex-shrink-0">
              <span :if={@has_idol && !@is_eliminated} class="text-yellow-400 text-[10px]" title="Has Hidden Immunity Idol">&#x2728;</span>
              <span :if={@immune && !@is_eliminated} class="text-yellow-300 text-[10px]" title="Immune">&#x1F3C6;</span>
              <span :if={@jury_member} class="text-purple-400 text-[10px]" title="Jury Member">&#x2696;</span>
              <span :if={@active && !@is_eliminated} class="sv-flame text-[10px]" title="Currently Acting" style="transform-origin: bottom center;">&#x1F525;</span>
            </div>
          </div>
          <div :if={@model_name && !@is_eliminated} class="text-[8px] text-white/20 truncate leading-tight mt-0.5">
            {format_model(@model_name)}
          </div>
          <div :if={@player_traits != [] && !@is_eliminated} class="flex gap-0.5 flex-wrap mt-0.5">
            <%= for trait <- @player_traits do %>
              <span class="text-[7px] px-1 py-0 rounded bg-amber-950/40 text-amber-400/70 border border-amber-500/10 leading-tight" title={trait}>
                {trait}
              </span>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Flexible Key Access ─────────────────────────────────────────────

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

  # ── Player Display Helpers ──────────────────────────────────────────

  defp player_name(nil, _players), do: "?"

  defp player_name(player_id, players) when is_map(players) do
    player = Map.get(players, player_id, Map.get(players, to_string(player_id), nil))

    if player do
      get_val(player, :name, nil) || get_val(player, :display_name, nil) || to_string(player_id)
    else
      to_string(player_id)
    end
  end

  defp player_name(player_id, _), do: to_string(player_id)

  defp player_initials(nil, _players), do: "?"

  defp player_initials(player_id, players) do
    name = player_name(player_id, players)

    name
    |> String.split(~r/[\s_-]+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
    |> String.slice(0, 2)
    |> case do
      "" -> String.slice(String.upcase(to_string(player_id)), 0, 2)
      initials -> initials
    end
  end

  defp format_model(nil), do: ""
  defp format_model(model) when is_binary(model), do: String.slice(model, 0, 20)
  defp format_model(model), do: String.slice(to_string(model), 0, 20)

  defp format_winner(winner) when is_binary(winner), do: winner
  defp format_winner(winner), do: to_string(winner)

  # ── Tribe Color ─────────────────────────────────────────────────────

  defp tribe_color(tribe_name) when is_binary(tribe_name) do
    name_lower = String.downcase(tribe_name)

    cond do
      String.contains?(name_lower, "fire") or String.contains?(name_lower, "red") or
          String.contains?(name_lower, "lava") ->
        "#f97316"

      String.contains?(name_lower, "ocean") or String.contains?(name_lower, "blue") or
          String.contains?(name_lower, "water") ->
        "#6366f1"

      String.contains?(name_lower, "jungle") or String.contains?(name_lower, "green") or
          String.contains?(name_lower, "forest") ->
        "#10b981"

      String.contains?(name_lower, "merge") ->
        "#a855f7"

      true ->
        # Deterministic color from name hash
        color_index = :erlang.phash2(name_lower, 6)

        case color_index do
          0 -> "#f97316"
          1 -> "#6366f1"
          2 -> "#10b981"
          3 -> "#ec4899"
          4 -> "#14b8a6"
          _ -> "#f59e0b"
        end
    end
  end

  defp tribe_color(tribe_name) when is_atom(tribe_name), do: tribe_color(Atom.to_string(tribe_name))
  defp tribe_color(_), do: "#6b7280"

  # ── Phase Helpers ───────────────────────────────────────────────────

  defp phase_label("challenge"), do: "IMMUNITY CHALLENGE"
  defp phase_label("strategy"), do: "STRATEGY & ALLIANCES"
  defp phase_label("tribal_council"), do: "TRIBAL COUNCIL"
  defp phase_label("final_tribal_council"), do: "FINAL TRIBAL COUNCIL"
  defp phase_label("game_over"), do: "GAME OVER"
  defp phase_label(other) when is_binary(other), do: String.upcase(other)
  defp phase_label(_), do: "UNKNOWN"

  defp phase_bg_class("challenge"), do: "sv-phase-challenge"
  defp phase_bg_class("strategy"), do: "sv-phase-strategy"
  defp phase_bg_class("tribal_council"), do: "sv-phase-tribal"
  defp phase_bg_class("final_tribal_council"), do: "sv-phase-ftc"
  defp phase_bg_class("game_over"), do: "sv-phase-gameover"
  defp phase_bg_class(_), do: "sv-phase-challenge"

  defp phase_title_color("challenge"), do: "text-emerald-300"
  defp phase_title_color("strategy"), do: "text-amber-200"
  defp phase_title_color("tribal_council"), do: "text-orange-300"
  defp phase_title_color("final_tribal_council"), do: "text-purple-200"
  defp phase_title_color("game_over"), do: "text-amber-200"
  defp phase_title_color(_), do: "text-white"

  # ── Immunity Check ──────────────────────────────────────────────────

  defp is_immune?(player_id, immune_player) do
    immune_player != nil && to_string(player_id) == to_string(immune_player)
  end

  # ── Challenge Helpers ───────────────────────────────────────────────

  defp challenge_badge_class("physical"), do: "bg-red-500/15 border-2 border-red-500/30"
  defp challenge_badge_class("puzzle"), do: "bg-blue-500/15 border-2 border-blue-500/30"
  defp challenge_badge_class("endurance"), do: "bg-emerald-500/15 border-2 border-emerald-500/30"
  defp challenge_badge_class(_), do: "bg-white/5 border-2 border-white/10"

  defp challenge_icon("physical"), do: "&#x1F4AA;"
  defp challenge_icon("puzzle"), do: "&#x1F9E9;"
  defp challenge_icon("endurance"), do: "&#x1F3CB;"
  defp challenge_icon(_), do: "&#x2753;"

  # ── Vote Helpers ────────────────────────────────────────────────────

  defp vote_delay_class(idx) when idx < 8, do: "sv-vote-delay-#{idx + 1}"
  defp vote_delay_class(_), do: ""

  defp jury_vote_for(juror_id, jury_votes) do
    Map.get(jury_votes, juror_id, Map.get(jury_votes, to_string(juror_id), nil))
  end

  defp jury_votes_for_winner(winner, jury_vote_tally) do
    Map.get(jury_vote_tally, winner, Map.get(jury_vote_tally, to_string(winner), 0))
  end

  # ── Whisper Alliance Detection ──────────────────────────────────────

  defp build_whisper_pairs(whisper_graph) when is_list(whisper_graph) do
    whisper_graph
    |> Enum.map(fn edge ->
      from = to_string(get_val(edge, :from, ""))
      to = to_string(get_val(edge, :to, ""))
      Enum.sort([from, to])
    end)
    |> Enum.reject(fn pair -> Enum.any?(pair, &(&1 == "")) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_pair, count} -> -count end)
  end

  defp build_whisper_pairs(_), do: []

  # ── Connection Emoji ──────────────────────────────────────────────

  defp connection_emoji("exes"), do: "&#x1F494;"
  defp connection_emoji("siblings"), do: "&#x1F46A;"
  defp connection_emoji("rivals"), do: "&#x2694;"
  defp connection_emoji("old_friends"), do: "&#x1F91D;"
  defp connection_emoji("allies"), do: "&#x1F91D;"
  defp connection_emoji("debt"), do: "&#x1F4B0;"
  defp connection_emoji("mentor_student"), do: "&#x1F4DA;"
  defp connection_emoji("secret_keepers"), do: "&#x1F92B;"
  defp connection_emoji("coworkers"), do: "&#x1F3E2;"
  defp connection_emoji("neighbors"), do: "&#x1F3E0;"
  defp connection_emoji(_), do: "&#x1F517;"
end
