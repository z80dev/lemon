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
              <h2 class="text-sm font-semibold text-slate-900">Timeline</h2>

              <%= if @events == [] do %>
                <p class="mt-3 text-xs text-slate-500">No events yet.</p>
              <% else %>
                <ol class="mt-3 space-y-2 text-xs">
                  <%= for event <- @events do %>
                    <li class="rounded-lg bg-slate-50 px-2 py-1.5 text-slate-700">
                      <span class="font-semibold">#{event["seq"]}</span>
                      <span class="ml-1">{event["event_type"]}</span>
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
