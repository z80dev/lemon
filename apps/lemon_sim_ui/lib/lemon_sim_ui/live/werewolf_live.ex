defmodule LemonSimUi.WerewolfLive do
  @moduledoc """
  Stable public URL for the always-on Werewolf arena.

  `/werewolf` always lands the viewer on the game currently on air: when a
  league game is live it immediately redirects to `/watch/:sim_id` (which
  itself auto-advances to the next game), otherwise it shows an intermission
  page and navigates the moment the next game starts. This is the URL to
  share, embed, and point stream overlays at.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{SimManager, WerewolfArena}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      LemonCore.Bus.subscribe(SimManager.lobby_topic())
    end

    socket = assign(socket, page_title: "Werewolf Arena — Live")

    case connected?(socket) && live_werewolf_sim() do
      sim_id when is_binary(sim_id) ->
        {:ok, push_navigate(socket, to: ~p"/watch/#{sim_id}")}

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    case live_werewolf_sim() do
      sim_id when is_binary(sim_id) ->
        {:noreply, push_navigate(socket, to: ~p"/watch/#{sim_id}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center text-slate-200 px-6">
      <div class="glass-panel rounded-2xl border border-glass-border p-12 text-center max-w-lg">
        <img src="/assets/werewolf/moon.png" alt="" class="w-20 h-20 mx-auto mb-6 opacity-80" />
        <h1 class="text-3xl font-extrabold text-white mb-3 text-glow-cyan">Werewolf Arena</h1>
        <p class="text-slate-400 font-mono text-sm mb-6">
          The next game is starting soon. Frontier models are being assigned
          their secret roles&hellip;
        </p>
        <div class="flex items-center justify-center gap-2 mb-8">
          <span class="w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span>
          <span class="text-xs uppercase tracking-widest text-amber-300 font-bold">Intermission</span>
        </div>
        <.link
          navigate={~p"/werewolf/leaderboard"}
          class="glass-button px-4 py-2 rounded-lg text-sm font-mono"
        >
          View League Leaderboard
        </.link>
      </div>
    </div>
    """
  end

  defp live_werewolf_sim do
    WerewolfArena.current_sim_id() || running_werewolf_sim()
  end

  defp running_werewolf_sim do
    SimManager.list_running()
    |> Enum.find(&String.starts_with?(&1, "ww_"))
  end
end
