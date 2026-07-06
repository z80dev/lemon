defmodule LemonSimUi.Live.Components.PokerBoard do
  @moduledoc """
  Renders the Poker (no-limit hold'em) simulation board with community
  cards, per-seat hole cards/stacks, pot/blinds, and hand results.
  """
  use Phoenix.Component

  alias LemonCore.MapHelpers
  alias LemonSimUi.ArtifactReader
  alias LemonSim.Examples.Poker.Engine.{Card, Table}

  attr(:world, :map, required: true)
  attr(:interactive, :boolean, default: false)

  def render(assigns) do
    world = assigns.world
    table = gv(world, :table)
    hand = gv(table, :hand)
    status = gv(world, :status, "in_progress")
    winner_ids = gv(world, :winner_ids, [])
    game_over_reason = gv(world, :game_over_reason)
    completed_hands = gv(world, :completed_hands, 0)
    max_hands = gv(world, :max_hands, 1)
    players = gv(world, :players, %{})
    player_stats = gv(world, :player_stats, %{})
    current_actor_id = gv(world, :current_actor_id)

    small_blind = gv(table, :small_blind) || gv(world, :small_blind) || 0
    big_blind = gv(table, :big_blind) || gv(world, :big_blind) || 0

    street = gv(hand, :street)
    pot = gv(hand, :pot)
    to_call = gv(hand, :to_call)
    board_cards = gv(hand, :board, [])
    acting_seat = gv(hand, :acting_seat)

    hand_label =
      if status == "game_over" do
        "Complete"
      else
        "Hand #{completed_hands + 1} of #{max_hands}"
      end

    seats = build_seats(table)

    seat_rows =
      Enum.map(seats, fn seat_info ->
        seat = seat_info.seat
        hand_player = hand_player_at(hand, seat)

        %{
          seat: seat,
          player_id: seat_info.player_id,
          seat_status: seat_info.status,
          model: player_model(players, seat_info.player_id),
          stack: (hand_player && gv(hand_player, :stack)) || seat_info.stack,
          committed_round: hand_player && gv(hand_player, :committed_round, 0),
          folded: !!(hand_player && gv(hand_player, :folded)),
          all_in: !!(hand_player && gv(hand_player, :all_in)),
          hole_cards: (hand_player && gv(hand_player, :hole_cards)) || [],
          acting: !!(hand && acting_seat == seat),
          position: seat_position(seat, hand)
        }
      end)

    result_view = build_result_view(gv(world, :last_hand_result), table)

    final_leaderboard = Enum.sort_by(seats, &(-&1.stack))

    stats_rows =
      players
      |> Enum.map(fn {player_id, pinfo} ->
        stats = Map.get(player_stats, player_id, %{})
        hands_played = gv(stats, :hands_played, 0)
        vpip_hands = gv(stats, :vpip_hands, 0)
        pfr_hands = gv(stats, :pfr_hands, 0)

        %{
          player_id: player_id,
          seat: gv(pinfo, :seat, 0),
          hands_played: hands_played,
          hands_won: gv(stats, :hands_won, 0),
          vpip_pct: pct(vpip_hands, hands_played),
          pfr_pct: pct(pfr_hands, hands_played)
        }
      end)
      |> Enum.sort_by(& &1.seat)

    assigns =
      assigns
      |> assign(:hand_label, hand_label)
      |> assign(:street_label, street_label(street))
      |> assign(:small_blind, small_blind)
      |> assign(:big_blind, big_blind)
      |> assign(:pot, pot)
      |> assign(:to_call, to_call)
      |> assign(:board_slots, board_slots(board_cards))
      |> assign(:hand_in_progress?, !is_nil(hand))
      |> assign(:current_actor_id, current_actor_id)
      |> assign(:seat_rows, seat_rows)
      |> assign(:result_view, result_view)
      |> assign(:stats_rows, stats_rows)
      |> assign(:game_status, status)
      |> assign(:winner_ids, winner_ids)
      |> assign(:game_over_reason, game_over_reason_label(game_over_reason))
      |> assign(:final_leaderboard, final_leaderboard)

    ~H"""
    <div class="relative w-full font-sans" style="background: #05130d; color: #e2e8f0; min-height: 600px;">
      <style>
        @keyframes pkr-acting-glow {
          0%, 100% { box-shadow: 0 0 0 1px rgba(52, 211, 153, 0.4), 0 0 12px rgba(52, 211, 153, 0.2); }
          50% { box-shadow: 0 0 0 1px rgba(52, 211, 153, 0.8), 0 0 22px rgba(52, 211, 153, 0.45); }
        }
        .pkr-acting { animation: pkr-acting-glow 1.8s ease-in-out infinite; }

        @keyframes pkr-pot-pulse {
          0%, 100% { text-shadow: 0 0 10px rgba(251, 191, 36, 0.35); }
          50% { text-shadow: 0 0 20px rgba(251, 191, 36, 0.6); }
        }
        .pkr-pot { animation: pkr-pot-pulse 2.4s ease-in-out infinite; }
      </style>

      <%!-- ── Header strip ── --%>
      <div
        class="flex flex-wrap items-center justify-between gap-3 px-4 py-3 border-b"
        style="border-color: rgba(16,185,129,0.15); background: linear-gradient(180deg, rgba(6,20,14,0.9), rgba(5,19,13,0.6));"
      >
        <div class="flex flex-wrap items-center gap-2">
          <div
            class="px-3 py-1 rounded-full text-xs font-bold uppercase tracking-widest border"
            style="background: rgba(16,185,129,0.1); color: #34d399; border-color: rgba(16,185,129,0.3);"
          >
            {@hand_label}
          </div>
          <div
            :if={@street_label}
            class="px-3 py-1 rounded-full text-xs font-bold uppercase tracking-wider border"
            style="background: rgba(245,158,11,0.1); color: #fbbf24; border-color: rgba(245,158,11,0.3);"
          >
            {@street_label}
          </div>
          <div class="text-xs font-mono text-slate-500">
            Blinds <span class="text-slate-300">{format_chips(@small_blind)}/{format_chips(@big_blind)}</span>
          </div>
          <div :if={@to_call && @to_call > 0} class="text-xs font-mono text-slate-500">
            To call <span class="text-slate-200 font-bold">{format_chips(@to_call)}</span>
          </div>
          <div :if={@hand_in_progress? && @game_status == "in_progress" && @current_actor_id} class="text-xs font-mono text-emerald-400/80 italic">
            Waiting on {@current_actor_id}&hellip;
          </div>
        </div>

        <div class="text-right">
          <div class="text-[10px] uppercase tracking-widest text-slate-500 font-bold">Pot</div>
          <div class="pkr-pot text-2xl font-black font-mono" style="color: #fbbf24;">
            {format_chips(@pot)}
          </div>
        </div>
      </div>

      <%!-- ── Community board ── --%>
      <div class="flex flex-col items-center gap-2 px-4 py-6">
        <div class="flex items-center gap-2">
          <.card_chip :for={card <- @board_slots} card={card} muted={!@hand_in_progress?} />
        </div>
        <div :if={!@hand_in_progress?} class="text-xs italic text-slate-500">
          {if @game_status == "game_over", do: "Table closed", else: "Waiting for next hand..."}
        </div>
      </div>

      <%!-- ── Seats ── --%>
      <div class="grid gap-3 px-4 pb-4" style="grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));">
        <.seat_tile :for={seat <- @seat_rows} seat={seat} />
      </div>

      <%!-- ── Last hand result ── --%>
      <div
        :if={@result_view}
        class="mx-4 mb-4 rounded-xl border p-4"
        style="background: rgba(6,20,14,0.6); border-color: rgba(16,185,129,0.15);"
      >
        <div class="flex items-center gap-2 mb-3">
          <span class="text-xs font-bold uppercase tracking-widest text-emerald-400">
            Last Hand #{@result_view.hand_id}
          </span>
          <span class="text-xs text-slate-500">&middot;</span>
          <span class="text-xs text-slate-400">{@result_view.ended_by_label}</span>
        </div>

        <div :if={@result_view.board != []} class="flex items-center gap-1.5 mb-3">
          <.card_chip :for={card <- @result_view.board} card={card} />
        </div>

        <div class="space-y-1 mb-2">
          <div :for={w <- @result_view.winners} class="flex items-center justify-between text-sm">
            <span class="text-slate-200 font-semibold">{w.player_id}</span>
            <span class="text-emerald-400 font-mono font-bold">+{format_chips(w.amount)}</span>
          </div>
        </div>

        <div :if={@result_view.showdown != []} class="space-y-1.5 border-t pt-2" style="border-color: rgba(255,255,255,0.06);">
          <div :for={s <- @result_view.showdown} class="flex items-center justify-between text-xs gap-2">
            <span class="text-slate-400 truncate">{s.player_id}</span>
            <div class="flex items-center gap-1.5">
              <.card_chip :for={card <- s.hole_cards} card={card} />
              <span :if={s.category_label} class="text-slate-500 ml-1 whitespace-nowrap">{s.category_label}</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- ── Session stats ── --%>
      <div
        :if={@stats_rows != []}
        class="mx-4 mb-4 rounded-xl border p-3 overflow-x-auto"
        style="background: rgba(6,20,14,0.4); border-color: rgba(255,255,255,0.06);"
      >
        <table class="min-w-full text-xs">
          <thead class="text-slate-500 uppercase tracking-widest font-mono">
            <tr>
              <th class="py-1 pr-4 text-left">Player</th>
              <th class="py-1 pr-4 text-right">Hands</th>
              <th class="py-1 pr-4 text-right">Won</th>
              <th class="py-1 pr-4 text-right">VPIP</th>
              <th class="py-1 pr-4 text-right">PFR</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-white/5">
            <tr :for={row <- @stats_rows}>
              <td class="py-1.5 pr-4 font-semibold text-slate-200">{row.player_id}</td>
              <td class="py-1.5 pr-4 text-right font-mono text-slate-300">{row.hands_played}</td>
              <td class="py-1.5 pr-4 text-right font-mono text-emerald-400">{row.hands_won}</td>
              <td class="py-1.5 pr-4 text-right font-mono text-slate-300">{row.vpip_pct}%</td>
              <td class="py-1.5 pr-4 text-right font-mono text-slate-300">{row.pfr_pct}%</td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- ── Game over banner ── --%>
      <div
        :if={@game_status == "game_over"}
        class="mx-4 mb-4 rounded-xl border p-5 text-center"
        style="background: linear-gradient(135deg, rgba(251,191,36,0.08), rgba(16,185,129,0.08)); border-color: rgba(251,191,36,0.25);"
      >
        <div class="text-3xl mb-2">{Phoenix.HTML.raw("&#x1F3C6;")}</div>
        <div class="text-lg font-black" style="color: #fbbf24;">
          {winner_banner_text(@winner_ids)}
        </div>
        <div :if={@game_over_reason} class="text-xs text-slate-500 mt-1">{@game_over_reason}</div>

        <div class="mt-4 space-y-1.5 max-w-sm mx-auto text-left">
          <div
            :for={{seat, rank} <- Enum.with_index(@final_leaderboard, 1)}
            class={[
              "flex items-center gap-2 px-3 py-1.5 rounded-lg",
              if(seat.player_id in @winner_ids, do: "bg-amber-500/10 border border-amber-500/20", else: "")
            ]}
          >
            <span class="text-sm font-bold font-mono w-5 text-right text-slate-500">{rank}</span>
            <span :if={seat.player_id in @winner_ids} class="text-xs">{Phoenix.HTML.raw("&#x1F3C6;")}</span>
            <span class="text-sm flex-1 truncate" style={if seat.player_id in @winner_ids, do: "color: #fbbf24;", else: "color: #e2e8f0;"}>
              {seat.player_id}
            </span>
            <span class="text-sm font-mono font-bold text-emerald-400">{format_chips(seat.stack)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Seat tile ─────────────────────────────────────────────────────

  attr(:seat, :map, required: true)

  defp seat_tile(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border p-3 flex flex-col gap-2 bg-black/20",
      seat_tile_class(@seat)
    ]}>
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-1.5 min-w-0">
          <span class="text-[10px] font-mono text-slate-600">S{@seat.seat}</span>
          <span class="text-sm font-bold text-slate-100 truncate">{@seat.player_id}</span>
          <span
            :if={@seat.position}
            class="px-1.5 py-0.5 rounded text-[9px] font-black uppercase tracking-wider bg-amber-500/15 text-amber-300 border border-amber-500/30"
          >
            {@seat.position}
          </span>
        </div>
        <span
          :if={@seat.acting}
          class="flex-shrink-0 flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-emerald-500/15 text-emerald-300 text-[9px] font-bold uppercase tracking-widest border border-emerald-500/30"
        >
          <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span> Acting
        </span>
      </div>

      <div :if={@seat.model} class="text-[9px] font-mono text-slate-500 truncate" title={@seat.model}>
        {short_model_name(@seat.model)}
      </div>

      <div :if={@seat.hole_cards != []} class="flex items-center gap-1.5">
        <.card_chip :for={card <- @seat.hole_cards} card={card} />
      </div>

      <div class="flex items-center justify-between text-xs">
        <div class="flex items-center gap-1.5 text-slate-400">
          <span class="font-mono font-bold text-slate-100">{format_chips(@seat.stack)}</span>
          <span class="text-[9px] uppercase tracking-wide text-slate-600">stack</span>
        </div>
        <div :if={@seat.committed_round && @seat.committed_round > 0} class="text-amber-300 font-mono text-xs">
          bet {format_chips(@seat.committed_round)}
        </div>
      </div>

      <div :if={@seat.folded || @seat.all_in || @seat.seat_status in ["busted", "sitting_out"]} class="flex items-center gap-1 flex-wrap">
        <span :if={@seat.folded} class="px-1.5 py-0.5 rounded text-[9px] font-bold uppercase bg-slate-800/70 text-slate-500 border border-slate-700">
          Folded
        </span>
        <span :if={@seat.all_in} class="px-1.5 py-0.5 rounded text-[9px] font-bold uppercase bg-red-900/40 text-red-300 border border-red-500/30">
          All-In
        </span>
        <span :if={@seat.seat_status == "busted"} class="px-1.5 py-0.5 rounded text-[9px] font-bold uppercase bg-slate-900 text-slate-600 border border-slate-700">
          Busted
        </span>
        <span :if={@seat.seat_status == "sitting_out"} class="px-1.5 py-0.5 rounded text-[9px] font-bold uppercase bg-slate-900 text-slate-600 border border-slate-700">
          Sitting Out
        </span>
      </div>
    </div>
    """
  end

  defp seat_tile_class(%{acting: true}), do: "pkr-acting border-emerald-500/40"
  defp seat_tile_class(%{folded: true}), do: "opacity-50 border-slate-800"
  defp seat_tile_class(%{seat_status: "busted"}), do: "opacity-40 border-slate-800"
  defp seat_tile_class(_seat), do: "border-slate-800"

  # ── Card chip ─────────────────────────────────────────────────────

  attr(:card, :any, default: nil)
  attr(:muted, :boolean, default: false)

  defp card_chip(assigns) do
    short = assigns.card && card_short(assigns.card)
    suit = short && String.last(short)

    assigns =
      assigns
      |> assign(:rank, short && String.slice(short, 0..-2//1))
      |> assign(:suit_symbol, suit && suit_symbol(suit))
      |> assign(:red?, !!(suit && red_suit?(suit)))

    ~H"""
    <div
      :if={@card}
      class={[
        "w-8 h-11 rounded-md border flex flex-col items-center justify-center font-mono font-bold text-sm shadow-sm bg-white flex-shrink-0",
        if(@red?, do: "text-red-600 border-red-200", else: "text-slate-900 border-slate-300")
      ]}
    >
      <span class="leading-none">{@rank}</span>
      <span class="leading-none text-xs">{@suit_symbol}</span>
    </div>
    <div
      :if={!@card}
      class={[
        "w-8 h-11 rounded-md border border-dashed flex-shrink-0",
        if(@muted, do: "border-slate-700/40 bg-slate-900/20", else: "border-slate-600/50 bg-slate-900/40")
      ]}
    >
    </div>
    """
  end

  # ── Flexible key access ───────────────────────────────────────────

  defp gv(nil, _key, default), do: default

  defp gv(map, key, default) when is_map(map) do
    case MapHelpers.get_key(map, key) do
      nil -> default
      value -> value
    end
  end

  defp gv(_map, _key, default), do: default

  defp gv(map, key), do: gv(map, key, nil)

  # ── Seats / hand-player lookups ──────────────────────────────────

  defp build_seats(table) do
    table
    |> gv(:seats, %{})
    |> Enum.map(fn {seat, seat_player} ->
      %{
        seat: to_int(seat),
        player_id: gv(seat_player, :player_id),
        stack: gv(seat_player, :stack, 0),
        status: to_string(gv(seat_player, :status, :active))
      }
    end)
    |> Enum.sort_by(& &1.seat)
  end

  defp hand_player_at(nil, _seat), do: nil

  defp hand_player_at(hand, seat) do
    hand_players = gv(hand, :players, %{})
    Map.get(hand_players, seat) || Map.get(hand_players, to_string(seat))
  end

  defp player_model(players, player_id) when is_map(players) do
    players
    |> Map.get(player_id, %{})
    |> gv(:model)
  end

  defp player_model(_players, _player_id), do: nil

  defp seat_position(_seat, nil), do: nil

  defp seat_position(seat, hand) do
    button = gv(hand, :button_seat)
    sb = gv(hand, :small_blind_seat)
    bb = gv(hand, :big_blind_seat)

    active =
      hand
      |> gv(:players, %{})
      |> Map.keys()
      |> Enum.map(&to_int/1)
      |> Enum.sort()

    if is_integer(seat) do
      Table.position_label(seat, button, sb, bb, active)
    end
  end

  defp to_int(seat) when is_integer(seat), do: seat

  defp to_int(seat) when is_binary(seat) do
    case Integer.parse(seat) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_int(_seat), do: 0

  # ── Last hand result ──────────────────────────────────────────────

  defp build_result_view(nil, _table), do: nil

  defp build_result_view(result, table) do
    seats = gv(table, :seats, %{})

    winners =
      result
      |> gv(:winners, %{})
      |> Enum.map(fn {seat, amount} ->
        %{seat: to_int(seat), player_id: seat_player_id(seats, seat), amount: amount}
      end)
      |> Enum.sort_by(&(-&1.amount))

    showdown =
      (gv(result, :showdown) || %{})
      |> Enum.map(fn {seat, info} ->
        %{
          seat: to_int(seat),
          player_id: seat_player_id(seats, seat),
          category_label: format_category(gv(info, :category)),
          hole_cards: gv(info, :hole_cards, [])
        }
      end)
      |> Enum.sort_by(& &1.seat)

    %{
      hand_id: gv(result, :hand_id),
      ended_by_label: ended_by_label(gv(result, :ended_by)),
      board: gv(result, :board, []),
      winners: winners,
      showdown: showdown
    }
  end

  defp seat_player_id(seats, seat) do
    case Map.get(seats, seat) || Map.get(seats, to_string(seat)) do
      nil -> "seat #{seat}"
      seat_player -> gv(seat_player, :player_id, "seat #{seat}")
    end
  end

  # ── Board slots (5 community card slots, padded with placeholders) ──

  defp board_slots(cards) when is_list(cards) do
    cards ++ List.duplicate(nil, max(5 - length(cards), 0))
  end

  defp board_slots(_cards), do: List.duplicate(nil, 5)

  # ── Card rendering helpers ────────────────────────────────────────

  @rank_names %{
    "two" => "2",
    "three" => "3",
    "four" => "4",
    "five" => "5",
    "six" => "6",
    "seven" => "7",
    "eight" => "8",
    "nine" => "9",
    "ten" => "T",
    "jack" => "J",
    "queen" => "Q",
    "king" => "K",
    "ace" => "A"
  }
  @suit_names %{"clubs" => "c", "diamonds" => "d", "hearts" => "h", "spades" => "s"}

  defp card_short(%Card{} = card), do: Card.to_short_string(card)
  defp card_short(card) when is_binary(card) and byte_size(card) == 2, do: card

  defp card_short(%{} = card) do
    rank = gv(card, :rank)
    suit = gv(card, :suit)
    rank_char = Map.get(@rank_names, to_string(rank), "?")
    suit_char = Map.get(@suit_names, to_string(suit), "?")
    rank_char <> suit_char
  end

  defp card_short(_card), do: "??"

  defp suit_symbol("c"), do: "♣"
  defp suit_symbol("d"), do: "♦"
  defp suit_symbol("h"), do: "♥"
  defp suit_symbol("s"), do: "♠"
  defp suit_symbol(_), do: "?"

  defp red_suit?(suit), do: suit in ["h", "d"]

  # ── Labels ────────────────────────────────────────────────────────

  defp street_label(:preflop), do: "Preflop"
  defp street_label("preflop"), do: "Preflop"
  defp street_label(:flop), do: "Flop"
  defp street_label("flop"), do: "Flop"
  defp street_label(:turn), do: "Turn"
  defp street_label("turn"), do: "Turn"
  defp street_label(:river), do: "River"
  defp street_label("river"), do: "River"
  defp street_label(street) when is_binary(street), do: String.capitalize(street)
  defp street_label(_), do: nil

  defp ended_by_label(:fold), do: "Won by fold"
  defp ended_by_label("fold"), do: "Won by fold"
  defp ended_by_label(:showdown), do: "Showdown"
  defp ended_by_label("showdown"), do: "Showdown"
  defp ended_by_label(_), do: "Hand complete"

  defp game_over_reason_label(:last_player_standing), do: "Last player standing"
  defp game_over_reason_label("last_player_standing"), do: "Last player standing"
  defp game_over_reason_label(:hand_limit), do: "Hand limit reached"
  defp game_over_reason_label("hand_limit"), do: "Hand limit reached"
  defp game_over_reason_label(:table_stalled), do: "Table stalled"
  defp game_over_reason_label("table_stalled"), do: "Table stalled"
  defp game_over_reason_label(_), do: nil

  defp format_category(nil), do: nil

  defp format_category(category) do
    category
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp winner_banner_text([]), do: "Game Over"
  defp winner_banner_text([single]), do: "#{single} wins!"
  defp winner_banner_text(many) when is_list(many), do: "Tied: #{Enum.join(many, ", ")}"

  # ── Chips / model formatting ─────────────────────────────────────

  defp format_chips(value), do: ArtifactReader.format_integer(value)

  defp pct(_numerator, 0), do: 0
  defp pct(numerator, denominator), do: round(numerator / denominator * 100)

  defp short_model_name(full_name) when is_binary(full_name) do
    full_name
    |> String.split("/")
    |> List.last()
    |> String.replace("-preview", "")
    |> String.replace("claude-", "")
    |> String.replace("gpt-", "gpt")
  end

  defp short_model_name(_), do: ""
end
