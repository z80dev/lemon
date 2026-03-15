defmodule LemonSimUi.Live.Components.AuctionBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr :world, :map, required: true
  attr :interactive, :boolean, default: false

  def render(assigns) do
    world = assigns.world
    players = MapHelpers.get_key(world, :players) || %{}
    auction_schedule = MapHelpers.get_key(world, :auction_schedule) || []
    current_round = MapHelpers.get_key(world, :current_round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 8
    current_item = MapHelpers.get_key(world, :current_item)
    current_item_index = MapHelpers.get_key(world, :current_item_index) || 0
    high_bid = MapHelpers.get_key(world, :high_bid) || 0
    high_bidder = MapHelpers.get_key(world, :high_bidder)
    active_bidders = MapHelpers.get_key(world, :active_bidders) || []
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    turn_order = MapHelpers.get_key(world, :turn_order) || []
    bid_history = MapHelpers.get_key(world, :bid_history) || []
    auction_results = MapHelpers.get_key(world, :auction_results) || []
    phase = MapHelpers.get_key(world, :phase) || "bidding"
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    scores = MapHelpers.get_key(world, :scores) || %{}
    traits = MapHelpers.get_key(world, :traits) || %{}
    connections = MapHelpers.get_key(world, :connections) || []
    journals = MapHelpers.get_key(world, :journals) || %{}

    sorted_players = Enum.sort_by(players, fn {id, _p} -> to_string(id) end)

    # Determine which items in schedule are completed vs upcoming
    completed_indices = MapSet.new(Enum.map(auction_results, fn r -> get_val(r, :item_index, -1) end))

    upcoming_items =
      auction_schedule
      |> Enum.with_index()
      |> Enum.reject(fn {_item, idx} -> MapSet.member?(completed_indices, idx) or idx == current_item_index end)
      |> Enum.filter(fn {_item, idx} -> idx > current_item_index end)
      |> Enum.take(6)

    # Recent bids (last 12)
    recent_bids = Enum.take(Enum.reverse(bid_history), 12)

    # Recent auction results (last 8)
    recent_results = Enum.take(Enum.reverse(auction_results), 8)

    # Current item category
    current_category =
      if current_item do
        get_val(current_item, :category, "artifact")
      else
        "artifact"
      end

    # Just-sold detection (last result matches current item index - 1)
    last_result = List.first(Enum.reverse(auction_results))

    just_sold =
      last_result != nil and
        length(auction_results) > 0 and
        status == "in_progress" and
        phase == "bidding" and
        high_bid == 0

    # Score ranking for victory
    score_ranking =
      scores
      |> Enum.map(fn {pid, sdata} ->
        total = get_val(sdata, :total, 0)
        {to_string(pid), sdata, total}
      end)
      |> Enum.sort_by(fn {_, _, total} -> total end, :desc)

    assigns =
      assigns
      |> assign(:players, players)
      |> assign(:sorted_players, sorted_players)
      |> assign(:auction_schedule, auction_schedule)
      |> assign(:current_round, current_round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:current_item, current_item)
      |> assign(:current_item_index, current_item_index)
      |> assign(:high_bid, high_bid)
      |> assign(:high_bidder, high_bidder)
      |> assign(:active_bidders, active_bidders)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:turn_order, turn_order)
      |> assign(:bid_history, bid_history)
      |> assign(:recent_bids, recent_bids)
      |> assign(:auction_results, auction_results)
      |> assign(:recent_results, recent_results)
      |> assign(:upcoming_items, upcoming_items)
      |> assign(:phase, phase)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:scores, scores)
      |> assign(:score_ranking, score_ranking)
      |> assign(:current_category, current_category)
      |> assign(:just_sold, just_sold)
      |> assign(:completed_indices, completed_indices)
      |> assign(:traits, traits)
      |> assign(:connections, connections)
      |> assign(:journals, journals)

    ~H"""
    <div class="ah-board relative font-sans w-full min-h-[700px] flex flex-col rounded-xl overflow-hidden">
      <style>
        /* ── Base Auction House Aesthetic ─────────────────────────── */
        .ah-board {
          background: linear-gradient(170deg, #0a0515 0%, #0d0f24 40%, #111827 100%);
          color: #e2e8f0;
        }

        /* ── Gavel Strike ── */
        @keyframes ah-gavel-strike {
          0% { transform: rotate(0deg); }
          20% { transform: rotate(-25deg); }
          40% { transform: rotate(5deg); }
          60% { transform: rotate(-3deg); }
          80% { transform: rotate(1deg); }
          100% { transform: rotate(0deg); }
        }
        .ah-gavel-strike { animation: ah-gavel-strike 0.6s ease-out; }

        /* ── Active Bidder Glow ── */
        @keyframes ah-active-glow {
          0%, 100% { box-shadow: 0 0 6px 2px rgba(6, 182, 212, 0.3); }
          50% { box-shadow: 0 0 20px 6px rgba(6, 182, 212, 0.6); }
        }
        .ah-active-glow { animation: ah-active-glow 2s ease-in-out infinite; }

        /* ── Bid Pulse ── */
        @keyframes ah-bid-pulse {
          0% { transform: scale(1); }
          50% { transform: scale(1.05); }
          100% { transform: scale(1); }
        }
        .ah-bid-pulse { animation: ah-bid-pulse 1.5s ease-in-out infinite; }

        /* ── Item Shimmer ── */
        @keyframes ah-item-shimmer {
          0% { background-position: -200% center; }
          100% { background-position: 200% center; }
        }
        .ah-item-shimmer {
          background: linear-gradient(90deg, transparent 0%, rgba(255,255,255,0.05) 50%, transparent 100%);
          background-size: 200% 100%;
          animation: ah-item-shimmer 3s linear infinite;
        }

        /* ── SOLD Flash ── */
        @keyframes ah-sold-flash {
          0% { opacity: 0; transform: scale(0.5) rotate(-5deg); }
          30% { opacity: 1; transform: scale(1.1) rotate(2deg); }
          60% { transform: scale(0.95) rotate(-1deg); }
          100% { opacity: 1; transform: scale(1) rotate(0deg); }
        }
        .ah-sold-flash { animation: ah-sold-flash 0.8s ease-out forwards; }

        /* ── Gold Shine ── */
        @keyframes ah-gold-shine {
          0%, 100% { text-shadow: 0 0 4px rgba(245, 158, 11, 0.3); }
          50% { text-shadow: 0 0 12px rgba(245, 158, 11, 0.7); }
        }
        .ah-gold-shine { animation: ah-gold-shine 2s ease-in-out infinite; }

        /* ── Category Glow Borders ── */
        @keyframes ah-cat-glow-purple {
          0%, 100% { box-shadow: 0 0 8px 1px rgba(139, 92, 246, 0.2), inset 0 0 8px 1px rgba(139, 92, 246, 0.05); }
          50% { box-shadow: 0 0 16px 3px rgba(139, 92, 246, 0.4), inset 0 0 12px 2px rgba(139, 92, 246, 0.1); }
        }
        @keyframes ah-cat-glow-amber {
          0%, 100% { box-shadow: 0 0 8px 1px rgba(245, 158, 11, 0.2), inset 0 0 8px 1px rgba(245, 158, 11, 0.05); }
          50% { box-shadow: 0 0 16px 3px rgba(245, 158, 11, 0.4), inset 0 0 12px 2px rgba(245, 158, 11, 0.1); }
        }
        @keyframes ah-cat-glow-blue {
          0%, 100% { box-shadow: 0 0 8px 1px rgba(6, 182, 212, 0.2), inset 0 0 8px 1px rgba(6, 182, 212, 0.05); }
          50% { box-shadow: 0 0 16px 3px rgba(6, 182, 212, 0.4), inset 0 0 12px 2px rgba(6, 182, 212, 0.1); }
        }
        .ah-glow-gem { animation: ah-cat-glow-purple 3s ease-in-out infinite; }
        .ah-glow-artifact { animation: ah-cat-glow-amber 3s ease-in-out infinite; }
        .ah-glow-scroll { animation: ah-cat-glow-blue 3s ease-in-out infinite; }

        /* ── Bid Feed Entry ── */
        @keyframes ah-feed-in {
          from { opacity: 0; transform: translateX(20px); }
          to { opacity: 1; transform: translateX(0); }
        }
        .ah-feed-entry { animation: ah-feed-in 0.3s ease-out forwards; }

        /* ── Victory Banner ── */
        @keyframes ah-victory-pulse {
          0%, 100% { transform: scale(1); opacity: 1; }
          50% { transform: scale(1.02); opacity: 0.95; }
        }
        .ah-victory { animation: ah-victory-pulse 2s ease-in-out infinite; }

        @keyframes ah-crown-float {
          0%, 100% { transform: translateY(0); }
          50% { transform: translateY(-4px); }
        }
        .ah-crown-float { animation: ah-crown-float 2s ease-in-out infinite; }

        /* ── Progress Bar Fill ── */
        @keyframes ah-bar-fill {
          from { width: 0%; }
        }
        .ah-bar-anim { animation: ah-bar-fill 0.8s ease-out forwards; }

        /* ── Scrollbar ── */
        .ah-scroll::-webkit-scrollbar { width: 4px; }
        .ah-scroll::-webkit-scrollbar-track { background: rgba(15, 23, 42, 0.5); }
        .ah-scroll::-webkit-scrollbar-thumb { background: rgba(51, 65, 85, 0.6); border-radius: 2px; }

        /* ── Item Card Hover ── */
        .ah-item-card {
          transition: transform 0.2s ease, box-shadow 0.2s ease;
        }
        .ah-item-card:hover {
          transform: translateY(-1px);
        }
      </style>

      <%!-- ════════════════════════════════════ TOP STATUS BAR ════════════════════════════════════ --%>
      <div class="border-b" style="border-color: rgba(139, 92, 246, 0.15); background: linear-gradient(180deg, #0f0a20 0%, #0a0515 100%);">
        <div class="flex items-center justify-between px-4 py-2.5">
          <div class="flex items-center gap-4">
            <%!-- Gavel Icon + Title --%>
            <div class="flex items-center gap-2">
              <span class="text-lg" style="filter: drop-shadow(0 0 4px rgba(245, 158, 11, 0.4));">&#128296;</span>
              <span class="text-sm font-bold uppercase tracking-widest" style="color: #f59e0b; text-shadow: 0 0 8px rgba(245, 158, 11, 0.3);">Auction House</span>
            </div>

            <%!-- Round Badge --%>
            <div class="flex items-center gap-2">
              <div class="text-xs font-mono uppercase tracking-widest" style="color: #475569;">Round</div>
              <div class="flex items-center gap-1 px-2.5 py-1 rounded-lg font-bold text-sm font-mono" style="background: rgba(139, 92, 246, 0.1); border: 1px solid rgba(139, 92, 246, 0.2); color: #e2e8f0;">
                <span>{@current_round}</span>
                <span class="text-xs font-normal" style="color: #64748b;">/ {@max_rounds}</span>
              </div>
            </div>

            <%!-- Phase Badge --%>
            <div class={[
              "px-3 py-1 rounded-full text-xs font-bold uppercase tracking-wider border",
              phase_badge_class(@phase)
            ]}>
              {phase_label(@phase)}
            </div>

            <%!-- Active Player --%>
            <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-2">
              <div class="w-1 h-4 rounded-full" style="background: #06b6d4;"></div>
              <span class="text-xs" style="color: #94a3b8;">Bidding:</span>
              <span class="text-xs font-bold px-2 py-0.5 rounded" style="background: rgba(6, 182, 212, 0.15); color: #06b6d4; border: 1px solid rgba(6, 182, 212, 0.3);">
                {player_name(@active_actor_id, @players)}
              </span>
            </div>
          </div>

          <%!-- Auction Status Indicator --%>
          <div class="flex items-center gap-3">
            <div :if={@game_status == "in_progress"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full animate-pulse" style="background: #f59e0b;"></div>
              <span class="text-xs font-mono uppercase" style="color: #f59e0b;">Auction Active</span>
            </div>
            <div :if={@game_status == "game_over"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full" style="background: #ef4444;"></div>
              <span class="text-xs font-mono uppercase" style="color: #ef4444;">Auction Closed</span>
            </div>
            <%!-- Item Progress --%>
            <div class="flex items-center gap-1.5 px-2 py-0.5 rounded" style="background: rgba(30, 41, 59, 0.5); border: 1px solid #1e293b;">
              <span class="text-[10px] font-mono" style="color: #64748b;">Items</span>
              <span class="text-xs font-bold font-mono" style="color: #94a3b8;">
                {length(@auction_results)}/{length(@auction_schedule)}
              </span>
            </div>
          </div>
        </div>

        <%!-- Round Progress Bar --%>
        <div class="h-0.5" style="background: rgba(30, 41, 59, 0.5);">
          <div
            class="h-full ah-bar-anim"
            style={"background: linear-gradient(90deg, #8b5cf6, #f59e0b); width: #{round_progress(@current_round, @max_rounds)}%;"}
          ></div>
        </div>
      </div>

      <%!-- ════════════════════════════════════ MAIN LAYOUT ════════════════════════════════════ --%>
      <div class="flex flex-1" style="min-height: 550px;">

        <%!-- ──────── LEFT PANEL: Player Roster ──────── --%>
        <div class="flex-shrink-0 border-r overflow-y-auto ah-scroll" style="width: 256px; border-color: rgba(139, 92, 246, 0.1); background: rgba(10, 5, 21, 0.6);">
          <div class="px-3 py-2 border-b" style="border-color: rgba(139, 92, 246, 0.1);">
            <div class="flex items-center gap-2">
              <div class="w-1.5 h-1.5 rounded-full" style="background: #8b5cf6;"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(139, 92, 246, 0.6);">Bidders</span>
              <span class="ml-auto text-[10px] font-mono" style="color: #475569;">{map_size(@players)}</span>
            </div>
          </div>

          <div class="p-2 space-y-2">
            <%= for {pid, pdata} <- @sorted_players do %>
              <% is_active = to_string(@active_actor_id) == to_string(pid) %>
              <% is_active_bidder = to_string(pid) in Enum.map(@active_bidders, &to_string/1) %>
              <% is_high_bidder = @high_bidder != nil and to_string(@high_bidder) == to_string(pid) %>
              <% name = get_val(pdata, :name, to_string(pid)) %>
              <% gold = get_val(pdata, :gold, 0) %>
              <% items = get_val(pdata, :items, []) %>
              <% p_status = get_val(pdata, :status, "active") %>
              <% objective = get_val(pdata, :secret_objective, nil) %>
              <div class={[
                "rounded-lg p-2.5 border transition-all",
                if(is_active, do: "ah-active-glow", else: ""),
                if(p_status != "active" and not is_active_bidder, do: "opacity-50", else: "")
              ]} style={player_card_style(is_active, is_high_bidder)}>
                <%!-- Name Row --%>
                <div class="flex items-center justify-between mb-1.5">
                  <div class="flex items-center gap-1.5">
                    <div class="w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold" style={player_avatar_style(pid)}>
                      {String.first(to_string(name)) |> String.upcase()}
                    </div>
                    <span class="text-xs font-bold truncate" style={"color: #{if is_active, do: "#06b6d4", else: if(is_high_bidder, do: "#f59e0b", else: "#e2e8f0")}; max-width: 110px;"}>
                      {name}
                    </span>
                  </div>
                  <div class="flex items-center gap-1">
                    <span :if={is_high_bidder} class="text-[9px] font-bold px-1.5 py-0.5 rounded" style="background: rgba(245, 158, 11, 0.15); color: #f59e0b; border: 1px solid rgba(245, 158, 11, 0.3);">
                      HIGH
                    </span>
                    <span :if={not is_active_bidder and @phase == "bidding" and @game_status == "in_progress"} class="text-[9px] px-1.5 py-0.5 rounded" style="background: rgba(71, 85, 105, 0.2); color: #64748b;">
                      OUT
                    </span>
                  </div>
                </div>

                <%!-- Trait Badges --%>
                <% player_traits = Map.get(@traits, name, Map.get(@traits, to_string(pid), [])) %>
                <div :if={player_traits != []} class="flex flex-wrap gap-1 mb-1.5">
                  <%= for trait <- player_traits do %>
                    <span class="text-[8px] font-semibold px-1.5 py-0.5 rounded-full" style="background: rgba(139, 92, 246, 0.12); color: #c4b5fd; border: 1px solid rgba(139, 92, 246, 0.25);">
                      {trait}
                    </span>
                  <% end %>
                </div>

                <%!-- Gold Bar --%>
                <div class="flex items-center gap-1.5 mb-1.5">
                  <span class="text-[10px]" style="color: #64748b;">Gold</span>
                  <div class="flex-1 h-2 rounded-full overflow-hidden" style="background: rgba(30, 41, 59, 0.5);">
                    <div class="h-full rounded-full ah-bar-anim" style={"background: linear-gradient(90deg, #b45309, #f59e0b); width: #{gold_bar_pct(gold, @sorted_players)};"}></div>
                  </div>
                  <span class="text-[10px] font-bold font-mono ah-gold-shine" style="color: #f59e0b; min-width: 28px; text-align: right;">
                    {gold}g
                  </span>
                </div>

                <%!-- Items Won (category dots) --%>
                <div class="flex items-center gap-1 flex-wrap">
                  <span :if={items == []} class="text-[9px]" style="color: #475569;">No items</span>
                  <%= for item <- items do %>
                    <% cat = get_val(item, :category, "artifact") %>
                    <div
                      class="w-3 h-3 rounded-full border"
                      style={category_dot_style(cat)}
                      title={get_val(item, :name, "Item")}
                    ></div>
                  <% end %>
                </div>

                <%!-- Secret Objective Hint --%>
                <div :if={objective} class="mt-1.5 px-1.5 py-1 rounded text-[9px] truncate" style="background: rgba(139, 92, 246, 0.06); border: 1px solid rgba(139, 92, 246, 0.1); color: #a78bfa;" title={objective}>
                  &#128270; {truncate_text(objective, 30)}
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- ──────── CENTER PANEL: Auction Block ──────── --%>
        <div class="flex-1 flex flex-col overflow-y-auto ah-scroll" style="background: rgba(13, 15, 36, 0.4);">

          <%!-- Current Item Display --%>
          <div class="p-4 flex-shrink-0">
            <div :if={@current_item && @game_status == "in_progress"} class="relative">
              <%!-- Item Showcase Card --%>
              <div class={[
                "relative rounded-xl border p-6 ah-item-shimmer",
                category_glow_class(@current_category)
              ]} style={current_item_card_style(@current_category)}>

                <%!-- Category Badge (top-left) --%>
                <div class="absolute top-3 left-3">
                  <span class="px-2.5 py-1 rounded-full text-[10px] font-bold uppercase tracking-wider border" style={category_badge_style(@current_category)}>
                    {category_icon(@current_category)} {get_val(@current_item, :category, "item")}
                  </span>
                </div>

                <%!-- Item Index (top-right) --%>
                <div class="absolute top-3 right-3">
                  <span class="text-[10px] font-mono px-2 py-0.5 rounded" style="background: rgba(30, 41, 59, 0.6); color: #64748b; border: 1px solid rgba(51, 65, 85, 0.3);">
                    Lot #{@current_item_index + 1}
                  </span>
                </div>

                <%!-- Item Name --%>
                <div class="text-center mt-6 mb-4">
                  <div class="text-2xl font-bold tracking-wide" style={category_name_style(@current_category)}>
                    {get_val(@current_item, :name, "Unknown Item")}
                  </div>
                  <div class="text-xs mt-1" style="color: #64748b;">
                    Base Value: <span class="font-bold font-mono" style="color: #94a3b8;">{get_val(@current_item, :base_value, 0)}g</span>
                  </div>
                </div>

                <%!-- Category Decorative Icon (large, centered, faded) --%>
                <div class="flex justify-center mb-4">
                  <span class="text-5xl" style={"opacity: 0.15; filter: #{category_icon_filter(@current_category)};"}>
                    {category_large_icon(@current_category)}
                  </span>
                </div>

                <%!-- Bidding Info --%>
                <div class="flex items-center justify-center gap-8">
                  <%!-- Current High Bid --%>
                  <div class="text-center">
                    <div class="text-[10px] uppercase tracking-wider mb-1" style="color: #64748b;">High Bid</div>
                    <div class={["text-3xl font-bold font-mono", if(@high_bid > 0, do: "ah-bid-pulse", else: "")]} style="color: #f59e0b; text-shadow: 0 0 12px rgba(245, 158, 11, 0.4);">
                      {if @high_bid > 0, do: "#{@high_bid}g", else: "---"}
                    </div>
                  </div>

                  <%!-- Divider --%>
                  <div class="w-px h-12" style="background: rgba(71, 85, 105, 0.3);"></div>

                  <%!-- High Bidder --%>
                  <div class="text-center">
                    <div class="text-[10px] uppercase tracking-wider mb-1" style="color: #64748b;">Leading</div>
                    <div class="text-lg font-bold" style={"color: #{if @high_bidder, do: "#06b6d4", else: "#475569"};"}>
                      {if @high_bidder, do: player_name(@high_bidder, @players), else: "No bids"}
                    </div>
                  </div>

                  <%!-- Divider --%>
                  <div class="w-px h-12" style="background: rgba(71, 85, 105, 0.3);"></div>

                  <%!-- Active Bidders Count --%>
                  <div class="text-center">
                    <div class="text-[10px] uppercase tracking-wider mb-1" style="color: #64748b;">Bidders Left</div>
                    <div class="text-lg font-bold font-mono" style="color: #a78bfa;">
                      {length(@active_bidders)}
                    </div>
                  </div>
                </div>

                <%!-- SOLD Overlay --%>
                <div :if={@just_sold} class="absolute inset-0 flex items-center justify-center rounded-xl" style="background: rgba(10, 5, 21, 0.85); z-index: 10;">
                  <div class="ah-sold-flash text-center">
                    <div class="text-5xl font-black tracking-widest" style="color: #f59e0b; text-shadow: 0 0 24px rgba(245, 158, 11, 0.6), 0 0 48px rgba(245, 158, 11, 0.3);">
                      SOLD!
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <%!-- No Current Item Placeholder --%>
            <div :if={@current_item == nil and @game_status == "in_progress"} class="rounded-xl border p-8 text-center" style="background: rgba(15, 23, 42, 0.4); border-color: rgba(51, 65, 85, 0.3);">
              <div class="text-sm" style="color: #64748b;">Preparing next lot...</div>
            </div>
          </div>

          <%!-- Auction Schedule --%>
          <div class="px-4 pb-4 flex-1">
            <div class="flex items-center gap-2 mb-3">
              <div class="w-1.5 h-1.5 rounded-full" style="background: #64748b;"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(100, 116, 139, 0.7);">Auction Schedule</span>
            </div>

            <%!-- Completed Auctions --%>
            <div :if={@auction_results != []} class="mb-3">
              <div class="text-[9px] uppercase tracking-wider mb-1.5" style="color: #475569;">Completed</div>
              <div class="flex flex-wrap gap-1.5">
                <%= for result <- @recent_results do %>
                  <% r_item = get_val(result, :item, %{}) %>
                  <% r_name = get_val(r_item, :name, get_val(result, :item_name, "?")) %>
                  <% r_cat = get_val(r_item, :category, get_val(result, :category, "artifact")) %>
                  <% r_winner_id = get_val(result, :winner, nil) %>
                  <% r_price = get_val(result, :price, 0) %>
                  <div class="ah-item-card px-2 py-1.5 rounded-lg border text-[10px]" style={completed_item_style(r_cat)}>
                    <div class="font-bold truncate" style={"color: #{category_text_color(r_cat)}; max-width: 90px;"}>
                      {category_icon(r_cat)} {r_name}
                    </div>
                    <div class="flex items-center gap-1 mt-0.5" style="color: #64748b;">
                      <span class="font-mono">{r_price}g</span>
                      <span>&rarr;</span>
                      <span class="truncate" style="max-width: 50px;">{if r_winner_id, do: player_name(r_winner_id, @players), else: "?"}</span>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Upcoming Items --%>
            <div :if={@upcoming_items != []}>
              <div class="text-[9px] uppercase tracking-wider mb-1.5" style="color: #475569;">Upcoming</div>
              <div class="flex flex-wrap gap-1.5">
                <%= for {item, _idx} <- @upcoming_items do %>
                  <% u_name = get_val(item, :name, "?") %>
                  <% u_cat = get_val(item, :category, "artifact") %>
                  <% u_val = get_val(item, :base_value, 0) %>
                  <div class="ah-item-card px-2 py-1.5 rounded-lg border text-[10px]" style={upcoming_item_style(u_cat)}>
                    <div class="font-semibold truncate" style={"color: #{category_text_color(u_cat)}; opacity: 0.7; max-width: 90px;"}>
                      {category_icon(u_cat)} {u_name}
                    </div>
                    <div class="font-mono mt-0.5" style="color: #475569;">{u_val}g</div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- ──────── RIGHT PANEL: Bid Feed & History ──────── --%>
        <div class="flex-shrink-0 border-l overflow-y-auto ah-scroll" style="width: 224px; border-color: rgba(139, 92, 246, 0.1); background: rgba(10, 5, 21, 0.5);">
          <div class="px-3 py-2 border-b" style="border-color: rgba(139, 92, 246, 0.1);">
            <div class="flex items-center gap-2">
              <div class="w-1.5 h-1.5 rounded-full" style="background: #06b6d4;"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(6, 182, 212, 0.6);">Live Feed</span>
            </div>
          </div>

          <div class="p-2 space-y-1">
            <%!-- Recent Bids --%>
            <%= for bid <- @recent_bids do %>
              <% bid_type = get_val(bid, :type, get_val(bid, :action, "bid")) %>
              <% bid_player = get_val(bid, :player_id, get_val(bid, :player, nil)) %>
              <% bid_amount = get_val(bid, :amount, get_val(bid, :bid, 0)) %>
              <% bid_item_name = get_val(bid, :item_name, nil) %>
              <div class="ah-feed-entry px-2 py-1.5 rounded border text-[10px]" style={bid_feed_style(bid_type)}>
                <%= cond do %>
                  <% bid_type in ["bid", "raise"] -> %>
                    <div class="flex items-center justify-between">
                      <span class="font-bold truncate" style={"color: #06b6d4; max-width: 80px;"}>{if bid_player, do: player_name(bid_player, @players), else: "?"}</span>
                      <span class="font-bold font-mono" style="color: #f59e0b;">{bid_amount}g</span>
                    </div>
                    <div class="mt-0.5" style="color: #475569;">placed a bid</div>
                  <% bid_type in ["pass", "fold", "withdraw"] -> %>
                    <div class="flex items-center justify-between">
                      <span class="font-semibold truncate" style={"color: #64748b; max-width: 100px;"}>{if bid_player, do: player_name(bid_player, @players), else: "?"}</span>
                      <span class="text-[9px] px-1.5 py-0.5 rounded" style="background: rgba(71, 85, 105, 0.2); color: #64748b;">PASS</span>
                    </div>
                  <% bid_type in ["sold", "won"] -> %>
                    <div class="flex items-center justify-between">
                      <span class="font-bold truncate" style={"color: #f59e0b; max-width: 70px;"}>{if bid_item_name, do: bid_item_name, else: "Item"}</span>
                      <span class="font-bold font-mono" style="color: #f59e0b;">{bid_amount}g</span>
                    </div>
                    <div class="mt-0.5" style="color: #fbbf24;">
                      SOLD to {if bid_player, do: player_name(bid_player, @players), else: "?"}
                    </div>
                  <% true -> %>
                    <div class="flex items-center gap-1.5">
                      <span class="truncate" style="color: #94a3b8;">
                        {if bid_player, do: player_name(bid_player, @players), else: "?"}: {bid_type}
                      </span>
                    </div>
                <% end %>
              </div>
            <% end %>

            <div :if={@recent_bids == []} class="text-[10px] text-center py-4" style="color: #475569;">
              No bids yet
            </div>
          </div>

          <%!-- Completed Auctions Summary --%>
          <div :if={@auction_results != []} class="border-t px-3 py-2" style="border-color: rgba(139, 92, 246, 0.1);">
            <div class="flex items-center gap-2 mb-2">
              <div class="w-1.5 h-1.5 rounded-full" style="background: #f59e0b;"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(245, 158, 11, 0.5);">Results</span>
            </div>
            <div class="space-y-1">
              <%= for result <- Enum.take(@recent_results, 5) do %>
                <% r_item = get_val(result, :item, %{}) %>
                <% r_name = get_val(r_item, :name, get_val(result, :item_name, "?")) %>
                <% r_cat = get_val(r_item, :category, get_val(result, :category, "artifact")) %>
                <% r_winner_id = get_val(result, :winner, nil) %>
                <% r_price = get_val(result, :price, 0) %>
                <div class="px-2 py-1 rounded text-[10px]" style="background: rgba(245, 158, 11, 0.04); border: 1px solid rgba(245, 158, 11, 0.1);">
                  <div class="flex items-center justify-between">
                    <span class="font-bold truncate" style={"color: #{category_text_color(r_cat)}; max-width: 80px;"}>
                      {category_icon(r_cat)} {r_name}
                    </span>
                    <span class="font-mono font-bold" style="color: #f59e0b;">{r_price}g</span>
                  </div>
                  <div class="mt-0.5 truncate" style="color: #64748b;">
                    &rarr; {if r_winner_id, do: player_name(r_winner_id, @players), else: "No winner"}
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Collector Journals --%>
          <div :if={@journals != %{}} class="border-t px-3 py-2" style="border-color: rgba(139, 92, 246, 0.1);">
            <div class="flex items-center gap-2 mb-2">
              <div class="w-1.5 h-1.5 rounded-full" style="background: #a78bfa;"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(167, 139, 250, 0.5);">Journals</span>
            </div>
            <div class="space-y-1.5">
              <%= for {collector, entries} <- @journals do %>
                <% recent_entries = Enum.take(Enum.sort_by(List.wrap(entries), &(-get_val(&1, :round, 0))), 2) %>
                <div :if={recent_entries != []} class="px-2 py-1.5 rounded" style="background: rgba(139, 92, 246, 0.04); border: 1px solid rgba(139, 92, 246, 0.1);">
                  <div class="text-[9px] font-bold mb-1 truncate" style="color: #c4b5fd; max-width: 180px;">
                    {collector}
                  </div>
                  <%= for entry <- recent_entries do %>
                    <div class="text-[9px] mb-0.5" style="color: #64748b;">
                      <span class="font-mono" style="color: #8b5cf6;">R{get_val(entry, :round, "?")}</span>
                      <span :if={get_val(entry, :phase, nil)} class="ml-0.5" style="color: #475569;">{get_val(entry, :phase, "")}</span>
                    </div>
                    <div class="text-[9px] italic leading-snug" style="color: #94a3b8;">
                      {truncate_text(to_string(get_val(entry, :thought, "")), 60)}
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Backstory Connections --%>
          <div :if={@connections != []} class="border-t px-3 py-2" style="border-color: rgba(139, 92, 246, 0.1);">
            <div class="flex items-center gap-2 mb-2">
              <div class="w-1.5 h-1.5 rounded-full" style="background: #8b5cf6;"></div>
              <span class="text-[10px] font-bold tracking-[0.2em] uppercase" style="color: rgba(139, 92, 246, 0.5);">Connections</span>
            </div>
            <div class="space-y-1">
              <%= for conn <- @connections do %>
                <% conn_players = get_val(conn, :players, []) %>
                <% conn_type = get_val(conn, :type, "unknown") %>
                <% conn_desc = get_val(conn, :description, "") %>
                <div class="px-2 py-1.5 rounded text-[9px]" style="background: rgba(139, 92, 246, 0.04); border: 1px solid rgba(139, 92, 246, 0.1);">
                  <div class="flex items-center gap-1 mb-0.5">
                    <span class="font-bold" style="color: #c4b5fd;">{Enum.join(conn_players, " & ")}</span>
                  </div>
                  <div class="font-semibold mb-0.5 px-1 py-0.5 rounded inline-block" style="background: rgba(139, 92, 246, 0.1); color: #a78bfa;">
                    {String.replace(to_string(conn_type), "_", " ")}
                  </div>
                  <div :if={conn_desc != ""} class="italic leading-snug mt-0.5" style="color: #64748b;">
                    {truncate_text(to_string(conn_desc), 70)}
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <%!-- ════════════════════════════════════ VICTORY OVERLAY ════════════════════════════════════ --%>
      <div :if={@game_status == "game_over"} class="absolute inset-0 flex items-center justify-center" style="background: rgba(10, 5, 21, 0.92); z-index: 50; backdrop-filter: blur(4px);">
        <div class="w-full max-w-2xl mx-4">
          <%!-- Victory Banner --%>
          <div class="ah-victory text-center mb-6">
            <div class="ah-crown-float text-4xl mb-2">&#128081;</div>
            <div class="text-3xl font-black tracking-wider" style="color: #f59e0b; text-shadow: 0 0 24px rgba(245, 158, 11, 0.5), 0 0 48px rgba(245, 158, 11, 0.2);">
              AUCTION COMPLETE
            </div>
            <div :if={@winner} class="mt-2 text-lg font-bold" style="color: #06b6d4; text-shadow: 0 0 12px rgba(6, 182, 212, 0.4);">
              {player_name(@winner, @players)} Wins!
            </div>
          </div>

          <%!-- Score Breakdown Table --%>
          <div :if={@score_ranking != []} class="rounded-xl border p-4" style="background: rgba(15, 23, 42, 0.6); border-color: rgba(139, 92, 246, 0.2);">
            <div class="text-[10px] font-bold uppercase tracking-[0.2em] mb-3" style="color: rgba(139, 92, 246, 0.5);">Final Standings</div>

            <%!-- Header Row --%>
            <div class="grid grid-cols-7 gap-2 px-2 py-1 mb-1 text-[9px] uppercase tracking-wider" style="color: #475569;">
              <div class="col-span-2">Player</div>
              <div class="text-right">Items</div>
              <div class="text-right">Sets</div>
              <div class="text-right">Gold</div>
              <div class="text-right">Obj.</div>
              <div class="text-right font-bold">Total</div>
            </div>

            <%= for {{pid, sdata, total}, rank} <- Enum.with_index(@score_ranking, 1) do %>
              <% is_winner = @winner != nil and to_string(@winner) == pid %>
              <div class={[
                "grid grid-cols-7 gap-2 px-2 py-2 rounded-lg border mb-1",
                if(is_winner, do: "ah-active-glow", else: "")
              ]} style={score_row_style(is_winner, rank)}>
                <div class="col-span-2 flex items-center gap-2">
                  <span class="text-xs font-bold font-mono" style={"color: #{rank_medal_color(rank)};"}>{rank_medal(rank)}</span>
                  <span class="text-xs font-bold truncate" style={"color: #{if is_winner, do: "#f59e0b", else: "#e2e8f0"}; max-width: 100px;"}>
                    {player_name(pid, @players)}
                  </span>
                </div>
                <div class="text-right text-xs font-mono" style="color: #a78bfa;">{get_val(sdata, :item_value, 0)}</div>
                <div class="text-right text-xs font-mono" style="color: #8b5cf6;">{get_val(sdata, :set_bonus, 0)}</div>
                <div class="text-right text-xs font-mono" style="color: #f59e0b;">{get_val(sdata, :gold_bonus, 0)}</div>
                <div class="text-right text-xs font-mono" style="color: #06b6d4;">{get_val(sdata, :objective_bonus, 0)}</div>
                <div class="text-right text-sm font-bold font-mono" style={"color: #{if is_winner, do: "#f59e0b", else: "#e2e8f0"}; text-shadow: #{if is_winner, do: "0 0 8px rgba(245, 158, 11, 0.4)", else: "none"};"}>
                  {total}
                </div>
              </div>
            <% end %>

            <%!-- Score Legend --%>
            <div class="mt-3 pt-3 border-t flex flex-wrap gap-3" style="border-color: rgba(51, 65, 85, 0.3);">
              <div class="flex items-center gap-1">
                <div class="w-2 h-2 rounded-full" style="background: #a78bfa;"></div>
                <span class="text-[9px]" style="color: #64748b;">Item Value</span>
              </div>
              <div class="flex items-center gap-1">
                <div class="w-2 h-2 rounded-full" style="background: #8b5cf6;"></div>
                <span class="text-[9px]" style="color: #64748b;">Set Bonus</span>
              </div>
              <div class="flex items-center gap-1">
                <div class="w-2 h-2 rounded-full" style="background: #f59e0b;"></div>
                <span class="text-[9px]" style="color: #64748b;">Gold Bonus</span>
              </div>
              <div class="flex items-center gap-1">
                <div class="w-2 h-2 rounded-full" style="background: #06b6d4;"></div>
                <span class="text-[9px]" style="color: #64748b;">Objective Bonus</span>
              </div>
            </div>
          </div>

          <%!-- Decorative Divider --%>
          <div class="w-48 h-0.5 rounded-full mx-auto mt-4" style="background: linear-gradient(90deg, transparent, #f59e0b, transparent);"></div>
        </div>
      </div>
    </div>
    """
  end

  # ── Map Value Access ───────────────────────────────────────────────

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

  # ── Player Name ────────────────────────────────────────────────────

  defp player_name(nil, _players), do: "?"

  defp player_name(id, players) when is_map(players) do
    pid = to_string(id)

    player_data =
      Map.get(players, id) ||
        Map.get(players, pid) ||
        (is_binary(id) && try_atom_key(players, id)) ||
        %{}

    get_val(player_data, :name, pid)
  end

  defp player_name(id, _), do: to_string(id)

  defp try_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  # ── Phase Styling ──────────────────────────────────────────────────

  defp phase_badge_class("bidding"), do: "border-amber-500/30 text-amber-400"
  defp phase_badge_class("scoring"), do: "border-violet-500/30 text-violet-400"
  defp phase_badge_class("game_over"), do: "border-red-500/30 text-red-400"
  defp phase_badge_class(_), do: "border-gray-500/30 text-gray-400"

  defp phase_label("bidding"), do: "Bidding"
  defp phase_label("scoring"), do: "Scoring"
  defp phase_label("game_over"), do: "Game Over"
  defp phase_label(other) when is_binary(other), do: String.capitalize(other)
  defp phase_label(_), do: "Unknown"

  # ── Player Card Styling ────────────────────────────────────────────

  defp player_card_style(true = _active, _high_bidder) do
    "background: rgba(6, 182, 212, 0.06); border-color: rgba(6, 182, 212, 0.3);"
  end

  defp player_card_style(false, true = _high_bidder) do
    "background: rgba(245, 158, 11, 0.04); border-color: rgba(245, 158, 11, 0.2);"
  end

  defp player_card_style(false, false) do
    "background: rgba(15, 23, 42, 0.4); border-color: #1e293b;"
  end

  defp player_avatar_style(pid) do
    hue = :erlang.phash2(to_string(pid), 360)
    "background: hsl(#{hue}, 60%, 25%); color: hsl(#{hue}, 70%, 75%); border: 1px solid hsl(#{hue}, 50%, 35%);"
  end

  # ── Category Styling ───────────────────────────────────────────────

  defp category_glow_class("gem"), do: "ah-glow-gem"
  defp category_glow_class("artifact"), do: "ah-glow-artifact"
  defp category_glow_class("scroll"), do: "ah-glow-scroll"
  defp category_glow_class(_), do: "ah-glow-artifact"

  defp category_icon("gem"), do: "&#128142;"
  defp category_icon("artifact"), do: "&#128081;"
  defp category_icon("scroll"), do: "&#128220;"
  defp category_icon(_), do: "&#128230;"

  defp category_large_icon("gem"), do: "&#128142;"
  defp category_large_icon("artifact"), do: "&#127942;"
  defp category_large_icon("scroll"), do: "&#128220;"
  defp category_large_icon(_), do: "&#128230;"

  defp category_icon_filter("gem"), do: "drop-shadow(0 0 8px rgba(139, 92, 246, 0.5))"
  defp category_icon_filter("artifact"), do: "drop-shadow(0 0 8px rgba(245, 158, 11, 0.5))"
  defp category_icon_filter("scroll"), do: "drop-shadow(0 0 8px rgba(6, 182, 212, 0.5))"
  defp category_icon_filter(_), do: "drop-shadow(0 0 8px rgba(100, 116, 139, 0.5))"

  defp category_text_color("gem"), do: "#a78bfa"
  defp category_text_color("artifact"), do: "#fbbf24"
  defp category_text_color("scroll"), do: "#22d3ee"
  defp category_text_color(_), do: "#94a3b8"

  defp category_name_style("gem") do
    "color: #c4b5fd; text-shadow: 0 0 12px rgba(139, 92, 246, 0.5);"
  end

  defp category_name_style("artifact") do
    "color: #fde68a; text-shadow: 0 0 12px rgba(245, 158, 11, 0.5);"
  end

  defp category_name_style("scroll") do
    "color: #a5f3fc; text-shadow: 0 0 12px rgba(6, 182, 212, 0.5);"
  end

  defp category_name_style(_) do
    "color: #e2e8f0; text-shadow: none;"
  end

  defp category_badge_style("gem") do
    "background: rgba(139, 92, 246, 0.15); color: #a78bfa; border-color: rgba(139, 92, 246, 0.3);"
  end

  defp category_badge_style("artifact") do
    "background: rgba(245, 158, 11, 0.15); color: #fbbf24; border-color: rgba(245, 158, 11, 0.3);"
  end

  defp category_badge_style("scroll") do
    "background: rgba(6, 182, 212, 0.15); color: #22d3ee; border-color: rgba(6, 182, 212, 0.3);"
  end

  defp category_badge_style(_) do
    "background: rgba(71, 85, 105, 0.15); color: #94a3b8; border-color: rgba(71, 85, 105, 0.3);"
  end

  defp category_dot_style("gem") do
    "background: rgba(139, 92, 246, 0.6); border-color: rgba(139, 92, 246, 0.8);"
  end

  defp category_dot_style("artifact") do
    "background: rgba(245, 158, 11, 0.6); border-color: rgba(245, 158, 11, 0.8);"
  end

  defp category_dot_style("scroll") do
    "background: rgba(6, 182, 212, 0.6); border-color: rgba(6, 182, 212, 0.8);"
  end

  defp category_dot_style(_) do
    "background: rgba(100, 116, 139, 0.6); border-color: rgba(100, 116, 139, 0.8);"
  end

  # ── Item Card Styles ───────────────────────────────────────────────

  defp current_item_card_style("gem") do
    "background: linear-gradient(135deg, rgba(139, 92, 246, 0.08) 0%, rgba(15, 23, 42, 0.6) 50%, rgba(139, 92, 246, 0.04) 100%); border-color: rgba(139, 92, 246, 0.25);"
  end

  defp current_item_card_style("artifact") do
    "background: linear-gradient(135deg, rgba(245, 158, 11, 0.08) 0%, rgba(15, 23, 42, 0.6) 50%, rgba(245, 158, 11, 0.04) 100%); border-color: rgba(245, 158, 11, 0.25);"
  end

  defp current_item_card_style("scroll") do
    "background: linear-gradient(135deg, rgba(6, 182, 212, 0.08) 0%, rgba(15, 23, 42, 0.6) 50%, rgba(6, 182, 212, 0.04) 100%); border-color: rgba(6, 182, 212, 0.25);"
  end

  defp current_item_card_style(_) do
    "background: rgba(15, 23, 42, 0.6); border-color: rgba(51, 65, 85, 0.3);"
  end

  defp completed_item_style(cat) do
    color = category_text_color(cat)
    "background: rgba(15, 23, 42, 0.3); border-color: #{color}22; opacity: 0.7;"
  end

  defp upcoming_item_style(cat) do
    color = category_text_color(cat)
    "background: rgba(15, 23, 42, 0.4); border-color: #{color}15;"
  end

  # ── Bid Feed Styling ───────────────────────────────────────────────

  defp bid_feed_style(type) when type in ["bid", "raise"] do
    "background: rgba(6, 182, 212, 0.04); border-color: rgba(6, 182, 212, 0.15);"
  end

  defp bid_feed_style(type) when type in ["pass", "fold", "withdraw"] do
    "background: rgba(30, 41, 59, 0.3); border-color: rgba(51, 65, 85, 0.2);"
  end

  defp bid_feed_style(type) when type in ["sold", "won"] do
    "background: rgba(245, 158, 11, 0.06); border-color: rgba(245, 158, 11, 0.2);"
  end

  defp bid_feed_style(_) do
    "background: rgba(15, 23, 42, 0.3); border-color: #1e293b;"
  end

  # ── Gold Bar Percentage ────────────────────────────────────────────

  defp gold_bar_pct(gold, sorted_players) when is_number(gold) do
    max_gold =
      sorted_players
      |> Enum.map(fn {_pid, pdata} ->
        g = get_val(pdata, :gold, 0)
        if is_number(g), do: g, else: 0
      end)
      |> Enum.max(fn -> 1 end)

    max_gold = max(max_gold, 1)
    pct = round(gold / max_gold * 100)
    "#{pct}%"
  end

  defp gold_bar_pct(_, _), do: "0%"

  # ── Round Progress ─────────────────────────────────────────────────

  defp round_progress(current, max_r) when is_number(current) and is_number(max_r) and max_r > 0 do
    round(current / max_r * 100)
  end

  defp round_progress(_, _), do: 0

  # ── Score Row Styling ──────────────────────────────────────────────

  defp score_row_style(true = _is_winner, _rank) do
    "background: rgba(245, 158, 11, 0.08); border-color: rgba(245, 158, 11, 0.3);"
  end

  defp score_row_style(false, 1) do
    "background: rgba(245, 158, 11, 0.04); border-color: rgba(245, 158, 11, 0.15);"
  end

  defp score_row_style(false, 2) do
    "background: rgba(148, 163, 184, 0.04); border-color: rgba(148, 163, 184, 0.1);"
  end

  defp score_row_style(false, 3) do
    "background: rgba(180, 83, 9, 0.04); border-color: rgba(180, 83, 9, 0.1);"
  end

  defp score_row_style(false, _) do
    "background: rgba(15, 23, 42, 0.4); border-color: #1e293b;"
  end

  # ── Rank Medals ────────────────────────────────────────────────────

  defp rank_medal(1), do: "&#129351;"
  defp rank_medal(2), do: "&#129352;"
  defp rank_medal(3), do: "&#129353;"
  defp rank_medal(n), do: "##{n}"

  defp rank_medal_color(1), do: "#f59e0b"
  defp rank_medal_color(2), do: "#94a3b8"
  defp rank_medal_color(3), do: "#b45309"
  defp rank_medal_color(_), do: "#64748b"

  # ── Text Utilities ─────────────────────────────────────────────────

  defp truncate_text(text, max_len) when is_binary(text) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end

  defp truncate_text(_, _), do: ""
end
