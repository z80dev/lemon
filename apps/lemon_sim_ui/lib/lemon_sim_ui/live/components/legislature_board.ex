defmodule LemonSimUi.Live.Components.LegislatureBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    bills = MapHelpers.get_key(world, :bills) || %{}
    players = MapHelpers.get_key(world, :players) || %{}
    phase = MapHelpers.get_key(world, :phase) || "caucus"
    session = MapHelpers.get_key(world, :session) || 1
    max_sessions = MapHelpers.get_key(world, :max_sessions) || 3
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || []
    caucus_messages = MapHelpers.get_key(world, :caucus_messages) || %{}
    message_history = MapHelpers.get_key(world, :message_history) || []
    floor_statements = MapHelpers.get_key(world, :floor_statements) || []
    proposed_amendments = MapHelpers.get_key(world, :proposed_amendments) || []
    vote_record = MapHelpers.get_key(world, :vote_record) || %{}
    votes_cast = MapHelpers.get_key(world, :votes_cast) || MapSet.new()
    scores = MapHelpers.get_key(world, :scores) || %{}
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)

    bill_order = ["infrastructure", "healthcare", "defense", "education", "environment"]

    # Build sorted player list by score
    sorted_players =
      players
      |> Enum.map(fn {pid, pdata} ->
        pid_str = to_string(pid)
        score = Map.get(scores, pid, Map.get(scores, pid_str, 0))
        capital = get_val(pdata, :political_capital, 0)
        {pid_str, pdata, score, capital}
      end)
      |> Enum.sort_by(fn {_, _, score, _} -> score end, :desc)

    # Active player faction info
    active_player_data =
      if active_actor_id do
        pid_str = to_string(active_actor_id)
        Map.get(players, active_actor_id) || Map.get(players, pid_str, %{})
      else
        %{}
      end

    active_faction = get_val(active_player_data, :faction, "Unknown")

    # Recent messages (last 8)
    recent_messages =
      message_history
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    # Current session floor statements
    session_statements =
      floor_statements
      |> Enum.filter(fn s ->
        Map.get(s, "session", Map.get(s, :session, 1)) == session
      end)
      |> Enum.reverse()
      |> Enum.take(5)
      |> Enum.reverse()

    # Votes submitted count
    votes_cast_count =
      cond do
        is_struct(votes_cast, MapSet) -> MapSet.size(votes_cast)
        is_list(votes_cast) -> length(votes_cast)
        true -> 0
      end

    total_players = map_size(players)

    assigns =
      assigns
      |> assign(:bills, bills)
      |> assign(:players, players)
      |> assign(:phase, phase)
      |> assign(:session, session)
      |> assign(:max_sessions, max_sessions)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:active_faction, active_faction)
      |> assign(:turn_order, turn_order)
      |> assign(:caucus_messages, caucus_messages)
      |> assign(:message_history, message_history)
      |> assign(:recent_messages, recent_messages)
      |> assign(:floor_statements, floor_statements)
      |> assign(:session_statements, session_statements)
      |> assign(:proposed_amendments, proposed_amendments)
      |> assign(:vote_record, vote_record)
      |> assign(:votes_cast, votes_cast)
      |> assign(:votes_cast_count, votes_cast_count)
      |> assign(:total_players, total_players)
      |> assign(:scores, scores)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:sorted_players, sorted_players)
      |> assign(:bill_order, bill_order)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0a0d1a; color: #e2e8f0; min-height: 640px;">
      <style>
        /* ── Bill pulse ── */
        @keyframes leg-bill-pulse {
          0%, 100% { filter: brightness(1); }
          50% { filter: brightness(1.12); }
        }
        .leg-bill-active { animation: leg-bill-pulse 2.5s ease-in-out infinite; }

        /* ── Session glow ── */
        @keyframes leg-session-glow {
          0%, 100% { box-shadow: 0 0 8px 2px rgba(245, 158, 11, 0.2); }
          50% { box-shadow: 0 0 20px 6px rgba(245, 158, 11, 0.5); }
        }
        .leg-session-active { animation: leg-session-glow 2s ease-in-out infinite; }

        /* ── Scanline ── */
        @keyframes leg-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .leg-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(245, 158, 11, 0.12), transparent);
          animation: leg-scanline 4s linear infinite;
          pointer-events: none;
        }

        /* ── Phase Breathe ── */
        @keyframes leg-phase-breathe {
          0%, 100% { opacity: 0.6; }
          50% { opacity: 1; }
        }
        .leg-phase-active { animation: leg-phase-breathe 2s ease-in-out infinite; }

        /* ── Vote flash ── */
        @keyframes leg-vote-flash {
          0% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.7); }
          50% { box-shadow: 0 0 24px 8px rgba(34, 197, 94, 0.3); }
          100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0); }
        }
        .leg-passed { animation: leg-vote-flash 2s ease-out; }

        /* ── Victory ── */
        @keyframes leg-victory-enter {
          from { opacity: 0; transform: scale(0.8) translateY(20px); }
          to { opacity: 1; transform: scale(1) translateY(0); }
        }
        .leg-victory { animation: leg-victory-enter 0.8s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

        /* ── Neon text ── */
        .leg-neon-amber { text-shadow: 0 0 8px rgba(245, 158, 11, 0.5); }
        .leg-neon-green { text-shadow: 0 0 8px rgba(34, 197, 94, 0.5); }
        .leg-neon-red { text-shadow: 0 0 8px rgba(239, 68, 68, 0.5); }
        .leg-neon-blue { text-shadow: 0 0 8px rgba(59, 130, 246, 0.5); }
      </style>

      <%!-- ═══════════════ STATUS BAR ═══════════════ --%>
      <div class="relative overflow-hidden" style="background: linear-gradient(90deg, rgba(245, 158, 11, 0.08), rgba(15, 23, 42, 0.9), rgba(139, 92, 246, 0.08)); border-bottom: 1px solid rgba(245, 158, 11, 0.15);">
        <div class="leg-scanline relative px-4 py-2.5 flex items-center justify-between">
          <%!-- Left: Game Identity --%>
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 rounded-full bg-amber-400 leg-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.25em] uppercase text-amber-400/70">LEGISLATURE</span>
            </div>
            <div class="h-4 w-px bg-amber-900/30"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-mono text-gray-500">SESSION</span>
              <span class="text-sm font-black text-white tabular-nums">{@session}</span>
              <span class="text-[10px] text-gray-600">/ {@max_sessions}</span>
            </div>
          </div>

          <%!-- Center: Phase Badge --%>
          <div class="flex items-center gap-2">
            <div class={[
              "px-3 py-1 rounded-full border text-[10px] font-bold tracking-wider uppercase",
              phase_badge_class(@phase)
            ]}>
              {phase_label(@phase)}
            </div>
            <div :if={@phase == "final_vote"} class="text-[10px] text-gray-500 tabular-nums">
              {@votes_cast_count}/{@total_players} voted
            </div>
          </div>

          <%!-- Right: Active Player --%>
          <div class="flex items-center gap-3">
            <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full leg-phase-active" style={"background: #{faction_color(to_string(@active_actor_id))};"}></div>
              <span class="text-[10px] font-bold" style={"color: #{faction_color(to_string(@active_actor_id))}"}>
                {@active_faction}
              </span>
            </div>
            <div :if={@game_status == "won"} class="flex items-center gap-1.5">
              <span class="text-[10px] font-bold text-amber-400 leg-neon-amber">GAME OVER</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ MAIN CONTENT ═══════════════ --%>
      <div class="flex" style="min-height: 580px;">

        <%!-- ──── LEFT: BILLS PANEL ──── --%>
        <div class="w-72 flex-shrink-0 p-4 overflow-y-auto border-r" style="border-color: rgba(245, 158, 11, 0.1);">

          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">BILLS ON FLOOR</span>
            <div class="flex-1 h-px bg-gradient-to-r from-amber-900/30 to-transparent"></div>
          </div>

          <div class="space-y-2">
            <%= for bill_id <- @bill_order do %>
              <% bill = Map.get(@bills, bill_id, Map.get(@bills, to_string(bill_id), %{})) %>
              <% bill_status = get_val(bill, :status, "pending") %>
              <% bill_color = bill_color(bill_id) %>
              <% amendments = get_val(bill, :amendments, []) %>
              <% lobby = get_val(bill, :lobby_support, %{}) |> Map.values() |> Enum.sum() %>
              <div
                class={["rounded-lg p-2.5 transition-all duration-300", if(bill_status == "pending", do: "leg-bill-active", else: "")]}
                style={"background: #{bill_bg(bill_color, bill_status)}; border: 1px solid #{bill_color}#{if bill_status == "pending", do: "30", else: "60"};"}
              >
                <div class="flex items-center justify-between mb-1">
                  <span class="text-[11px] font-bold capitalize" style={"color: #{bill_color}"}>{bill_id}</span>
                  <span class={["text-[9px] font-black tracking-wider uppercase px-1.5 py-0.5 rounded", bill_status_class(bill_status)]}>
                    {String.upcase(bill_status)}
                  </span>
                </div>
                <% title = get_val(bill, :title, bill_id) %>
                <div class="text-[9px] text-gray-500 mb-1.5 leading-tight">
                  {String.slice(title, 0, 40)}{if String.length(title) > 40, do: "...", else: ""}
                </div>
                <div class="flex items-center gap-2 text-[9px] text-gray-600">
                  <span :if={length(amendments) > 0} class="text-purple-400">{length(amendments)} amd</span>
                  <span :if={lobby > 0} class="text-amber-500">{lobby} lobby</span>
                  <span :if={length(amendments) == 0 && lobby == 0} class="text-gray-700">no amendments</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- ──── CENTER: PHASE CONTENT ──── --%>
        <div class="flex-1 p-4 overflow-y-auto">

          <%!-- Victory card --%>
          <div :if={@game_status == "won"} class="leg-victory mb-4">
            <div class="rounded-xl p-6 text-center" style="background: linear-gradient(135deg, rgba(245, 158, 11, 0.12), rgba(15, 23, 42, 0.95)); border: 2px solid rgba(245, 158, 11, 0.4);">
              <div class="text-2xl font-black text-amber-400 leg-neon-amber mb-2">SESSION ENDS</div>
              <% winner_data = Map.get(@players, @winner) || Map.get(@players, to_string(@winner), %{}) %>
              <% winner_faction = get_val(winner_data, :faction, to_string(@winner)) %>
              <div class="text-lg text-white font-bold mb-1">{winner_faction}</div>
              <div class="text-sm text-gray-400">wins the legislature with highest score!</div>
            </div>
          </div>

          <%!-- Caucus panel --%>
          <div :if={@phase == "caucus"}>
            <div class="flex items-center gap-2 mb-3">
              <div class="w-1.5 h-1.5 rounded-full bg-blue-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-blue-400/50">CAUCUS ROOM</span>
              <div class="flex-1 h-px bg-gradient-to-r from-blue-900/30 to-transparent"></div>
            </div>
            <div class="rounded-xl p-3 mb-3" style="background: rgba(15, 23, 42, 0.6); border: 1px solid rgba(59, 130, 246, 0.15);">
              <%= if @recent_messages == [] do %>
                <div class="text-center text-[11px] text-gray-600 py-4">No private messages exchanged yet</div>
              <% else %>
                <div class="space-y-1.5">
                  <%= for msg <- @recent_messages do %>
                    <% from_id = Map.get(msg, "from", Map.get(msg, :from, "?")) %>
                    <% to_id = Map.get(msg, "to", Map.get(msg, :to, "?")) %>
                    <% sess = Map.get(msg, "session", Map.get(msg, :session, "?")) %>
                    <% msg_type = Map.get(msg, "type", Map.get(msg, :type, "message")) %>
                    <% from_faction = get_faction_name(to_string(from_id), @players) %>
                    <% to_faction = get_faction_name(to_string(to_id), @players) %>
                    <div class="flex items-center gap-2 py-1 px-2 rounded" style="background: rgba(15, 23, 42, 0.4);">
                      <div class="w-1.5 h-1.5 rounded-full flex-shrink-0" style={"background: #{faction_color(to_string(from_id))}"}></div>
                      <span class="text-[10px] font-semibold flex-shrink-0" style={"color: #{faction_color(to_string(from_id))}"}>
                        {short_faction(from_faction)}
                      </span>
                      <span class="text-[9px] text-gray-600">{if msg_type == "trade", do: "⇄", else: "→"}</span>
                      <span class="text-[10px] font-semibold flex-shrink-0" style={"color: #{faction_color(to_string(to_id))}"}>
                        {short_faction(to_faction)}
                      </span>
                      <span class="text-[9px] text-gray-700 ml-auto">S{sess}</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Floor debate panel --%>
          <div :if={@phase == "floor_debate"}>
            <div class="flex items-center gap-2 mb-3">
              <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">FLOOR DEBATE</span>
              <div class="flex-1 h-px bg-gradient-to-r from-amber-900/30 to-transparent"></div>
            </div>
            <div class="rounded-xl p-3 mb-3" style="background: rgba(15, 23, 42, 0.6); border: 1px solid rgba(245, 158, 11, 0.15);">
              <%= if @session_statements == [] do %>
                <div class="text-center text-[11px] text-gray-600 py-4">No speeches delivered yet this session</div>
              <% else %>
                <div class="space-y-2">
                  <%= for stmt <- @session_statements do %>
                    <% player_id = Map.get(stmt, "player_id", Map.get(stmt, :player_id, "?")) %>
                    <% bill_id = Map.get(stmt, "bill_id", Map.get(stmt, :bill_id, "?")) %>
                    <% speech = Map.get(stmt, "speech", Map.get(stmt, :speech, "")) %>
                    <% speech_preview = String.slice(speech, 0, 100) <> if String.length(speech) > 100, do: "...", else: "" %>
                    <% faction = get_faction_name(to_string(player_id), @players) %>
                    <div class="py-2 px-2.5 rounded" style="background: rgba(15, 23, 42, 0.4);">
                      <div class="flex items-center gap-2 mb-1">
                        <div class="w-1.5 h-1.5 rounded-full" style={"background: #{faction_color(to_string(player_id))}"}></div>
                        <span class="text-[10px] font-bold" style={"color: #{faction_color(to_string(player_id))}"}>
                          {short_faction(faction)}
                        </span>
                        <span class="text-[9px] text-gray-600">on</span>
                        <span class="text-[9px] font-semibold capitalize" style={"color: #{bill_color(bill_id)}"}>
                          {bill_id}
                        </span>
                      </div>
                      <div class="text-[9px] text-gray-400 leading-relaxed pl-3">{speech_preview}</div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Amendment panel --%>
          <div :if={@phase == "amendment"}>
            <div class="flex items-center gap-2 mb-3">
              <div class="w-1.5 h-1.5 rounded-full bg-purple-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-purple-400/50">AMENDMENT PROPOSALS</span>
              <div class="flex-1 h-px bg-gradient-to-r from-purple-900/30 to-transparent"></div>
            </div>
            <div class="rounded-xl p-3 mb-3" style="background: rgba(15, 23, 42, 0.6); border: 1px solid rgba(139, 92, 246, 0.15);">
              <%= if @proposed_amendments == [] do %>
                <div class="text-center text-[11px] text-gray-600 py-4">No amendments proposed yet</div>
              <% else %>
                <div class="space-y-2">
                  <%= for amendment <- Enum.take(@proposed_amendments, 6) do %>
                    <% proposer = Map.get(amendment, :proposer_id, Map.get(amendment, "proposer_id", "?")) %>
                    <% bill_id = Map.get(amendment, :bill_id, Map.get(amendment, "bill_id", "?")) %>
                    <% text = Map.get(amendment, :amendment_text, Map.get(amendment, "amendment_text", "")) %>
                    <% text_preview = String.slice(text, 0, 80) <> if String.length(text) > 80, do: "...", else: "" %>
                    <% faction = get_faction_name(to_string(proposer), @players) %>
                    <div class="py-2 px-2.5 rounded" style="background: rgba(139, 92, 246, 0.06); border: 1px solid rgba(139, 92, 246, 0.1);">
                      <div class="flex items-center gap-2 mb-1">
                        <div class="w-1.5 h-1.5 rounded-full" style={"background: #{faction_color(to_string(proposer))}"}></div>
                        <span class="text-[10px] font-bold" style={"color: #{faction_color(to_string(proposer))}"}>
                          {short_faction(faction)}
                        </span>
                        <span class="text-[9px] text-gray-600">amends</span>
                        <span class="text-[9px] font-semibold capitalize" style={"color: #{bill_color(bill_id)}"}>
                          {bill_id}
                        </span>
                      </div>
                      <div class="text-[9px] text-gray-400 pl-3">{text_preview}</div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Amendment vote panel --%>
          <div :if={@phase == "amendment_vote"}>
            <div class="flex items-center gap-2 mb-3">
              <div class="w-1.5 h-1.5 rounded-full bg-red-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-red-400/50">AMENDMENT VOTE</span>
              <div class="flex-1 h-px bg-gradient-to-r from-red-900/30 to-transparent"></div>
            </div>
            <div class="rounded-xl p-3 mb-3" style="background: rgba(15, 23, 42, 0.6); border: 1px solid rgba(239, 68, 68, 0.15);">
              <div class="space-y-2">
                <%= for amendment <- Enum.take(@proposed_amendments, 8) do %>
                  <% amendment_id = Map.get(amendment, :id, Map.get(amendment, "id", "?")) %>
                  <% bill_id = Map.get(amendment, :bill_id, Map.get(amendment, "bill_id", "?")) %>
                  <% votes = Map.get(amendment, :votes, Map.get(amendment, "votes", %{})) %>
                  <% passed = Map.get(amendment, :passed, nil) %>
                  <% yes_count = Enum.count(votes, fn {_k, v} -> v == "yes" end) %>
                  <% no_count = Enum.count(votes, fn {_k, v} -> v == "no" end) %>
                  <div class="py-2 px-2.5 rounded" style={"background: #{amendment_vote_bg(passed)}; border: 1px solid #{amendment_vote_border(passed)};"}>
                    <div class="flex items-center justify-between mb-1">
                      <span class="text-[10px] font-mono text-gray-500">{String.slice(amendment_id, 0, 30)}</span>
                      <span class="text-[9px] capitalize" style={"color: #{bill_color(bill_id)}"}>bill: {bill_id}</span>
                    </div>
                    <div class="flex items-center gap-3">
                      <span class="text-[11px] font-bold text-green-400">{yes_count}Y</span>
                      <div class="flex-1 h-2 rounded-full bg-gray-800 overflow-hidden">
                        <%= if yes_count + no_count > 0 do %>
                          <div class="h-full rounded-full bg-green-500 opacity-70" style={"width: #{round(yes_count / (yes_count + no_count) * 100)}%"}></div>
                        <% end %>
                      </div>
                      <span class="text-[11px] font-bold text-red-400">{no_count}N</span>
                      <span :if={passed == true} class="text-[9px] font-black text-green-400 leg-neon-green">PASSED</span>
                      <span :if={passed == false} class="text-[9px] font-black text-red-400 leg-neon-red">FAILED</span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Final vote panel --%>
          <div :if={@phase == "final_vote"}>
            <div class="flex items-center gap-2 mb-3">
              <div class="w-1.5 h-1.5 rounded-full bg-green-500/70"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-green-400/50">FINAL VOTE</span>
              <div class="flex-1 h-px bg-gradient-to-r from-green-900/30 to-transparent"></div>
            </div>
            <div class="rounded-xl p-3" style="background: rgba(15, 23, 42, 0.6); border: 1px solid rgba(34, 197, 94, 0.15);">
              <div class="space-y-3">
                <%= for bill_id <- @bill_order do %>
                  <% bill = Map.get(@bills, bill_id, %{}) %>
                  <% bill_status = get_val(bill, :status, "pending") %>
                  <% yes_count = Enum.count(@vote_record, fn {_p, votes} -> Map.get(votes, bill_id, "no") == "yes" end) %>
                  <% no_count = map_size(@vote_record) - yes_count %>
                  <% total = yes_count + no_count %>
                  <% bcolor = bill_color(bill_id) %>
                  <div class={["rounded p-2", if(bill_status == "passed", do: "leg-passed", else: "")]}>
                    <div class="flex items-center justify-between mb-1.5">
                      <span class="text-[11px] font-bold capitalize" style={"color: #{bcolor}"}>{bill_id}</span>
                      <div class="flex items-center gap-1.5">
                        <span class="text-[10px] text-green-400 font-semibold">{yes_count}Y</span>
                        <span class="text-[9px] text-gray-600">/</span>
                        <span class="text-[10px] text-red-400 font-semibold">{no_count}N</span>
                        <span :if={bill_status == "passed"} class="text-[9px] font-black text-green-400 ml-1 leg-neon-green">PASSED</span>
                        <span :if={bill_status == "failed"} class="text-[9px] font-black text-red-400 ml-1 leg-neon-red">FAILED</span>
                      </div>
                    </div>
                    <div class="h-2 rounded-full overflow-hidden" style="background: rgba(15, 23, 42, 0.8);">
                      <%= if total > 0 do %>
                        <div class="h-full rounded-full opacity-70" style={"background: #{bcolor}; width: #{round(yes_count / total * 100)}%"}></div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

        </div>

        <%!-- ──── RIGHT: SCOREBOARD ──── --%>
        <div class="w-64 flex-shrink-0 p-4 overflow-y-auto border-l" style="border-color: rgba(245, 158, 11, 0.1);">

          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full bg-amber-500/70"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-amber-400/50">SCOREBOARD</span>
            <div class="flex-1 h-px bg-gradient-to-r from-amber-900/30 to-transparent"></div>
          </div>

          <div class="space-y-2">
            <%= for {pid_str, pdata, score, capital} <- @sorted_players do %>
              <% faction = get_val(pdata, :faction, pid_str) %>
              <% is_active = to_string(@active_actor_id) == pid_str %>
              <% is_winner = to_string(@winner) == pid_str %>
              <% color = faction_color(pid_str) %>
              <div
                class={["rounded-lg p-2.5 transition-all duration-300", if(is_active, do: "leg-session-active", else: "")]}
                style={"background: #{if is_winner, do: "rgba(245, 158, 11, 0.08)", else: "rgba(15, 23, 42, 0.5)"}; border: 1px solid #{if is_winner, do: "rgba(245, 158, 11, 0.4)", else: color}20;"}
              >
                <div class="flex items-center gap-1.5 mb-1">
                  <div class="w-2 h-2 rounded-full flex-shrink-0" style={"background: #{color}"}></div>
                  <span class="text-[11px] font-bold truncate" style={"color: #{color}"}>{short_faction(faction)}</span>
                  <span :if={is_winner} class="ml-auto text-[9px] font-black text-amber-400 leg-neon-amber">WINNER</span>
                </div>
                <div class="flex items-center justify-between">
                  <div class="text-[18px] font-black tabular-nums" style={"color: #{color}"}>{score}</div>
                  <div class="text-right">
                    <div class="text-[9px] text-gray-600">pts</div>
                    <div class="text-[9px] text-amber-500">{capital} cap</div>
                  </div>
                </div>
                <% max_score = 300 %>
                <div class="h-1.5 rounded-full mt-1.5 overflow-hidden" style="background: rgba(15, 23, 42, 0.8);">
                  <div class="h-full rounded-full opacity-60" style={"background: #{color}; width: #{round(min(max(score, 0) / max_score, 1.0) * 100)}%"}></div>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Session progress --%>
          <div class="mt-4 pt-3" style="border-top: 1px solid rgba(245, 158, 11, 0.1);">
            <div class="text-[9px] text-gray-600 mb-2 uppercase tracking-wider">Session Progress</div>
            <div class="flex gap-1">
              <%= for s <- 1..@max_sessions do %>
                <div
                  class="flex-1 h-2 rounded-sm"
                  style={"background: #{if s < @session, do: "rgba(245, 158, 11, 0.6)", else: if s == @session, do: "rgba(245, 158, 11, 0.3)", else: "rgba(71, 85, 105, 0.2)"}; border: 1px solid #{if s <= @session, do: "rgba(245, 158, 11, 0.3)", else: "rgba(71, 85, 105, 0.1)"};"}
                ></div>
              <% end %>
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

  defp phase_badge_class("caucus"),
    do: "bg-blue-900/40 border-blue-600/40 text-blue-300"

  defp phase_badge_class("floor_debate"),
    do: "bg-amber-900/40 border-amber-600/40 text-amber-300"

  defp phase_badge_class("amendment"),
    do: "bg-purple-900/40 border-purple-600/40 text-purple-300"

  defp phase_badge_class("amendment_vote"),
    do: "bg-red-900/40 border-red-600/40 text-red-300"

  defp phase_badge_class("final_vote"),
    do: "bg-green-900/40 border-green-600/40 text-green-300"

  defp phase_badge_class(_),
    do: "bg-gray-900/40 border-gray-600/40 text-gray-300"

  defp phase_label("caucus"), do: "Caucus"
  defp phase_label("floor_debate"), do: "Floor Debate"
  defp phase_label("amendment"), do: "Amendment"
  defp phase_label("amendment_vote"), do: "Amend. Vote"
  defp phase_label("final_vote"), do: "Final Vote"
  defp phase_label(other), do: String.replace(other || "unknown", "_", " ")

  defp bill_color("infrastructure"), do: "#f59e0b"
  defp bill_color("healthcare"), do: "#22c55e"
  defp bill_color("defense"), do: "#ef4444"
  defp bill_color("education"), do: "#3b82f6"
  defp bill_color("environment"), do: "#14b8a6"
  defp bill_color(_), do: "#94a3b8"

  defp bill_bg(color, "passed"), do: "#{color}18"
  defp bill_bg(color, "failed"), do: "rgba(239, 68, 68, 0.05)"
  defp bill_bg(color, _), do: "#{color}08"

  defp bill_status_class("passed"), do: "bg-green-900/60 text-green-300"
  defp bill_status_class("failed"), do: "bg-red-900/60 text-red-400"
  defp bill_status_class(_), do: "bg-gray-800/60 text-gray-500"

  defp amendment_vote_bg(true), do: "rgba(34, 197, 94, 0.06)"
  defp amendment_vote_bg(false), do: "rgba(239, 68, 68, 0.06)"
  defp amendment_vote_bg(_), do: "rgba(15, 23, 42, 0.4)"

  defp amendment_vote_border(true), do: "rgba(34, 197, 94, 0.2)"
  defp amendment_vote_border(false), do: "rgba(239, 68, 68, 0.2)"
  defp amendment_vote_border(_), do: "rgba(71, 85, 105, 0.2)"

  # Player colors keyed by player_id
  defp faction_color("player_1"), do: "#ef4444"
  defp faction_color("player_2"), do: "#3b82f6"
  defp faction_color("player_3"), do: "#22c55e"
  defp faction_color("player_4"), do: "#f59e0b"
  defp faction_color("player_5"), do: "#8b5cf6"
  defp faction_color("player_6"), do: "#06b6d4"
  defp faction_color("player_7"), do: "#f97316"
  defp faction_color(_), do: "#94a3b8"

  defp get_faction_name(player_id, players) when is_binary(player_id) do
    data = Map.get(players, player_id) || Map.get(players, String.to_atom(player_id), %{})
    get_val(data, :faction, player_id)
  end

  defp get_faction_name(_, _), do: "Unknown"

  defp short_faction(faction) when is_binary(faction) do
    words = String.split(faction, " ")

    cond do
      length(words) >= 2 -> Enum.take(words, 2) |> Enum.join(" ")
      true -> faction
    end
  end

  defp short_faction(other), do: to_string(other)

  defp get_val(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_map, _key, default), do: default
end
