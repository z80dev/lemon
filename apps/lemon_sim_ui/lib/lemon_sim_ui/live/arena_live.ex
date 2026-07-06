defmodule LemonSimUi.ArenaLive do
  @moduledoc """
  Stable public URL for an always-on arena domain.

  `/arena/:domain` always lands the viewer on that domain's game currently on
  air: when a league game is live it immediately redirects to
  `/watch/:sim_id` (which auto-advances to the next game), otherwise it shows
  an intermission page and navigates the moment the next game starts. These
  are the URLs to share, embed, and point stream overlays at.
  """

  use LemonSimUi, :live_view

  alias LemonSimUi.{Arena, ArenaDomains, SimManager}

  @impl true
  def mount(%{"domain" => slug}, _session, socket) do
    case ArenaDomains.domain_atom(slug) do
      {:ok, domain} ->
        if connected?(socket) do
          LemonCore.Bus.subscribe(SimManager.lobby_topic())
        end

        theme = ArenaDomains.get(domain)

        socket =
          assign(socket,
            domain: domain,
            theme: theme,
            page_title: "#{theme.title} Arena — Live"
          )

        case connected?(socket) && live_sim(domain) do
          sim_id when is_binary(sim_id) ->
            {:ok, push_navigate(socket, to: ~p"/watch/#{sim_id}")}

          _ ->
            {:ok, socket}
        end

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Unknown arena")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :sim_lobby_changed}, socket) do
    case live_sim(socket.assigns.domain) do
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
        <div class="text-6xl mb-6">{@theme.icon}</div>
        <h1 class="text-3xl font-extrabold text-white mb-3 text-glow-cyan">
          {@theme.title} Arena
        </h1>
        <p class="text-slate-400 font-mono text-sm mb-6">
          The next game is starting soon. Frontier models are taking their
          seats&hellip;
        </p>
        <div class="flex items-center justify-center gap-2 mb-8">
          <span class="w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span>
          <span class="text-xs uppercase tracking-widest text-amber-300 font-bold">Intermission</span>
        </div>
        <div class="flex items-center justify-center gap-3">
          <.link
            navigate={~p"/arena/#{@domain}/leaderboard"}
            class="glass-button px-4 py-2 rounded-lg text-sm font-mono"
          >
            League Leaderboard
          </.link>
          <.link navigate={~p"/"} class="glass-button px-4 py-2 rounded-lg text-sm font-mono">
            Lobby
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp live_sim(domain) do
    Arena.current_sim_id(domain) || running_sim(domain)
  end

  defp running_sim(domain) do
    prefix = Arena.sim_prefix(domain)

    SimManager.list_running()
    |> Enum.find(&String.starts_with?(&1, prefix))
  end
end
