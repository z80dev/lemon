defmodule LemonWeb.Games.LobbyLive do
  @moduledoc false

  use LemonWeb, :live_view

  alias LemonGames.{Bus, Matches.Service}
  alias LemonCore.Event

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Bus.subscribe_lobby()

    {:ok,
     socket
     |> assign(:page_title, "Games Lobby")
     |> assign(:matches, Service.list_lobby())}
  end

  @impl true
  def handle_info(%Event{type: :game_lobby_changed}, socket) do
    {:noreply, assign(socket, :matches, Service.list_lobby())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto w-full max-w-5xl px-4 py-6">
      <h1 class="text-2xl font-bold">Games Lobby</h1>

      <%= if @matches == [] do %>
        <p class="mt-4 text-sm text-slate-600">No matches yet.</p>
      <% else %>
        <div class="mt-4 overflow-hidden rounded-lg border border-slate-200 bg-white">
          <table class="min-w-full divide-y divide-slate-200 text-sm">
            <thead class="bg-slate-50 text-left">
              <tr>
                <th class="px-3 py-2">Match</th>
                <th class="px-3 py-2">Game</th>
                <th class="px-3 py-2">Status</th>
                <th class="px-3 py-2">Players</th>
                <th class="px-3 py-2">Turn</th>
                <th class="px-3 py-2">Watch</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-slate-100">
              <tr :for={match <- @matches}>
                <td class="px-3 py-2 font-mono text-xs">{match["id"]}</td>
                <td class="px-3 py-2">{match["game_type"]}</td>
                <td class="px-3 py-2">{match["status"]}</td>
                <td class="px-3 py-2">{players_label(match["players"])}</td>
                <td class="px-3 py-2">#{match["turn_number"]}</td>
                <td class="px-3 py-2">
                  <.link navigate={~p"/games/#{match["id"]}"} class="text-blue-600 hover:underline">
                    Open
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </main>
    """
  end

  defp players_label(players) when is_map(players) do
    p1 = get_in(players, ["p1", "display_name"]) || "p1"
    p2 = get_in(players, ["p2", "display_name"]) || "pending"
    "#{p1} vs #{p2}"
  end

  defp players_label(_), do: "unknown"
end
