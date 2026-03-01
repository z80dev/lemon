defmodule LemonWeb.Games.MatchLive do
  @moduledoc false

  use LemonWeb, :live_view

  alias LemonCore.Event
  alias LemonGames.{Bus, Matches.Service}
  alias LemonWeb.Games.Components.BoardComponent

  @impl true
  def mount(%{"match_id" => match_id}, _session, socket) do
    if connected?(socket), do: Bus.subscribe_match(match_id)

    {:ok,
     socket
     |> assign(:page_title, "Game Match")
     |> assign(:match_id, match_id)
     |> load_match()}
  end

  @impl true
  def handle_info(%Event{type: :game_match_event}, socket) do
    {:noreply, load_match(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto w-full max-w-5xl px-4 py-6">
      <div class="mb-4 flex items-center justify-between">
        <h1 class="text-2xl font-bold">Game Match</h1>
        <.link navigate={~p"/games"} class="text-sm text-blue-600 hover:underline">← Back to lobby</.link>
      </div>

      <%= if @match == nil do %>
        <p class="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          Match not found.
        </p>
      <% else %>
        <section class="rounded-lg border border-slate-200 bg-white p-4">
          <div class="grid gap-2 text-sm sm:grid-cols-2">
            <p><span class="font-semibold">Match:</span> <span class="font-mono text-xs">{@match["id"]}</span></p>
            <p><span class="font-semibold">Game:</span> {@match["game_type"]}</p>
            <p><span class="font-semibold">Status:</span> {@match["status"]}</p>
            <p><span class="font-semibold">Turn:</span> #{@match["turn_number"]}</p>
            <p><span class="font-semibold">Next:</span> {@match["next_player"] || "—"}</p>
            <p><span class="font-semibold">Players:</span> {players_label(@match["players"])}</p>
          </div>
        </section>

        <section class="mt-4 rounded-lg border border-slate-200 bg-white p-4">
          <h2 class="mb-2 text-lg font-semibold">Board</h2>
          <BoardComponent.board game_type={@match["game_type"]} game_state={@match["game_state"]} />
        </section>

        <section class="mt-4 rounded-lg border border-slate-200 bg-white p-4">
          <h2 class="mb-2 text-lg font-semibold">Timeline</h2>
          <%= if @events == [] do %>
            <p class="text-sm text-slate-600">No events yet.</p>
          <% else %>
            <ul class="space-y-1 text-sm">
              <li :for={event <- @events}>
                <span class="font-mono text-xs text-slate-500">#{event["seq"]}</span>
                <span class="ml-2">{event["event_type"]}</span>
              </li>
            </ul>
          <% end %>
        </section>

        <%= if @match["status"] == "finished" do %>
          <section class="mt-4 rounded-lg border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
            <span class="font-semibold">Result:</span>
            winner={@match["result"]["winner"] || "—"}, reason={@match["result"]["reason"] || "—"}
          </section>
        <% end %>
      <% end %>
    </main>
    """
  end

  defp load_match(socket) do
    match_id = socket.assigns.match_id

    case Service.get_match(match_id, "spectator") do
      {:ok, match} ->
        {:ok, events, _next, _more} = Service.list_events(match_id, 0, 200, "spectator")
        assign(socket, :match, match) |> assign(:events, events)

      {:error, :not_found, _} ->
        assign(socket, :match, nil) |> assign(:events, [])
    end
  end

  defp players_label(players) when is_map(players) do
    p1 = get_in(players, ["p1", "display_name"]) || "p1"
    p2 = get_in(players, ["p2", "display_name"]) || "pending"
    "#{p1} vs #{p2}"
  end

  defp players_label(_), do: "unknown"
end
