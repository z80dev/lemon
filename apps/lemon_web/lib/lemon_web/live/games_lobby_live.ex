defmodule LemonWeb.GamesLobbyLive do
  @moduledoc false

  use LemonWeb, :live_view

  alias LemonCore.Event
  alias LemonGames.{Bus, Matches.Service}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bus.subscribe_lobby()
    end

    {:ok,
     socket
     |> assign(:page_title, "Lemon Games")
     |> assign(:matches, Service.list_lobby())}
  end

  @impl true
  def handle_info(%Event{type: :game_lobby_changed}, socket) do
    {:noreply, assign(socket, :matches, Service.list_lobby())}
  end

  def handle_info(%Event{}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-100">
      <div class="mx-auto w-full max-w-5xl px-4 py-6 sm:px-6">
        <header class="rounded-2xl border border-slate-200 bg-white px-4 py-4 shadow-sm">
          <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon Games</p>
          <h1 class="mt-1 text-xl font-semibold text-slate-900">Live Lobby</h1>
          <p class="mt-2 text-sm text-slate-600">
            Public matches update automatically. Open a match to watch turns and the event timeline.
          </p>
        </header>

        <section class="mt-4 rounded-2xl border border-slate-200 bg-white shadow-sm">
          <%= if @matches == [] do %>
            <p class="p-6 text-sm text-slate-500">No public matches yet.</p>
          <% else %>
            <ul class="divide-y divide-slate-200">
              <%= for match <- @matches do %>
                <li class="flex items-center justify-between gap-3 px-4 py-3 sm:px-6">
                  <div>
                    <p class="text-sm font-semibold text-slate-900">{label_game(match["game_type"])}</p>
                    <p class="text-xs text-slate-600">
                      <code class="rounded bg-slate-100 px-1 py-0.5">{match["id"]}</code>
                    </p>
                  </div>

                  <div class="flex items-center gap-3">
                    <span class={status_class(match["status"])}>{match["status"]}</span>
                    <.link
                      navigate={~p"/games/#{match["id"]}"}
                      class="rounded-lg bg-slate-900 px-3 py-1.5 text-xs font-medium text-white hover:bg-slate-700"
                    >
                      Watch
                    </.link>
                  </div>
                </li>
              <% end %>
            </ul>
          <% end %>
        </section>
      </div>
    </main>
    """
  end

  defp label_game("connect4"), do: "Connect4"
  defp label_game("rock_paper_scissors"), do: "Rock Paper Scissors"
  defp label_game(other), do: other

  defp status_class(status) do
    base = "rounded-full px-2.5 py-1 text-xs font-medium "

    case status do
      "active" -> base <> "bg-emerald-100 text-emerald-700"
      "finished" -> base <> "bg-slate-200 text-slate-700"
      "expired" -> base <> "bg-amber-100 text-amber-700"
      _ -> base <> "bg-blue-100 text-blue-700"
    end
  end
end
