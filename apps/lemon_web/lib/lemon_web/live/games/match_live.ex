defmodule LemonWeb.Games.MatchLive do
  @moduledoc false

  use LemonWeb, :live_view

  alias LemonCore.Event
  alias LemonGames.{Bus, Matches.Service}
  alias LemonWeb.Games.Components.BoardComponent

  @refresh_ms 1_000
  @event_batch_limit 200
  @max_catch_up_batches 5

  @impl true
  def mount(%{"match_id" => match_id}, _session, socket) do
    if connected?(socket) do
      Bus.subscribe_match(match_id)
      Process.send_after(self(), :refresh_match, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Game Match")
     |> assign(:match_id, match_id)
     |> assign(:last_event_seq, 0)
     |> load_match()}
  end

  @impl true
  def handle_info(%Event{type: :game_match_event}, socket) do
    {:noreply, catch_up_match(socket)}
  end

  def handle_info(:refresh_match, socket) do
    Process.send_after(self(), :refresh_match, @refresh_ms)
    {:noreply, catch_up_match(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto w-full max-w-5xl px-4 py-6">
      <div class="mb-6 flex items-center justify-between">
        <.link navigate={~p"/games"} class="text-sm text-slate-500 hover:text-blue-600"
        >← Back to lobby</.link>
        <.status_indicator status={@match && @match["status"]} />
      </div>

      <%= if @match == nil do %>
        <div class="rounded-xl border border-amber-200 bg-amber-50 p-8 text-center">
          <p class="text-amber-900">Match not found.</p>
        </div>
      <% else %>
        <% p1 = get_in(@match, ["players", "p1"]) %>
        <% p2 = get_in(@match, ["players", "p2"]) %>
        <% winner = @match["result"]["winner"] %>

        <div class="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <div class="flex items-center justify-between">
            <.player_card player={p1} is_winner={winner == "p1"} is_active={@match["next_player"] == "p1"} />

            <div class="flex flex-col items-center px-4">
              <div class="text-3xl font-black text-slate-300">VS</div>
              <div class="mt-2 text-xs text-slate-500">Turn #{@match["turn_number"]}</div>
            </div>

            <.player_card player={p2} is_winner={winner == "p2"} is_active={@match["next_player"] == "p2"} />
          </div>

          <div class="mt-8 flex justify-center">
            <BoardComponent.board game_type={@match["game_type"]} game_state={@match["game_state"]} />
          </div>

          <%= if @match["status"] == "finished" do %>
            <div class="mt-6 rounded-xl border-2 border-emerald-200 bg-emerald-50 p-4 text-center">
              <div class="text-2xl">🏆</div>
              <p class="mt-1 font-semibold text-emerald-900">
                <%= case winner do %>
                  <% "p1" -> %> {p1["display_name"] || "Player 1"} wins!
                  <% "p2" -> %> {p2["display_name"] || "Player 2"} wins!
                  <% _ -> %> It's a draw!
                <% end %>
              </p>
              <p class="text-sm text-emerald-700">{@match["result"]["reason"] || "Game complete"}</p>
            </div>
          <% end %>
        </div>

        <section class="mt-6 rounded-xl border border-slate-200 bg-white p-4">
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wide text-slate-500">Move History</h2>
          <%= if @events == [] do %>
            <p class="text-sm text-slate-500">No moves yet.</p>
          <% else %>
            <div class="flex flex-wrap gap-2">
              <.event_chip :for={event <- Enum.take(@events, 20)} event={event} />
            </div>
          <% end %>
        </section>
      <% end %>
    </main>
    """
  end

  def status_indicator(assigns) do
    {color, label} =
      case assigns.status do
        "active" -> {"bg-emerald-500", "Live"}
        "pending_accept" -> {"bg-amber-500", "Waiting"}
        "finished" -> {"bg-slate-400", "Finished"}
        _ -> {"bg-slate-400", "Unknown"}
      end

    assigns = assign(assigns, color: color, label: label)

    ~H"""
    <div class="flex items-center gap-2 text-sm text-slate-600">
      <span class={["h-2.5 w-2.5 rounded-full", @color]}></span>
      {@label}
    </div>
    """
  end

  def player_card(assigns) do
    {name, avatar, bot} =
      case assigns.player do
        %{"display_name" => name, "agent_type" => "lemon_bot"} -> {name, "🤖", true}
        %{"display_name" => name} -> {name, "👤", false}
        _ -> {"Unknown", "❓", false}
      end

    assigns = assign(assigns, name: name, avatar: avatar, bot: bot)

    ~H"""
    <div class={["flex flex-col items-center rounded-xl p-4 transition-all",
      @is_winner && "bg-yellow-100 ring-2 ring-yellow-400",
      @is_active && !@is_winner && "bg-blue-50 ring-2 ring-blue-300",
      !@is_active && !@is_winner && "bg-slate-50"
    ]}>
      <div class={["flex h-16 w-16 items-center justify-center rounded-full text-3xl shadow-sm",
        @bot && "bg-purple-100" || "bg-blue-100"
      ]}>
        {@avatar}
      </div>
      <div class="mt-2 text-center">
        <div class="font-semibold text-slate-900">{@name}</div>
        <%= if @bot do %>
          <div class="text-xs text-purple-600">Bot</div>
        <% end %>
        <%= if @is_active && !@is_winner do %>
          <div class="mt-1 text-xs font-medium text-blue-600">Thinking...</div>
        <% end %>
        <%= if @is_winner do %>
          <div class="mt-1 text-lg">👑</div>
        <% end %>
      </div>
    </div>
    """
  end

  def event_chip(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded-full bg-slate-100 px-2 py-1 text-xs text-slate-700">
      <span class="mr-1 font-mono text-slate-400">#{@event["seq"]}</span>
      {@event["event_type"]}
    </span>
    """
  end

  defp load_match(socket) do
    match_id = socket.assigns.match_id

    case Service.get_match(match_id, "spectator") do
      {:ok, match} ->
        case fetch_events_since(match_id, 0, "spectator") do
          {:ok, events, next_after_seq} ->
            socket
            |> assign(:match, match)
            |> assign(:events, events)
            |> assign(:last_event_seq, next_after_seq)

          {:error, :not_found, _} ->
            assign(socket, :match, nil)
            |> assign(:events, [])
            |> assign(:last_event_seq, 0)
        end

      {:error, :not_found, _} ->
        assign(socket, :match, nil)
        |> assign(:events, [])
        |> assign(:last_event_seq, 0)
    end
  end

  defp catch_up_match(socket) do
    match_id = socket.assigns.match_id
    after_seq = socket.assigns.last_event_seq || 0

    case fetch_events_since(match_id, after_seq, "spectator") do
      {:ok, [], _next_after_seq} ->
        socket

      {:ok, new_events, next_after_seq} ->
        case Service.get_match(match_id, "spectator") do
          {:ok, match} ->
            socket
            |> assign(:match, match)
            |> assign(:events, append_events(socket.assigns.events || [], new_events))
            |> assign(:last_event_seq, next_after_seq)

          {:error, :not_found, _} ->
            socket
            |> assign(:match, nil)
            |> assign(:events, [])
            |> assign(:last_event_seq, 0)
        end

      {:error, :not_found, _} ->
        socket
        |> assign(:match, nil)
        |> assign(:events, [])
        |> assign(:last_event_seq, 0)
    end
  end

  defp fetch_events_since(match_id, after_seq, viewer, depth \\ 0, acc \\ [])

  defp fetch_events_since(_match_id, after_seq, _viewer, depth, acc)
       when depth >= @max_catch_up_batches do
    {:ok, acc, after_seq}
  end

  defp fetch_events_since(match_id, after_seq, viewer, depth, acc) do
    case Service.list_events(match_id, after_seq, @event_batch_limit, viewer) do
      {:ok, events, next_after_seq, true} ->
        fetch_events_since(match_id, next_after_seq, viewer, depth + 1, acc ++ events)

      {:ok, events, next_after_seq, false} ->
        {:ok, acc ++ events, next_after_seq}

      {:error, _code, _message} = error ->
        error
    end
  end

  defp append_events(existing, new_events) do
    existing_seqs = existing |> Enum.map(& &1["seq"]) |> MapSet.new()

    merged =
      existing ++
        Enum.reject(new_events, fn event -> MapSet.member?(existing_seqs, event["seq"]) end)

    keep = 400
    drop_count = max(length(merged) - keep, 0)
    Enum.drop(merged, drop_count)
  end

  defp players_label(players) when is_map(players) do
    p1 = get_in(players, ["p1", "display_name"]) || "p1"
    p2 = get_in(players, ["p2", "display_name"]) || "pending"
    "#{p1} vs #{p2}"
  end

  defp players_label(_), do: "unknown"
end
