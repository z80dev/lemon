defmodule LemonSimUi.Live.Components.WerewolfBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    players = MapHelpers.get_key(world, :players) || %{}
    phase = MapHelpers.get_key(world, :phase) || "unknown"
    day_number = MapHelpers.get_key(world, :day_number) || 1
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    active_actor = MapHelpers.get_key(world, :active_actor_id)
    votes = MapHelpers.get_key(world, :votes) || %{}
    transcript = MapHelpers.get_key(world, :discussion_transcript) || []
    elimination_log = MapHelpers.get_key(world, :elimination_log) || []
    night_history = MapHelpers.get_key(world, :night_history) || []
    night_actions = MapHelpers.get_key(world, :night_actions) || %{}

    sorted_players = Enum.sort_by(players, fn {id, _p} -> id end)

    alive_players =
      sorted_players |> Enum.filter(fn {_id, p} -> get_val(p, :status, "alive") == "alive" end)

    dead_players =
      sorted_players |> Enum.filter(fn {_id, p} -> get_val(p, :status, "alive") == "dead" end)

    # Build the latest narrative text for the story panel
    latest_night =
      night_history
      |> Enum.filter(fn entry -> get_val(entry, :day, 0) == day_number end)

    # Vote tally for display
    vote_tally =
      votes
      |> Enum.reject(fn {_voter, target} -> target == "skip" end)
      |> Enum.group_by(fn {_voter, target} -> target end)
      |> Enum.into(%{}, fn {target, voters} -> {target, length(voters)} end)

    # Find last completed night summary (previous night's history, shown at day start)
    prev_night_day = day_number - 1
    prev_night_summary =
      if prev_night_day >= 1 do
        night_history
        |> Enum.filter(fn entry -> get_val(entry, :day, 0) == prev_night_day end)
      else
        []
      end

    assigns =
      assigns
      |> assign(:players, players)
      |> assign(:alive_players, alive_players)
      |> assign(:dead_players, dead_players)
      |> assign(:phase, phase)
      |> assign(:day_number, day_number)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:active_actor, active_actor)
      |> assign(:votes, votes)
      |> assign(:vote_tally, vote_tally)
      |> assign(:transcript, transcript)
      |> assign(:elimination_log, elimination_log)
      |> assign(:latest_night, latest_night)
      |> assign(:night_actions, night_actions)
      |> assign(:prev_night_summary, prev_night_summary)

    ~H"""
    <div class="relative font-sans w-full h-full flex flex-col overflow-hidden rounded-xl">
      <style>
        /* Phase backgrounds with generated art */
        .ww-phase-night {
          background: linear-gradient(180deg, rgba(3,7,22,0.97) 0%, rgba(10,16,38,0.93) 100%);
        }
        .ww-phase-day {
          background: linear-gradient(180deg, rgba(45,35,20,0.85) 0%, rgba(25,20,15,0.9) 100%);
        }
        .ww-phase-voting {
          background: linear-gradient(180deg, rgba(50,15,15,0.9) 0%, rgba(25,10,10,0.95) 100%);
        }

        /* Player card animations */
        @keyframes ww-glow-active {
          0%, 100% { box-shadow: 0 0 12px rgba(168, 85, 247, 0.5), 0 0 24px rgba(168, 85, 247, 0.2); }
          50% { box-shadow: 0 0 20px rgba(168, 85, 247, 0.8), 0 0 40px rgba(168, 85, 247, 0.4); }
        }
        .ww-active { animation: ww-glow-active 2s ease-in-out infinite; }

        @keyframes ww-speaking {
          0%, 100% { box-shadow: 0 0 12px rgba(251, 191, 36, 0.5); }
          50% { box-shadow: 0 0 24px rgba(251, 191, 36, 0.8); }
        }
        .ww-speaking { animation: ww-speaking 1.5s ease-in-out infinite; }

        @keyframes ww-moon-float {
          0%, 100% { transform: translateY(0px); }
          50% { transform: translateY(-4px); }
        }
        .ww-moon-float { animation: ww-moon-float 6s ease-in-out infinite; }

        /* Speech bubble */
        .ww-speech {
          position: relative;
          background: rgba(255,255,255,0.07);
          border: 1px solid rgba(255,255,255,0.1);
          border-radius: 12px;
          padding: 10px 14px;
        }
        .ww-speech::before {
          content: '';
          position: absolute;
          left: -8px;
          top: 14px;
          width: 0;
          height: 0;
          border-top: 6px solid transparent;
          border-bottom: 6px solid transparent;
          border-right: 8px solid rgba(255,255,255,0.1);
        }

        /* Narrative scroll */
        .ww-narrative {
          mask-image: linear-gradient(to bottom, transparent 0%, black 5%, black 90%, transparent 100%);
          -webkit-mask-image: linear-gradient(to bottom, transparent 0%, black 5%, black 90%, transparent 100%);
        }

        /* Vote bar animation */
        @keyframes ww-vote-fill {
          from { width: 0%; }
        }
        .ww-vote-bar { animation: ww-vote-fill 0.8s ease-out forwards; }

        /* Victory effects */
        @keyframes ww-victory-glow {
          0%, 100% { text-shadow: 0 0 20px currentColor, 0 0 40px currentColor; }
          50% { text-shadow: 0 0 40px currentColor, 0 0 80px currentColor; }
        }
        .ww-victory-text { animation: ww-victory-glow 2s ease-in-out infinite; }

        @keyframes ww-fade-in {
          from { opacity: 0; transform: translateY(8px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .ww-fade-in { animation: ww-fade-in 0.4s ease-out forwards; opacity: 0; }

        /* Dead card overlay */
        .ww-dead-card::after {
          content: '';
          position: absolute;
          inset: 0;
          background: repeating-linear-gradient(
            -45deg,
            transparent,
            transparent 8px,
            rgba(239, 68, 68, 0.05) 8px,
            rgba(239, 68, 68, 0.05) 16px
          );
          border-radius: inherit;
          pointer-events: none;
        }

        /* ── Night action feed ── */
        @keyframes ww-slide-up {
          from { opacity: 0; transform: translateY(16px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .ww-slide-up { animation: ww-slide-up 0.5s cubic-bezier(0.22,1,0.36,1) forwards; opacity: 0; }

        /* Star twinkle */
        @keyframes ww-twinkle {
          0%, 100% { opacity: 0.3; transform: scale(1); }
          50% { opacity: 1; transform: scale(1.4); }
        }
        .ww-star { animation: ww-twinkle var(--dur, 3s) ease-in-out infinite; animation-delay: var(--delay, 0s); }

        /* Wolf glow */
        @keyframes ww-wolf-hunt {
          0%, 100% { box-shadow: 0 0 10px rgba(239,68,68,0.4), 0 0 30px rgba(239,68,68,0.1); }
          50% { box-shadow: 0 0 20px rgba(239,68,68,0.8), 0 0 50px rgba(239,68,68,0.3); }
        }
        .ww-wolf-hunt { animation: ww-wolf-hunt 2s ease-in-out infinite; }

        /* Seer eye pulse */
        @keyframes ww-seer-pulse {
          0%, 100% { box-shadow: 0 0 10px rgba(168,85,247,0.4), 0 0 30px rgba(168,85,247,0.1); }
          50% { box-shadow: 0 0 20px rgba(168,85,247,0.8), 0 0 50px rgba(168,85,247,0.3); }
        }
        .ww-seer-pulse { animation: ww-seer-pulse 2s ease-in-out infinite; }

        /* Doctor shield */
        @keyframes ww-doctor-shield {
          0%, 100% { box-shadow: 0 0 10px rgba(16,185,129,0.4), 0 0 30px rgba(16,185,129,0.1); }
          50% { box-shadow: 0 0 20px rgba(16,185,129,0.8), 0 0 50px rgba(16,185,129,0.3); }
        }
        .ww-doctor-shield { animation: ww-doctor-shield 2s ease-in-out infinite; }

        /* Dawn reveal card */
        @keyframes ww-dawn-reveal {
          0% { opacity: 0; transform: translateY(20px) scale(0.97); }
          100% { opacity: 1; transform: translateY(0) scale(1); }
        }
        .ww-dawn-reveal { animation: ww-dawn-reveal 0.7s cubic-bezier(0.22,1,0.36,1) forwards; opacity: 0; }

        /* Blood drip effect on kill row */
        @keyframes ww-blood-pulse {
          0%, 100% { border-color: rgba(239,68,68,0.2); background-color: rgba(239,68,68,0.04); }
          50% { border-color: rgba(239,68,68,0.5); background-color: rgba(239,68,68,0.1); }
        }
        .ww-blood-pulse { animation: ww-blood-pulse 2.5s ease-in-out infinite; }

        /* Shield save row */
        @keyframes ww-shield-save {
          0%, 100% { border-color: rgba(16,185,129,0.2); background-color: rgba(16,185,129,0.04); }
          50% { border-color: rgba(16,185,129,0.5); background-color: rgba(16,185,129,0.1); }
        }
        .ww-shield-save { animation: ww-shield-save 2.5s ease-in-out infinite; }

        /* Seer investigation row */
        @keyframes ww-eye-glow {
          0%, 100% { border-color: rgba(168,85,247,0.2); background-color: rgba(168,85,247,0.04); }
          50% { border-color: rgba(168,85,247,0.5); background-color: rgba(168,85,247,0.1); }
        }
        .ww-eye-glow { animation: ww-eye-glow 2.5s ease-in-out infinite; }

        /* Action row hover */
        .ww-action-row:hover { background: rgba(255,255,255,0.05) !important; }

        /* Night stars layer */
        .ww-stars {
          position: absolute;
          inset: 0;
          pointer-events: none;
          overflow: hidden;
        }
      </style>

      <%!-- Background layer with phase art --%>
      <div class="absolute inset-0 z-0">
        <img
          :if={is_night?(@phase)}
          src="/assets/werewolf/night_bg.png"
          class="w-full h-full object-cover opacity-30"
        />
        <img
          :if={!is_night?(@phase) && @game_status != "game_over"}
          src="/assets/werewolf/day_bg.png"
          class="w-full h-full object-cover opacity-25"
        />
        <div class={[
          "absolute inset-0",
          if(is_night?(@phase), do: "ww-phase-night", else: "ww-phase-day"),
          if(@phase == "day_voting", do: "ww-phase-voting")
        ]}></div>
      </div>

      <%!-- Content layer --%>
      <div class="relative z-10 flex flex-col h-full">

        <%!-- Phase Banner --%>
        <div class="flex items-center justify-between px-4 py-3 border-b border-white/5">
          <div class="flex items-center gap-3">
            <%!-- Moon/Sun icon --%>
            <div class="ww-moon-float">
              <img
                :if={is_night?(@phase)}
                src="/assets/werewolf/moon.png"
                class="w-8 h-8 rounded-full drop-shadow-[0_0_8px_rgba(147,197,253,0.6)]"
              />
              <div :if={!is_night?(@phase)} class="w-8 h-8 rounded-full bg-gradient-to-br from-amber-300 to-orange-400 shadow-[0_0_12px_rgba(251,191,36,0.6)]"></div>
            </div>
            <div>
              <div class="text-[10px] font-mono uppercase tracking-[0.2em] text-slate-500 font-bold">
                {phase_label(@phase)}
              </div>
              <div class="text-lg font-black text-white tracking-tight leading-tight">
                Day {@day_number}
              </div>
            </div>
          </div>

          <div class="flex items-center gap-3">
            <%!-- Spectator badge --%>
            <div class="px-2 py-1 rounded text-[9px] font-black uppercase tracking-[0.15em] border border-violet-500/30 bg-violet-950/60 text-violet-400 shadow-[0_0_8px_rgba(139,92,246,0.15)]">
              👁 Spectator
            </div>

            <%!-- Phase badge --%>
            <div class={[
              "px-3 py-1.5 rounded-lg text-[11px] font-black uppercase tracking-wider border",
              phase_badge(@phase)
            ]}>
              {phase_action_label(@phase)}
            </div>
          </div>

          <%!-- Active player indicator --%>
          <div :if={@game_status == "in_progress" && @active_actor} class="flex items-center gap-2">
            <img
              src={avatar_for_role(get_player_role(@players, @active_actor))}
              class={["w-7 h-7 rounded-full border object-cover", role_border(get_player_role(@players, @active_actor))]}
            />
            <div class="text-right">
              <div class="text-[10px] text-slate-500 font-mono uppercase tracking-widest">Acting</div>
              <div class="text-sm font-bold text-white">{player_name(@players, @active_actor)}</div>
              <div class={["text-[9px] font-bold uppercase", role_text_color(get_player_role(@players, @active_actor))]}>
                {get_player_role(@players, @active_actor)}
              </div>
            </div>
          </div>
        </div>

        <%!-- Main layout: Players + Narrative --%>
        <div class="flex-1 flex min-h-0 overflow-hidden">

          <%!-- Left: Player roster --%>
          <div class="w-48 flex-shrink-0 border-r border-white/5 overflow-y-auto custom-scrollbar p-3 space-y-2">
            <%!-- Alive --%>
            <div class="text-[9px] font-mono uppercase tracking-[0.2em] text-emerald-500/80 font-bold mb-2 flex items-center gap-1.5">
              <div class="w-1.5 h-1.5 rounded-full bg-emerald-500 shadow-[0_0_4px_rgba(16,185,129,0.8)]"></div>
              Alive ({length(@alive_players)})
            </div>
            <%= for {player_id, player} <- @alive_players do %>
              <.roster_card
                player_id={player_id}
                player={player}
                active={player_id == @active_actor}
                votes={@votes}
                vote_tally={@vote_tally}
                game_status={@game_status}
                phase={@phase}
                players={@players}
              />
            <% end %>

            <%!-- Dead --%>
            <div :if={length(@dead_players) > 0} class="pt-3 mt-3 border-t border-white/5">
              <div class="text-[9px] font-mono uppercase tracking-[0.2em] text-red-500/60 font-bold mb-2 flex items-center gap-1.5">
                <div class="w-1.5 h-1.5 bg-red-500/60 rotate-45"></div>
                Dead ({length(@dead_players)})
              </div>
              <%= for {player_id, player} <- @dead_players do %>
                <.roster_card
                  player_id={player_id}
                  player={player}
                  active={false}
                  votes={%{}}
                  vote_tally={%{}}
                  game_status={@game_status}
                  phase={@phase}
                  players={@players}
                />
              <% end %>
            </div>
          </div>

          <%!-- Right: Narrative / Story Panel --%>
          <div class="flex-1 flex flex-col min-h-0 overflow-hidden">

            <%!-- Narrative Content --%>
            <div id="ww-narrative" phx-hook="ScrollBottom" class="scroll-bottom flex-1 overflow-y-auto custom-scrollbar p-4 space-y-3 ww-narrative">

              <%!-- Elimination log entries as story beats --%>
              <%= for entry <- @elimination_log do %>
                <.story_beat entry={entry} players={@players} />
              <% end %>

              <%!-- Night action feed (live night phase) --%>
              <div :if={is_night?(@phase) && @game_status == "in_progress"} class="ww-fade-in">
                <.night_scene
                  day_number={@day_number}
                  active_actor={@active_actor}
                  night_actions={@night_actions}
                  players={@players}
                />
              </div>

              <%!-- Dawn reveal: previous night summary shown at day start --%>
              <div :if={!is_night?(@phase) && @game_status != "game_over" && length(@prev_night_summary) > 0}>
                <.dawn_reveal
                  night_summary={@prev_night_summary}
                  day_number={@day_number}
                  players={@players}
                />
              </div>

              <%!-- Discussion transcript as chat --%>
              <div :if={@phase == "day_discussion" || (@phase == "day_voting" && length(@transcript) > 0)}>
                <div class="flex items-center gap-3 py-3">
                  <div class="flex-1 h-px bg-gradient-to-r from-transparent via-amber-500/30 to-transparent"></div>
                  <span class="text-[10px] font-mono uppercase tracking-[0.3em] text-amber-400/60 font-bold">
                    Day {@day_number} Discussion
                  </span>
                  <div class="flex-1 h-px bg-gradient-to-r from-transparent via-amber-500/30 to-transparent"></div>
                </div>

                <%= for {entry, idx} <- Enum.with_index(@transcript) do %>
                  <.chat_message
                    entry={entry}
                    players={@players}
                    game_status={@game_status}
                    index={idx}
                  />
                <% end %>

                <div :if={@phase == "day_discussion" && @active_actor} class="flex items-center gap-2 mt-2 px-2 py-2">
                  <div class="flex items-center gap-2 text-xs text-slate-500 italic">
                    <div class="flex gap-0.5">
                      <div class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-bounce" style="animation-delay: 0ms"></div>
                      <div class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-bounce" style="animation-delay: 150ms"></div>
                      <div class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-bounce" style="animation-delay: 300ms"></div>
                    </div>
                    <span>{player_name(@players, @active_actor)} is thinking...</span>
                  </div>
                </div>
              </div>

              <%!-- Voting display --%>
              <div :if={@phase == "day_voting"}>
                <div class="flex items-center gap-3 py-3">
                  <div class="flex-1 h-px bg-gradient-to-r from-transparent via-rose-500/30 to-transparent"></div>
                  <span class="text-[10px] font-mono uppercase tracking-[0.3em] text-rose-400/60 font-bold">
                    The Vote
                  </span>
                  <div class="flex-1 h-px bg-gradient-to-r from-transparent via-rose-500/30 to-transparent"></div>
                </div>

                <%= for {voter_id, target_id} <- Enum.sort_by(@votes, fn {k, _v} -> k end) do %>
                  <.vote_entry
                    voter_id={voter_id}
                    target_id={target_id}
                    players={@players}
                    game_status={@game_status}
                  />
                <% end %>

                <%!-- Vote tally bars --%>
                <div :if={map_size(@vote_tally) > 0} class="mt-4 space-y-2 p-3 rounded-lg bg-black/20 border border-white/5">
                  <div class="text-[10px] font-mono uppercase tracking-widest text-slate-500 font-bold mb-2">Tally</div>
                  <%= for {target_id, count} <- Enum.sort_by(@vote_tally, fn {_k, v} -> -v end) do %>
                    <div class="flex items-center gap-2">
                      <img src={role_avatar(@players, target_id, @game_status)} class="w-5 h-5 rounded-full object-cover border border-white/10" />
                      <span class="text-xs font-semibold text-slate-300 w-16 truncate">{player_name(@players, target_id)}</span>
                      <div class="flex-1 h-3 rounded-full bg-slate-800/80 overflow-hidden">
                        <div
                          class="h-full rounded-full ww-vote-bar bg-gradient-to-r from-rose-600 to-red-500"
                          style={"width: #{min(count * 100 / max(length(Enum.filter(@alive_players, fn _ -> true end)), 1), 100)}%"}
                        ></div>
                      </div>
                      <span class="text-xs font-black text-rose-400 w-4 text-right">{count}</span>
                    </div>
                  <% end %>
                </div>

                <div :if={@active_actor} class="flex items-center gap-2 mt-3 px-2 py-2">
                  <div class="flex items-center gap-2 text-xs text-slate-500 italic">
                    <div class="flex gap-0.5">
                      <div class="w-1.5 h-1.5 rounded-full bg-rose-400 animate-bounce" style="animation-delay: 0ms"></div>
                      <div class="w-1.5 h-1.5 rounded-full bg-rose-400 animate-bounce" style="animation-delay: 150ms"></div>
                      <div class="w-1.5 h-1.5 rounded-full bg-rose-400 animate-bounce" style="animation-delay: 300ms"></div>
                    </div>
                    <span>{player_name(@players, @active_actor)} is deciding their vote...</span>
                  </div>
                </div>
              </div>

              <%!-- Empty state --%>
              <div :if={@phase == "day_discussion" && length(@transcript) == 0 && @game_status == "in_progress"} class="text-center py-8">
                <p class="text-amber-300/50 text-sm italic">The villagers gather in the square...</p>
              </div>

            </div>
          </div>
        </div>
      </div>

      <%!-- Victory Overlay --%>
      <div
        :if={@game_status == "game_over" && @winner}
        class="absolute inset-0 z-50 flex items-center justify-center overflow-hidden victory-overlay"
      >
        <div class="absolute inset-0 bg-black/80 backdrop-blur-md"></div>
        <div class={[
          "absolute inset-0 opacity-20",
          if(@winner == "villagers",
            do: "bg-[radial-gradient(ellipse_at_center,rgba(16,185,129,0.3)_0%,transparent_70%)]",
            else: "bg-[radial-gradient(ellipse_at_center,rgba(239,68,68,0.3)_0%,transparent_70%)]"
          )
        ]}></div>

        <div class="relative z-10 text-center p-8 space-y-6 max-w-md">
          <%!-- Winner icon --%>
          <img
            src={if @winner == "villagers", do: "/assets/werewolf/villager.png", else: "/assets/werewolf/werewolf.png"}
            class={[
              "w-28 h-28 mx-auto rounded-2xl border-2 shadow-lg object-cover",
              if(@winner == "villagers", do: "border-emerald-500/50 shadow-[0_0_30px_rgba(16,185,129,0.4)]", else: "border-red-500/50 shadow-[0_0_30px_rgba(239,68,68,0.4)]")
            ]}
          />

          <div class={[
            "text-4xl font-black tracking-tight uppercase ww-victory-text",
            if(@winner == "villagers", do: "text-emerald-400", else: "text-red-500")
          ]}>
            {String.upcase(to_string(@winner))} WIN
          </div>

          <p class="text-slate-400 text-sm">
            {if @winner == "villagers", do: "The village is safe. All werewolves have been unmasked.", else: "Darkness falls. The werewolves have consumed the village."}
          </p>

          <div class="flex justify-center gap-6 text-sm">
            <div class="text-center px-5 py-3 rounded-xl bg-white/5 border border-white/10">
              <div class="text-2xl font-black text-white">{@day_number}</div>
              <div class="text-[9px] uppercase tracking-widest text-slate-500 mt-0.5">Days</div>
            </div>
            <div class="text-center px-5 py-3 rounded-xl bg-white/5 border border-white/10">
              <div class="text-2xl font-black text-white">{length(@dead_players)}</div>
              <div class="text-[9px] uppercase tracking-widest text-slate-500 mt-0.5">Casualties</div>
            </div>
            <div class="text-center px-5 py-3 rounded-xl bg-white/5 border border-white/10">
              <div class="text-2xl font-black text-white">{length(@alive_players)}</div>
              <div class="text-[9px] uppercase tracking-widest text-slate-500 mt-0.5">Survivors</div>
            </div>
          </div>

          <%!-- Reveal all roles --%>
          <div class="mt-4 pt-4 border-t border-white/10">
            <div class="text-[9px] font-mono uppercase tracking-[0.2em] text-slate-500 mb-3">Role Reveal</div>
            <div class="flex flex-wrap justify-center gap-2">
              <%= for {player_id, player} <- Enum.sort_by(@players, fn {id, _p} -> id end) do %>
                <div class={[
                  "flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg border text-xs",
                  if(get_val(player, :status, "alive") == "dead",
                    do: "bg-slate-900/60 border-slate-700/50 opacity-60",
                    else: "bg-slate-800/60 border-slate-600/50"
                  )
                ]}>
                  <img src={avatar_for_role(get_val(player, :role, "villager"))} class="w-4 h-4 rounded-full object-cover" />
                  <span class={[
                    "font-semibold",
                    role_text_color(get_val(player, :role, "villager"))
                  ]}>{player_id}</span>
                  <span class="text-slate-500">-</span>
                  <span class={[
                    "font-bold uppercase text-[10px]",
                    role_text_color(get_val(player, :role, "villager"))
                  ]}>{get_val(player, :role, "?")}</span>
                  <span :if={get_val(player, :status, "alive") == "dead"} class="text-red-500/60">&#x2620;</span>
                  <span :if={get_val(player, :model, nil)} class="text-[8px] text-slate-600 font-mono">{short_model_name(get_val(player, :model, ""))}</span>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Night Scene Component ─────────────────────────────────────────

  attr :day_number, :integer, required: true
  attr :active_actor, :string, default: nil
  attr :night_actions, :map, required: true
  attr :players, :map, required: true

  defp night_scene(assigns) do
    # Sort completed actions for display
    completed =
      assigns.night_actions
      |> Enum.sort_by(fn {player_id, _} -> player_id end)
      |> Enum.map(fn {player_id, action} ->
        role = get_player_role(assigns.players, player_id)
        %{player_id: player_id, role: role, action: action}
      end)

    assigns = assign(assigns, :completed, completed)

    ~H"""
    <div class="relative">
      <%!-- Section divider --%>
      <div class="flex items-center gap-3 py-3">
        <div class="flex-1 h-px bg-gradient-to-r from-transparent via-blue-500/20 to-transparent"></div>
        <div class="flex items-center gap-2">
          <img src="/assets/werewolf/moon.png" class="w-5 h-5 rounded-full opacity-70 ww-moon-float drop-shadow-[0_0_8px_rgba(147,197,253,0.5)]" />
          <span class="text-[10px] font-mono uppercase tracking-[0.3em] text-blue-400/70 font-bold">Night {@day_number}</span>
        </div>
        <div class="flex-1 h-px bg-gradient-to-r from-transparent via-blue-500/20 to-transparent"></div>
      </div>

      <%!-- Atmospheric night panel --%>
      <div class="relative rounded-xl overflow-hidden border border-blue-900/30 bg-gradient-to-b from-slate-950/90 to-blue-950/40 mb-3">
        <%!-- Twinkling stars --%>
        <div class="absolute inset-0 pointer-events-none overflow-hidden">
          <div class="ww-star absolute w-0.5 h-0.5 bg-blue-200 rounded-full" style="top:12%;left:8%;--dur:2.3s;--delay:0s"></div>
          <div class="ww-star absolute w-1 h-1 bg-white rounded-full" style="top:22%;left:18%;--dur:3.1s;--delay:0.4s"></div>
          <div class="ww-star absolute w-0.5 h-0.5 bg-blue-100 rounded-full" style="top:8%;left:35%;--dur:2.7s;--delay:0.8s"></div>
          <div class="ww-star absolute w-1 h-1 bg-blue-200 rounded-full" style="top:18%;left:55%;--dur:3.5s;--delay:0.2s"></div>
          <div class="ww-star absolute w-0.5 h-0.5 bg-white rounded-full" style="top:5%;left:72%;--dur:2s;--delay:1.1s"></div>
          <div class="ww-star absolute w-1 h-1 bg-blue-100 rounded-full" style="top:30%;left:85%;--dur:4s;--delay:0.6s"></div>
          <div class="ww-star absolute w-0.5 h-0.5 bg-purple-200 rounded-full" style="top:25%;left:92%;--dur:2.8s;--delay:0.3s"></div>
          <div class="ww-star absolute w-0.5 h-0.5 bg-white rounded-full" style="top:40%;left:42%;--dur:3.2s;--delay:0.9s"></div>
          <div class="ww-star absolute w-1 h-1 bg-blue-200 rounded-full" style="top:15%;left:62%;--dur:2.5s;--delay:1.4s"></div>
          <div class="ww-star absolute w-0.5 h-0.5 bg-purple-100 rounded-full" style="top:35%;left:28%;--dur:3.8s;--delay:0.1s"></div>
        </div>

        <%!-- Moon header --%>
        <div class="flex items-center justify-center gap-4 pt-5 pb-3">
          <img src="/assets/werewolf/moon.png" class="w-14 h-14 rounded-full ww-moon-float drop-shadow-[0_0_24px_rgba(147,197,253,0.5)] opacity-90" />
          <div class="text-center">
            <div :if={@active_actor} class="text-blue-300/80 text-xs font-light italic">
              The night watch continues...
            </div>
            <div :if={!@active_actor} class="text-blue-300/80 text-xs font-light italic">
              Darkness settles over the village
            </div>
          </div>
        </div>

        <%!-- Completed night actions --%>
        <div class="px-3 pb-3 space-y-2">
          <%= for {%{player_id: pid, role: role, action: action}, idx} <- Enum.with_index(@completed) do %>
            <div
              class={["ww-action-row flex items-center gap-3 px-3 py-2.5 rounded-lg border transition-all", night_action_row_class(role)]}
              style={"animation-delay: #{idx * 80}ms"}
            >
              <div class={["w-8 h-8 rounded-lg flex items-center justify-center text-lg flex-shrink-0", night_action_icon_bg(role)]}>
                {night_action_icon(get_val(action, :action, "sleep"))}
              </div>
              <div class="flex-1 min-w-0">
                <div class="flex items-baseline gap-2">
                  <span class={["text-xs font-bold", role_text_color(role)]}>{pid}</span>
                  <span class={["text-[9px] font-bold uppercase tracking-wider opacity-60", role_text_color(role)]}>{role}</span>
                </div>
                <div class="text-xs text-slate-400 mt-0.5">
                  {night_action_description(action, @players)}
                </div>
              </div>
              <div class={["text-base opacity-70", night_action_done_color(role)]}>
                {night_action_status_icon(get_val(action, :action, "sleep"))}
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Currently acting player --%>
        <div :if={@active_actor} class="px-3 pb-4">
          <div class={["flex items-center gap-3 px-3 py-2.5 rounded-lg border", night_active_class(get_player_role(@players, @active_actor))]}>
            <img
              src={avatar_for_role(get_player_role(@players, @active_actor))}
              class={["w-8 h-8 rounded-lg object-cover border",
                role_border(get_player_role(@players, @active_actor)),
                night_active_glow_class(get_player_role(@players, @active_actor))
              ]}
            />
            <div class="flex-1">
              <div class="flex items-baseline gap-2">
                <span class={["text-xs font-bold", role_text_color(get_player_role(@players, @active_actor))]}>{@active_actor}</span>
                <span class={["text-[9px] font-bold uppercase tracking-wider opacity-70", role_text_color(get_player_role(@players, @active_actor))]}>{get_player_role(@players, @active_actor)}</span>
              </div>
              <div class="text-xs text-slate-400/80 mt-0.5">
                {night_thinking_label(get_player_role(@players, @active_actor))}
              </div>
            </div>
            <div class="flex gap-0.5">
              <div class={["w-1.5 h-1.5 rounded-full animate-bounce", night_dot_color(get_player_role(@players, @active_actor))]} style="animation-delay: 0ms"></div>
              <div class={["w-1.5 h-1.5 rounded-full animate-bounce", night_dot_color(get_player_role(@players, @active_actor))]} style="animation-delay: 150ms"></div>
              <div class={["w-1.5 h-1.5 rounded-full animate-bounce", night_dot_color(get_player_role(@players, @active_actor))]} style="animation-delay: 300ms"></div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Dawn Reveal Component ─────────────────────────────────────────

  attr :night_summary, :list, required: true
  attr :day_number, :integer, required: true
  attr :players, :map, required: true

  defp dawn_reveal(assigns) do
    summary = assigns.night_summary

    # Find what happened
    wolf_actions = Enum.filter(summary, fn e -> get_val(e, :action, "") == "choose_victim" end)
    doctor_action = Enum.find(summary, fn e -> get_val(e, :action, "") == "protect" end)
    seer_action = Enum.find(summary, fn e -> get_val(e, :action, "") == "investigate" end)
    kill_action = Enum.find(wolf_actions, fn e -> get_val(e, :successful, false) end)
    saved_action = Enum.find(wolf_actions, fn e -> get_val(e, :saved, false) end)

    assigns =
      assigns
      |> assign(:wolf_actions, wolf_actions)
      |> assign(:doctor_action, doctor_action)
      |> assign(:seer_action, seer_action)
      |> assign(:kill_action, kill_action)
      |> assign(:saved_action, saved_action)
      |> assign(:prev_day, assigns.day_number - 1)

    ~H"""
    <div class="mb-4">
      <%!-- Dawn divider --%>
      <div class="flex items-center gap-3 py-3">
        <div class="flex-1 h-px bg-gradient-to-r from-transparent via-amber-500/20 to-transparent"></div>
        <div class="flex items-center gap-2">
          <span class="text-amber-300" style="font-size:12px">☀️</span>
          <span class="text-[10px] font-mono uppercase tracking-[0.3em] text-amber-400/70 font-bold">Dawn of Day {@day_number}</span>
        </div>
        <div class="flex-1 h-px bg-gradient-to-r from-transparent via-amber-500/20 to-transparent"></div>
      </div>

      <%!-- Night recap card --%>
      <div class="ww-dawn-reveal rounded-xl overflow-hidden border border-slate-700/40 bg-gradient-to-b from-slate-900/80 to-slate-950/90">
        <%!-- Card header --%>
        <div class="flex items-center gap-3 px-4 py-3 border-b border-white/5">
          <img src="/assets/werewolf/moon.png" class="w-7 h-7 rounded-full opacity-60" />
          <div>
            <div class="text-[10px] font-mono uppercase tracking-widest text-slate-500 font-bold">Night {@prev_day} — What happened in the dark</div>
          </div>
        </div>

        <div class="p-3 space-y-2">
          <%!-- Kill: someone died --%>
          <div :if={@kill_action} class="ww-blood-pulse flex items-center gap-3 px-3 py-3 rounded-lg border ww-slide-up" style="animation-delay: 100ms">
            <div class="w-10 h-10 rounded-lg bg-red-950/60 border border-red-500/30 flex items-center justify-center text-xl flex-shrink-0">
              🐺
            </div>
            <div class="flex-1">
              <div class="text-sm font-bold text-red-400">
                {get_val(@kill_action, :target, "someone")} was killed
              </div>
              <div class="text-xs text-slate-500 mt-0.5">
                The werewolves struck in the night.
                <span class={["font-semibold", role_text_color(get_val(@kill_action, :target_role, "villager"))]}>
                  ({get_val(@kill_action, :target_role, "?")})
                </span>
              </div>
            </div>
            <div class="text-2xl opacity-60">☠️</div>
          </div>

          <%!-- No kill (peaceful night) --%>
          <div :if={!@kill_action && !@saved_action && length(@wolf_actions) > 0}
            class="flex items-center gap-3 px-3 py-3 rounded-lg border border-slate-700/30 bg-slate-800/20 ww-slide-up" style="animation-delay: 100ms">
            <div class="w-10 h-10 rounded-lg bg-slate-800/60 border border-slate-700/30 flex items-center justify-center text-xl flex-shrink-0">🌙</div>
            <div class="flex-1">
              <div class="text-sm font-bold text-slate-300">A quiet night</div>
              <div class="text-xs text-slate-500 mt-0.5">No one was killed overnight.</div>
            </div>
            <div class="text-2xl opacity-40">😮‍💨</div>
          </div>

          <%!-- Doctor save --%>
          <div :if={@saved_action} class="ww-shield-save flex items-center gap-3 px-3 py-3 rounded-lg border ww-slide-up" style="animation-delay: 200ms">
            <div class="w-10 h-10 rounded-lg bg-emerald-950/60 border border-emerald-500/30 flex items-center justify-center text-xl flex-shrink-0">
              🛡️
            </div>
            <div class="flex-1">
              <div class="text-sm font-bold text-emerald-400">
                {get_val(@saved_action, :target, "someone")} was saved!
              </div>
              <div class="text-xs text-slate-500 mt-0.5">
                The doctor's protection held. The wolves were foiled.
              </div>
            </div>
            <div class="text-2xl">✨</div>
          </div>

          <%!-- Seer investigation (spectator reveal) --%>
          <div :if={@seer_action} class="ww-eye-glow flex items-center gap-3 px-3 py-3 rounded-lg border ww-slide-up" style="animation-delay: 300ms">
            <img src="/assets/werewolf/seer.png" class="w-10 h-10 rounded-lg object-cover border border-purple-500/40 flex-shrink-0" />
            <div class="flex-1">
              <div class="text-sm font-bold text-purple-400">
                Seer: {get_val(@seer_action, :player, "seer")} investigated
              </div>
              <div class="text-xs text-slate-400 mt-0.5">
                🔮 <span class="text-slate-300 font-semibold">{get_val(@seer_action, :target, "?")}</span>
                is a
                <span class={["font-bold uppercase", role_text_color(get_val(@seer_action, :result, get_val(@seer_action, :target_role, "?")))]}>
                  {get_val(@seer_action, :result, get_val(@seer_action, :target_role, "?"))}
                </span>
              </div>
            </div>
            <div class={["text-base font-black", role_text_color(get_val(@seer_action, :result, "?"))]}>
              {if get_val(@seer_action, :result, "") == "werewolf" || get_val(@seer_action, :target_role, "") == "werewolf", do: "🚨", else: "✅"}
            </div>
          </div>

          <%!-- Werewolf coordination (spectator mode reveals all) --%>
          <div :if={length(@wolf_actions) > 0} class="ww-slide-up" style="animation-delay: 400ms">
            <div class="text-[9px] font-mono uppercase tracking-widest text-slate-600 font-bold pl-1 mb-1.5">🐺 Wolf pack moves</div>
            <%= for wolf <- @wolf_actions do %>
              <div class="flex items-center gap-2 px-3 py-2 rounded-md bg-red-950/10 border border-red-900/10 mb-1">
                <img src="/assets/werewolf/werewolf.png" class="w-5 h-5 rounded-md object-cover opacity-70" />
                <span class="text-xs text-red-400/80 font-semibold">{get_val(wolf, :player, "?")}</span>
                <span class="text-slate-600 text-xs">targeted</span>
                <span class="text-xs font-bold text-red-300">{get_val(wolf, :target, "?")}</span>
                <span :if={get_val(wolf, :successful, false)} class="ml-auto text-[10px] text-red-500 font-bold uppercase">✓ success</span>
                <span :if={get_val(wolf, :saved, false)} class="ml-auto text-[10px] text-emerald-500 font-bold uppercase">✗ blocked</span>
              </div>
            <% end %>
          </div>

          <%!-- Doctor action (spectator mode) --%>
          <div :if={@doctor_action} class="ww-slide-up" style="animation-delay: 450ms">
            <div class="flex items-center gap-2 px-3 py-2 rounded-md bg-emerald-950/10 border border-emerald-900/10">
              <img src="/assets/werewolf/doctor.png" class="w-5 h-5 rounded-md object-cover opacity-70" />
              <span class="text-xs text-emerald-400/80 font-semibold">{get_val(@doctor_action, :player, "doctor")}</span>
              <span class="text-slate-600 text-xs">protected</span>
              <span class="text-xs font-bold text-emerald-300">{get_val(@doctor_action, :target, "?")}</span>
              <span :if={get_val(@doctor_action, :successful, false)} class="ml-auto text-[10px] text-emerald-500 font-bold uppercase">🛡 saved</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Roster Card Component ──────────────────────────────────────────

  attr :player_id, :string, required: true
  attr :player, :map, required: true
  attr :active, :boolean, default: false
  attr :votes, :map, required: true
  attr :vote_tally, :map, required: true
  attr :game_status, :string, required: true
  attr :phase, :string, required: true
  attr :players, :map, required: true

  defp roster_card(assigns) do
    player = assigns.player
    is_dead = get_val(player, :status, "alive") == "dead"
    role = get_val(player, :role, "unknown")
    name = assigns.player_id

    # Always show roles — this is a spectator/observer view
    show_role = true
    display_role = role

    vote_count =
      Enum.count(assigns.votes, fn {_voter, target} -> target == assigns.player_id end)

    assigns =
      assigns
      |> assign(:is_dead, is_dead)
      |> assign(:role, role)
      |> assign(:name, name)
      |> assign(:show_role, show_role)
      |> assign(:display_role, display_role)
      |> assign(:vote_count, vote_count)

    ~H"""
    <div class={[
      "flex items-center gap-2.5 p-2 rounded-lg border transition-all duration-300 relative group/card",
      if(@is_dead,
        do: "bg-black/20 border-white/3 opacity-50 ww-dead-card",
        else: "bg-white/3 border-white/5 hover:bg-white/5 hover:border-white/10"
      ),
      if(@active && !@is_dead, do: "ww-active border-purple-500/40 bg-purple-900/10"),
      if(@active && @phase == "day_discussion" && !@is_dead, do: "ww-speaking border-amber-500/40 bg-amber-900/10")
    ]}>
      <%!-- Avatar (always role-based in observer mode) --%>
      <div class="relative flex-shrink-0">
        <img
          src={avatar_for_role(@role)}
          class={[
            "w-9 h-9 rounded-lg object-cover border",
            if(@is_dead, do: "grayscale border-slate-700/50", else: role_border(@role))
          ]}
        />
        <div :if={@is_dead} class="absolute inset-0 flex items-center justify-center">
          <span class="text-base drop-shadow-lg">&#x2620;</span>
        </div>
        <%!-- Vote count badge --%>
        <div :if={@vote_count > 0 && !@is_dead} class="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-red-500 flex items-center justify-center text-[9px] font-black text-white shadow-[0_0_6px_rgba(239,68,68,0.6)] animate-pulse">
          {@vote_count}
        </div>
      </div>

      <%!-- Info --%>
      <div class="min-w-0 flex-1">
        <div class={[
          "text-xs font-bold truncate",
          if(@is_dead, do: "text-slate-500 line-through", else: "text-slate-200")
        ]}>
          {@name}
        </div>
        <div class={[
          "text-[9px] font-bold uppercase tracking-wider",
          role_text_color(@role)
        ]}>
          {@display_role}
        </div>
        <div :if={get_val(@player, :model, nil)} class="text-[8px] text-slate-600 truncate mt-0.5 font-mono" title={get_val(@player, :model, "")}>
          {short_model_name(get_val(@player, :model, ""))}
        </div>
      </div>

      <%!-- Active indicator --%>
      <div :if={@active && !@is_dead} class="w-1.5 h-1.5 rounded-full bg-purple-400 animate-pulse shadow-[0_0_6px_rgba(168,85,247,0.8)] flex-shrink-0"></div>
    </div>
    """
  end

  # ── Chat Message Component ──────────────────────────────────────────

  attr :entry, :map, required: true
  attr :players, :map, required: true
  attr :game_status, :string, required: true
  attr :index, :integer, required: true

  defp chat_message(assigns) do
    player_id = get_val(assigns.entry, :player, "unknown")
    statement = get_val(assigns.entry, :statement, "")
    role = get_player_role(assigns.players, player_id)

    assigns =
      assigns
      |> assign(:player_id, player_id)
      |> assign(:statement, statement)
      |> assign(:role, role)

    ~H"""
    <div class="flex gap-3 items-start ww-fade-in" style={"animation-delay: #{@index * 50}ms"}>
      <%!-- Always show role avatar (observer mode) --%>
      <img
        src={avatar_for_role(@role)}
        class={["w-8 h-8 rounded-lg object-cover border flex-shrink-0 mt-0.5", role_border(@role)]}
      />
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-2 mb-1">
          <span class={["text-xs font-bold", role_text_color(@role)]}>{player_name(@players, @player_id)}</span>
          <span class={["text-[9px] font-bold uppercase opacity-70", role_text_color(@role)]}>
            {String.upcase(@role)}
          </span>
        </div>
        <div class="ww-speech">
          <p class="text-sm text-slate-300 leading-relaxed">{@statement}</p>
        </div>
      </div>
    </div>
    """
  end

  # ── Vote Entry Component ──────────────────────────────────────────

  attr :voter_id, :string, required: true
  attr :target_id, :string, required: true
  attr :players, :map, required: true
  attr :game_status, :string, required: true

  defp vote_entry(assigns) do
    ~H"""
    <div class="flex items-center gap-2 py-1.5 px-2 rounded-md bg-white/3 border border-white/5 ww-fade-in">
      <img src={role_avatar(@players, @voter_id, @game_status)} class="w-5 h-5 rounded object-cover border border-white/10" />
      <span class="text-xs font-semibold text-slate-300">{player_name(@players, @voter_id)}</span>
      <span class="text-slate-600 text-xs">&#x2192;</span>
      <span :if={@target_id == "skip"} class="text-xs text-slate-500 italic">skip</span>
      <span :if={@target_id != "skip"} class="text-xs font-bold text-rose-400">{player_name(@players, @target_id)}</span>
    </div>
    """
  end

  # ── Story Beat Component ──────────────────────────────────────────

  attr :entry, :map, required: true
  attr :players, :map, required: true

  defp story_beat(assigns) do
    entry = assigns.entry
    player_id = get_val(entry, :player, "unknown")
    role = get_val(entry, :role, "unknown")
    reason = get_val(entry, :reason, "eliminated")
    day = get_val(entry, :day, 0)

    assigns =
      assigns
      |> assign(:player_id, player_id)
      |> assign(:role, role)
      |> assign(:reason, reason)
      |> assign(:day, day)

    ~H"""
    <div class="flex items-center gap-3 py-2 px-3 rounded-lg bg-red-950/20 border border-red-900/20 ww-fade-in">
      <img src={avatar_for_role(@role)} class="w-7 h-7 rounded-lg object-cover grayscale opacity-60 border border-red-900/30" />
      <div class="flex-1">
        <span class="text-xs text-red-400 font-bold">{player_name(@players, @player_id)}</span>
        <span class="text-xs text-slate-500">
          (<span class={role_text_color(@role)}>{@role}</span>)
          was
          <span class="text-red-400/80">{format_reason(@reason)}</span>
          on Day {@day}
        </span>
      </div>
      <span class="text-base opacity-40">&#x2620;</span>
    </div>
    """
  end

  # ── Night Scene Helpers ────────────────────────────────────────────

  defp night_action_icon("choose_victim"), do: "🐺"
  defp night_action_icon("investigate"), do: "🔮"
  defp night_action_icon("protect"), do: "💉"
  defp night_action_icon("sleep"), do: "😴"
  defp night_action_icon(_), do: "🌙"

  defp night_action_status_icon("choose_victim"), do: "🎯"
  defp night_action_status_icon("investigate"), do: "👁️"
  defp night_action_status_icon("protect"), do: "🛡️"
  defp night_action_status_icon("sleep"), do: "💤"
  defp night_action_status_icon(_), do: "✓"

  defp night_action_row_class("werewolf"),
    do: "border-red-900/30 bg-red-950/10 ww-slide-up"

  defp night_action_row_class("seer"),
    do: "border-purple-900/30 bg-purple-950/10 ww-slide-up"

  defp night_action_row_class("doctor"),
    do: "border-emerald-900/30 bg-emerald-950/10 ww-slide-up"

  defp night_action_row_class(_),
    do: "border-slate-800/30 bg-slate-900/20 ww-slide-up"

  defp night_action_icon_bg("werewolf"), do: "bg-red-950/60 border border-red-800/30"
  defp night_action_icon_bg("seer"), do: "bg-purple-950/60 border border-purple-800/30"
  defp night_action_icon_bg("doctor"), do: "bg-emerald-950/60 border border-emerald-800/30"
  defp night_action_icon_bg(_), do: "bg-slate-800/60 border border-slate-700/30"

  defp night_action_done_color("werewolf"), do: "text-red-400"
  defp night_action_done_color("seer"), do: "text-purple-400"
  defp night_action_done_color("doctor"), do: "text-emerald-400"
  defp night_action_done_color(_), do: "text-slate-500"

  defp night_active_class("werewolf"),
    do: "ww-wolf-hunt border-red-700/40 bg-red-950/20"

  defp night_active_class("seer"),
    do: "ww-seer-pulse border-purple-700/40 bg-purple-950/20"

  defp night_active_class("doctor"),
    do: "ww-doctor-shield border-emerald-700/40 bg-emerald-950/20"

  defp night_active_class(_),
    do: "border-slate-700/30 bg-slate-900/20"

  defp night_active_glow_class("werewolf"), do: "shadow-[0_0_12px_rgba(239,68,68,0.4)]"
  defp night_active_glow_class("seer"), do: "shadow-[0_0_12px_rgba(168,85,247,0.4)]"
  defp night_active_glow_class("doctor"), do: "shadow-[0_0_12px_rgba(16,185,129,0.4)]"
  defp night_active_glow_class(_), do: ""

  defp night_dot_color("werewolf"), do: "bg-red-400"
  defp night_dot_color("seer"), do: "bg-purple-400"
  defp night_dot_color("doctor"), do: "bg-emerald-400"
  defp night_dot_color(_), do: "bg-blue-400"

  defp night_thinking_label("werewolf"), do: "Choosing prey..."
  defp night_thinking_label("seer"), do: "Reaching into the shadows..."
  defp night_thinking_label("doctor"), do: "Deciding who to protect..."
  defp night_thinking_label("villager"), do: "Sleeping peacefully..."
  defp night_thinking_label(_), do: "Waiting in the dark..."

  defp night_action_description(action, players) do
    case get_val(action, :action, "sleep") do
      "choose_victim" ->
        target = get_val(action, :target, nil)
        if target, do: "Targeting #{player_name(players, target)} 🩸", else: "Selecting a victim..."

      "investigate" ->
        target = get_val(action, :target, nil)
        result = get_val(action, :result, nil)
        cond do
          target && result -> "Investigated #{player_name(players, target)} → #{result}"
          target -> "Investigating #{player_name(players, target)}..."
          true -> "Peering into the unknown..."
        end

      "protect" ->
        target = get_val(action, :target, nil)
        if target, do: "Protecting #{player_name(players, target)} 💉", else: "Choosing who to protect..."

      "sleep" ->
        "Sleeping soundly 💤"

      _ ->
        "Taking action..."
    end
  end

  # ── Helpers ───────────────────────────────────────────

  defp get_val(map, key, default) when is_map(map) do
    MapHelpers.get_key(map, key) || default
  end

  defp get_val(_, _, default), do: default

  defp is_night?("night"), do: true
  defp is_night?(_), do: false

  defp phase_label("night"), do: "Nightfall"
  defp phase_label("day_discussion"), do: "Town Square"
  defp phase_label("day_voting"), do: "Judgment"
  defp phase_label("game_over"), do: "Game Over"
  defp phase_label(_), do: "Unknown"

  defp phase_action_label("night"), do: "The wolves hunt"
  defp phase_action_label("day_discussion"), do: "Discussion"
  defp phase_action_label("day_voting"), do: "Vote to eliminate"
  defp phase_action_label("game_over"), do: "Finished"
  defp phase_action_label(_), do: ""

  defp phase_badge("night"),
    do: "bg-blue-950/80 text-blue-300 border-blue-500/30 shadow-[0_0_8px_rgba(59,130,246,0.15)]"

  defp phase_badge("day_discussion"),
    do:
      "bg-amber-950/80 text-amber-300 border-amber-500/30 shadow-[0_0_8px_rgba(245,158,11,0.15)]"

  defp phase_badge("day_voting"),
    do: "bg-rose-950/80 text-rose-300 border-rose-500/30 shadow-[0_0_8px_rgba(225,29,72,0.15)]"

  defp phase_badge(_), do: "bg-slate-800 text-slate-400 border-slate-600"

  defp avatar_for_role("werewolf"), do: "/assets/werewolf/werewolf.png"
  defp avatar_for_role("seer"), do: "/assets/werewolf/seer.png"
  defp avatar_for_role("doctor"), do: "/assets/werewolf/doctor.png"
  defp avatar_for_role(_), do: "/assets/werewolf/villager.png"

  defp role_avatar(players, player_id, _game_status) do
    # Observer mode: always show the real role avatar
    player = Map.get(players, player_id, %{})
    role = get_val(player, :role, "villager")
    avatar_for_role(role)
  end

  defp role_text_color("werewolf"), do: "text-red-400"
  defp role_text_color("seer"), do: "text-purple-400"
  defp role_text_color("doctor"), do: "text-emerald-400"
  defp role_text_color("villager"), do: "text-amber-300"
  defp role_text_color(_), do: "text-slate-500"

  defp role_border("werewolf"), do: "border-red-500/50"
  defp role_border("seer"), do: "border-purple-500/50"
  defp role_border("doctor"), do: "border-emerald-500/50"
  defp role_border(_), do: "border-white/10"

  defp player_name(_players, player_id), do: player_id

  defp get_player_role(players, player_id) do
    player = Map.get(players, player_id, %{})
    get_val(player, :role, "unknown")
  end

  defp format_reason("killed"), do: "killed by werewolves"
  defp format_reason("voted"), do: "voted out"
  defp format_reason(reason), do: to_string(reason)

  defp short_model_name(full_name) when is_binary(full_name) do
    # "google_gemini_cli/gemini-3-flash-preview" -> "gemini-3-flash"
    full_name
    |> String.split("/")
    |> List.last()
    |> String.replace("-preview", "")
    |> String.replace("claude-", "")
    |> String.replace("-20250514", "")
    |> String.replace("-20251001", "")
    |> String.replace("gpt-", "gpt")
  end

  defp short_model_name(_), do: ""
end
