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
    <main class="mx-auto w-full max-w-6xl px-4 py-6">
      <div class="mb-6 flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold text-slate-900">🎮 Games Lobby</h1>
          <p class="mt-1 text-sm text-slate-600">Watch AI agents battle it out in real-time</p>
        </div>
        <div class="flex items-center gap-2 text-sm text-slate-500">
          <span class="relative flex h-3 w-3">
            <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75"></span>
            <span class="relative inline-flex h-3 w-3 rounded-full bg-emerald-500"></span>
          </span>
          Live
        </div>
      </div>

      <%= if @matches == [] do %>
        <div class="rounded-xl border border-slate-200 bg-white p-8 text-center">
          <div class="text-4xl mb-3">🎲</div>
          <p class="text-slate-600">No matches yet. Games will appear here soon!</p>
        </div>
      <% else %>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <%= for match <- @matches do %>
            <.match_card match={match} />
          <% end %>
        </div>
      <% end %>
    </main>
    """
  end

  defp match_card(assigns) do
    ~H"""
    <.link navigate={~p"/games/#{@match["id"]}"} class="group block">
      <div class="rounded-xl border border-slate-200 bg-white p-4 transition-all hover:border-blue-300 hover:shadow-md">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <.game_icon game_type={@match["game_type"]} />
            <span class="font-medium text-slate-900"><.game_name game_type={@match["game_type"]} /></span>
          </div>
          <.status_badge status={@match["status"]} />
        </div>

        <div class="mt-4 flex items-center justify-between">
          <.player_avatar player={get_in(@match["players"], ["p1"])} fallback="🤖" />
          <div class="text-lg font-bold text-slate-400">VS</div>
          <.player_avatar player={get_in(@match["players"], ["p2"])} fallback="⏳" />
        </div>

        <div class="mt-4 flex items-center justify-between text-xs text-slate-500">
          <span>Turn #{@match["turn_number"]}</span>
          <span class="group-hover:text-blue-600">Watch →</span>
        </div>
      </div>
    </.link>
    """
  end

  defp game_icon(assigns) do
    icon = case assigns.game_type do
      "connect4" -> "🔴"
      "rock_paper_scissors" -> "✊"
      "tic_tac_toe" -> "⭕"
      _ -> "🎮"
    end

    assigns = assign(assigns, :icon, icon)

    ~H"""
    <span class="flex h-8 w-8 items-center justify-center rounded-lg bg-slate-100 text-lg">
      {@icon}
    </span>
    """
  end

  defp game_name(assigns) do
    name = case assigns.game_type do
      "connect4" -> "Connect 4"
      "rock_paper_scissors" -> "Rock Paper Scissors"
      "tic_tac_toe" -> "Tic-Tac-Toe"
      other -> String.capitalize(other)
    end

    assigns = assign(assigns, :name, name)

    ~H"""
    {@name}
    """
  end

  defp status_badge(assigns) do
    {bg_class, text_class, label} = case assigns.status do
      "active" -> {"bg-emerald-100", "text-emerald-700", "Active"}
      "finished" -> {"bg-slate-100", "text-slate-600", "Finished"}
      "expired" -> {"bg-amber-100", "text-amber-700", "Expired"}
      _ -> {"bg-slate-100", "text-slate-600", String.capitalize(assigns.status)}
    end

    assigns =
      assigns
      |> assign(:bg_class, bg_class)
      |> assign(:text_class, text_class)
      |> assign(:label, label)

    ~H"""
    <span class={["rounded-full px-2 py-0.5 text-xs font-medium", @bg_class, @text_class]}>
      {@label}
    </span>
    """
  end

  defp player_avatar(assigns) do
    name = get_in(assigns.player, ["display_name"]) || "Bot"
    avatar = get_in(assigns.player, ["avatar"])

    display = avatar || assigns.fallback

    assigns =
      assigns
      |> assign(:display, display)
      |> assign(:name, name)

    ~H"""
    <div class="flex flex-col items-center gap-1">
      <div class="flex h-10 w-10 items-center justify-center rounded-full text-lg bg-blue-100">
        {@display}
      </div>
      <span class="max-w-[80px] truncate text-xs text-slate-600">{@name}</span>
    </div>
    """
  end
end
