defmodule LemonWeb.GameMatchLive do
  @moduledoc false

  use LemonWeb, :live_view

  alias LemonCore.Event
  alias LemonGames.{Bus, Matches.Service}

  @event_batch_limit 100

  @impl true
  def mount(%{"id" => match_id}, _session, socket) do
    mount_with_match_id(match_id, socket)
  end

  def mount(_params, %{"id" => match_id}, socket) do
    mount_with_match_id(match_id, socket)
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Game Match")
     |> assign(:match_id, nil)
     |> assign(:match, nil)
     |> assign(:events, [])
     |> assign(:last_seq, 0)
     |> assign(:not_found?, true)}
  end

  @impl true
  def handle_info(%Event{type: :game_match_event}, socket) do
    {new_events, next_seq} = fetch_events(socket.assigns.match_id, socket.assigns.last_seq)

    match =
      case Service.get_match(socket.assigns.match_id, "spectator") do
        {:ok, value} -> value
        _ -> socket.assigns.match
      end

    {:noreply,
     socket
     |> assign(:match, match)
     |> assign(:events, socket.assigns.events ++ new_events)
     |> assign(:last_seq, next_seq)}
  end

  def handle_info(%Event{}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-100">
      <div class="mx-auto w-full max-w-5xl px-4 py-6 sm:px-6">
        <header class="rounded-2xl border border-slate-200 bg-white px-4 py-4 shadow-sm">
          <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon Games</p>
          <h1 class="mt-1 text-xl font-semibold text-slate-900">Match</h1>
          <p class="mt-2 text-xs text-slate-600">
            <code class="rounded bg-slate-100 px-1 py-0.5">{@match_id}</code>
          </p>
        </header>

        <%= if @not_found? do %>
          <section class="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
            Match not found.
          </section>
        <% else %>
          <section class="mt-4 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-slate-900">Players</h2>
              <span class={status_class(@match["status"])}>{status_label(@match)}</span>
            </div>

            <div class="mt-3 grid gap-3 sm:grid-cols-2">
              <%= for slot <- ["p1", "p2"] do %>
                <div class="rounded-xl border border-slate-200 bg-slate-50 px-3 py-2">
                  <p class="text-xs uppercase tracking-wide text-slate-500">{slot_label(slot)}</p>
                  <p class="mt-1 flex items-center gap-2 text-sm font-semibold text-slate-900">
                    <span>{slot_avatar(slot)}</span>
                    <span>{player_name(@match, slot)}</span>
                  </p>
                  <p class="mt-1 text-xs text-slate-500">{player_agent_id(@match, slot)}</p>
                </div>
              <% end %>
            </div>

            <p :if={@match["status"] == "active"} class="mt-3 text-xs text-slate-600">
              Turn {@match["turn_number"]} · Up next:
              <span class="font-semibold text-slate-800">{player_name(@match, @match["next_player"])}</span>
            </p>
          </section>

          <section class="mt-4 grid gap-4 lg:grid-cols-3">
            <article class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm lg:col-span-2">
              <h2 class="text-sm font-semibold text-slate-900">Game State</h2>
              <p class="mt-1 text-xs text-slate-600">{label_game(@match["game_type"])} · status: {@match["status"]}</p>

              <div class="mt-4">
                <%= if @match["game_type"] == "connect4" do %>
                  <.connect4_board board={get_in(@match, ["game_state", "board"]) || []} />
                <% else %>
                  <.rps_state state={@match["game_state"] || %{}} result={@match["result"]} />
                <% end %>
              </div>
            </article>

            <article class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <h2 class="text-sm font-semibold text-slate-900">Move History</h2>

              <%= if @events == [] do %>
                <p class="mt-3 text-xs text-slate-500">No events yet.</p>
              <% else %>
                <ol class="mt-3 space-y-2 text-xs">
                  <%= for event <- @events do %>
                    <li class="rounded-lg bg-slate-50 px-2 py-1.5 text-slate-700">
                      <span class="font-semibold">#{event["seq"]}</span>
                      <span class="ml-1">{event_line(@match, event)}</span>
                    </li>
                  <% end %>
                </ol>
              <% end %>
            </article>
          </section>
        <% end %>
      </div>
    </main>
    """
  end

  attr(:board, :list, required: true)

  defp connect4_board(assigns) do
    ~H"""
    <div class="inline-block rounded-xl bg-blue-700 p-2 shadow">
      <%= for row <- @board do %>
        <div class="flex gap-1 py-0.5">
          <%= for cell <- row do %>
            <span class="inline-flex h-6 w-6 items-center justify-center rounded-full bg-blue-200 text-sm">
              {connect4_chip(cell)}
            </span>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:result, :map, default: nil)

  defp rps_state(assigns) do
    throws = assigns.state["throws"] || %{}

    assigns =
      assigns
      |> assign(:p1_throw, throws["p1"] || "?")
      |> assign(:p2_throw, throws["p2"] || "?")

    ~H"""
    <div class="space-y-2 text-sm text-slate-800">
      <p>P1 throw: <span class="font-semibold">{@p1_throw}</span></p>
      <p>P2 throw: <span class="font-semibold">{@p2_throw}</span></p>
      <%= if is_map(@result) and @result["winner"] do %>
        <p class="text-xs text-slate-600">Winner: {@result["winner"]}</p>
      <% end %>
    </div>
    """
  end

  defp connect4_chip(0), do: "·"
  defp connect4_chip(1), do: "🟡"
  defp connect4_chip(2), do: "🔴"
  defp connect4_chip(_), do: "·"

  defp slot_label("p1"), do: "Player 1"
  defp slot_label("p2"), do: "Player 2"
  defp slot_label(_), do: "Player"

  defp slot_avatar("p1"), do: "🍋"
  defp slot_avatar("p2"), do: "🤖"
  defp slot_avatar(_), do: "🎮"

  defp player_name(match, slot) do
    get_in(match, ["players", slot, "display_name"]) || fallback_slot_name(slot)
  end

  defp player_agent_id(match, slot) do
    get_in(match, ["players", slot, "agent_id"]) || "waiting for player"
  end

  defp fallback_slot_name("p1"), do: "Player 1"
  defp fallback_slot_name("p2"), do: "Player 2"
  defp fallback_slot_name(_), do: "Player"

  defp status_label(%{"status" => "finished", "result" => %{"winner" => winner}} = match) do
    "Final · Winner: " <> player_name(match, winner)
  end

  defp status_label(%{"status" => "active"} = match) do
    "Live · Turn " <> to_string(match["turn_number"] || 0)
  end

  defp status_label(%{"status" => status}), do: String.capitalize(status)

  defp status_class(status) when is_binary(status) do
    base = "rounded-full px-2.5 py-1 text-xs font-medium "

    case status do
      "active" -> base <> "bg-emerald-100 text-emerald-700"
      "finished" -> base <> "bg-slate-200 text-slate-700"
      "expired" -> base <> "bg-amber-100 text-amber-700"
      _ -> base <> "bg-blue-100 text-blue-700"
    end
  end

  defp status_class(%{"status" => status}), do: status_class(status)

  defp event_line(match, %{"event_type" => "move_submitted"} = event) do
    slot = get_in(event, ["actor", "slot"])
    player = player_name(match, slot)
    move = format_move(match["game_type"], get_in(event, ["payload", "move"]))
    "#{player} played #{move}"
  end

  defp event_line(match, %{"event_type" => "move_rejected"} = event) do
    slot = get_in(event, ["actor", "slot"])
    player = player_name(match, slot)
    reason = get_in(event, ["payload", "reason"]) || "invalid move"
    "#{player} attempted an invalid move (#{reason})"
  end

  defp event_line(match, %{"event_type" => "accepted"} = event) do
    agent_id = get_in(event, ["actor", "agent_id"]) || "player"
    "#{agent_id} joined as #{player_name(match, "p2")}"
  end

  defp event_line(_match, %{"event_type" => "match_created"}), do: "Match created"
  defp event_line(_match, %{"event_type" => "finished"}), do: "Match finished"
  defp event_line(_match, %{"event_type" => "expired"}), do: "Match expired"
  defp event_line(_match, %{"event_type" => type}), do: type

  defp format_move("connect4", %{"column" => col}), do: "column #{col}"
  defp format_move("rock_paper_scissors", %{"value" => value}), do: value
  defp format_move(_game, move) when is_map(move), do: inspect(move)
  defp format_move(_game, _), do: "a move"

  defp label_game("connect4"), do: "Connect4"
  defp label_game("rock_paper_scissors"), do: "Rock Paper Scissors"
  defp label_game(other), do: other

  defp mount_with_match_id(match_id, socket) do
    if connected?(socket) do
      Bus.subscribe_match(match_id)
    end

    {match, events, last_seq, not_found?} = load_initial(match_id)

    {:ok,
     socket
     |> assign(:page_title, "Game Match")
     |> assign(:match_id, match_id)
     |> assign(:match, match)
     |> assign(:events, events)
     |> assign(:last_seq, last_seq)
     |> assign(:not_found?, not_found?)}
  end

  defp load_initial(match_id) do
    match =
      case Service.get_match(match_id, "spectator") do
        {:ok, value} -> value
        _ -> nil
      end

    {events, last_seq} = fetch_events(match_id, 0)

    {match, events, last_seq, is_nil(match)}
  end

  defp fetch_events(match_id, after_seq) do
    do_fetch_events(match_id, after_seq, [])
  end

  defp do_fetch_events(match_id, after_seq, acc) do
    case Service.list_events(match_id, after_seq, @event_batch_limit, "spectator") do
      {:ok, events, next_seq, true} ->
        do_fetch_events(match_id, next_seq, acc ++ events)

      {:ok, events, next_seq, false} ->
        {acc ++ events, next_seq}

      _ ->
        {acc, after_seq}
    end
  end
end
