defmodule LemonSimUi.Live.Components.StockMarketBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr(:world, :map, required: true)
  attr(:interactive, :boolean, default: false)

  def render(assigns) do
    world = assigns.world
    players = MapHelpers.get_key(world, :players) || %{}
    stocks = MapHelpers.get_key(world, :stocks) || %{}
    phase = MapHelpers.get_key(world, :phase) || "discussion"
    round = MapHelpers.get_key(world, :round) || 1
    max_rounds = MapHelpers.get_key(world, :max_rounds) || 10
    active_actor_id = MapHelpers.get_key(world, :active_actor_id)
    discussion_transcript = MapHelpers.get_key(world, :discussion_transcript) || []
    whisper_log = MapHelpers.get_key(world, :whisper_log) || []
    whisper_graph = MapHelpers.get_key(world, :whisper_graph) || []
    market_calls = MapHelpers.get_key(world, :market_calls) || []
    market_call_history = MapHelpers.get_key(world, :market_call_history) || []
    round_summaries = MapHelpers.get_key(world, :round_summaries) || []
    trades = MapHelpers.get_key(world, :trades) || %{}
    market_news = MapHelpers.get_key(world, :market_news) || ""
    status = MapHelpers.get_key(world, :status) || "in_progress"
    winner = MapHelpers.get_key(world, :winner)
    discussion_round = MapHelpers.get_key(world, :discussion_round) || 0
    discussion_round_limit = MapHelpers.get_key(world, :discussion_round_limit) || 3
    traits = MapHelpers.get_key(world, :traits) || %{}
    connections = MapHelpers.get_key(world, :connections) || []
    journals = MapHelpers.get_key(world, :journals) || %{}

    # Pre-compute stock list sorted by ticker
    stock_list =
      stocks
      |> Enum.map(fn {ticker, data} -> {to_string(ticker), data} end)
      |> Enum.sort_by(fn {ticker, _} -> ticker end)

    # Pre-compute player rankings by portfolio value
    player_list =
      players
      |> Enum.map(fn {pid, pdata} ->
        pval = portfolio_value(pdata, stocks)
        {to_string(pid), pdata, pval}
      end)
      |> Enum.sort_by(fn {_, _, val} -> val end, :desc)

    max_portfolio_val =
      case player_list do
        [{_, _, v} | _] when v > 0 -> v
        _ -> 1
      end

    # Build ticker tape text
    ticker_tape =
      stock_list
      |> Enum.map(fn {ticker, data} ->
        price = get_val(data, :price, 0.0)
        history = get_val(data, :history, [])
        prev = List.last(history) || price
        change = price - prev
        sign = if change >= 0, do: "+", else: ""
        "#{ticker} $#{format_price(price)} (#{sign}#{format_price(change)})"
      end)
      |> Enum.join("    ///    ")

    # Recent trades for blotter (current round)
    trade_list =
      trades
      |> Enum.map(fn {pid, trade_data} ->
        {to_string(pid), trade_data}
      end)
      |> Enum.sort_by(fn {pid, _} -> pid end)

    # Whisper summary: count per player pair
    whisper_pairs =
      whisper_graph
      |> Enum.map(fn wh ->
        {to_string(get_val(wh, :from, "")), to_string(get_val(wh, :to, ""))}
      end)
      |> Enum.uniq()

    assigns =
      assigns
      |> assign(:players, players)
      |> assign(:stocks, stocks)
      |> assign(:stock_list, stock_list)
      |> assign(:phase, phase)
      |> assign(:round, round)
      |> assign(:max_rounds, max_rounds)
      |> assign(:active_actor_id, active_actor_id)
      |> assign(:discussion_transcript, discussion_transcript)
      |> assign(:whisper_log, whisper_log)
      |> assign(:whisper_graph, whisper_graph)
      |> assign(:whisper_pairs, whisper_pairs)
      |> assign(:market_calls, market_calls)
      |> assign(:market_call_history, market_call_history)
      |> assign(:round_summaries, round_summaries)
      |> assign(:trades, trades)
      |> assign(:trade_list, trade_list)
      |> assign(:market_news, market_news)
      |> assign(:game_status, status)
      |> assign(:winner, winner)
      |> assign(:player_list, player_list)
      |> assign(:max_portfolio_val, max_portfolio_val)
      |> assign(:ticker_tape, ticker_tape)
      |> assign(:discussion_round, discussion_round)
      |> assign(:discussion_round_limit, discussion_round_limit)
      |> assign(:traits, traits)
      |> assign(:connections, connections)
      |> assign(:journals, journals)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0a0e1a; color: #e2e8f0; min-height: 600px;">
      <style>
        /* ── Ticker Tape ── */
        @keyframes sm-ticker-scroll {
          0% { transform: translateX(0); }
          100% { transform: translateX(-50%); }
        }
        .sm-ticker-tape {
          animation: sm-ticker-scroll 30s linear infinite;
          white-space: nowrap;
        }

        /* ── Price Flash ── */
        @keyframes sm-flash-green {
          0% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.6); }
          50% { box-shadow: 0 0 16px 4px rgba(16, 185, 129, 0.3); }
          100% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0); }
        }
        @keyframes sm-flash-red {
          0% { box-shadow: 0 0 0 0 rgba(239, 68, 68, 0.6); }
          50% { box-shadow: 0 0 16px 4px rgba(239, 68, 68, 0.3); }
          100% { box-shadow: 0 0 0 0 rgba(239, 68, 68, 0); }
        }
        .sm-price-up { animation: sm-flash-green 1.5s ease-out; }
        .sm-price-down { animation: sm-flash-red 1.5s ease-out; }

        /* ── Active Trader Glow ── */
        @keyframes sm-active-glow {
          0%, 100% { box-shadow: 0 0 6px 2px rgba(6, 182, 212, 0.3); }
          50% { box-shadow: 0 0 18px 6px rgba(6, 182, 212, 0.6); }
        }
        .sm-active-trader { animation: sm-active-glow 2s ease-in-out infinite; }

        /* ── Speech Bubble Fade In ── */
        @keyframes sm-bubble-in {
          from { opacity: 0; transform: translateY(8px); }
          to { opacity: 1; transform: translateY(0); }
        }
        .sm-bubble { animation: sm-bubble-in 0.35s ease-out forwards; }

        /* ── Typing Indicator ── */
        @keyframes sm-typing-dot {
          0%, 60%, 100% { opacity: 0.3; transform: translateY(0); }
          30% { opacity: 1; transform: translateY(-3px); }
        }
        .sm-typing-dot-1 { animation: sm-typing-dot 1.2s ease-in-out infinite; }
        .sm-typing-dot-2 { animation: sm-typing-dot 1.2s ease-in-out 0.2s infinite; }
        .sm-typing-dot-3 { animation: sm-typing-dot 1.2s ease-in-out 0.4s infinite; }

        /* ── Bar Grow ── */
        @keyframes sm-bar-grow {
          from { width: 0%; }
        }
        .sm-bar-anim { animation: sm-bar-grow 0.6s ease-out forwards; }

        /* ── Victory Banner ── */
        @keyframes sm-victory-pulse {
          0%, 100% { transform: scale(1); opacity: 1; }
          50% { transform: scale(1.03); opacity: 0.95; }
        }
        .sm-victory { animation: sm-victory-pulse 2s ease-in-out infinite; }

        @keyframes sm-confetti-fall {
          0% { transform: translateY(-10px) rotate(0deg); opacity: 1; }
          100% { transform: translateY(40px) rotate(360deg); opacity: 0; }
        }
        .sm-confetti { animation: sm-confetti-fall 3s ease-in-out infinite; }

        /* ── Sparkline ── */
        .sm-sparkline-path {
          fill: none;
          stroke-width: 1.5;
          stroke-linecap: round;
          stroke-linejoin: round;
        }

        /* ── Whisper Line ── */
        @keyframes sm-whisper-dash {
          to { stroke-dashoffset: -12; }
        }
        .sm-whisper-line {
          stroke-dasharray: 4 4;
          animation: sm-whisper-dash 1s linear infinite;
        }

        /* ── News Scroll ── */
        @keyframes sm-news-scroll {
          0% { transform: translateX(100%); }
          100% { transform: translateX(-100%); }
        }
        .sm-news-scroll {
          animation: sm-news-scroll 20s linear infinite;
        }

        /* ── Market Call Pulse ── */
        @keyframes sm-call-pulse {
          0%, 100% { border-color: rgba(245, 158, 11, 0.3); }
          50% { border-color: rgba(245, 158, 11, 0.7); }
        }
        .sm-call-pulse { animation: sm-call-pulse 2s ease-in-out infinite; }

        /* ── Star Shimmer ── */
        @keyframes sm-star-shimmer {
          0%, 100% { opacity: 0.8; }
          50% { opacity: 1; }
        }
        .sm-star { animation: sm-star-shimmer 3s ease-in-out infinite; }

        /* ── Scrollbar ── */
        .sm-scroll::-webkit-scrollbar { width: 4px; }
        .sm-scroll::-webkit-scrollbar-track { background: rgba(15, 23, 42, 0.5); }
        .sm-scroll::-webkit-scrollbar-thumb { background: rgba(51, 65, 85, 0.6); border-radius: 2px; }
      </style>

      <%!-- ════════════════════════════════════════════ TOP BAR ════════════════════════════════════════════ --%>
      <div class="border-b" style="border-color: #1e293b; background: linear-gradient(180deg, #0f172a 0%, #0a0e1a 100%);">
        <%!-- Ticker Tape --%>
        <div class="overflow-hidden py-1" style="background: #020617; border-bottom: 1px solid #1e293b;">
          <div class="sm-ticker-tape inline-block">
            <span class="text-xs font-mono tracking-wide" style="color: #64748b;">
              {@ticker_tape}    ///    {@ticker_tape}
            </span>
          </div>
        </div>

        <%!-- Status Row --%>
        <div class="flex items-center justify-between px-4 py-2">
          <div class="flex items-center gap-4">
            <%!-- Round Badge --%>
            <div class="flex items-center gap-2">
              <div class="text-xs font-mono uppercase tracking-widest" style="color: #475569;">Round</div>
              <div class="flex items-center gap-1 px-2 py-0.5 rounded font-bold text-sm font-mono" style="background: #1e293b; color: #e2e8f0;">
                <span>{@round}</span>
                <span class="text-xs font-normal" style="color: #64748b;">/ {@max_rounds}</span>
              </div>
            </div>

            <%!-- Phase Badge --%>
            <div class={[
              "px-3 py-1 rounded-full text-xs font-bold uppercase tracking-wider border",
              phase_badge_class(@phase)
            ]}>
              {phase_label(@phase)}
              <span :if={@phase == "discussion"} class="ml-1 font-normal opacity-70">
                ({@discussion_round}/{@discussion_round_limit})
              </span>
            </div>

            <%!-- Active Trader --%>
            <div :if={@active_actor_id && @game_status == "in_progress"} class="flex items-center gap-2">
              <div class="w-1 h-4 rounded-full" style="background: #06b6d4;"></div>
              <span class="text-xs" style="color: #94a3b8;">Active:</span>
              <span class="text-xs font-bold px-2 py-0.5 rounded" style="background: rgba(6, 182, 212, 0.15); color: #06b6d4; border: 1px solid rgba(6, 182, 212, 0.3);">
                {player_name(@active_actor_id, @players)}
              </span>
            </div>
          </div>

          <%!-- Market Status --%>
          <div class="flex items-center gap-3">
            <div :if={@game_status == "in_progress"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full animate-pulse" style="background: #10b981;"></div>
              <span class="text-xs font-mono uppercase" style="color: #10b981;">Markets Open</span>
            </div>
            <div :if={@game_status == "game_over"} class="flex items-center gap-1.5">
              <div class="w-2 h-2 rounded-full" style="background: #ef4444;"></div>
              <span class="text-xs font-mono uppercase" style="color: #ef4444;">Markets Closed</span>
            </div>
          </div>
        </div>

        <%!-- News Ticker --%>
        <div :if={@market_news != ""} class="overflow-hidden py-1 border-t" style="background: rgba(245, 158, 11, 0.05); border-color: rgba(245, 158, 11, 0.15);">
          <div class="flex items-center gap-2 px-4">
            <span class="text-xs font-bold uppercase tracking-wider flex-shrink-0 px-1.5 py-0.5 rounded" style="color: #f59e0b; background: rgba(245, 158, 11, 0.1);">
              NEWS
            </span>
            <div class="overflow-hidden flex-1">
              <div class="sm-news-scroll inline-block text-xs" style="color: #fbbf24;">
                {@market_news}
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- ════════════════════════════════════════════ MAIN LAYOUT ════════════════════════════════════════════ --%>
      <div class="flex" style="height: calc(100% - 100px); min-height: 500px;">

        <%!-- ──────── LEFT PANEL: Trader Roster ──────── --%>
        <div class="flex-shrink-0 border-r overflow-y-auto sm-scroll" style="width: 210px; border-color: #1e293b; background: #0c1120;">
          <div class="px-3 py-2 border-b" style="border-color: #1e293b;">
            <div class="text-xs font-bold uppercase tracking-widest" style="color: #475569;">Traders</div>
          </div>
          <div class="p-2 space-y-2">
            <%= for {pid, pdata, pval} <- @player_list do %>
              <% is_active = to_string(@active_actor_id) == pid %>
              <% name = get_val(pdata, :name, pid) %>
              <% cash = get_val(pdata, :cash, 0) %>
              <% reputation = get_val(pdata, :reputation, 3) %>
              <% portfolio = get_val(pdata, :portfolio, %{}) %>
              <% wealth_history = compute_wealth_hint(pdata, @stocks) %>
              <div class={[
                "rounded-lg p-2.5 border transition-all",
                if(is_active, do: "sm-active-trader", else: "")
              ]} style={trader_card_style(is_active)}>
                <%!-- Name + Active Indicator --%>
                <div class="flex items-center justify-between mb-1.5">
                  <div class="flex items-center gap-1.5">
                    <div class="w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold" style={trader_avatar_style(pid)}>
                      {String.first(to_string(name)) |> String.upcase()}
                    </div>
                    <span class="text-xs font-bold truncate" style={"color: #{if is_active, do: "#06b6d4", else: "#e2e8f0"}; max-width: 100px;"}>
                      {name}
                    </span>
                  </div>
                  <div :if={is_active && @phase == "discussion"} class="flex gap-0.5 items-end">
                    <div class="w-1 h-1 rounded-full sm-typing-dot-1" style="background: #06b6d4;"></div>
                    <div class="w-1 h-1 rounded-full sm-typing-dot-2" style="background: #06b6d4;"></div>
                    <div class="w-1 h-1 rounded-full sm-typing-dot-3" style="background: #06b6d4;"></div>
                  </div>
                </div>

                <%!-- Trait Badges --%>
                <% trader_traits = get_val(@traits, to_string(name), get_val(@traits, pid, [])) %>
                <div :if={is_list(trader_traits) && trader_traits != []} class="flex flex-wrap gap-0.5 mb-1">
                  <%= for trait <- trader_traits do %>
                    <span class="px-1 py-0 rounded text-xs" style="background: rgba(16, 185, 129, 0.1); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.2); font-size: 9px; line-height: 14px;">
                      {trait}
                    </span>
                  <% end %>
                </div>

                <%!-- Reputation Stars --%>
                <div class="flex items-center gap-0.5 mb-1">
                  {reputation_stars(reputation)}
                </div>

                <%!-- Portfolio Value --%>
                <div class="flex items-center justify-between mb-1">
                  <span class="text-xs" style="color: #64748b;">Value</span>
                  <span class="text-xs font-bold font-mono" style="color: #10b981;">${format_price(pval)}</span>
                </div>

                <%!-- Cash --%>
                <div class="flex items-center justify-between mb-1.5">
                  <span class="text-xs" style="color: #64748b;">Cash</span>
                  <span class="text-xs font-mono" style="color: #94a3b8;">${format_price(cash)}</span>
                </div>

                <%!-- Mini Holdings --%>
                <div :if={map_size(portfolio) > 0} class="flex flex-wrap gap-1">
                  <%= for {ticker, shares} <- portfolio do %>
                    <% shares_val = if is_number(shares), do: shares, else: 0 %>
                    <div :if={shares_val != 0} class="px-1.5 py-0.5 rounded text-xs font-mono" style={"background: #{if shares_val > 0, do: "rgba(16, 185, 129, 0.1)", else: "rgba(239, 68, 68, 0.1)"}; color: #{if shares_val > 0, do: "#10b981", else: "#ef4444"}; border: 1px solid #{if shares_val > 0, do: "rgba(16, 185, 129, 0.2)", else: "rgba(239, 68, 68, 0.2)"};"}>
                      {ticker} {shares_val}
                    </div>
                  <% end %>
                </div>

                <%!-- Mini Wealth Sparkline --%>
                <div :if={length(wealth_history) > 1} class="mt-1.5">
                  <svg viewBox="0 0 80 16" class="w-full" style="height: 16px;">
                    <path d={sparkline_path(wealth_history, 80, 16)} class="sm-sparkline-path" style="stroke: #06b6d4; opacity: 0.6;" />
                  </svg>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- ──────── CENTER PANEL ──────── --%>
        <div class="flex-1 flex flex-col overflow-hidden" style="background: #0a0e1a;">

          <%!-- ──── Stock Price Cards ──── --%>
          <div class="border-b p-3" style="border-color: #1e293b;">
            <div class="flex gap-2 overflow-x-auto">
              <%= for {ticker, data} <- @stock_list do %>
                <% price = get_val(data, :price, 0.0) %>
                <% history = get_val(data, :history, []) %>
                <% full_history = history ++ [price] %>
                <% prev = List.last(history) || price %>
                <% change = price - prev %>
                <% pct_change = if prev != 0, do: change / prev * 100, else: 0.0 %>
                <% is_up = change >= 0 %>
                <% stock_name = get_val(data, :name, ticker) %>
                <div
                  class={[
                    "flex-1 min-w-[140px] rounded-lg border p-3",
                    if(is_up, do: "sm-price-up", else: "sm-price-down")
                  ]}
                  style={"background: #0f172a; border-color: #{if is_up, do: "rgba(16, 185, 129, 0.25)", else: "rgba(239, 68, 68, 0.25)"}; transition: border-color 0.3s;"}
                >
                  <%!-- Ticker + Name --%>
                  <div class="flex items-center justify-between mb-1">
                    <span class="text-sm font-bold font-mono" style="color: #e2e8f0;">{ticker}</span>
                    <span class="text-xs truncate ml-2" style="color: #64748b; max-width: 70px;">{stock_name}</span>
                  </div>

                  <%!-- Price --%>
                  <div class="flex items-baseline gap-2 mb-2">
                    <span class="text-lg font-bold font-mono" style={"color: #{if is_up, do: "#10b981", else: "#ef4444"};"}>${format_price(price)}</span>
                    <span class="text-xs font-mono flex items-center gap-0.5" style={"color: #{if is_up, do: "#10b981", else: "#ef4444"};"}>
                      <span :if={is_up}>&#9650;</span>
                      <span :if={!is_up}>&#9660;</span>
                      {format_price(abs(change))}
                      <span class="opacity-60">({format_pct(pct_change)}%)</span>
                    </span>
                  </div>

                  <%!-- Sparkline Chart --%>
                  <svg viewBox="0 0 120 28" class="w-full" style="height: 28px;">
                    <%!-- Area fill under the line --%>
                    <defs>
                      <linearGradient id={"grad-#{ticker}"} x1="0" y1="0" x2="0" y2="1">
                        <stop offset="0%" stop-color={if is_up, do: "#10b981", else: "#ef4444"} stop-opacity="0.3" />
                        <stop offset="100%" stop-color={if is_up, do: "#10b981", else: "#ef4444"} stop-opacity="0.02" />
                      </linearGradient>
                    </defs>
                    <path d={sparkline_area_path(full_history, 120, 28)} fill={"url(#grad-#{ticker})"} />
                    <path d={sparkline_path(full_history, 120, 28)} class="sm-sparkline-path" style={"stroke: #{if is_up, do: "#10b981", else: "#ef4444"};"} />
                    <%!-- Current price dot --%>
                    <circle
                      cx={sparkline_last_x(full_history, 120)}
                      cy={sparkline_last_y(full_history, 28)}
                      r="2.5"
                      fill={if is_up, do: "#10b981", else: "#ef4444"}
                    />
                  </svg>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- ──── Discussion Feed ──── --%>
          <div class="flex-1 overflow-y-auto sm-scroll p-4" id="sm-discussion-feed" phx-hook="ScrollBottom">
            <div :if={@discussion_transcript == [] && @market_calls == []} class="flex items-center justify-center h-full">
              <div class="text-center" style="color: #475569;">
                <div class="text-3xl mb-2" style="opacity: 0.3;">&#x1F4C8;</div>
                <div class="text-sm">Waiting for market activity...</div>
              </div>
            </div>

            <div class="space-y-2">
              <%!-- Market Calls (shown at top of feed) --%>
              <%= for call <- @market_calls do %>
                <% caller_id = to_string(get_val(call, :player, "")) %>
                <% stock = to_string(get_val(call, :stock, "")) %>
                <% stance = to_string(get_val(call, :stance, "")) %>
                <% confidence = get_val(call, :confidence, 3) %>
                <% thesis = get_val(call, :thesis, "") %>
                <% is_bull = stance == "bullish" %>
                <div class="sm-bubble sm-call-pulse rounded-lg border p-3 mx-2" style={"background: #{if is_bull, do: "rgba(16, 185, 129, 0.06)", else: "rgba(239, 68, 68, 0.06)"}; border-color: #{if is_bull, do: "rgba(16, 185, 129, 0.25)", else: "rgba(239, 68, 68, 0.25)"};"}>
                  <div class="flex items-center gap-2 mb-1.5">
                    <span class="text-lg">{if is_bull, do: Phoenix.HTML.raw("&#x1F402;"), else: Phoenix.HTML.raw("&#x1F43B;")}</span>
                    <span class="text-xs font-bold" style={"color: #{if is_bull, do: "#10b981", else: "#ef4444"};"}>{String.upcase(stance)} CALL</span>
                    <span class="text-xs font-mono font-bold" style="color: #f59e0b;">{stock}</span>
                    <span class="text-xs" style="color: #64748b;">by {player_name(caller_id, @players)}</span>
                    <%!-- Confidence meter --%>
                    <div class="flex gap-0.5 ml-auto">
                      <%= for i <- 1..5 do %>
                        <div class="w-1.5 h-3 rounded-sm" style={"background: #{if i <= confidence, do: (if is_bull, do: "#10b981", else: "#ef4444"), else: "#1e293b"};"}></div>
                      <% end %>
                    </div>
                  </div>
                  <div :if={thesis != ""} class="text-xs italic" style="color: #94a3b8;">
                    "{thesis}"
                  </div>
                </div>
              <% end %>

              <%!-- Discussion Messages --%>
              <%= for {msg, idx} <- Enum.with_index(@discussion_transcript) do %>
                <% speaker_id = to_string(get_val(msg, :player, "")) %>
                <% statement = get_val(msg, :statement, "") %>
                <% msg_type = to_string(get_val(msg, :type, "statement")) %>
                <% is_market_call = msg_type == "market_call" %>
                <div class="sm-bubble flex gap-2 items-start" style={"animation-delay: #{idx * 50}ms;"}>
                  <%!-- Avatar --%>
                  <div class="w-7 h-7 rounded-full flex-shrink-0 flex items-center justify-center text-xs font-bold mt-0.5" style={trader_avatar_style(speaker_id)}>
                    {String.first(player_name(speaker_id, @players)) |> String.upcase()}
                  </div>
                  <%!-- Bubble --%>
                  <div class={[
                    "rounded-lg px-3 py-2 max-w-[85%] border",
                    if(is_market_call, do: "sm-call-pulse", else: "")
                  ]} style={speech_bubble_style(is_market_call)}>
                    <div class="flex items-center gap-2 mb-0.5">
                      <span class="text-xs font-bold" style="color: #06b6d4;">{player_name(speaker_id, @players)}</span>
                      <span :if={is_market_call} class="text-xs px-1.5 py-0.5 rounded" style="background: rgba(245, 158, 11, 0.15); color: #f59e0b; font-size: 9px; font-weight: 700; letter-spacing: 0.05em;">CALL</span>
                    </div>
                    <div class="text-xs leading-relaxed" style="color: #cbd5e1;">{statement}</div>
                  </div>
                </div>
              <% end %>

              <%!-- Whisper Messages (subtle, indented) --%>
              <%= for wh <- @whisper_log do %>
                <% from_id = to_string(get_val(wh, :from, "")) %>
                <% to_id = to_string(get_val(wh, :to, "")) %>
                <% wmsg = get_val(wh, :message, "") %>
                <div class="sm-bubble flex gap-2 items-start ml-8 opacity-70">
                  <div class="w-5 h-5 rounded-full flex-shrink-0 flex items-center justify-center text-xs font-bold mt-0.5" style="background: rgba(100, 116, 139, 0.2); color: #64748b; border: 1px dashed #475569;">
                    {String.first(player_name(from_id, @players)) |> String.upcase()}
                  </div>
                  <div class="rounded-lg px-3 py-1.5 border" style="background: rgba(30, 41, 59, 0.3); border-color: rgba(71, 85, 105, 0.3); border-style: dashed;">
                    <div class="flex items-center gap-1.5 mb-0.5">
                      <span class="text-xs italic" style="color: #64748b;">
                        {player_name(from_id, @players)} whispers to {player_name(to_id, @players)}
                      </span>
                    </div>
                    <div class="text-xs" style="color: #94a3b8;">{wmsg}</div>
                  </div>
                </div>
              <% end %>

              <%!-- Typing Indicator for Active Speaker --%>
              <div :if={@active_actor_id && @phase == "discussion" && @game_status == "in_progress"} class="sm-bubble flex gap-2 items-start">
                <div class="w-7 h-7 rounded-full flex-shrink-0 flex items-center justify-center text-xs font-bold mt-0.5" style={trader_avatar_style(to_string(@active_actor_id))}>
                  {String.first(player_name(@active_actor_id, @players)) |> String.upcase()}
                </div>
                <div class="rounded-lg px-3 py-2 border" style="background: rgba(15, 23, 42, 0.6); border-color: rgba(6, 182, 212, 0.2);">
                  <div class="flex items-center gap-1">
                    <div class="w-1.5 h-1.5 rounded-full sm-typing-dot-1" style="background: #06b6d4;"></div>
                    <div class="w-1.5 h-1.5 rounded-full sm-typing-dot-2" style="background: #06b6d4;"></div>
                    <div class="w-1.5 h-1.5 rounded-full sm-typing-dot-3" style="background: #06b6d4;"></div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- ──────── RIGHT PANEL ──────── --%>
        <div class="flex-shrink-0 border-l overflow-y-auto sm-scroll" style="width: 200px; border-color: #1e293b; background: #0c1120;">

          <%!-- ── Leaderboard ── --%>
          <div class="border-b" style="border-color: #1e293b;">
            <div class="px-3 py-2 border-b" style="border-color: #1e293b;">
              <div class="text-xs font-bold uppercase tracking-widest" style="color: #475569;">Leaderboard</div>
            </div>
            <div class="p-2 space-y-1.5">
              <%= for {{pid, pdata, pval}, rank} <- Enum.with_index(@player_list, 1) do %>
                <% bar_pct = if @max_portfolio_val > 0, do: pval / @max_portfolio_val * 100, else: 0 %>
                <% lb_name = get_val(pdata, :name, pid) %>
                <% lb_traits = get_val(@traits, to_string(lb_name), get_val(@traits, pid, [])) %>
                <div class="relative">
                  <div class="flex items-center justify-between mb-0.5">
                    <div class="flex items-center gap-1.5">
                      <span class="text-xs font-bold font-mono" style={"color: #{rank_color(rank)};"}>{rank}</span>
                      <span class="text-xs truncate" style="color: #e2e8f0; max-width: 80px;">{lb_name}</span>
                    </div>
                    <span class="text-xs font-mono font-bold" style="color: #10b981;">${format_price(pval)}</span>
                  </div>
                  <div :if={is_list(lb_traits) && lb_traits != []} class="flex flex-wrap gap-0.5 mb-0.5">
                    <%= for trait <- lb_traits do %>
                      <span class="px-1 rounded" style="background: rgba(16, 185, 129, 0.1); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.2); font-size: 8px; line-height: 12px;">
                        {trait}
                      </span>
                    <% end %>
                  </div>
                  <%!-- Value Bar --%>
                  <div class="w-full rounded-full overflow-hidden" style="height: 4px; background: #1e293b;">
                    <div class="sm-bar-anim rounded-full" style={"height: 100%; width: #{bar_pct}%; background: linear-gradient(90deg, #{rank_gradient(rank)});"}></div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- ── Trade Blotter ── --%>
          <div class="border-b" style="border-color: #1e293b;">
            <div class="px-3 py-2 border-b" style="border-color: #1e293b;">
              <div class="text-xs font-bold uppercase tracking-widest" style="color: #475569;">Trade Blotter</div>
            </div>
            <div class="p-2 space-y-1">
              <div :if={@trade_list == []} class="text-xs text-center py-2" style="color: #475569;">
                No trades this round
              </div>
              <%= for {pid, trade_data} <- @trade_list do %>
                <% action = to_string(get_val(trade_data, :action, "hold")) %>
                <% ticker = to_string(get_val(trade_data, :stock, get_val(trade_data, :ticker, ""))) %>
                <% amount = get_val(trade_data, :amount, get_val(trade_data, :shares, 0)) %>
                <div class="rounded px-2 py-1.5 border" style={trade_entry_style(action)}>
                  <div class="flex items-center justify-between">
                    <span class="text-xs truncate" style="color: #94a3b8; max-width: 60px;">{player_name(pid, @players)}</span>
                    <span class="text-xs font-bold uppercase px-1.5 py-0.5 rounded" style={trade_action_badge(action)}>
                      {action}
                    </span>
                  </div>
                  <div :if={ticker != "" && action != "hold"} class="flex items-center justify-between mt-0.5">
                    <span class="text-xs font-mono font-bold" style="color: #e2e8f0;">{ticker}</span>
                    <span class="text-xs font-mono" style="color: #64748b;">x{amount}</span>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- ── Whisper Network ── --%>
          <div>
            <div class="px-3 py-2 border-b" style="border-color: #1e293b;">
              <div class="text-xs font-bold uppercase tracking-widest" style="color: #475569;">Whisper Network</div>
            </div>
            <div class="p-2">
              <div :if={@whisper_pairs == []} class="text-xs text-center py-2" style="color: #475569;">
                No private channels
              </div>
              <%!-- Whisper connections as a mini graph --%>
              <div :if={@whisper_pairs != []} class="space-y-1">
                <%= for {from, to} <- @whisper_pairs do %>
                  <div class="flex items-center gap-1.5 px-1 py-1 rounded" style="background: rgba(30, 41, 59, 0.3);">
                    <div class="w-5 h-5 rounded-full flex items-center justify-center text-xs font-bold" style={trader_avatar_style(from)}>
                      {String.first(player_name(from, @players)) |> String.upcase()}
                    </div>
                    <%!-- Animated dashed line --%>
                    <svg viewBox="0 0 24 8" class="flex-1" style="height: 8px;">
                      <line x1="0" y1="4" x2="24" y2="4" class="sm-whisper-line" style="stroke: #475569; stroke-width: 1;" />
                    </svg>
                    <div class="w-5 h-5 rounded-full flex items-center justify-center text-xs font-bold" style={trader_avatar_style(to)}>
                      {String.first(player_name(to, @players)) |> String.upcase()}
                    </div>
                  </div>
                <% end %>
              </div>

              <%!-- Market Call History Summary --%>
              <div :if={@market_call_history != []} class="mt-3 border-t pt-2" style="border-color: #1e293b;">
                <div class="text-xs font-bold uppercase tracking-widest mb-1.5" style="color: #475569;">Call History</div>
                <div class="space-y-1">
                  <%= for call <- Enum.take(@market_call_history, 6) do %>
                    <% caller_id = to_string(get_val(call, :player, "")) %>
                    <% stock = to_string(get_val(call, :stock, "")) %>
                    <% stance = to_string(get_val(call, :stance, "")) %>
                    <% is_bull = stance == "bullish" %>
                    <div class="flex items-center gap-1 text-xs">
                      <span style={"color: #{if is_bull, do: "#10b981", else: "#ef4444"};"}>{if is_bull, do: Phoenix.HTML.raw("&#9650;"), else: Phoenix.HTML.raw("&#9660;")}</span>
                      <span class="font-mono" style="color: #94a3b8;">{stock}</span>
                      <span class="truncate" style="color: #64748b; max-width: 60px;">{player_name(caller_id, @players)}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- ──────── FAR-RIGHT PANEL: Journals & Connections ──────── --%>
        <div
          :if={map_size(@journals) > 0 || @connections != []}
          class="flex-shrink-0 border-l overflow-y-auto sm-scroll"
          style="width: 195px; border-color: #1e293b; background: #0c1120;"
        >
          <%!-- ── Trader Thoughts / Journal ── --%>
          <div :if={map_size(@journals) > 0} class="border-b" style="border-color: #1e293b;">
            <div class="px-3 py-2 border-b" style="border-color: #1e293b;">
              <div class="text-xs font-bold uppercase tracking-widest" style="color: #475569;">Trader Thoughts</div>
            </div>
            <div class="p-2 space-y-2">
              <%= for {trader_name, entries} <- Enum.sort_by(@journals, fn {k, _v} -> to_string(k) end) do %>
                <% journal_entries = if is_list(entries), do: entries, else: [] %>
                <div :if={journal_entries != []} class="rounded-lg p-2 border" style="background: rgba(15, 23, 42, 0.4); border-color: #1e293b;">
                  <div class="flex items-center gap-1.5 mb-1.5">
                    <div class="w-4 h-4 rounded-full flex items-center justify-center text-xs font-bold" style={trader_avatar_style(to_string(trader_name))}>
                      {String.first(to_string(trader_name)) |> String.upcase()}
                    </div>
                    <span class="text-xs font-bold truncate" style="color: #e2e8f0; max-width: 110px;">{trader_name}</span>
                  </div>
                  <div class="space-y-1">
                    <%= for entry <- Enum.take(Enum.reverse(journal_entries), 3) do %>
                      <% j_round = get_val(entry, :round, "?") %>
                      <% j_phase = get_val(entry, :phase, "") %>
                      <% j_thought = get_val(entry, :thought, "") %>
                      <div class="rounded px-1.5 py-1 border" style="background: rgba(16, 185, 129, 0.03); border-color: rgba(16, 185, 129, 0.1);">
                        <div class="flex items-center gap-1 mb-0.5">
                          <span class="font-mono" style="color: #34d399; font-size: 8px;">R{j_round}</span>
                          <span :if={j_phase != ""} style="color: #475569; font-size: 8px;">{j_phase}</span>
                        </div>
                        <div class="text-xs leading-snug" style="color: #94a3b8; font-size: 10px;">{j_thought}</div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- ── Backstory Connections ── --%>
          <div :if={@connections != []}>
            <div class="px-3 py-2 border-b" style="border-color: #1e293b;">
              <div class="text-xs font-bold uppercase tracking-widest" style="color: #475569;">Connections</div>
            </div>
            <div class="p-2 space-y-1.5">
              <%= for conn <- @connections do %>
                <% conn_players = get_val(conn, :players, []) %>
                <% conn_type = get_val(conn, :type, "") %>
                <% conn_desc = get_val(conn, :description, "") %>
                <% [p_a, p_b] = case conn_players do
                  [a, b] -> [to_string(a), to_string(b)]
                  _ -> ["?", "?"]
                end %>
                <div class="rounded-lg p-2 border" style="background: rgba(15, 23, 42, 0.4); border-color: rgba(16, 185, 129, 0.15);">
                  <div class="flex items-center gap-1 mb-1">
                    <div class="w-4 h-4 rounded-full flex items-center justify-center text-xs font-bold" style={trader_avatar_style(p_a)}>
                      {String.first(p_a) |> String.upcase()}
                    </div>
                    <svg viewBox="0 0 16 8" class="flex-shrink-0" style="width: 16px; height: 8px;">
                      <line x1="0" y1="4" x2="16" y2="4" style="stroke: #34d399; stroke-width: 1; stroke-dasharray: 2 2;" />
                    </svg>
                    <div class="w-4 h-4 rounded-full flex items-center justify-center text-xs font-bold" style={trader_avatar_style(p_b)}>
                      {String.first(p_b) |> String.upcase()}
                    </div>
                    <span class="px-1 rounded ml-auto" style="background: rgba(16, 185, 129, 0.1); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.2); font-size: 8px; line-height: 12px;">
                      {String.replace(to_string(conn_type), "_", " ")}
                    </span>
                  </div>
                  <div :if={conn_desc != ""} class="text-xs leading-snug" style="color: #64748b; font-size: 9px;">
                    {conn_desc}
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>

      <%!-- ════════════════════════════════════════════ VICTORY OVERLAY ════════════════════════════════════════════ --%>
      <div
        :if={@game_status == "game_over" && @winner}
        class="absolute inset-0 z-50 flex items-center justify-center"
        style="background: rgba(2, 6, 23, 0.88); backdrop-filter: blur(8px);"
      >
        <div class="text-center sm-victory relative" style="max-width: 500px;">
          <%!-- Decorative confetti particles --%>
          <div class="absolute -top-8 left-1/4 w-2 h-2 rounded-full sm-confetti" style="background: #10b981; animation-delay: 0s;"></div>
          <div class="absolute -top-6 left-1/3 w-1.5 h-1.5 rounded-full sm-confetti" style="background: #f59e0b; animation-delay: 0.4s;"></div>
          <div class="absolute -top-10 left-1/2 w-2 h-2 rounded-full sm-confetti" style="background: #06b6d4; animation-delay: 0.8s;"></div>
          <div class="absolute -top-7 left-2/3 w-1.5 h-1.5 rounded-full sm-confetti" style="background: #ef4444; animation-delay: 1.2s;"></div>
          <div class="absolute -top-9 right-1/4 w-2 h-2 rounded-full sm-confetti" style="background: #10b981; animation-delay: 1.6s;"></div>

          <%!-- Trophy --%>
          <div class="text-5xl mb-3" style="filter: drop-shadow(0 0 20px rgba(245, 158, 11, 0.5));">
            {Phoenix.HTML.raw("&#x1F3C6;")}
          </div>

          <%!-- Title Banner --%>
          <div class="mb-2 px-6 py-2 rounded-lg inline-block" style="background: linear-gradient(135deg, rgba(245, 158, 11, 0.2) 0%, rgba(16, 185, 129, 0.2) 100%); border: 1px solid rgba(245, 158, 11, 0.3);">
            <div class="text-xs font-bold uppercase tracking-[0.3em] mb-1" style="color: #f59e0b;">Wolf of Wall Street</div>
            <div class="text-2xl font-black tracking-tight" style="color: #e2e8f0;">
              {player_name(@winner, @players)}
            </div>
          </div>

          <%!-- Winner Stats --%>
          <% winner_data = get_val(@players, String.to_atom(@winner || ""), get_val(@players, @winner, %{})) %>
          <% winner_val = portfolio_value(winner_data, @stocks) %>
          <div class="flex justify-center gap-6 mt-4">
            <div class="text-center">
              <div class="text-xl font-bold font-mono" style="color: #10b981;">${format_price(winner_val)}</div>
              <div class="text-xs uppercase tracking-wider mt-0.5" style="color: #64748b;">Portfolio Value</div>
            </div>
            <div class="text-center">
              <div class="text-xl font-bold font-mono" style="color: #e2e8f0;">{@round}</div>
              <div class="text-xs uppercase tracking-wider mt-0.5" style="color: #64748b;">Rounds Played</div>
            </div>
            <div class="text-center">
              <div class="text-xl font-bold font-mono" style="color: #f59e0b;">{reputation_stars(get_val(winner_data, :reputation, 5))}</div>
              <div class="text-xs uppercase tracking-wider mt-0.5" style="color: #64748b;">Reputation</div>
            </div>
          </div>

          <%!-- Final Rankings --%>
          <div class="mt-6 rounded-lg p-4 text-left" style="background: rgba(15, 23, 42, 0.6); border: 1px solid #1e293b;">
            <div class="text-xs font-bold uppercase tracking-widest mb-3" style="color: #475569;">Final Rankings</div>
            <div class="space-y-2">
              <%= for {{pid, pdata, pval}, rank} <- Enum.with_index(@player_list, 1) do %>
                <% is_winner = to_string(@winner) == pid %>
                <div class="flex items-center gap-3 py-1" style={if is_winner, do: "background: rgba(245, 158, 11, 0.05); border-radius: 6px; padding: 6px 8px; border: 1px solid rgba(245, 158, 11, 0.15);", else: "padding: 6px 8px;"}>
                  <span class="text-sm font-bold font-mono w-5 text-right" style={"color: #{rank_color(rank)};"}>{rank}</span>
                  <span :if={is_winner} class="text-xs">{Phoenix.HTML.raw("&#x1F3C6;")}</span>
                  <span class="text-sm flex-1 truncate" style={"color: #{if is_winner, do: "#f59e0b", else: "#e2e8f0"};"}>{get_val(pdata, :name, pid)}</span>
                  <span class="text-sm font-mono font-bold" style="color: #10b981;">${format_price(pval)}</span>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Decorative bottom line --%>
          <div class="mt-6 mx-auto rounded-full" style="width: 200px; height: 2px; background: linear-gradient(90deg, transparent, #f59e0b, transparent);"></div>
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

  # ── Player Name ──────────────────────────────────────────────────

  defp player_name(nil, _players), do: "?"

  defp player_name(id, players) when is_map(players) do
    pid = to_string(id)
    # Try atom and string keys for the player map
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

  # ── Sparkline SVG Helpers ────────────────────────────────────────

  defp sparkline_path([], _w, _h), do: ""
  defp sparkline_path([_single], _w, _h), do: ""

  defp sparkline_path(points, w, h) do
    {min_v, max_v} = Enum.min_max(points)
    range = max(max_v - min_v, 0.01)
    n = length(points)
    step = w / max(n - 1, 1)
    padding = 2

    points
    |> Enum.with_index()
    |> Enum.map(fn {val, i} ->
      x = Float.round(i * step, 1)
      y = Float.round(h - padding - (val - min_v) / range * (h - 2 * padding), 1)
      {x, y}
    end)
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
    |> then(fn coords -> "M #{coords}" end)
  end

  defp sparkline_area_path([], _w, _h), do: ""
  defp sparkline_area_path([_single], _w, _h), do: ""

  defp sparkline_area_path(points, w, h) do
    {min_v, max_v} = Enum.min_max(points)
    range = max(max_v - min_v, 0.01)
    n = length(points)
    step = w / max(n - 1, 1)
    padding = 2

    line_points =
      points
      |> Enum.with_index()
      |> Enum.map(fn {val, i} ->
        x = Float.round(i * step, 1)
        y = Float.round(h - padding - (val - min_v) / range * (h - 2 * padding), 1)
        {x, y}
      end)

    line_str = Enum.map_join(line_points, " ", fn {x, y} -> "#{x},#{y}" end)
    {last_x, _} = List.last(line_points)
    {first_x, _} = List.first(line_points)

    "M #{line_str} L #{last_x},#{h} L #{first_x},#{h} Z"
  end

  defp sparkline_last_x([], _w), do: 0

  defp sparkline_last_x(points, w) do
    n = length(points)
    step = w / max(n - 1, 1)
    Float.round((n - 1) * step, 1)
  end

  defp sparkline_last_y([], _h), do: 0

  defp sparkline_last_y(points, h) do
    {min_v, max_v} = Enum.min_max(points)
    range = max(max_v - min_v, 0.01)
    padding = 2
    val = List.last(points)
    Float.round(h - padding - (val - min_v) / range * (h - 2 * padding), 1)
  end

  # ── Price Formatting ─────────────────────────────────────────────

  defp format_price(val) when is_float(val), do: :erlang.float_to_binary(val, decimals: 2)
  defp format_price(val) when is_integer(val), do: :erlang.float_to_binary(val / 1, decimals: 2)
  defp format_price(_), do: "0.00"

  defp format_pct(val) when is_float(val), do: :erlang.float_to_binary(abs(val), decimals: 1)
  defp format_pct(_), do: "0.0"

  # ── Portfolio Value Calculation ──────────────────────────────────

  defp portfolio_value(player_data, stocks) when is_map(player_data) do
    cash = get_val(player_data, :cash, 0)
    portfolio = get_val(player_data, :portfolio, %{})
    short_book = get_val(player_data, :short_book, %{})

    long_value =
      Enum.reduce(portfolio, 0, fn {ticker, shares}, acc ->
        stock =
          Map.get(stocks, ticker) || Map.get(stocks, to_string(ticker)) ||
            try_atom_key(stocks, to_string(ticker)) || %{}

        price = get_val(stock, :price, 0)
        shares_num = if is_number(shares), do: shares, else: 0
        acc + shares_num * price
      end)

    short_value =
      Enum.reduce(short_book, 0, fn {ticker, short_data}, acc ->
        stock =
          Map.get(stocks, ticker) || Map.get(stocks, to_string(ticker)) ||
            try_atom_key(stocks, to_string(ticker)) || %{}

        current_price = get_val(stock, :price, 0)
        # short_data might be a map with shares and entry_price, or just shares count
        {shares_num, entry_price} = parse_short_entry(short_data, current_price)
        # Short P/L = (entry_price - current_price) * shares
        acc + (entry_price - current_price) * shares_num
      end)

    cash + long_value + short_value
  end

  defp portfolio_value(_, _), do: 0

  defp parse_short_entry(data, current_price) when is_map(data) do
    shares = get_val(data, :shares, 0)
    entry = get_val(data, :entry_price, current_price)

    {if(is_number(shares), do: shares, else: 0),
     if(is_number(entry), do: entry, else: current_price)}
  end

  defp parse_short_entry(shares, current_price) when is_number(shares),
    do: {shares, current_price}

  defp parse_short_entry(_, current_price), do: {0, current_price}

  # ── Wealth Sparkline Data ────────────────────────────────────────

  defp compute_wealth_hint(player_data, stocks) do
    # Use trade_history to approximate past wealth, or just show current as single point
    trade_history = get_val(player_data, :trade_history, [])
    current = portfolio_value(player_data, stocks)

    case trade_history do
      hist when is_list(hist) and length(hist) > 0 ->
        # Extract past portfolio values if available
        values =
          Enum.map(hist, fn entry ->
            get_val(entry, :portfolio_value, get_val(entry, :value, current))
          end)

        values ++ [current]

      _ ->
        # Just the current value -- need at least 2 for a sparkline
        [current * 0.9, current]
    end
  end

  # ── Reputation Stars ─────────────────────────────────────────────

  defp reputation_stars(rep) when is_number(rep) do
    filled = round(min(max(rep, 0), 5))
    empty = 5 - filled

    stars =
      String.duplicate("&#9733;", filled) <>
        String.duplicate("&#9734;", empty)

    Phoenix.HTML.raw(
      "<span class=\"sm-star\" style=\"color: #f59e0b; font-size: 10px; letter-spacing: 1px;\">#{stars}</span>"
    )
  end

  defp reputation_stars(_), do: reputation_stars(3)

  # ── Phase Badge ──────────────────────────────────────────────────

  defp phase_badge_class("discussion") do
    "border-cyan-500/30 text-cyan-400"
  end

  defp phase_badge_class("trading") do
    "border-emerald-500/30 text-emerald-400"
  end

  defp phase_badge_class("game_over") do
    "border-amber-500/30 text-amber-400"
  end

  defp phase_badge_class(_) do
    "border-gray-500/30 text-gray-400"
  end

  defp phase_label("discussion"), do: "Discussion"
  defp phase_label("trading"), do: "Trading"
  defp phase_label("game_over"), do: "Game Over"
  defp phase_label(other) when is_binary(other), do: String.capitalize(other)
  defp phase_label(_), do: "Unknown"

  # ── Trader Card Styling ──────────────────────────────────────────

  defp trader_card_style(true = _active) do
    "background: rgba(6, 182, 212, 0.06); border-color: rgba(6, 182, 212, 0.3);"
  end

  defp trader_card_style(false) do
    "background: rgba(15, 23, 42, 0.4); border-color: #1e293b;"
  end

  defp trader_avatar_style(pid) do
    # Deterministic color based on player id hash
    hue = :erlang.phash2(to_string(pid), 360)

    "background: hsl(#{hue}, 60%, 25%); color: hsl(#{hue}, 70%, 75%); border: 1px solid hsl(#{hue}, 50%, 35%);"
  end

  # ── Speech Bubble Styling ────────────────────────────────────────

  defp speech_bubble_style(true = _is_call) do
    "background: rgba(15, 23, 42, 0.7); border-color: rgba(245, 158, 11, 0.25);"
  end

  defp speech_bubble_style(false) do
    "background: rgba(15, 23, 42, 0.6); border-color: #1e293b;"
  end

  # ── Trade Entry Styling ──────────────────────────────────────────

  defp trade_entry_style(action) do
    case action do
      "buy" -> "background: rgba(16, 185, 129, 0.05); border-color: rgba(16, 185, 129, 0.2);"
      "sell" -> "background: rgba(239, 68, 68, 0.05); border-color: rgba(239, 68, 68, 0.2);"
      "short" -> "background: rgba(239, 68, 68, 0.08); border-color: rgba(239, 68, 68, 0.25);"
      "cover" -> "background: rgba(6, 182, 212, 0.05); border-color: rgba(6, 182, 212, 0.2);"
      _ -> "background: rgba(30, 41, 59, 0.3); border-color: #1e293b;"
    end
  end

  defp trade_action_badge(action) do
    case action do
      "buy" -> "background: rgba(16, 185, 129, 0.15); color: #10b981;"
      "sell" -> "background: rgba(239, 68, 68, 0.15); color: #ef4444;"
      "short" -> "background: rgba(239, 68, 68, 0.2); color: #f87171;"
      "cover" -> "background: rgba(6, 182, 212, 0.15); color: #06b6d4;"
      "hold" -> "background: rgba(71, 85, 105, 0.2); color: #64748b;"
      _ -> "background: rgba(71, 85, 105, 0.15); color: #64748b;"
    end
  end

  # ── Rank Helpers ─────────────────────────────────────────────────

  defp rank_color(1), do: "#f59e0b"
  defp rank_color(2), do: "#94a3b8"
  defp rank_color(3), do: "#b45309"
  defp rank_color(_), do: "#64748b"

  defp rank_gradient(1), do: "#f59e0b, #10b981"
  defp rank_gradient(2), do: "#94a3b8, #64748b"
  defp rank_gradient(3), do: "#b45309, #92400e"
  defp rank_gradient(_), do: "#475569, #334155"
end
