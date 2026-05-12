defmodule LemonWeb.OpsRunLive do
  @moduledoc false

  use LemonWeb, :live_view

  @impl true
  def mount(%{"run_id" => run_id}, _session, socket) do
    {:ok, assign_detail(socket, run_id)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_detail(socket, socket.assigns.run_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-100">
      <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-6 sm:py-6">
        <header class="rounded-2xl border border-slate-200 bg-white px-4 py-4 shadow-sm">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                Lemon Operations
              </p>
              <h1 class="mt-1 truncate text-xl font-semibold text-slate-900">Run {shorten(@run_id)}</h1>
              <p class="mt-2 text-sm text-slate-600">
                Timeline, failures, tool events, and child run references.
              </p>
            </div>
            <div class="flex gap-2">
              <.link navigate={~p"/ops"} class="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 shadow-sm">
                Operations
              </.link>
              <button
                type="button"
                phx-click="refresh"
                class="rounded-lg bg-slate-900 px-3 py-2 text-sm font-medium text-white shadow-sm"
              >
                Refresh
              </button>
            </div>
          </div>
        </header>

        <section class="mt-4 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <.metric title="Status" value={@detail.summary.status || "unknown"} detail={summary_detail(@detail.summary)} />
          <.metric title="Events" value={length(@detail.events)} detail="introspection events" />
          <.metric title="Failures" value={length(@detail.failures)} detail="error or failed events" />
          <.metric title="Approvals" value={length(@detail.pending_approvals)} detail="pending execution requests" />
          <.metric title="Descendants" value={graph_descendant_count(@detail.graph)} detail="child and nested runs" />
        </section>

        <section class="mt-4 grid gap-4 lg:grid-cols-2">
          <.panel title="Pending Approvals">
            <%= if @detail.pending_approvals == [] do %>
              <.empty text="No pending approvals for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for approval <- @detail.pending_approvals do %>
                  <div class="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2">
                    <p class="text-sm font-medium text-amber-950">{approval.tool || "unknown tool"}</p>
                    <%= if approval.rationale do %>
                      <p class="mt-1 text-xs text-amber-800">{approval.rationale}</p>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Failures">
            <%= if @detail.failures == [] do %>
              <.empty text="No failure events recorded for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.failures do %>
                  <.event_card event={event} tone="error" />
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Tool Events">
            <%= if @detail.tool_events == [] do %>
              <.empty text="No tool events recorded for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.tool_events do %>
                  <.event_card event={event} tone="tool" />
                <% end %>
              </div>
            <% end %>
          </.panel>
        </section>

        <section class="mt-4 grid gap-4 lg:grid-cols-2">
          <.panel title="Run Graph">
            <%= if is_nil(@detail.graph) or graph_descendant_count(@detail.graph) == 0 do %>
              <.empty text="No child runs recorded for this run." />
            <% else %>
              <.run_tree node={@detail.graph} depth={0} root_id={@run_id} />
            <% end %>
          </.panel>

          <.panel title="Event Counts">
            <%= if map_size(@detail.event_counts) == 0 do %>
              <.empty text="No event counts available." />
            <% else %>
              <div class="space-y-2">
                <%= for {event_type, count} <- Enum.sort(@detail.event_counts) do %>
                  <div class="flex justify-between gap-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <span class="truncate text-sm text-slate-700">{event_type}</span>
                    <span class="text-sm font-medium text-slate-900">{count}</span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>
        </section>

        <section class="mt-4">
          <.panel title="Timeline">
            <%= if @detail.events == [] do %>
              <.empty text="No introspection events found for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.events do %>
                  <.event_card event={event} tone="default" />
                <% end %>
              </div>
            <% end %>
          </.panel>
        </section>

        <section class="mt-4">
          <.panel title="Support Bundle">
            <div class="grid gap-3 lg:grid-cols-2">
              <div class="lg:col-span-2">
                <.link
                  href={~p"/ops/support-bundle"}
                  class="inline-flex rounded-lg bg-slate-900 px-3 py-2 text-sm font-medium text-white shadow-sm"
                >
                  Download Support Bundle
                </.link>
              </div>
              <div>
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Source-dev</p>
                <code class="mt-1 block overflow-x-auto rounded-lg bg-slate-950 px-3 py-2 text-xs text-slate-100">
                  {@detail.support.source_dev}
                </code>
              </div>
              <div>
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Release runtime</p>
                <code class="mt-1 block overflow-x-auto rounded-lg bg-slate-950 px-3 py-2 text-xs text-slate-100">
                  {@detail.support.release_runtime}
                </code>
              </div>
            </div>
          </.panel>
        </section>
      </div>
    </main>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-sm">
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500">{@title}</p>
      <p class="mt-2 truncate text-2xl font-semibold text-slate-900">{@value}</p>
      <p class="mt-1 text-xs text-slate-500">{@detail}</p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <h2 class="text-sm font-semibold text-slate-900">{@title}</h2>
      <div class="mt-3">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:node, :map, required: true)
  attr(:depth, :integer, required: true)
  attr(:root_id, :string, required: true)

  defp run_tree(assigns) do
    ~H"""
    <div class={if @depth == 0, do: "space-y-2", else: "ml-4 space-y-2 border-l border-slate-200 pl-3"}>
      <div class="flex items-center justify-between gap-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
        <div class="min-w-0">
          <%= if @node.run_id == @root_id do %>
            <p class="truncate text-sm font-medium text-slate-900">{shorten(@node.run_id)}</p>
          <% else %>
            <.link navigate={~p"/ops/runs/#{@node.run_id}"} class="truncate text-sm font-medium text-slate-900 hover:underline">
              {shorten(@node.run_id)}
            </.link>
          <% end %>
          <p class="truncate text-xs text-slate-500">
            {(@node.engine || "unknown engine") <> " / " <> (@node.agent_id || "unknown agent")}
          </p>
        </div>
        <span class={status_badge_class(@node.status)}>{@node.status}</span>
      </div>
      <%= for child <- @node.children do %>
        <.run_tree node={child} depth={@depth + 1} root_id={@root_id} />
      <% end %>
    </div>
    """
  end

  attr(:event, :map, required: true)
  attr(:tone, :string, default: "default")

  defp event_card(assigns) do
    ~H"""
    <div class={event_card_class(@tone, @event)}>
      <div class="flex flex-col gap-1 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0">
          <p class="truncate text-sm font-medium text-slate-900">{@event.event_type || "unknown"}</p>
          <p class="truncate text-xs text-slate-500">{format_ts(@event.ts_ms)}</p>
        </div>
        <%= if @event.tool do %>
          <span class="rounded-full bg-slate-200 px-2 py-1 text-xs font-medium text-slate-700">
            {@event.tool}
          </span>
        <% end %>
      </div>
      <%= if @event.error do %>
        <p class="mt-2 rounded-md bg-rose-100 px-2 py-1 text-xs text-rose-800">
          {format_value(@event.error)}
        </p>
      <% end %>
      <%= if @event.preview do %>
        <pre class="mt-2 max-h-40 overflow-auto whitespace-pre-wrap rounded-md bg-slate-950 px-3 py-2 text-xs text-slate-100"><%= format_value(@event.preview) %></pre>
      <% end %>
    </div>
    """
  end

  attr(:text, :string, required: true)

  defp empty(assigns) do
    ~H"""
    <p class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-500">
      {@text}
    </p>
    """
  end

  defp assign_detail(socket, run_id) do
    socket
    |> assign(:page_title, "Lemon Run #{run_id}")
    |> assign(:run_id, run_id)
    |> assign(:detail, LemonWeb.OpsDashboard.run_detail(run_id))
  end

  defp summary_detail(summary) do
    cond do
      is_binary(summary.engine) and is_binary(summary.agent_id) ->
        "#{summary.engine} / #{summary.agent_id}"

      is_binary(summary.engine) ->
        summary.engine

      true ->
        "run summary"
    end
  end

  defp graph_descendant_count(nil), do: 0

  defp graph_descendant_count(%{children: children}) when is_list(children) do
    length(children) + Enum.reduce(children, 0, &(graph_descendant_count(&1) + &2))
  end

  defp graph_descendant_count(_), do: 0

  defp event_card_class("error", _event),
    do: "rounded-lg border border-rose-200 bg-rose-50 px-3 py-2"

  defp event_card_class("tool", _event),
    do: "rounded-lg border border-sky-200 bg-sky-50 px-3 py-2"

  defp event_card_class(_tone, %{error: error}) when not is_nil(error),
    do: "rounded-lg border border-rose-200 bg-rose-50 px-3 py-2"

  defp event_card_class(_tone, _event),
    do: "rounded-lg border border-slate-200 bg-slate-50 px-3 py-2"

  defp status_badge_class("completed"),
    do: "rounded-full bg-emerald-100 px-2 py-1 text-xs font-medium text-emerald-700"

  defp status_badge_class("started"),
    do: "rounded-full bg-sky-100 px-2 py-1 text-xs font-medium text-sky-700"

  defp status_badge_class("aborted"),
    do: "rounded-full bg-amber-100 px-2 py-1 text-xs font-medium text-amber-700"

  defp status_badge_class(_),
    do: "rounded-full bg-rose-100 px-2 py-1 text-xs font-medium text-rose-700"

  defp format_ts(nil), do: "timestamp unavailable"

  defp format_ts(ts_ms) when is_integer(ts_ms) do
    ts_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  rescue
    _ -> Integer.to_string(ts_ms)
  end

  defp format_ts(value), do: inspect(value)

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value, pretty: true, limit: 50, printable_limit: 1_000)

  defp shorten(nil), do: "unknown"

  defp shorten(value) when is_binary(value) and byte_size(value) > 28,
    do: String.slice(value, 0, 28) <> "..."

  defp shorten(value) when is_binary(value), do: value
  defp shorten(value), do: inspect(value)
end
