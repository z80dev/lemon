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
        <div class="rounded-xl border border-slate-200 bg-slate-50 p-8 text-center">
          <p class="text-slate-600">No active matches right now.</p>
          <p class="mt-1 text-sm text-slate-500">Matches are created automatically — check back in a moment!</p>
        </div>
      <% else %>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.match_card :for={match <- @matches} match={match} />
        </div>
      <% end %>
    </main>
    """
  end

  def match_card(assigns) do
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
          <.player_avatar player={get_in(@match, ["players", "p1"])} slot="p1" />
          <div class="text-lg font-bold text-slate-400">VS</div>
          <.player_avatar player={get_in(@match, ["players", "p2"])} slot="p2" />
        </div>

        <div class="mt-4 flex items-center justify-between text-xs text-slate-500">
          <span>Turn #{@match["turn_number"]}</span>
          <span class="group-hover:text-blue-600">Watch →</span>
        </div>
      </div>
    </.link>
    """
  end

  def game_icon(assigns) do
    ~H"""
    <span class="flex h-8 w-8 items-center justify-center rounded-lg bg-slate-100 text-lg">
      <%= case @game_type do %>
        <% "rock_paper_scissors" -> %>✊
        <% "connect4" -> %>🔴
        <% "tic_tac_toe" -> %>⭕
        <% "battleship" -> %>🚢
        <% _ -> %>🎮
      <% end %>
    </span>
    """
  end

  def game_name(assigns) do
    ~H"""
    <%= case @game_type do %>
      <% "rock_paper_scissors" -> %>Rock Paper Scissors
      <% "connect4" -> %>Connect 4
      <% "tic_tac_toe" -> %>Tic-Tac-Toe
      <% "battleship" -> %>Battleship
      <% other -> %><%= other %>
    <% end %>
    """
  end

  def status_badge(assigns) do
    {bg, text, label} = case @status do
      "active" -> {"bg-emerald-100", "text-emerald-700", "Live"}
      "pending_accept" -> {"bg-amber-100", "text-amber-700", "Waiting"}
      "finished" -> {"bg-slate-100", "text-slate-600", "Finished"}
      _ -> {"bg-slate-100", "text-slate-600", @status}
    end

    assigns = assign(assigns, bg: bg, text: text, label: label)

    ~H"""
    <span class={["rounded-full px-2 py-0.5 text-xs font-medium", @bg, @text]}>
      {@label}
    </span>
    """
  end

  def player_avatar(assigns) do
    {name, avatar, bot} = case @player do
      %{"display_name" => name, "agent_type" => "lemon_bot"} -> {name, "🤖", true}
      %{"display_name" => name} -> {name, "👤", false}
      _ -> {"Waiting...", "⏳", false}
    end

    assigns = assign(assigns, name: name, avatar: avatar, bot: bot)

    ~H"""
    <div class="flex flex-col items-center gap-1">
      <div class={["flex h-10 w-10 items-center justify-center rounded-full text-lg", @bot && "bg-purple-100" || "bg-blue-100"]}>
        {@avatar}
      </div>
      <span class="max-w-[80px] truncate text-xs text-slate-600">{@name}</span>
    </div>
    """
  end

  defp players_label(players) when is_map(players) do
    p1 = get_in(players, ["p1", "display_name"]) || "p1"
    p2 = get_in(players, ["p2", "display_name"]) || "pending"
    "#{p1} vs #{p2}"
  end

  defp players_label(_), do: "unknown"
end
