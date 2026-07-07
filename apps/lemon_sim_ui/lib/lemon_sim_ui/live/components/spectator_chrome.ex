defmodule LemonSimUi.Live.Components.SpectatorChrome do
  @moduledoc """
  Shared chrome for `LemonSimUi.SpectatorLive` domain views: the header bar
  (back link, title, meta line, League link, winner banner, LIVE/STOPPED
  badge), the winner banner on its own, and the "LIVE FEED" event log panel.

  Every supported domain's spectator view composes these instead of
  duplicating the ~30-line header block and ~15-line live-feed block.
  Board rendering itself stays with each domain's own board component
  (e.g. `LemonSimUi.Live.Components.PokerBoard`); this module only owns the
  surrounding page chrome.
  """

  use Phoenix.Component

  alias LemonSimUi.Live.Components.EventLog

  attr(:sim_id, :string, required: true)
  attr(:border_class, :string, required: true)
  attr(:bg_class, :string, required: true)
  attr(:hover_class, :string, required: true)
  attr(:league_path, :string, default: nil)
  attr(:winner, :any, default: nil)
  attr(:running, :boolean, required: true)
  attr(:show_stopped, :boolean, default: true)
  slot(:meta, required: true)

  def page_header(assigns) do
    ~H"""
    <header class={"flex items-center justify-between px-6 py-3 border-b #{@border_class} #{@bg_class} backdrop-blur-md flex-shrink-0"}>
      <div class="flex items-center gap-4">
        <a href="/" class={"text-slate-500 #{@hover_class} transition-colors"} title="Back to dashboard">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
            <path
              fill-rule="evenodd"
              d="M9.707 16.707a1 1 0 01-1.414 0l-6-6a1 1 0 010-1.414l6-6a1 1 0 011.414 1.414L5.414 9H17a1 1 0 110 2H5.414l4.293 4.293a1 1 0 010 1.414z"
              clip-rule="evenodd"
            />
          </svg>
        </a>
        <div>
          <h1 class="text-xl font-bold text-white tracking-tight">{@sim_id}</h1>
          <div class="flex items-center gap-2 text-xs font-mono text-slate-400">
            {render_slot(@meta)}
          </div>
        </div>
      </div>

      <div class="flex items-center gap-3">
        <.link
          :if={@league_path}
          navigate={@league_path}
          class="text-[11px] font-mono text-slate-400 hover:text-cyan-300 px-3 py-1.5 rounded border border-slate-700 hover:border-cyan-500/40 transition-colors"
        >
          League
        </.link>
        <.winner_banner winner={@winner} />
        <span
          :if={@running}
          class="text-[11px] font-bold tracking-widest uppercase px-3 py-1.5 rounded-sm bg-red-500/10 text-red-400 border border-red-500/30 flex items-center gap-2 shadow-[0_0_10px_rgba(239,68,68,0.2)]"
        >
          <span class="w-2 h-2 rounded-full bg-red-500 animate-pulse shadow-[0_0_8px_rgba(239,68,68,0.8)]"></span>
          LIVE
        </span>
        <span
          :if={!@running && @show_stopped}
          class="text-[11px] font-mono text-slate-500 px-3 py-1.5 rounded border border-slate-700"
        >
          STOPPED
        </span>
      </div>
    </header>
    """
  end

  attr(:winner, :any, default: nil)

  def winner_banner(%{winner: nil} = assigns), do: ~H""

  def winner_banner(assigns) do
    ~H"""
    <span class="text-sm font-bold px-3 py-1.5 rounded bg-amber-500/10 text-amber-400 border border-amber-500/30">
      Winner: {@winner}
    </span>
    """
  end

  @doc """
  Renders the domain label + progress + phase segment used in each page
  header's meta line (e.g. `VendingBench | Day 3/30 | Operating`). Domains
  whose progress format doesn't fit "label | progress | phase" (poker's
  optional street badge) can append extra segments via the `:extra` slot.
  """
  attr(:label, :string, required: true)
  attr(:label_class, :string, required: true)
  attr(:progress, :string, required: true)
  attr(:phase, :string, default: nil)
  slot(:extra)

  def meta_line(assigns) do
    ~H"""
    <span class={@label_class}>{@label}</span>
    <span class="text-slate-600">|</span>
    <span>{@progress}</span>
    <span :if={@phase} class="text-slate-600">|</span>
    <span :if={@phase} class="capitalize">{@phase}</span>
    {render_slot(@extra)}
    """
  end

  @doc """
  Renders the "LIVE FEED" footer panel (icon + title + scrollable event
  log). `wrapper_class`/`body_class` are passed through verbatim because the
  panel sits in two different parent layouts: a `flex-shrink-0`, fixed-height
  footer inside a `flex flex-col overflow-hidden` page (space_station,
  stock_market, survivor, werewolf), or a plain block at the bottom of a
  scrolling page (poker).
  """
  attr(:events, :list, required: true)
  attr(:wrapper_class, :string, required: true)
  attr(:body_class, :string, default: "h-36")

  def live_feed_panel(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <div class="px-4 py-2 border-b border-glass-border bg-slate-900/40">
        <h3 class="text-[9px] font-mono uppercase tracking-widest text-emerald-400 font-bold flex items-center gap-1.5">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
            <path
              fill-rule="evenodd"
              d="M3 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1zm0 4a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1z"
              clip-rule="evenodd"
            />
          </svg>
          LIVE FEED
        </h3>
      </div>
      <div class={"p-0 #{@body_class} overflow-hidden"}>
        <EventLog.render events={@events} />
      </div>
    </div>
    """
  end
end
