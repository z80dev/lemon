defmodule LemonSimUi.Live.Components.MurderMysteryBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    rooms = MapHelpers.get_key(world, :rooms) || %{}
    players = MapHelpers.get_key(world, :players) || %{}
    phase = MapHelpers.get_key(world, :phase) || "investigation"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 5
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || []
    interrogation_log = MapHelpers.get_key(world, :interrogation_log) || []
    discussion_log = MapHelpers.get_key(world, :discussion_log) || []
    accusations = MapHelpers.get_key(world, :accusations) || []
    planted_evidence = MapHelpers.get_key(world, :planted_evidence) || []
    destroyed_evidence = MapHelpers.get_key(world, :destroyed_evidence) || []
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    journals = MapHelpers.get_key(world, :journals) || %{}

    # Room grid layout: 2 rows x 3 columns
    room_grid = [
      ["library", "ballroom", "conservatory"],
      ["study", "kitchen", "cellar"]
    ]

    # Build sorted player list by clues found
    sorted_players =
      players
      |> Enum.map(fn {pid, pdata} ->
        pid_str = to_string(pid)
        clues_found = get_val(pdata, :clues_found, []) |> length()
        role = get_val(pdata, :role, "investigator")
        accusations_remaining = get_val(pdata, :accusations_remaining, 1)
        {pid_str, pdata, role, clues_found, accusations_remaining}
      end)
      |> Enum.sort_by(fn {_, _, _, clues, _} -> clues end, :desc)

    # Active player info
    active_player_data =
      if active_actor_id do
        pid_str = to_string(active_actor_id)
        Map.get(players, active_actor_id) || Map.get(players, pid_str, %{})
      else
        %{}
      end

    active_name = get_val(active_player_data, :name, get_val(active_player_data, "name", "Unknown"))

    # Recent interrogations (last 5 answered)
    recent_interrogations =
      interrogation_log
      |> Enum.filter(fn e -> Map.get(e, "answer") != nil end)
      |> Enum.reverse()
      |> Enum.take(5)
      |> Enum.reverse()

    # Recent discussion (last 8)
    recent_discussion =
      discussion_log
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    # Correct accusation
    winning_accusation = Enum.find(accusations, fn a -> Map.get(a, "correct", false) end)

    assigns =
      assigns
      |> assign(:rooms, rooms)
      |> assign(:players, players)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:active_name, active_name)
      |> assign(:turn_order, turn_order)
      |> assign(:interrogation_log, interrogation_log)
      |> assign(:recent_interrogations, recent_interrogations)
      |> assign(:discussion_log, discussion_log)
      |> assign(:recent_discussion, recent_discussion)
      |> assign(:accusations, accusations)
      |> assign(:winning_accusation, winning_accusation)
      |> assign(:planted_evidence, planted_evidence)
      |> assign(:destroyed_evidence, destroyed_evidence)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:room_grid, room_grid)
      |> assign(:sorted_players, sorted_players)
      |> assign(:journals, journals)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0d0a0e; color: #e2e0f0; min-height: 640px;">
      <style>
        /* ── Candle Flicker ── */
        @keyframes mm-flicker {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.88; }
          75% { opacity: 0.95; }
        }
        .mm-candle { animation: mm-flicker 3s ease-in-out infinite; }

        /* ── Clue Pulse ── */
        @keyframes mm-clue-pulse {
          0%, 100% { box-shadow: 0 0 4px 0 rgba(212, 175, 55, 0.2); }
          50% { box-shadow: 0 0 12px 3px rgba(212, 175, 55, 0.4); }
        }
        .mm-clue-glow { animation: mm-clue-pulse 2.5s ease-in-out infinite; }

        /* ── Suspect Highlight ── */
        @keyframes mm-suspect-breathe {
          0%, 100% { border-color: rgba(192, 57, 43, 0.3); }
          50% { border-color: rgba(192, 57, 43, 0.7); }
        }
        .mm-active-suspect { animation: mm-suspect-breathe 2s ease-in-out infinite; }

        /* ── Phase Badge Pulse ── */
        @keyframes mm-phase-pulse {
          0%, 100% { opacity: 0.7; }
          50% { opacity: 1; }
        }
        .mm-phase-active { animation: mm-phase-pulse 2s ease-in-out infinite; }

        /* ── Accusation Flash ── */
        @keyframes mm-accusation-flash {
          0% { box-shadow: 0 0 0 0 rgba(192, 57, 43, 0.8); }
          50% { box-shadow: 0 0 20px 8px rgba(192, 57, 43, 0.3); }
          100% { box-shadow: 0 0 0 0 rgba(192, 57, 43, 0); }
        }
        .mm-accusation { animation: mm-accusation-flash 1.5s ease-out; }

        /* ── Victory Entrance ── */
        @keyframes mm-victory-enter {
          from { opacity: 0; transform: scale(0.9) translateY(12px); }
          to { opacity: 1; transform: scale(1) translateY(0); }
        }
        .mm-victory { animation: mm-victory-enter 0.7s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

        /* ── Evidence Destroyed ── */
        @keyframes mm-destroy {
          0% { opacity: 1; transform: scale(1); }
          50% { opacity: 0.5; transform: scale(0.95); }
          100% { opacity: 1; transform: scale(1); }
        }
        .mm-destroyed { animation: mm-destroy 0.8s ease-out; }
      </style>

      <%!-- ═══════════════ STATUS BAR ═══════════════ --%>
      <div class="relative overflow-hidden" style="background: linear-gradient(90deg, rgba(192, 57, 43, 0.08), rgba(13, 10, 14, 0.9), rgba(142, 68, 173, 0.08)); border-bottom: 1px solid rgba(212, 175, 55, 0.15);">
        <div class="mm-candle relative px-4 py-2.5 flex items-center justify-between">
          <%!-- Left: Game Identity --%>
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 rounded-full bg-amber-500 mm-phase-active"></div>
              <span class="text-[10px] font-bold tracking-[0.25em] uppercase" style="color: rgba(212, 175, 55, 0.7);">MURDER MYSTERY</span>
            </div>
            <div class="h-4 w-px bg-amber-900/30"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-mono text-gray-500">RND</span>
              <span class="text-sm font-black text-white tabular-nums">{@round}</span>
              <span class="text-[10px] text-gray-600">/ {@max_rounds}</span>
            </div>
          </div>

          <%!-- Center: Phase Badge --%>
          <div class="flex items-center gap-2">
            <div class={["px-3 py-1 rounded-full border text-[10px] font-bold tracking-wider uppercase", mm_phase_badge_class(@phase)]}>
              {mm_phase_label(@phase)}
            </div>
          </div>

          <%!-- Right: Active Player + Win Condition --%>
          <div class="flex items-center gap-3">
            <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full mm-phase-active" style={"background: #{suspect_color(to_string(@active_actor_id))};"}></div>
              <span class="text-[10px] font-bold" style={"color: #{suspect_color(to_string(@active_actor_id))};"}>{@active_name}</span>
            </div>
            <div class="h-4 w-px bg-amber-900/30"></div>
            <div class="flex items-center gap-1">
              <span class="text-[10px] text-gray-500">WIN</span>
              <span class="text-[10px] font-bold text-amber-400">correct accusation</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- ═══════════════ MAIN CONTENT ═══════════════ --%>
      <div class="flex" style="min-height: 580px;">

        <%!-- ──── LEFT: MANSION MAP + EVIDENCE ──── --%>
        <div class="flex-1 p-4 overflow-y-auto">

          <%!-- Mansion Header --%>
          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full" style="background: rgba(212, 175, 55, 0.7);"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(212, 175, 55, 0.5);">MANSION FLOOR PLAN</span>
            <div class="flex-1 h-px bg-gradient-to-r from-amber-900/30 to-transparent"></div>
          </div>

          <%!-- Room Grid --%>
          <div class="rounded-xl overflow-hidden" style="background: linear-gradient(135deg, rgba(26, 21, 32, 0.9), rgba(13, 10, 14, 0.95)); border: 1px solid rgba(212, 175, 55, 0.1);">
            <div class="p-4">
              <div class="grid grid-cols-3 gap-3">
                <%= for row <- @room_grid do %>
                  <%= for room_id <- row do %>
                    <% room_data = get_room(@rooms, room_id) %>
                    <% clues_present = get_val(room_data, :clues_present, []) |> length() %>
                    <% searched_by = get_val(room_data, :searched_by, []) %>
                    <% search_count = length(searched_by) %>
                    <% room_name = get_val(room_data, :name, room_id) %>
                    <div
                      class="rounded-lg p-3 text-center relative"
                      style={"background: #{room_bg(clues_present, search_count)}; border: 1px solid #{room_border(clues_present)};"}
                    >
                      <%!-- Room Name --%>
                      <div class="text-[10px] font-bold tracking-wider uppercase mb-2" style={"color: #{room_text_color(clues_present, search_count)};"}>
                        {room_name}
                      </div>

                      <%!-- Clue Count Badge --%>
                      <div class="flex items-center justify-center gap-1.5 mb-2">
                        <div
                          class={"inline-flex items-center justify-center w-9 h-9 rounded-full text-sm font-black #{if clues_present > 0, do: "mm-clue-glow", else: ""}"}
                          style={"background: #{if clues_present > 0, do: "rgba(212, 175, 55, 0.15)", else: "rgba(61, 47, 74, 0.3)"}; color: #{if clues_present > 0, do: "#d4af37", else: "#5a4f6a"}; border: 2px solid #{if clues_present > 0, do: "rgba(212, 175, 55, 0.4)", else: "rgba(61, 47, 74, 0.3)"};"}
                        >
                          {clues_present}
                        </div>
                      </div>

                      <%!-- Clue Label --%>
                      <div class="text-[8px] uppercase tracking-wide" style={"color: #{if clues_present > 0, do: "rgba(212, 175, 55, 0.6)", else: "rgba(90, 79, 106, 0.7)"};"}>
                        {if clues_present == 1, do: "clue", else: "clues"}
                      </div>

                      <%!-- Searched indicator --%>
                      <div :if={search_count > 0} class="mt-1.5 flex items-center justify-center gap-0.5">
                        <%= for pid <- Enum.take(searched_by, 4) do %>
                          <div class="w-2 h-2 rounded-full" style={"background: #{suspect_color(to_string(pid))}; opacity: 0.7;"}></div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Evidence Manipulation Stats --%>
          <div :if={length(@planted_evidence) > 0 or length(@destroyed_evidence) > 0} class="mt-3 flex gap-2">
            <div :if={length(@planted_evidence) > 0} class="flex-1 rounded-lg px-3 py-2 text-center" style="background: rgba(192, 57, 43, 0.1); border: 1px solid rgba(192, 57, 43, 0.2);">
              <div class="text-[9px] uppercase tracking-wide text-red-400/60 mb-0.5">Planted</div>
              <div class="text-lg font-black text-red-400">{length(@planted_evidence)}</div>
            </div>
            <div :if={length(@destroyed_evidence) > 0} class="flex-1 rounded-lg px-3 py-2 text-center" style="background: rgba(142, 68, 173, 0.1); border: 1px solid rgba(142, 68, 173, 0.2);">
              <div class="text-[9px] uppercase tracking-wide text-purple-400/60 mb-0.5">Destroyed</div>
              <div class="text-lg font-black text-purple-400">{length(@destroyed_evidence)}</div>
            </div>
          </div>

          <%!-- Discussion Log --%>
          <div :if={length(@recent_discussion) > 0} class="mt-4">
            <div class="flex items-center gap-2 mb-2">
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-blue-400/50">PUBLIC DISCUSSION</span>
              <div class="flex-1 h-px bg-gradient-to-r from-blue-900/20 to-transparent"></div>
            </div>
            <div class="space-y-1.5">
              <%= for entry <- @recent_discussion do %>
                <% pid = Map.get(entry, "player_id", "?") %>
                <% entry_type = Map.get(entry, "type", "finding") %>
                <% content = Map.get(entry, "content", "") %>
                <% round_num = Map.get(entry, "round", "?") %>
                <% pinfo = Map.get(@players, pid, %{}) %>
                <% pname = get_val(pinfo, :name, get_val(pinfo, "name", pid)) %>
                <div class="rounded-lg px-3 py-2" style={"background: #{discussion_entry_bg(entry_type)}; border: 1px solid #{discussion_entry_border(entry_type)};"}>
                  <div class="flex items-center gap-2 mb-0.5">
                    <div class="w-1.5 h-1.5 rounded-full" style={"background: #{suspect_color(pid)};"}></div>
                    <span class="text-[10px] font-bold" style={"color: #{suspect_color(pid)};"}>
                      {pname}
                    </span>
                    <span class={"text-[9px] font-bold uppercase tracking-wide #{discussion_type_class(entry_type)}"}>
                      {entry_type}
                    </span>
                    <span class="text-[9px] text-gray-600 ml-auto">R{round_num}</span>
                  </div>
                  <div class="text-[10px] text-gray-400 leading-relaxed">{String.slice(content, 0, 120)}</div>
                </div>
              <% end %>
            </div>
          </div>

        </div>

        <%!-- ──── RIGHT: SUSPECTS + INTERROGATIONS + ACCUSATIONS ──── --%>
        <div class="w-80 flex-shrink-0 border-l p-4 overflow-y-auto" style="border-color: rgba(61, 47, 74, 0.4); background: rgba(26, 21, 32, 0.5);">

          <%!-- Game Over Banner --%>
          <div :if={@game_status == "won"} class="mm-victory mb-4 rounded-xl px-4 py-3 text-center" style={"background: #{winner_bg(@winner)}; border: 1px solid #{winner_border(@winner)};"}>
            <div class="text-[10px] font-bold tracking-[0.2em] uppercase mb-1" style={"color: #{winner_color(@winner)};"}>
              {winner_label(@winner)}
            </div>
            <div :if={@winning_accusation} class="text-[10px] text-gray-400">
              <% solver = Map.get(@winning_accusation, "player_id", "?") %>
              <% sinfo = Map.get(@players, solver, %{}) %>
              <% sname = get_val(sinfo, :name, get_val(sinfo, "name", solver)) %>
              Solved by {sname}
            </div>
          </div>

          <%!-- Suspects Header --%>
          <div class="flex items-center gap-2 mb-3">
            <div class="w-1.5 h-1.5 rounded-full bg-red-500/70"></div>
            <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-red-400/50">SUSPECTS</span>
            <div class="flex-1 h-px bg-gradient-to-r from-red-900/20 to-transparent"></div>
          </div>

          <div class="space-y-2 mb-4">
            <%= for {pid, pdata, role, clue_count, acc_remaining} <- @sorted_players do %>
              <% guest_name = get_val(pdata, :name, get_val(pdata, "name", pid)) %>
              <% alibi = get_val(pdata, :alibi, get_val(pdata, "alibi", "unknown")) %>
              <% is_active = to_string(@active_actor_id) == pid %>
              <% color = suspect_color(pid) %>
              <div
                class={["rounded-lg p-2.5", if(is_active, do: "mm-active-suspect", else: "")]}
                style={"background: #{if is_active, do: color <> "12", else: "rgba(26, 21, 32, 0.6)"}; border: 1px solid #{if is_active, do: color <> "50", else: "rgba(61, 47, 74, 0.3)"};"}
              >
                <div class="flex items-center gap-2 mb-1">
                  <div class="w-2 h-2 rounded-full flex-shrink-0" style={"background: #{color};"}></div>
                  <span class="text-[11px] font-bold text-gray-100" style="font-style: italic;">{guest_name}</span>
                  <span class="text-[9px] text-gray-600 ml-auto">{pid}</span>
                </div>
                <div class="text-[9px] text-gray-500 ml-4 mb-1.5 italic">"{alibi}"</div>
                <div class="flex items-center gap-2 ml-4">
                  <div class="flex items-center gap-1">
                    <span class="text-[8px] text-amber-400/60">clues</span>
                    <span class="text-[10px] font-bold text-amber-400">{clue_count}</span>
                  </div>
                  <div class="w-px h-3 bg-gray-700"></div>
                  <div class="flex items-center gap-1">
                    <span class="text-[8px]" style={"color: #{if acc_remaining > 0, do: "rgba(39, 174, 96, 0.6)", else: "rgba(192, 57, 43, 0.6)"};"}>
                      acc
                    </span>
                    <span class="text-[10px] font-bold" style={"color: #{if acc_remaining > 0, do: "#27ae60", else: "#c0392b"};"}>
                      {acc_remaining}
                    </span>
                  </div>
                  <div :if={role == "killer" and @game_status == "won"} class="ml-auto">
                    <span class="text-[8px] font-bold text-red-400 uppercase tracking-wide">KILLER</span>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Interrogation Log --%>
          <div :if={length(@recent_interrogations) > 0} class="mb-4">
            <div class="flex items-center gap-2 mb-2">
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-blue-400/50">INTERROGATIONS</span>
              <div class="flex-1 h-px bg-gradient-to-r from-blue-900/20 to-transparent"></div>
            </div>
            <div class="space-y-2">
              <%= for qa <- @recent_interrogations do %>
                <% asker_id = Map.get(qa, "asker_id", "?") %>
                <% target_id = Map.get(qa, "target_id", "?") %>
                <% question = Map.get(qa, "question", "") %>
                <% answer = Map.get(qa, "answer", "") %>
                <% round_num = Map.get(qa, "round", "?") %>
                <% asker_info = Map.get(@players, asker_id, %{}) %>
                <% target_info = Map.get(@players, target_id, %{}) %>
                <% asker_name = get_val(asker_info, :name, get_val(asker_info, "name", asker_id)) %>
                <% target_name = get_val(target_info, :name, get_val(target_info, "name", target_id)) %>
                <div class="rounded-lg px-2.5 py-2" style="background: rgba(41, 128, 185, 0.06); border: 1px solid rgba(41, 128, 185, 0.15);">
                  <div class="flex items-center gap-1 mb-1">
                    <span class="text-[9px] font-bold" style={"color: #{suspect_color(asker_id)};"}>
                      {asker_name}
                    </span>
                    <span class="text-[9px] text-gray-600"> asked </span>
                    <span class="text-[9px] font-bold" style={"color: #{suspect_color(target_id)};"}>
                      {target_name}
                    </span>
                    <span class="text-[9px] text-gray-700 ml-auto">R{round_num}</span>
                  </div>
                  <div class="text-[9px] text-gray-500 mb-1 italic">Q: {String.slice(question, 0, 70)}</div>
                  <div class="text-[9px] text-gray-400">A: {String.slice(answer, 0, 70)}</div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Accusations --%>
          <div :if={length(@accusations) > 0}>
            <div class="flex items-center gap-2 mb-2">
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase text-red-400/50">ACCUSATIONS</span>
              <div class="flex-1 h-px bg-gradient-to-r from-red-900/20 to-transparent"></div>
            </div>
            <div class="space-y-1.5">
              <%= for acc <- @accusations do %>
                <% pid = Map.get(acc, "player_id", "?") %>
                <% accused = Map.get(acc, "accused_id", "?") %>
                <% weapon = Map.get(acc, "weapon", "?") %>
                <% room = Map.get(acc, "room_id", "?") %>
                <% correct = Map.get(acc, "correct", false) %>
                <% round_num = Map.get(acc, "round", "?") %>
                <% pinfo = Map.get(@players, pid, %{}) %>
                <% pname = get_val(pinfo, :name, get_val(pinfo, "name", pid)) %>
                <div
                  class={["rounded-lg px-2.5 py-2", if(correct, do: "mm-accusation", else: "")]}
                  style={"background: #{if correct, do: "rgba(39, 174, 96, 0.1)", else: "rgba(192, 57, 43, 0.07)"}; border: 1px solid #{if correct, do: "rgba(39, 174, 96, 0.3)", else: "rgba(192, 57, 43, 0.2)"};"}
                >
                  <div class="flex items-center gap-1 mb-0.5">
                    <span class="text-[9px] font-bold" style={"color: #{suspect_color(pid)};"}>
                      {pname}
                    </span>
                    <span class={"text-[9px] font-bold ml-auto #{if correct, do: "text-green-400", else: "text-red-400"}"}>
                      {if correct, do: "CORRECT", else: "WRONG"}
                    </span>
                  </div>
                  <div class="text-[9px] text-gray-500">
                    accused {accused} with {weapon} in {room} (R{round_num})
                  </div>
                </div>
              <% end %>
            </div>
          </div>

        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_room(rooms, room_id) do
    Map.get(rooms, room_id) ||
      Map.get(rooms, String.to_atom(room_id)) ||
      %{}
  end

  defp get_val(map, atom_key, default) when is_map(map) do
    case Map.get(map, atom_key) do
      nil ->
        str_key = if is_atom(atom_key), do: Atom.to_string(atom_key), else: atom_key

        case Map.get(map, str_key) do
          nil -> default
          val -> val
        end

      val ->
        val
    end
  end

  defp get_val(_map, _key, default), do: default

  defp suspect_color("player_1"), do: "#c0392b"
  defp suspect_color("player_2"), do: "#2980b9"
  defp suspect_color("player_3"), do: "#27ae60"
  defp suspect_color("player_4"), do: "#f39c12"
  defp suspect_color("player_5"), do: "#8e44ad"
  defp suspect_color("player_6"), do: "#16a085"
  defp suspect_color(_), do: "#9c8faa"

  defp mm_phase_badge_class("investigation"), do: "border-green-800/60 text-green-400 bg-green-900/20"
  defp mm_phase_badge_class("interrogation"), do: "border-blue-800/60 text-blue-400 bg-blue-900/20"
  defp mm_phase_badge_class("discussion"), do: "border-amber-800/60 text-amber-400 bg-amber-900/20"
  defp mm_phase_badge_class("killer_action"), do: "border-red-800/60 text-red-400 bg-red-900/20"
  defp mm_phase_badge_class("deduction_vote"), do: "border-purple-800/60 text-purple-400 bg-purple-900/20"
  defp mm_phase_badge_class(_), do: "border-gray-700 text-gray-400 bg-gray-900/20"

  defp mm_phase_label("investigation"), do: "Investigation"
  defp mm_phase_label("interrogation"), do: "Interrogation"
  defp mm_phase_label("discussion"), do: "Discussion"
  defp mm_phase_label("killer_action"), do: "Killer's Move"
  defp mm_phase_label("deduction_vote"), do: "Deduction Vote"
  defp mm_phase_label(p), do: String.capitalize(p || "")

  defp room_bg(clue_count, search_count) when clue_count > 0 and search_count > 0,
    do: "rgba(212, 175, 55, 0.08)"
  defp room_bg(clue_count, _search_count) when clue_count > 0,
    do: "rgba(212, 175, 55, 0.05)"
  defp room_bg(_clue_count, search_count) when search_count > 0,
    do: "rgba(26, 21, 32, 0.5)"
  defp room_bg(_clue_count, _search_count),
    do: "rgba(26, 21, 32, 0.3)"

  defp room_border(clue_count) when clue_count > 0, do: "rgba(212, 175, 55, 0.25)"
  defp room_border(_), do: "rgba(61, 47, 74, 0.25)"

  defp room_text_color(clue_count, _search_count) when clue_count > 0, do: "rgba(212, 175, 55, 0.9)"
  defp room_text_color(_clue_count, _search_count), do: "rgba(90, 79, 106, 0.8)"

  defp discussion_entry_bg("theory"), do: "rgba(41, 128, 185, 0.07)"
  defp discussion_entry_bg("challenge"), do: "rgba(192, 57, 43, 0.07)"
  defp discussion_entry_bg(_), do: "rgba(39, 174, 96, 0.05)"

  defp discussion_entry_border("theory"), do: "rgba(41, 128, 185, 0.2)"
  defp discussion_entry_border("challenge"), do: "rgba(192, 57, 43, 0.2)"
  defp discussion_entry_border(_), do: "rgba(39, 174, 96, 0.15)"

  defp discussion_type_class("theory"), do: "text-blue-400/70"
  defp discussion_type_class("challenge"), do: "text-red-400/70"
  defp discussion_type_class(_), do: "text-green-400/70"

  defp winner_bg("investigators"), do: "rgba(39, 174, 96, 0.1)"
  defp winner_bg("killer"), do: "rgba(192, 57, 43, 0.1)"
  defp winner_bg(_), do: "rgba(61, 47, 74, 0.2)"

  defp winner_border("investigators"), do: "rgba(39, 174, 96, 0.3)"
  defp winner_border("killer"), do: "rgba(192, 57, 43, 0.3)"
  defp winner_border(_), do: "rgba(61, 47, 74, 0.3)"

  defp winner_color("investigators"), do: "#27ae60"
  defp winner_color("killer"), do: "#c0392b"
  defp winner_color(_), do: "#d4af37"

  defp winner_label("investigators"), do: "INVESTIGATORS WIN"
  defp winner_label("killer"), do: "KILLER ESCAPES"
  defp winner_label(_), do: "CASE CLOSED"
end
