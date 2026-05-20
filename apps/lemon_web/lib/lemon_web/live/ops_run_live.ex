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

  def handle_event("resolve-approval", %{"id" => approval_id, "decision" => decision}, socket) do
    socket =
      case LemonWeb.OpsDashboard.resolve_approval(approval_id, decision) do
        :ok ->
          socket
          |> put_flash(:info, "Approval resolved.")
          |> assign_detail(socket.assigns.run_id)

        {:error, _reason} ->
          put_flash(socket, :error, "Approval could not be resolved.")
      end

    {:noreply, socket}
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
                    <%= if oauth_authorization_url(approval) do %>
                      <div class="mt-3 rounded-md border border-amber-200 bg-white px-2 py-2">
                        <a
                          href={oauth_authorization_url(approval)}
                          target="_blank"
                          rel="noreferrer"
                          class="inline-flex rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                        >
                          Open OAuth
                        </a>
                        <p class="mt-2 break-all text-xs text-amber-900">
                          resource: {approval_action_value(approval, :resource) || "unknown"}
                        </p>
                        <p class="mt-1 break-all text-xs text-amber-900">
                          redirect: {approval_action_value(approval, :redirect_uri) || "unknown"}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          scope: {approval_action_value(approval, :scope) || "unspecified"}
                        </p>
                      </div>
                    <% end %>
                    <%= if sampling_approval?(approval) do %>
                      <div class="mt-3 rounded-md border border-amber-200 bg-white px-2 py-2">
                        <p class="text-xs font-semibold text-amber-950">MCP sampling request</p>
                        <p class="mt-1 text-xs text-amber-900">
                          model: {approval_action_value(approval, :requested_model) || "unspecified"}
                          · max tokens: {format_value(approval_action_value(approval, :max_tokens))}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          messages: {format_value(approval_action_value(approval, :message_count))}
                          · text chars: {format_value(approval_action_value(approval, :text_char_count))}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          roles: {format_inline_list(approval_action_value(approval, :roles))}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          content: {format_action_map(approval_action_value(approval, :content_kinds))}
                        </p>
                        <p class="mt-1 break-all text-xs text-amber-900">
                          request: {approval_action_value(approval, :request_hash) || "unknown"}
                        </p>
                      </div>
                    <% end %>
                    <div class="mt-3 flex flex-wrap gap-2">
                      <.approval_button approval={approval} decision="approve_once" label="Approve Once" />
                      <.approval_button approval={approval} decision="approve_session" label="Session" />
                      <.approval_button approval={approval} decision="approve_agent" label="Agent" />
                      <.approval_button approval={approval} decision="approve_global" label="Global" />
                      <.approval_button approval={approval} decision="deny" label="Deny" tone="danger" />
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Approval Events">
            <%= if @detail.approval_events == [] do %>
              <.empty text="No approval lifecycle events recorded for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.approval_events do %>
                  <.event_card event={event} tone="approval" />
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

          <.panel title="Learning Events">
            <%= if @detail.learning_events == [] do %>
              <.empty text="No skill or memory events recorded for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.learning_events do %>
                  <.event_card event={event} tone="learning" />
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Channel Events">
            <%= if @detail.channel_events == [] do %>
              <.empty text="No Telegram or Discord channel events recorded for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.channel_events do %>
                  <.event_card event={event} tone="channel" />
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Cron Events">
            <%= if @detail.cron_events == [] do %>
              <.empty text="No cron lifecycle events recorded for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.cron_events do %>
                  <.event_card event={event} tone="cron" />
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Subagent Events">
            <%= if @detail.subagent_events == [] do %>
              <.empty text="No delegation or subagent events recorded for this run." />
            <% else %>
              <div class="space-y-3">
                <%= for event <- @detail.subagent_events do %>
                  <.event_card event={event} tone="subagent" />
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

  attr(:approval, :map, required: true)
  attr(:decision, :string, required: true)
  attr(:label, :string, required: true)
  attr(:tone, :string, default: "default")

  defp approval_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="resolve-approval"
      phx-value-id={@approval.id}
      phx-value-decision={@decision}
      class={approval_button_class(@tone)}
    >
      {@label}
    </button>
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

  defp event_card_class("approval", _event),
    do: "rounded-lg border border-amber-200 bg-amber-50 px-3 py-2"

  defp event_card_class("learning", _event),
    do: "rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2"

  defp event_card_class("channel", _event),
    do: "rounded-lg border border-indigo-200 bg-indigo-50 px-3 py-2"

  defp event_card_class("cron", _event),
    do: "rounded-lg border border-violet-200 bg-violet-50 px-3 py-2"

  defp event_card_class("subagent", _event),
    do: "rounded-lg border border-cyan-200 bg-cyan-50 px-3 py-2"

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

  defp approval_button_class("danger") do
    "rounded-md bg-rose-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
  end

  defp approval_button_class(_) do
    "rounded-md bg-amber-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
  end

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

  defp oauth_authorization_url(approval) do
    approval_action_value(approval, :authorization_url)
  end

  defp sampling_approval?(approval) do
    approval_action_value(approval, :type) == "mcp_sampling"
  end

  defp approval_action_value(%{action: action}, key) when is_map(action) do
    Map.get(action, key) || Map.get(action, Atom.to_string(key))
  end

  defp approval_action_value(_, _), do: nil

  defp format_inline_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "none"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_inline_list(_), do: "none"

  defp format_action_map(values) when is_map(values) and map_size(values) > 0 do
    values
    |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)
    |> Enum.join(", ")
  end

  defp format_action_map(_), do: "none"

  defp shorten(nil), do: "unknown"

  defp shorten(value) when is_binary(value) and byte_size(value) > 28,
    do: String.slice(value, 0, 28) <> "..."

  defp shorten(value) when is_binary(value), do: value
  defp shorten(value), do: inspect(value)
end
