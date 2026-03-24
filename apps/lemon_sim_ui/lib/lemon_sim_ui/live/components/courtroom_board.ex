defmodule LemonSimUi.Live.Components.CourtroomBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world

    phase = MapHelpers.get_key(world, :phase) || "opening_statements"
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    players = MapHelpers.get_key(world, :players) || %{}
    testimony_log = MapHelpers.get_key(world, :testimony_log) || []
    evidence_presented = MapHelpers.get_key(world, :evidence_presented) || []
    objections = MapHelpers.get_key(world, :objections) || []
    verdict_votes = MapHelpers.get_key(world, :verdict_votes) || %{}
    jury_notes = MapHelpers.get_key(world, :jury_notes) || %{}
    case_file = MapHelpers.get_key(world, :case_file) || %{}
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    outcome = MapHelpers.get_key(world, :outcome)

    # Case file details
    case_title = get_val(case_file, :title, "Courtroom Trial")
    case_defendant = get_val(case_file, :defendant, "Unknown")
    case_description = get_val(case_file, :description, "")
    evidence_list = get_val(case_file, :evidence_list, [])
    evidence_details = get_val(case_file, :evidence_details, %{})

    # Separate players by role
    prosecution = get_player_by_role(players, "prosecution")
    defense = get_player_by_role(players, "defense")
    witnesses = get_players_by_role(players, "witness")
    jurors = get_players_by_role(players, "juror")

    # Recent testimony (last 12)
    recent_testimony =
      testimony_log
      |> Enum.reverse()
      |> Enum.take(12)
      |> Enum.reverse()

    # Objection stats
    sustained_count = Enum.count(objections, &(get_val(&1, :ruling, "overruled") == "sustained"))
    overruled_count = Enum.count(objections, &(get_val(&1, :ruling, "overruled") == "overruled"))

    # Evidence utilization
    total_evidence = length(evidence_list)
    presented_count = length(evidence_presented)

    evidence_pct =
      if total_evidence > 0 do
        round(presented_count / total_evidence * 100)
      else
        0
      end

    # Verdict tallies
    guilty_votes = verdict_votes |> Map.values() |> Enum.count(&(&1 == "guilty"))
    not_guilty_votes = verdict_votes |> Map.values() |> Enum.count(&(&1 == "not_guilty"))

    assigns =
      assigns
      |> assign(:phase, phase)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:players, players)
      |> assign(:prosecution, prosecution)
      |> assign(:defense, defense)
      |> assign(:witnesses, witnesses)
      |> assign(:jurors, jurors)
      |> assign(:testimony_log, testimony_log)
      |> assign(:recent_testimony, recent_testimony)
      |> assign(:evidence_presented, evidence_presented)
      |> assign(:evidence_list, evidence_list)
      |> assign(:evidence_details, evidence_details)
      |> assign(:evidence_pct, evidence_pct)
      |> assign(:presented_count, presented_count)
      |> assign(:total_evidence, total_evidence)
      |> assign(:objections, objections)
      |> assign(:sustained_count, sustained_count)
      |> assign(:overruled_count, overruled_count)
      |> assign(:verdict_votes, verdict_votes)
      |> assign(:guilty_votes, guilty_votes)
      |> assign(:not_guilty_votes, not_guilty_votes)
      |> assign(:jury_notes, jury_notes)
      |> assign(:case_file, case_file)
      |> assign(:case_title, case_title)
      |> assign(:case_defendant, case_defendant)
      |> assign(:case_description, case_description)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:outcome, outcome)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0d0f14; color: #e8eaf0; min-height: 640px;">
      <style>
        /* ── Phase Pulse ── */
        @keyframes ct-phase-pulse {
          0%, 100% { opacity: 0.7; }
          50% { opacity: 1; }
        }
        .ct-phase-active { animation: ct-phase-pulse 2.5s ease-in-out infinite; }

        /* ── Gavel Bang ── */
        @keyframes ct-gavel {
          0%, 100% { transform: rotate(0deg); }
          25% { transform: rotate(-15deg); }
          75% { transform: rotate(5deg); }
        }
        .ct-gavel-active { animation: ct-gavel 0.8s ease-in-out; }

        /* ── Verdict Entrance ── */
        @keyframes ct-verdict-enter {
          from { opacity: 0; transform: scale(0.85) translateY(16px); }
          to { opacity: 1; transform: scale(1) translateY(0); }
        }
        .ct-verdict { animation: ct-verdict-enter 0.7s cubic-bezier(0.16, 1, 0.3, 1) forwards; }

        /* ── Testimony Fade ── */
        @keyframes ct-testimony-in {
          from { opacity: 0; transform: translateY(4px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .ct-testimony-item { animation: ct-testimony-in 0.3s ease-out forwards; }

        /* ── Objection Flash ── */
        @keyframes ct-objection-flash {
          0%, 100% { background: transparent; }
          50% { background: rgba(192, 57, 43, 0.15); }
        }
        .ct-objection { animation: ct-objection-flash 0.5s ease-in-out 2; }

        /* ── Scanline ── */
        @keyframes ct-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .ct-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(212, 175, 55, 0.12), transparent);
          animation: ct-scanline 5s linear infinite;
          pointer-events: none;
        }
      </style>

      <!-- Header -->
      <div style="background: #161b26; border-bottom: 1px solid #252d3d; padding: 12px 20px; display: flex; align-items: center; justify-content: space-between;">
        <div style="display: flex; align-items: center; gap: 12px;">
          <span style="font-size: 11px; letter-spacing: 3px; color: #d4af37; font-weight: 700;">COURT OF LAW</span>
          <span style="color: #252d3d;">|</span>
          <span style="font-size: 13px; color: #e8eaf0; font-weight: 600;"><%= @case_title %></span>
        </div>
        <div style="display: flex; align-items: center; gap: 10px;">
          <span class="ct-phase-active" style={"padding: 3px 10px; border-radius: 12px; font-size: 10px; font-weight: 700; letter-spacing: 1px; background: #{phase_bg(@phase)}; color: #{phase_color(@phase)};"}>
            <%= phase_label(@phase) %>
          </span>
          <%= if @game_status == "complete" do %>
            <span style="padding: 3px 10px; border-radius: 12px; font-size: 10px; font-weight: 700; background: rgba(212,175,55,0.15); color: #d4af37;">
              CONCLUDED
            </span>
          <% end %>
        </div>
      </div>

      <!-- Main Layout: 3 columns -->
      <div style="display: grid; grid-template-columns: 220px 1fr 240px; gap: 0; min-height: 560px;">

        <!-- Left: Participants -->
        <div style="border-right: 1px solid #252d3d; padding: 12px 0;">
          <div style="padding: 6px 14px 10px; font-size: 10px; letter-spacing: 2px; color: #7a6520; font-weight: 700;">
            PARTICIPANTS
          </div>

          <!-- Case Info -->
          <div style="margin: 0 10px 12px; background: #161b26; border-radius: 6px; padding: 10px 12px; border: 1px solid #252d3d;">
            <div style="font-size: 10px; color: #8892a4; margin-bottom: 4px;">DEFENDANT</div>
            <div style="font-size: 12px; color: #e8eaf0; font-weight: 600;"><%= @case_defendant %></div>
          </div>

          <!-- Prosecution -->
          <%= if @prosecution do %>
            <.participant_card
              player_id="prosecution"
              role="prosecution"
              is_active={@active_actor_id == "prosecution"}
              is_winner={@winner == "prosecution"}
            />
          <% end %>

          <!-- Defense -->
          <%= if @defense do %>
            <.participant_card
              player_id="defense"
              role="defense"
              is_active={@active_actor_id == "defense"}
              is_winner={@winner == "defense"}
            />
          <% end %>

          <!-- Witnesses -->
          <%= if @witnesses != [] do %>
            <div style="padding: 8px 14px 4px; font-size: 9px; letter-spacing: 2px; color: #4a5568; font-weight: 700;">
              WITNESSES
            </div>
            <%= for {wid, _winfo} <- @witnesses do %>
              <.participant_card
                player_id={wid}
                role="witness"
                is_active={@active_actor_id == wid}
                is_winner={false}
              />
            <% end %>
          <% end %>

          <!-- Jurors -->
          <%= if @jurors != [] do %>
            <div style="padding: 8px 14px 4px; font-size: 9px; letter-spacing: 2px; color: #4a5568; font-weight: 700;">
              JURY
            </div>
            <%= for {jid, _jinfo} <- @jurors do %>
              <% vote = Map.get(@verdict_votes, jid) %>
              <.juror_card
                juror_id={jid}
                vote={vote}
                is_active={@active_actor_id == jid}
              />
            <% end %>
          <% end %>
        </div>

        <!-- Center: Court Record + Verdict -->
        <div style="padding: 12px 16px; display: flex; flex-direction: column; gap: 12px;">

          <!-- Verdict banner (when concluded) -->
          <%= if @game_status == "complete" do %>
            <div class="ct-verdict" style={"background: #{verdict_bg(@outcome)}; border: 1px solid #{verdict_border(@outcome)}; border-radius: 10px; padding: 16px 20px; text-align: center;"}>
              <div style="font-size: 10px; letter-spacing: 3px; color: #8892a4; margin-bottom: 6px;">THE JURY FINDS THE DEFENDANT</div>
              <div style={"font-size: 28px; font-weight: 800; color: #{verdict_color(@outcome)}; letter-spacing: 2px;"}><%= verdict_label(@outcome) %></div>
              <div style="margin-top: 8px; display: flex; justify-content: center; gap: 20px;">
                <span style="font-size: 12px; color: #c0392b;"><%= @guilty_votes %> Guilty</span>
                <span style="font-size: 12px; color: #2980b9;"><%= @not_guilty_votes %> Not Guilty</span>
              </div>
              <%= if @winner do %>
                <div style="margin-top: 8px; font-size: 12px; color: #d4af37;"><%= role_label(get_role_for(@players, @winner)) %> wins</div>
              <% end %>
            </div>
          <% end %>

          <!-- Case Description -->
          <div style="background: #161b26; border-radius: 8px; padding: 12px 14px; border: 1px solid #252d3d; font-style: italic; font-size: 12px; color: #8892a4; line-height: 1.6;">
            <%= @case_description %>
          </div>

          <!-- Court Record -->
          <div style="flex: 1; background: #161b26; border-radius: 8px; border: 1px solid #252d3d; overflow: hidden;">
            <div style="padding: 10px 14px; border-bottom: 1px solid #252d3d; font-size: 10px; letter-spacing: 2px; color: #7a6520; font-weight: 700; background: rgba(22,27,38,0.8);">
              COURT RECORD
            </div>
            <div style="padding: 8px 4px; max-height: 360px; overflow-y: auto;">
              <%= if @recent_testimony == [] do %>
                <div style="text-align: center; padding: 40px 20px; font-size: 13px; color: #4a5568; font-style: italic;">
                  Court is called to order...
                </div>
              <% else %>
                <%= for {entry, idx} <- Enum.with_index(@recent_testimony) do %>
                  <% is_recent = idx >= length(@recent_testimony) - 3 %>
                  <% type = get_val(entry, :type, "?") %>
                  <% player_id = get_val(entry, :player_id, get_val(entry, :asker_id, "?")) %>
                  <% content = get_val(entry, :content, "") %>
                  <% role = get_role_for(@players, player_id) %>
                  <div class={if is_recent, do: "ct-testimony-item", else: ""} style={"padding: 8px 14px; opacity: #{if is_recent, do: "1", else: "0.5"}; border-bottom: 1px solid #1a2030;"}>
                    <div style="display: flex; align-items: center; gap: 6px; margin-bottom: 4px;">
                      <span style={"width: 8px; height: 8px; border-radius: 50%; background: #{role_color(role)}; display: inline-block; flex-shrink: 0;"}></span>
                      <span style={"font-size: 10px; font-weight: 700; color: #{role_color(role)};"}><%= role_label(role) %></span>
                      <span style="font-size: 9px; color: #4a5568;"><%= entry_type_label(type) %></span>
                    </div>
                    <div style="font-size: 11px; color: #8892a4; line-height: 1.5; padding-left: 14px; font-style: italic;">
                      <%= if is_binary(content), do: String.slice(content, 0, 200), else: "" %><%= if is_binary(content) and String.length(content) > 200, do: "...", else: "" %>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Right: Evidence & Stats -->
        <div style="border-left: 1px solid #252d3d; padding: 12px 0; display: flex; flex-direction: column; gap: 0;">

          <!-- Evidence panel -->
          <div style="padding: 0 12px 12px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #7a6520; font-weight: 700; margin-bottom: 10px; padding-top: 6px;">
              EVIDENCE
            </div>

            <!-- Progress bar -->
            <div style="margin-bottom: 10px;">
              <div style="display: flex; justify-content: space-between; font-size: 10px; color: #4a5568; margin-bottom: 4px;">
                <span>Presented</span>
                <span><%= @presented_count %>/<%= @total_evidence %> (<%= @evidence_pct %>%)</span>
              </div>
              <div style="height: 4px; background: #252d3d; border-radius: 2px;">
                <div style={"height: 4px; background: #d4af37; border-radius: 2px; width: #{@evidence_pct}%; transition: width 0.3s ease;"}>
                </div>
              </div>
            </div>

            <!-- Evidence list -->
            <div style="display: flex; flex-direction: column; gap: 3px; max-height: 200px; overflow-y: auto;">
              <%= for ev_id <- @evidence_list do %>
                <% is_presented = ev_id in @evidence_presented %>
                <% info = Map.get(@evidence_details, ev_id, Map.get(@evidence_details, String.to_atom(ev_id), %{})) %>
                <% is_incriminating = get_val(info, :incriminating, false) %>
                <div style={"display: flex; align-items: center; gap: 6px; padding: 4px 6px; border-radius: 4px; opacity: #{if is_presented, do: "1", else: "0.35"}; background: #{if is_presented, do: "rgba(212,175,55,0.06)", else: "transparent"};"}>
                  <span style={"width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; background: #{if is_incriminating, do: "#c0392b", else: "#2980b9"};"}>
                  </span>
                  <span style={"font-size: 9px; color: #{if is_presented, do: "#e8eaf0", else: "#4a5568"}; font-family: monospace;"}><%= String.replace(ev_id, "_", " ") %></span>
                  <%= if is_presented do %>
                    <span style="margin-left: auto; font-size: 9px; color: #d4af37;">&#x2713;</span>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Divider -->
          <div style="height: 1px; background: #252d3d; margin: 0 12px 12px;"></div>

          <!-- Objections panel -->
          <div style="padding: 0 12px 12px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #7a6520; font-weight: 700; margin-bottom: 10px;">
              OBJECTIONS
            </div>
            <div style="display: flex; gap: 8px;">
              <div style="flex: 1; background: rgba(39,174,96,0.08); border: 1px solid rgba(39,174,96,0.2); border-radius: 6px; padding: 8px; text-align: center;">
                <div style="font-size: 18px; font-weight: 800; color: #27ae60;"><%= @sustained_count %></div>
                <div style="font-size: 9px; color: #4a5568; letter-spacing: 1px;">SUSTAINED</div>
              </div>
              <div style="flex: 1; background: rgba(192,57,43,0.08); border: 1px solid rgba(192,57,43,0.2); border-radius: 6px; padding: 8px; text-align: center;">
                <div style="font-size: 18px; font-weight: 800; color: #c0392b;"><%= @overruled_count %></div>
                <div style="font-size: 9px; color: #4a5568; letter-spacing: 1px;">OVERRULED</div>
              </div>
            </div>
          </div>

          <!-- Divider -->
          <div style="height: 1px; background: #252d3d; margin: 0 12px 12px;"></div>

          <!-- Jury Vote Tracker -->
          <%= if @phase in ["deliberation", "verdict"] or map_size(@verdict_votes) > 0 do %>
            <div style="padding: 0 12px;">
              <div style="font-size: 10px; letter-spacing: 2px; color: #7a6520; font-weight: 700; margin-bottom: 10px;">
                JURY VOTES
              </div>
              <div style="display: flex; flex-direction: column; gap: 4px;">
                <%= for {jid, _} <- @jurors do %>
                  <% vote = Map.get(@verdict_votes, jid) %>
                  <div style="display: flex; align-items: center; gap: 6px;">
                    <span style="font-size: 10px; color: #8892a4; flex: 1;"><%= format_player_name(jid) %></span>
                    <%= if vote do %>
                      <span style={"font-size: 10px; font-weight: 700; padding: 2px 6px; border-radius: 4px; background: #{if vote == "guilty", do: "rgba(192,57,43,0.15)", else: "rgba(41,128,185,0.15)"}; color: #{if vote == "guilty", do: "#c0392b", else: "#2980b9"};"}>
                        <%= String.upcase(String.replace(vote, "_", " ")) %>
                      </span>
                    <% else %>
                      <span style="font-size: 10px; color: #4a5568; font-style: italic;">pending</span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

        </div>
      </div>
    </div>
    """
  end

  # -- Sub-components --

  attr :player_id, :string, required: true
  attr :role, :string, required: true
  attr :is_active, :boolean, default: false
  attr :is_winner, :boolean, default: false

  defp participant_card(assigns) do
    ~H"""
    <div style={"margin: 2px 8px; padding: 8px 10px; border-radius: 6px; border: 1px solid #{if @is_winner, do: "#d4af37", else: if(@is_active, do: role_color(@role), else: "transparent")}; background: #{if @is_winner, do: "rgba(212,175,55,0.07)", else: if(@is_active, do: "rgba(30,40,60,0.8)", else: "transparent")};"}>
      <div style="display: flex; align-items: center; gap: 6px;">
        <span style={"width: 8px; height: 8px; border-radius: 50%; background: #{role_color(@role)}; flex-shrink: 0;"}></span>
        <span style={"font-size: 11px; font-weight: 700; color: #{role_color(@role)};"}><%= role_label(@role) %></span>
        <%= if @is_active do %>
          <span style="margin-left: auto; font-size: 9px; color: #d4af37; font-weight: 700;">&#x25B6;</span>
        <% end %>
        <%= if @is_winner do %>
          <span style="margin-left: auto; font-size: 9px; color: #d4af37; font-weight: 700;">WINNER</span>
        <% end %>
      </div>
      <div style="font-size: 9px; color: #4a5568; padding-left: 14px; margin-top: 2px; font-family: monospace;"><%= @player_id %></div>
    </div>
    """
  end

  attr :juror_id, :string, required: true
  attr :vote, :string, default: nil
  attr :is_active, :boolean, default: false

  defp juror_card(assigns) do
    ~H"""
    <div style={"margin: 2px 8px; padding: 7px 10px; border-radius: 6px; border: 1px solid #{if @is_active, do: "#8e44ad", else: "transparent"}; background: #{if @is_active, do: "rgba(30,40,60,0.8)", else: "transparent"};"}>
      <div style="display: flex; align-items: center; gap: 6px;">
        <span style="width: 7px; height: 7px; border-radius: 50%; background: #8e44ad; flex-shrink: 0;"></span>
        <span style="font-size: 10px; color: #8892a4; flex: 1; font-family: monospace;"><%= format_player_name(@juror_id) %></span>
        <%= if @vote do %>
          <span style={"font-size: 9px; font-weight: 700; color: #{if @vote == "guilty", do: "#c0392b", else: "#2980b9"};"}>
            <%= String.slice(@vote, 0, 1) |> String.upcase() %>
          </span>
        <% end %>
        <%= if @is_active do %>
          <span style="font-size: 9px; color: #d4af37;">&#x25B6;</span>
        <% end %>
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp get_player_by_role(players, role) do
    Enum.find(players, fn {_id, info} -> get_val(info, :role, nil) == role end)
  end

  defp get_players_by_role(players, role) do
    players
    |> Enum.filter(fn {_id, info} -> get_val(info, :role, nil) == role end)
    |> Enum.sort_by(fn {id, _} -> id end)
  end

  defp get_role_for(players, player_id) do
    case Map.get(players, player_id) do
      nil -> "unknown"
      info -> get_val(info, :role, "unknown")
    end
  end

  defp role_color("prosecution"), do: "#c0392b"
  defp role_color("defense"), do: "#2980b9"
  defp role_color("witness"), do: "#27ae60"
  defp role_color("juror"), do: "#8e44ad"
  defp role_color(_), do: "#8892a4"

  defp role_label("prosecution"), do: "Prosecution"
  defp role_label("defense"), do: "Defense"
  defp role_label("witness"), do: "Witness"
  defp role_label("juror"), do: "Juror"
  defp role_label(other), do: String.capitalize(to_string(other || ""))

  defp phase_label("opening_statements"), do: "OPENING"
  defp phase_label("prosecution_case"), do: "PROSECUTION"
  defp phase_label("cross_examination"), do: "CROSS"
  defp phase_label("defense_case"), do: "DEFENSE"
  defp phase_label("defense_cross"), do: "DEF. CROSS"
  defp phase_label("closing_arguments"), do: "CLOSING"
  defp phase_label("deliberation"), do: "DELIBERATION"
  defp phase_label("verdict"), do: "VERDICT"
  defp phase_label(other), do: String.upcase(to_string(other || ""))

  defp phase_color("opening_statements"), do: "#2980b9"
  defp phase_color("prosecution_case"), do: "#c0392b"
  defp phase_color("cross_examination"), do: "#e67e22"
  defp phase_color("defense_case"), do: "#2980b9"
  defp phase_color("defense_cross"), do: "#e67e22"
  defp phase_color("closing_arguments"), do: "#2980b9"
  defp phase_color("deliberation"), do: "#8e44ad"
  defp phase_color("verdict"), do: "#d4af37"
  defp phase_color(_), do: "#8892a4"

  defp phase_bg(phase) do
    color = phase_color(phase)
    "#{color}22"
  end

  defp verdict_label("guilty"), do: "GUILTY"
  defp verdict_label("not_guilty"), do: "NOT GUILTY"
  defp verdict_label("hung_jury"), do: "HUNG JURY"
  defp verdict_label(_), do: "CONCLUDED"

  defp verdict_color("guilty"), do: "#c0392b"
  defp verdict_color("not_guilty"), do: "#2980b9"
  defp verdict_color("hung_jury"), do: "#8892a4"
  defp verdict_color(_), do: "#d4af37"

  defp verdict_bg("guilty"), do: "rgba(192,57,43,0.08)"
  defp verdict_bg("not_guilty"), do: "rgba(41,128,185,0.08)"
  defp verdict_bg(_), do: "rgba(22,27,38,0.95)"

  defp verdict_border("guilty"), do: "rgba(192,57,43,0.4)"
  defp verdict_border("not_guilty"), do: "rgba(41,128,185,0.4)"
  defp verdict_border(_), do: "#252d3d"

  defp entry_type_label("statement"), do: "— statement"
  defp entry_type_label("question"), do: "— question"
  defp entry_type_label("challenge"), do: "— challenge"
  defp entry_type_label(other), do: "— #{other}"

  defp format_player_name(nil), do: "?"
  defp format_player_name("juror_" <> n), do: "Juror #{n}"
  defp format_player_name("witness_" <> n), do: "Witness #{n}"
  defp format_player_name(name), do: name

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_map, _key, default), do: default
end
