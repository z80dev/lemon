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
      <%!-- Header with back link --%>
      <div class="mb-6 flex items-center justify-between">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/games"} class="flex h-10 w-10 items-center justify-center rounded-full bg-slate-100 text-slate-600 transition-colors hover:bg-slate-200">
            ←
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-slate-900">
              <.game_icon game_type={@match && @match["game_type"]} />
              <span class="ml-2"><.game_name game_type={@match && @match["game_type"]} /></span>
            </h1>
            <p class="text-sm text-slate-500">Match {@match_id |> String.slice(0, 8)}...</p>
          </div>
        </div>
        <.status_badge status={@match && @match["status"]} />
      </div>

      <%= if @match == nil do %>
        <div class="rounded-xl border border-amber-200 bg-amber-50 p-8 text-center">
          <div class="mb-3 text-4xl">🔍</div>
          <p class="text-amber-900">Match not found.</p>
        </div>
      <% else %>
        <%!-- Player Battle Header --%>
        <section class="mb-6 rounded-2xl border border-slate-200 bg-gradient-to-br from-white to-slate-50 p-6">
          <div class="flex items-center justify-between">
            <.player_card player={get_in(@match["players"], ["p1"])} is_winner={@match["status"] == "finished" && @match["result"]["winner"] == "p1"} />
            
            <div class="flex flex-col items-center px-4">
              <div class="text-3xl font-black text-slate-300">VS</div>
              <%= if @match["status"] == "active" do %>
                <div class="mt-2 flex items-center gap-1.5 text-xs text-emerald-600">
                  <span class="relative flex h-2 w-2">
                    <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-75"></span>
                    <span class="relative inline-flex h-2 w-2 rounded-full bg-emerald-500"></span>
                  </span>
                  Live
                </div>
              <% end %>
            </div>
            
            <.player_card player={get_in(@match["players"], ["p2"])} is_winner={@match["status"] == "finished" && @match["result"]["winner"] == "p2"} />
          </div>
        </section>

        <div class="grid gap-6 lg:grid-cols-3">
          <%!-- Main Game Board --%>
          <section class="lg:col-span-2 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <div class="mb-4 flex items-center justify-between">
              <h2 class="text-lg font-semibold text-slate-900">Game Board</h2>
              <%= if @match["status"] == "active" do %>
                <div class="flex items-center gap-2 text-sm text-slate-600">
                  <span class="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-700">
                    Turn {@match["turn_number"]}
                  </span>
                  <span>Next: <span class="font-medium">{next_player_name(@match)}</span></span>
                </div>
              <% end %>
            </div>
            
            <div class="flex justify-center">
              <BoardComponent.board game_type={@match["game_type"]} game_state={@match["game_state"]} />
            </div>
          </section>

          <%!-- Sidebar: Move History & Stats --%>
          <section class="space-y-4">
            <%!-- Result Banner (if finished) --%>
            <%= if @match["status"] == "finished" do %>
              <div class={result_banner_class(@match["result"])}>
                <div class="text-2xl mb-1">
                  <%= if @match["result"]["winner"] do %>
                    🏆
                  <% else %>
                    🤝
                  <% end %>
                </div>
                <p class="font-bold">
                  <%= if @match["result"]["winner"] do %>
                    {winner_name(@match)} wins!
                  <% else %>
                    Draw!
                  <% end %>
                </p>
                <p class="text-xs opacity-90 mt-1">{@match["result"]["reason"] || "Game completed"}</p>
              </div>
            <% end %>

            <%!-- Move Timeline --%>
            <div class="rounded-xl border border-slate-200 bg-white p-4">
              <h3 class="mb-3 text-sm font-semibold text-slate-900">Move History</h3>
              <%= if @events == [] do %>
                <p class="text-sm text-slate-500 italic">No moves yet...</p>
              <% else %>
                <ul class="max-h-64 space-y-2 overflow-y-auto text-sm">
                  <%= for event <- Enum.reverse(@events) do %>
                    <li class="flex items-start gap-2 rounded-lg bg-slate-50 p-2">
                      <span class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-slate-200 text-xs font-medium text-slate-600">
                        {event["seq"]}
                      </span>
                      <div class="min-w-0 flex-1">
                        <p class="font-medium text-slate-900 truncate">
                          {event["event_type"] |> String.replace("_", " ") |> String.capitalize()}
                        </p>
                        <%= if event["data"] && event["data"]["player_id"] do %>
                          <p class="text-xs text-slate-500">
                            by {event["data"]["player_id"]}
                          </p>
                        <% end %>
                      </div>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>

            <%!-- Match Stats --%>
            <div class="rounded-xl border border-slate-200 bg-white p-4">
              <h3 class="mb-3 text-sm font-semibold text-slate-900">Match Stats</h3>
              <dl class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <dt class="text-slate-500">Status</dt>
                  <dd class="font-medium">{String.capitalize(@match["status"])}</dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-slate-500">Total Turns</dt>
                  <dd class="font-medium">{@match["turn_number"]}</dd>
                </div>
                <div class="flex justify-between">
                  <dt class="text-slate-500">Game Type</dt>
                  <dd class="font-medium">{format_game_type(@match["game_type"])}</dd>
                </div>
              </dl>
            </div>
          </section>
        </div>
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

  defp game_icon(assigns) do
    icon = case assigns.game_type do
      "connect4" -> "🔴"
      "rock_paper_scissors" -> "✊"
      "tic_tac_toe" -> "⭕"
      _ -> "🎮"
    end

    assigns = assign(assigns, :icon, icon)

    ~H"""
    <span class="inline-block">{@icon}</span>
    """
  end

  defp game_name(assigns) do
    name = case assigns.game_type do
      "connect4" -> "Connect 4"
      "rock_paper_scissors" -> "Rock Paper Scissors"
      "tic_tac_toe" -> "Tic-Tac-Toe"
      other when is_binary(other) -> String.capitalize(other)
      _ -> "Game"
    end

    assigns = assign(assigns, :name, name)

    ~H"""
    {@name}
    """
  end

  defp status_badge(assigns) do
    {bg_class, text_class, label, icon} = case assigns.status do
      "active" -> {"bg-emerald-100", "text-emerald-700", "Active", "●"}
      "finished" -> {"bg-slate-100", "text-slate-700", "Finished", "✓"}
      "expired" -> {"bg-amber-100", "text-amber-700", "Expired", "⏱"}
      _ -> {"bg-slate-100", "text-slate-600", String.capitalize(assigns.status || "Unknown"), "?"}
    end

    assigns =
      assigns
      |> assign(:bg_class, bg_class)
      |> assign(:text_class, text_class)
      |> assign(:label, label)
      |> assign(:icon, icon)

    ~H"""
    <span class={["inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-sm font-medium", @bg_class, @text_class]}>
      <span>{@icon}</span>
      {@label}
    </span>
    """
  end

  defp player_card(assigns) do
    name = get_in(assigns.player, ["display_name"]) || "Bot"
    avatar = get_in(assigns.player, ["avatar"]) || "🤖"
    
    crown_class = if assigns.is_winner, do: "ring-2 ring-yellow-400 ring-offset-2", else: ""
    
    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:avatar, avatar)
      |> assign(:crown_class, crown_class)

    ~H"""
    <div class="flex flex-col items-center text-center">
      <div class={["relative flex h-16 w-16 items-center justify-center rounded-full bg-gradient-to-br from-blue-100 to-blue-200 text-3xl", @crown_class]}>
        {@avatar}
        <%= if @is_winner do %>
          <span class="absolute -top-1 -right-1 flex h-6 w-6 items-center justify-center rounded-full bg-yellow-400 text-sm">👑</span>
        <% end %>
      </div>
      <span class="mt-2 max-w-[120px] truncate font-medium text-slate-900">{@name}</span>
    </div>
    """
  end

  defp next_player_name(match) do
    next = match["next_player"]
    players = match["players"] || %{}
    
    case get_in(players, [next, "display_name"]) do
      nil -> next || "—"
      name -> name
    end
  end

  defp winner_name(match) do
    winner = match["result"]["winner"]
    players = match["players"] || %{}
    
    case get_in(players, [winner, "display_name"]) do
      nil -> winner || "—"
      name -> name
    end
  end

  defp result_banner_class(result) do
    if result["winner"] do
      "rounded-xl bg-gradient-to-r from-yellow-100 to-amber-100 border border-yellow-200 p-4 text-center text-amber-900"
    else
      "rounded-xl bg-gradient-to-r from-slate-100 to-slate-200 border border-slate-300 p-4 text-center text-slate-700"
    end
  end

  defp format_game_type(nil), do: "Unknown"
  defp format_game_type(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
