defmodule LemonSimUi.Live.Components.StartupIncubatorBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    players = MapHelpers.get_key(world, :players) || %{}
    startups = MapHelpers.get_key(world, :startups) || %{}
    investors_map = MapHelpers.get_key(world, :investors) || %{}
    phase = MapHelpers.get_key(world, :phase) || "pitch"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 5
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || []
    term_sheets = MapHelpers.get_key(world, :term_sheets) || %{}
    deal_history = MapHelpers.get_key(world, :deal_history) || []
    pitch_log = MapHelpers.get_key(world, :pitch_log) || []
    market_conditions = MapHelpers.get_key(world, :market_conditions) || %{}
    market_event_log = MapHelpers.get_key(world, :market_event_log) || []
    question_log = MapHelpers.get_key(world, :question_log) || []
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    journals = MapHelpers.get_key(world, :journals) || %{}

    # Sector colors
    sector_colors = %{
      "ai" => "#7c3aed",
      "fintech" => "#0891b2",
      "healthtech" => "#059669",
      "edtech" => "#d97706",
      "climatetech" => "#16a34a",
      "ecommerce" => "#dc2626"
    }

    # Player card colors (up to 8)
    player_colors = [
      "#e63946", "#457b9d", "#2a9d8f", "#e9c46a",
      "#a8dadc", "#f4a261", "#8338ec", "#fb5607"
    ]

    # Split and sort players by role
    sorted_founders =
      players
      |> Enum.filter(fn {_id, p} -> get_val(p, :role, "founder") == "founder" end)
      |> Enum.map(fn {pid, pdata} ->
        startup = Map.get(startups, pid, %{})
        valuation = get_val(startup, :valuation, 0)
        {to_string(pid), pdata, startup, valuation}
      end)
      |> Enum.sort_by(fn {_, _, _, val} -> val end, :desc)

    sorted_investors =
      players
      |> Enum.filter(fn {_id, p} -> get_val(p, :role, "founder") != "founder" end)
      |> Enum.map(fn {pid, pdata} ->
        investor = Map.get(investors_map, pid, %{})
        {to_string(pid), pdata, investor}
      end)
      |> Enum.sort_by(fn {pid, _, _} -> pid end)

    recent_deals = deal_history |> Enum.reverse() |> Enum.take(8) |> Enum.reverse()
    recent_pitches = pitch_log |> Enum.reverse() |> Enum.take(6) |> Enum.reverse()
    last_market_event = List.last(market_event_log)

    active_term_sheets =
      term_sheets
      |> Enum.filter(fn {_k, sheet} -> Map.get(sheet, "status") in ["pending", "countered"] end)
      |> Enum.map(fn {_k, sheet} -> sheet end)

    active_actor_str = if active_actor_id, do: to_string(active_actor_id), else: nil

    assigns =
      assigns
      |> assign(:players, players)
      |> assign(:startups, startups)
      |> assign(:investors_map, investors_map)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:active_actor_str, active_actor_str)
      |> assign(:turn_order, turn_order)
      |> assign(:term_sheets, term_sheets)
      |> assign(:active_term_sheets, active_term_sheets)
      |> assign(:deal_history, deal_history)
      |> assign(:recent_deals, recent_deals)
      |> assign(:pitch_log, pitch_log)
      |> assign(:recent_pitches, recent_pitches)
      |> assign(:market_conditions, market_conditions)
      |> assign(:market_event_log, market_event_log)
      |> assign(:last_market_event, last_market_event)
      |> assign(:question_log, question_log)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:journals, journals)
      |> assign(:sorted_founders, sorted_founders)
      |> assign(:sorted_investors, sorted_investors)
      |> assign(:sector_colors, sector_colors)
      |> assign(:player_colors, player_colors)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0a0d14; color: #e8edf5; min-height: 640px;">
      <style>
        /* ── Valuation Pulse ── */
        @keyframes si-val-pulse {
          0%, 100% { filter: brightness(1); }
          50% { filter: brightness(1.2); }
        }
        .si-val-active { animation: si-val-pulse 2.5s ease-in-out infinite; }

        /* ── Deal Flash ── */
        @keyframes si-deal-flash {
          0% { box-shadow: 0 0 0 0 rgba(0, 212, 170, 0.8); }
          50% { box-shadow: 0 0 24px 8px rgba(0, 212, 170, 0.3); }
          100% { box-shadow: 0 0 0 0 rgba(0, 212, 170, 0); }
        }
        .si-deal-closed { animation: si-deal-flash 2s ease-out; }

        /* ── Phase Breathe ── */
        @keyframes si-phase-breathe {
          0%, 100% { opacity: 0.65; }
          50% { opacity: 1; }
        }
        .si-phase-active { animation: si-phase-breathe 2s ease-in-out infinite; }

        /* ── Market Event Slide ── */
        @keyframes si-market-in {
          from { opacity: 0; transform: translateX(16px); }
          to { opacity: 1; transform: translateX(0); }
        }
        .si-market-item { animation: si-market-in 0.4s ease-out forwards; }

        /* ── Card Enter ── */
        @keyframes si-card-enter {
          from { opacity: 0; transform: translateY(8px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .si-card { animation: si-card-enter 0.3s ease-out forwards; }

        /* ── Winner Glow ── */
        @keyframes si-winner-glow {
          0%, 100% { box-shadow: 0 0 12px 2px rgba(0,212,170,0.4); }
          50% { box-shadow: 0 0 28px 8px rgba(0,212,170,0.7); }
        }
        .si-winner { animation: si-winner-glow 1.8s ease-in-out infinite; }

        /* ── Scanline ── */
        @keyframes si-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .si-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(0,212,170,0.1), transparent);
          animation: si-scanline 5s linear infinite;
          pointer-events: none;
        }
      </style>

      <!-- Header bar -->
      <div class="si-scanline relative flex items-center justify-between px-4 py-2"
           style="background: #131826; border-bottom: 1px solid #1e2a40; height: 52px;">
        <div class="flex items-center gap-3">
          <span class="text-xl font-bold tracking-wide" style="color: #00d4aa;">STARTUP INCUBATOR</span>
          <span class="text-xs px-2 py-0.5 rounded font-semibold"
                style={phase_badge_style(@phase)}>
            <%= String.upcase(String.replace(@phase, "_", " ")) %>
          </span>
        </div>

        <div class="flex items-center gap-6">
          <span class="text-sm font-semibold" style="color: #7a8ba0;">
            Round <span style="color: #e8edf5;"><%= @round %></span> / <%= @max_rounds %>
          </span>

          <%= if @active_actor_str do %>
            <span class="text-sm" style="color: #7a8ba0;">
              Active: <span class="font-semibold" style="color: #00d4aa;"><%= @active_actor_str %></span>
            </span>
          <% end %>

          <%= if @game_status == "won" and @winner do %>
            <span class="text-sm font-bold px-3 py-1 rounded si-winner"
                  style="background: rgba(0,212,170,0.15); color: #00d4aa; border: 1px solid #00d4aa;">
              WINNER: <%= @winner %>
            </span>
          <% end %>
        </div>
      </div>

      <!-- Main layout: sidebar | center | market panel -->
      <div class="flex" style="min-height: 588px;">

        <!-- Left sidebar: founders -->
        <div class="shrink-0 overflow-y-auto" style="width: 300px; border-right: 1px solid #1e2a40; background: #0a0d14;">
          <div class="px-3 py-2 text-xs font-bold tracking-widest"
               style="color: #1a5c52; background: #131826; border-bottom: 1px solid #1e2a40;">
            FOUNDERS
          </div>

          <%= for {pid, _pdata, startup, _val} <- @sorted_founders do %>
            <%
              f_idx = Enum.find_index(@turn_order, &(to_string(&1) == pid)) || 0
              color = Enum.at(@player_colors, f_idx, "#00d4aa")
              sector = get_val(startup, :sector, "unknown")
              sector_color = Map.get(@sector_colors, sector, "#7a8ba0")
              valuation = get_val(startup, :valuation, 0)
              traction = get_val(startup, :traction, 0)
              employees = get_val(startup, :employees, 0)
              cash = get_val(startup, :cash_on_hand, 0)
              funding = get_val(startup, :funding_raised, 0)
              is_active = @active_actor_str == pid
              is_winner = @winner && to_string(@winner) == pid
            %>
            <div class={"si-card p-3 border-b" <> if(is_active, do: " si-val-active", else: "") <> if(is_winner, do: " si-winner", else: "")}
                 style={"border-color: #1e2a40;" <> if(is_active, do: "background: rgba(#{hex_to_rgb(color)},0.05);", else: "")}>
              <div class="flex items-center justify-between mb-1">
                <div class="flex items-center gap-2">
                  <div class="w-2.5 h-2.5 rounded-full" style={"background: #{color};"}></div>
                  <span class="text-sm font-semibold" style={"color: #{color};"}><%= pid %></span>
                </div>
                <span class="text-xs font-bold px-1.5 py-0.5 rounded"
                      style={"background: #{sector_color}22; color: #{sector_color};"}>
                  <%= String.upcase(sector) %>
                </span>
              </div>

              <div class="grid grid-cols-2 gap-x-2 gap-y-0.5 mt-2 text-xs">
                <span style="color: #7a8ba0;">Valuation</span>
                <span class="text-right font-bold" style="color: #e8edf5;">$<%= format_num(valuation) %></span>
                <span style="color: #7a8ba0;">Traction</span>
                <span class="text-right" style="color: #e8edf5;"><%= traction %></span>
                <span style="color: #7a8ba0;">Employees</span>
                <span class="text-right" style="color: #e8edf5;"><%= employees %></span>
                <span style="color: #7a8ba0;">Cash</span>
                <span class="text-right" style="color: #e8edf5;">$<%= format_num(cash) %></span>
                <span style="color: #7a8ba0;">Raised</span>
                <span class="text-right" style="color: #e8edf5;">$<%= format_num(funding) %></span>
              </div>

              <%= if is_winner do %>
                <div class="mt-2 text-center text-xs font-bold" style="color: #00d4aa;">WINNER</div>
              <% end %>
            </div>
          <% end %>

          <!-- Investors section -->
          <div class="px-3 py-2 text-xs font-bold tracking-widest mt-2"
               style="color: #1a5c52; background: #131826; border-bottom: 1px solid #1e2a40; border-top: 1px solid #1e2a40;">
            INVESTORS
          </div>

          <%= for {pid, _pdata, investor} <- @sorted_investors do %>
            <%
              i_idx = Enum.find_index(@turn_order, &(to_string(&1) == pid)) || 0
              color = Enum.at(@player_colors, i_idx, "#7a8ba0")
              fund_size = get_val(investor, :fund_size, 0)
              remaining = get_val(investor, :remaining_capital, 0)
              portfolio = get_val(investor, :portfolio, [])
              deployed = fund_size - remaining
              pct = if fund_size > 0, do: round(deployed / fund_size * 100), else: 0
              is_active = @active_actor_str == pid
              is_winner = @winner && to_string(@winner) == pid
            %>
            <div class={"si-card p-3 border-b" <> if(is_active, do: " si-val-active", else: "") <> if(is_winner, do: " si-winner", else: "")}
                 style={"border-color: #1e2a40;" <> if(is_active, do: "background: rgba(#{hex_to_rgb(color)},0.05);", else: "")}>
              <div class="flex items-center gap-2 mb-2">
                <div class="w-2.5 h-2.5 rounded-full" style={"background: #{color};"}></div>
                <span class="text-sm font-semibold" style={"color: #{color};"}><%= pid %></span>
                <span class="text-xs px-1.5 py-0.5 rounded" style={"background: #{color}22; color: #{color};"}>VC</span>
              </div>

              <div class="grid grid-cols-2 gap-x-2 gap-y-0.5 text-xs">
                <span style="color: #7a8ba0;">Fund</span>
                <span class="text-right font-bold" style="color: #e8edf5;">$<%= format_num(fund_size) %></span>
                <span style="color: #7a8ba0;">Remaining</span>
                <span class="text-right" style="color: #e8edf5;">$<%= format_num(remaining) %></span>
                <span style="color: #7a8ba0;">Portfolio</span>
                <span class="text-right" style="color: #e8edf5;"><%= length(portfolio) %> cos.</span>
              </div>

              <!-- Deployment bar -->
              <div class="mt-2">
                <div class="flex justify-between text-xs mb-0.5" style="color: #7a8ba0;">
                  <span>Deployed</span>
                  <span><%= pct %>%</span>
                </div>
                <div class="h-1.5 rounded-full" style="background: #1e2a40;">
                  <div class="h-1.5 rounded-full transition-all duration-500"
                       style={"background: #{color}; width: #{pct}%;"}>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Center: phase content -->
        <div class="flex-1 flex flex-col overflow-hidden" style="min-width: 0;">

          <!-- Phase: Pitch -->
          <%= if @phase == "pitch" do %>
            <div class="p-4 flex-1 overflow-y-auto">
              <div class="text-xs font-bold tracking-widest mb-3" style="color: #1a5c52;">PITCH STAGE</div>

              <%= if @recent_pitches == [] do %>
                <div class="text-center py-8 text-sm" style="color: #3d4d60;">Awaiting pitches...</div>
              <% else %>
                <div class="space-y-3">
                  <%= for pitch <- @recent_pitches do %>
                    <%
                      fid = Map.get(pitch, "founder_id", Map.get(pitch, :founder_id, "?"))
                      text = Map.get(pitch, "pitch_text", Map.get(pitch, :pitch_text, ""))
                      rnd = Map.get(pitch, "round", Map.get(pitch, :round, "?"))
                      f_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(fid))) || 0
                      color = Enum.at(@player_colors, f_idx, "#7a8ba0")
                      startup = Map.get(@startups, fid, %{})
                      sector = get_val(startup, :sector, "?")
                      sc = Map.get(@sector_colors, sector, "#7a8ba0")
                    %>
                    <div class="si-card rounded-lg p-3" style="background: #131826; border: 1px solid #1e2a40;">
                      <div class="flex items-center justify-between mb-2">
                        <div class="flex items-center gap-2">
                          <div class="w-2 h-2 rounded-full" style={"background: #{color};"}></div>
                          <span class="text-sm font-semibold" style={"color: #{color};"}><%= fid %></span>
                          <span class="text-xs px-1 rounded" style={"background: #{sc}22; color: #{sc};"}><%= String.upcase(sector) %></span>
                        </div>
                        <span class="text-xs" style="color: #3d4d60;">R<%= rnd %></span>
                      </div>
                      <p class="text-sm leading-relaxed" style="color: #9db0c4;"><%= text %></p>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <!-- Phase: Due Diligence -->
          <%= if @phase == "due_diligence" do %>
            <div class="p-4 flex-1 overflow-y-auto">
              <div class="text-xs font-bold tracking-widest mb-3" style="color: #1a5c52;">DUE DILIGENCE</div>

              <div class="space-y-2">
                <%= for entry <- Enum.take(@question_log, -12) do %>
                  <%
                    is_question = not (Map.has_key?(entry, "answer") or Map.has_key?(entry, :answer))
                    actor_id_key = if is_question, do: "investor_id", else: "founder_id"
                    actor = Map.get(entry, actor_id_key, Map.get(entry, String.to_atom(actor_id_key), "?"))
                    text = if is_question,
                      do: Map.get(entry, "question", Map.get(entry, :question, "")),
                      else: Map.get(entry, "answer", Map.get(entry, :answer, ""))
                    a_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(actor))) || 0
                    color = Enum.at(@player_colors, a_idx, "#7a8ba0")
                    label = if is_question, do: "Q", else: "A"
                    bg = if is_question, do: "#0891b222", else: "#05996922"
                    text_color = if is_question, do: "#0891b2", else: "#059669"
                  %>
                  <div class="si-card flex gap-2 items-start p-2 rounded" style={"background: #{bg}; border: 1px solid #{text_color}33;"}>
                    <span class="text-xs font-bold mt-0.5 shrink-0 px-1 rounded" style={"background: #{text_color}33; color: #{text_color};"}><%= label %></span>
                    <div>
                      <span class="text-xs font-semibold" style={"color: #{color};"}><%= actor %></span>
                      <span class="text-xs ml-1" style="color: #9db0c4;"><%= text %></span>
                    </div>
                  </div>
                <% end %>

                <%= if @question_log == [] do %>
                  <div class="text-center py-8 text-sm" style="color: #3d4d60;">
                    Investors probing founders — truth is optional.
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <!-- Phase: Negotiation -->
          <%= if @phase == "negotiation" do %>
            <div class="p-4 flex-1 overflow-y-auto">
              <div class="text-xs font-bold tracking-widest mb-3" style="color: #1a5c52;">DEAL ROOM</div>

              <!-- Active term sheets -->
              <%= if @active_term_sheets != [] do %>
                <div class="mb-4">
                  <div class="text-xs mb-2" style="color: #7a8ba0;">ACTIVE TERM SHEETS</div>
                  <div class="space-y-2">
                    <%= for sheet <- @active_term_sheets do %>
                      <%
                        fid = Map.get(sheet, "founder_id", "?")
                        iid = Map.get(sheet, "investor_id", "?")
                        amount = Map.get(sheet, "amount", 0)
                        equity = Map.get(sheet, "equity_pct", 0)
                        st = Map.get(sheet, "status", "pending")
                        f_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(fid))) || 0
                        i_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(iid))) || 0
                        f_color = Enum.at(@player_colors, f_idx, "#7a8ba0")
                        i_color = Enum.at(@player_colors, i_idx, "#7a8ba0")
                        status_color = if st == "countered", do: "#d97706", else: "#0891b2"
                      %>
                      <div class="si-card rounded-lg p-2 flex items-center gap-2"
                           style="background: #131826; border: 1px solid #1e2a40;">
                        <div class="w-2 h-2 rounded-full" style={"background: #{i_color};"}></div>
                        <span class="text-xs font-semibold" style={"color: #{i_color};"}><%= iid %></span>
                        <span class="text-xs" style="color: #3d4d60;">&#x2192;</span>
                        <div class="w-2 h-2 rounded-full" style={"background: #{f_color};"}></div>
                        <span class="text-xs font-semibold" style={"color: #{f_color};"}><%= fid %></span>
                        <span class="flex-1 text-center text-xs font-bold" style="color: #00d4aa;">
                          $<%= format_num(amount) %> / <%= equity %>%
                        </span>
                        <span class="text-xs px-1.5 rounded font-semibold" style={"background: #{status_color}22; color: #{status_color};"}>
                          <%= String.upcase(st) %>
                        </span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <!-- Recent closed deals -->
              <div class="text-xs mb-2" style="color: #7a8ba0;">CLOSED DEALS</div>
              <%= if @recent_deals == [] do %>
                <div class="text-center py-6 text-sm" style="color: #3d4d60;">No deals closed yet</div>
              <% else %>
                <div class="space-y-1.5">
                  <%= for deal <- @recent_deals do %>
                    <%
                      fid = Map.get(deal, "founder_id", Map.get(deal, :founder_id, "?"))
                      iid = Map.get(deal, "investor_id", Map.get(deal, :investor_id, "?"))
                      amount = Map.get(deal, "amount", Map.get(deal, :amount, 0))
                      equity = Map.get(deal, "equity_pct", Map.get(deal, :equity_pct, 0))
                      rnd = Map.get(deal, "round", Map.get(deal, :round, "?"))
                      f_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(fid))) || 0
                      i_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(iid))) || 0
                      f_color = Enum.at(@player_colors, f_idx, "#7a8ba0")
                      i_color = Enum.at(@player_colors, i_idx, "#7a8ba0")
                    %>
                    <div class="si-deal-closed rounded p-2 flex items-center gap-2 text-xs"
                         style="background: rgba(0,212,170,0.05); border: 1px solid rgba(0,212,170,0.2);">
                      <div class="w-1.5 h-1.5 rounded-full" style={"background: #{i_color};"}></div>
                      <span style={"color: #{i_color};"}><%= iid %></span>
                      <span class="font-bold" style="color: #00d4aa;">$<%= format_num(amount) %> / <%= equity %>%</span>
                      <span style={"color: #{f_color};"}><%= fid %></span>
                      <span class="ml-auto" style="color: #3d4d60;">R<%= rnd %></span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <!-- Phase: Operations -->
          <%= if @phase == "operations" do %>
            <div class="p-4 flex-1 overflow-y-auto">
              <div class="text-xs font-bold tracking-widest mb-3" style="color: #1a5c52;">OPERATIONS</div>

              <%= if @last_market_event do %>
                <%
                  event_name = Map.get(@last_market_event, "name", Map.get(@last_market_event, :name, "Market Event"))
                  event_desc = Map.get(@last_market_event, "description", Map.get(@last_market_event, :description, ""))
                %>
                <div class="si-market-item mb-4 rounded-lg p-3" style="background: rgba(220,38,38,0.08); border: 1px solid rgba(220,38,38,0.3);">
                  <div class="text-sm font-bold mb-1" style="color: #dc2626;"><%= event_name %></div>
                  <p class="text-xs" style="color: #9db0c4;"><%= event_desc %></p>
                </div>
              <% end %>

              <div class="text-xs mb-2" style="color: #7a8ba0;">ALLOCATING RESOURCES</div>
              <div class="text-center py-6 text-sm" style="color: #3d4d60;">
                Founders deploying capital...
              </div>
            </div>
          <% end %>

          <!-- Market event phase (auto) -->
          <%= if @phase == "market_event" do %>
            <div class="p-4 flex-1 flex items-center justify-center">
              <div class="text-center">
                <div class="text-lg font-bold mb-2" style="color: #dc2626;">MARKET EVENT</div>
                <div class="text-sm" style="color: #7a8ba0;">Sector conditions shifting...</div>
              </div>
            </div>
          <% end %>

        </div>

        <!-- Right panel: market conditions -->
        <div class="shrink-0 overflow-y-auto" style="width: 260px; border-left: 1px solid #1e2a40; background: #0a0d14;">
          <div class="px-3 py-2 text-xs font-bold tracking-widest"
               style="color: #1a5c52; background: #131826; border-bottom: 1px solid #1e2a40;">
            MARKET
          </div>

          <div class="p-3 space-y-3">
            <%= for {sector, multiplier} <- Enum.sort(@market_conditions) do %>
              <%
                sc = Map.get(@sector_colors, sector, "#7a8ba0")
                pct = min(trunc(multiplier / 20.0 * 100), 100)
              %>
              <div class="si-market-item">
                <div class="flex justify-between items-center mb-1">
                  <span class="text-xs font-bold" style={"color: #{sc};"}><%= String.upcase(sector) %></span>
                  <span class="text-xs font-bold" style="color: #e8edf5;"><%= Float.round(multiplier * 1.0, 1) %>x</span>
                </div>
                <div class="h-1.5 rounded-full" style="background: #1e2a40;">
                  <div class="h-1.5 rounded-full transition-all duration-700"
                       style={"background: #{sc}; width: #{pct}%;"}>
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @last_market_event do %>
              <div class="mt-4 pt-3" style="border-top: 1px solid #1e2a40;">
                <div class="text-xs mb-1" style="color: #7a8ba0;">LAST EVENT</div>
                <div class="text-xs font-semibold" style="color: #dc2626;">
                  <%= Map.get(@last_market_event, "name", Map.get(@last_market_event, :name, "")) %>
                </div>
              </div>
            <% end %>
          </div>

          <!-- Recent deals in sidebar -->
          <div class="px-3 py-2 text-xs font-bold tracking-widest mt-2"
               style="color: #1a5c52; background: #131826; border-bottom: 1px solid #1e2a40; border-top: 1px solid #1e2a40;">
            RECENT DEALS
          </div>

          <div class="p-2 space-y-1.5">
            <%= for deal <- Enum.take(@recent_deals, 6) do %>
              <%
                fid = Map.get(deal, "founder_id", Map.get(deal, :founder_id, "?"))
                iid = Map.get(deal, "investor_id", Map.get(deal, :investor_id, "?"))
                amount = Map.get(deal, "amount", Map.get(deal, :amount, 0))
                equity = Map.get(deal, "equity_pct", Map.get(deal, :equity_pct, 0))
                f_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(fid))) || 0
                i_idx = Enum.find_index(@turn_order, &(to_string(&1) == to_string(iid))) || 0
                f_color = Enum.at(@player_colors, f_idx, "#7a8ba0")
                i_color = Enum.at(@player_colors, i_idx, "#7a8ba0")
              %>
              <div class="text-xs rounded p-1.5" style="background: #131826;">
                <span class="font-semibold" style={"color: #{i_color};"}><%= iid %></span>
                <span class="mx-1" style="color: #00d4aa;">$<%= format_num(amount) %></span>
                <span style={"color: #{f_color};"}><%= fid %></span>
                <div class="text-xs" style="color: #3d4d60;"><%= equity %>% equity</div>
              </div>
            <% end %>

            <%= if @recent_deals == [] do %>
              <div class="text-center py-4 text-xs" style="color: #3d4d60;">No deals yet</div>
            <% end %>
          </div>
        </div>

      </div>

      <!-- Footer -->
      <div class="flex items-center justify-center px-4"
           style="background: #131826; border-top: 1px solid #1e2a40; height: 48px;">
        <span class="text-sm" style="color: #e8edf5;">
          <%= footer_text(assigns) %>
        </span>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp phase_badge_style("pitch"),         do: "background: rgba(124,58,237,0.2); color: #7c3aed;"
  defp phase_badge_style("due_diligence"), do: "background: rgba(8,145,178,0.2); color: #0891b2;"
  defp phase_badge_style("negotiation"),   do: "background: rgba(217,119,6,0.2); color: #d97706;"
  defp phase_badge_style("market_event"),  do: "background: rgba(220,38,38,0.2); color: #dc2626;"
  defp phase_badge_style("operations"),    do: "background: rgba(5,150,105,0.2); color: #059669;"
  defp phase_badge_style(_),               do: "background: rgba(122,139,160,0.2); color: #7a8ba0;"

  defp footer_text(assigns) do
    cond do
      assigns.game_status == "won" and assigns.winner ->
        "#{assigns.winner} wins the Startup Incubator!"

      assigns.recent_deals != [] ->
        deal = List.last(assigns.recent_deals)
        fid = Map.get(deal, "founder_id", Map.get(deal, :founder_id, "?"))
        iid = Map.get(deal, "investor_id", Map.get(deal, :investor_id, "?"))
        amount = Map.get(deal, "amount", Map.get(deal, :amount, 0))
        "Latest deal: #{iid} invested $#{format_num(amount)} in #{fid}"

      assigns.last_market_event ->
        name = Map.get(assigns.last_market_event, "name", Map.get(assigns.last_market_event, :name, "Market Event"))
        "Market event: #{name}"

      assigns.active_actor_str ->
        phase_label =
          case assigns.phase do
            "pitch" -> "pitching"
            "due_diligence" -> "in due diligence"
            "negotiation" -> "negotiating"
            "operations" -> "allocating funds"
            _ -> "acting"
          end

        "#{assigns.active_actor_str} is #{phase_label}... Round #{assigns.round}/#{assigns.max_rounds}"

      true ->
        "Round #{assigns.round}/#{assigns.max_rounds} — #{String.replace(assigns.phase, "_", " ")} phase"
    end
  end

  defp format_num(n) when is_number(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_num(n) when is_number(n) and n >= 1_000 do
    "#{trunc(Float.round(n / 1_000, 0))}K"
  end

  defp format_num(n) when is_number(n), do: "#{trunc(n)}"
  defp format_num(n), do: to_string(n)

  # Convert hex color to "r,g,b" for rgba() use
  defp hex_to_rgb("#" <> hex) when byte_size(hex) == 6 do
    {r, _} = Integer.parse(binary_part(hex, 0, 2), 16)
    {g, _} = Integer.parse(binary_part(hex, 2, 2), 16)
    {b, _} = Integer.parse(binary_part(hex, 4, 2), 16)
    "#{r},#{g},#{b}"
  end

  defp hex_to_rgb(_), do: "0,212,170"

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_map, _key, default), do: default
end
