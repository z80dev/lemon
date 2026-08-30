defmodule LemonWeb.ManagementLive do
  @moduledoc "Authenticated operations surface for durable Lemon sessions."

  use LemonWeb, :live_view

  alias LemonCore.{NodeRegistry, SessionLifecycle}
  alias LemonCore.Runtime.Health

  @expected_apps [:lemon_core, :lemon_router, :lemon_web]
  @max_sessions 200
  @max_history 100
  @default_prune_days 30
  @day_ms 86_400_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Lemon Management")
     |> assign(:query, "")
     |> assign(:archive_filter, "active")
     |> assign(:selected_key, nil)
     |> assign(:selected, nil)
     |> assign(:history, [])
     |> assign(:sessions, [])
     |> assign(:matched_count, 0)
     |> assign(:total_count, 0)
     |> assign(:prune_days, Integer.to_string(@default_prune_days))
     |> assign(:prune_preview, nil)
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_runtime()
     |> refresh_sessions()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_key = normalize_session_key(params["session_key"])

    {:noreply,
     socket
     |> assign(:selected_key, selected_key)
     |> refresh_selected()}
  end

  @impl true
  def handle_event("search", %{"filters" => filters}, socket) do
    socket =
      socket
      |> assign(:query, normalize_query(filters["query"]))
      |> assign(:archive_filter, normalize_archive_filter(filters["archive_filter"]))
      |> assign(:prune_preview, nil)
      |> clear_feedback()
      |> refresh_sessions()
      |> refresh_selected()

    {:noreply, socket}
  end

  def handle_event("patch", %{"session-key" => session_key, "field" => field}, socket) do
    with %{} = session <- SessionLifecycle.get(session_key),
         {:ok, attrs} <- toggle_attrs(field, session),
         {:ok, _updated} <- SessionLifecycle.patch(session_key, attrs) do
      {:noreply,
       socket
       |> assign(:prune_preview, nil)
       |> assign(:notice, mutation_notice(field))
       |> assign(:error, nil)
       |> refresh_sessions()
       |> refresh_selected()}
    else
      nil -> {:noreply, assign(socket, :error, "That session no longer exists.")}
      {:error, reason} -> {:noreply, assign(socket, :error, lifecycle_error(reason))}
    end
  end

  def handle_event("update-title", %{"metadata" => params}, socket) do
    with session_key when is_binary(session_key) <- socket.assigns.selected_key,
         {:ok, _updated} <- SessionLifecycle.patch(session_key, %{title: params["title"]}) do
      {:noreply,
       socket
       |> assign(:prune_preview, nil)
       |> assign(:notice, "Session title updated.")
       |> assign(:error, nil)
       |> refresh_sessions()
       |> refresh_selected()}
    else
      nil -> {:noreply, assign(socket, :error, "Select a session first.")}
      {:error, reason} -> {:noreply, assign(socket, :error, lifecycle_error(reason))}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:notice, "Runtime state refreshed.")
     |> assign(:error, nil)
     |> refresh_runtime()
     |> refresh_sessions()
     |> refresh_selected()}
  end

  def handle_event("preview-prune", %{"prune" => %{"days" => days}}, socket) do
    with {:ok, days} <- parse_prune_days(days),
         threshold = System.system_time(:millisecond) - days * @day_ms,
         {:ok, preview} <- SessionLifecycle.prune(older_than_ms: threshold) do
      {:noreply,
       socket
       |> assign(:prune_days, Integer.to_string(days))
       |> assign(:prune_preview, preview)
       |> assign(:notice, prune_preview_notice(preview))
       |> assign(:error, nil)}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:prune_preview, nil)
         |> assign(:error, lifecycle_error(reason))}
    end
  end

  def handle_event("confirm-prune", _params, %{assigns: %{prune_preview: nil}} = socket) do
    {:noreply, assign(socket, :error, "Preview the exact candidate set before pruning.")}
  end

  def handle_event("confirm-prune", _params, socket) do
    preview = socket.assigns.prune_preview

    case SessionLifecycle.prune(
           older_than_ms: preview.older_than_ms,
           dry_run: false,
           confirm_token: preview.confirmation_token
         ) do
      {:ok, result} ->
        selected_key =
          if socket.assigns.selected_key in result.deleted_session_keys,
            do: nil,
            else: socket.assigns.selected_key

        {:noreply,
         socket
         |> assign(:selected_key, selected_key)
         |> assign(:prune_preview, nil)
         |> assign(
           :notice,
           "Pruned #{result.deleted_count} archived session(s) and verified deletion."
         )
         |> assign(:error, nil)
         |> refresh_sessions()
         |> refresh_selected()}

      {:error, :confirmation_mismatch} ->
        {:noreply,
         socket
         |> assign(:prune_preview, nil)
         |> assign(
           :error,
           "The candidate set changed. Preview again before any session is deleted."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :error, lifecycle_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" class="management-page">
      <div class="management-container">
        <header class="management-header">
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon</p>
            <h1 class="mt-1 text-lg font-semibold text-slate-900 sm:text-xl">Session management</h1>
            <p class="mt-1 text-sm text-slate-600">
              Search, inspect, resume, export, and safely retire durable sessions.
            </p>
          </div>
          <div class="management-header-actions">
            <.link href={~p"/"} class="management-secondary-link">Open chat</.link>
            <button type="button" phx-click="refresh" class="management-primary-button">
              Refresh
            </button>
          </div>
        </header>

        <section aria-labelledby="runtime-title" class="management-status-grid">
          <h2 id="runtime-title" class="sr-only">Runtime status</h2>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Runtime</p>
            <div class="management-status-line">
              <span class={status_dot_class(@runtime.status)} aria-hidden="true"></span>
              <strong>{status_label(@runtime.status)}</strong>
            </div>
            <p class="text-xs text-slate-500">
              {length(@runtime.apps)} apps started; {length(@runtime.missing)} expected missing
            </p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Execution nodes</p>
            <p class="management-status-value">{length(@nodes)} live</p>
            <p class="text-xs text-slate-500">
              {node_names(@nodes)}
            </p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Durable sessions</p>
            <p class="management-status-value">{@total_count} total</p>
            <p class="text-xs text-slate-500">{@matched_count} match current filters</p>
          </div>
        </section>

        <div id="management-feedback" aria-live="polite" class="management-feedback">
          <%= if @notice do %>
            <p class="management-notice">{@notice}</p>
          <% end %>
          <%= if @error do %>
            <p role="alert" class="management-error">{@error}</p>
          <% end %>
        </div>

        <div class="management-layout">
          <section aria-labelledby="sessions-title" class="management-panel">
            <div class="management-panel-header">
              <div>
                <h2 id="sessions-title" class="font-semibold text-slate-900">Sessions</h2>
                <p class="text-xs text-slate-500">Pins sort first, then newest activity.</p>
              </div>
            </div>

            <.form
              for={
                to_form(
                  %{"query" => @query, "archive_filter" => @archive_filter},
                  as: :filters
                )
              }
              id="session-filters"
              phx-change="search"
              class="management-filter-form"
            >
              <label for="filters_query" class="sr-only">Search sessions</label>
              <input
                id="filters_query"
                name="filters[query]"
                type="search"
                value={@query}
                placeholder="Search title, key, prompt, or answer"
                phx-debounce="250"
                class="management-input"
              />
              <label for="filters_archive_filter" class="sr-only">Archive filter</label>
              <select
                id="filters_archive_filter"
                name="filters[archive_filter]"
                class="management-select"
              >
                <option value="active" selected={@archive_filter == "active"}>Active</option>
                <option value="archived" selected={@archive_filter == "archived"}>Archived</option>
                <option value="all" selected={@archive_filter == "all"}>All</option>
              </select>
            </.form>

            <div id="session-list" class="management-session-list">
              <%= if @sessions == [] do %>
                <p class="management-empty">No sessions match these filters.</p>
              <% else %>
                <%= for session <- @sessions do %>
                  <article
                    id={"session-#{dom_id(session.session_key)}"}
                    class={session_row_class(session.session_key, @selected_key)}
                  >
                    <div class="management-session-copy">
                      <.link
                        patch={~p"/manage/sessions/#{session.session_key}"}
                        class="management-session-title"
                      >
                        {session.title || session.session_key}
                      </.link>
                      <p class="management-session-key">{session.session_key}</p>
                      <p class="text-xs text-slate-500">
                        {session.run_count} runs · {format_time(session.updated_at_ms)}
                      </p>
                    </div>
                    <div class="management-row-actions">
                      <button
                        type="button"
                        phx-click="patch"
                        phx-value-session-key={session.session_key}
                        phx-value-field="pinned"
                        class="management-icon-button"
                        aria-label={if session.pinned, do: "Unpin session", else: "Pin session"}
                        title={if session.pinned, do: "Unpin", else: "Pin"}
                      >
                        {if session.pinned, do: "Pinned", else: "Pin"}
                      </button>
                      <button
                        type="button"
                        phx-click="patch"
                        phx-value-session-key={session.session_key}
                        phx-value-field="archived"
                        class="management-icon-button"
                        aria-label={
                          if session.archived, do: "Restore session", else: "Archive session"
                        }
                        title={if session.archived, do: "Restore", else: "Archive"}
                      >
                        {if session.archived, do: "Restore", else: "Archive"}
                      </button>
                    </div>
                  </article>
                <% end %>
              <% end %>
            </div>

            <section aria-labelledby="prune-title" class="management-prune">
              <h3 id="prune-title" class="font-semibold text-slate-900">Guarded prune</h3>
              <p class="text-xs text-slate-500">
                Only archived, unpinned sessions older than the threshold are candidates.
              </p>
              <.form
                for={to_form(%{"days" => @prune_days}, as: :prune)}
                id="prune-form"
                phx-submit="preview-prune"
                class="management-prune-form"
              >
                <label for="prune_days" class="text-xs font-medium text-slate-700">Older than days</label>
                <input
                  id="prune_days"
                  name="prune[days]"
                  type="number"
                  min="1"
                  max="3650"
                  required
                  value={@prune_days}
                  class="management-number-input"
                />
                <button type="submit" class="management-secondary-button">Preview</button>
              </.form>
              <%= if @prune_preview do %>
                <div id="prune-preview" class="management-prune-preview">
                  <p>
                    <strong>{@prune_preview.candidate_count}</strong> exact candidate(s):
                    {candidate_names(@prune_preview.candidate_session_keys)}
                  </p>
                  <button
                    type="button"
                    phx-click="confirm-prune"
                    class="management-danger-button"
                    disabled={@prune_preview.candidate_count == 0}
                  >
                    Confirm verified prune
                  </button>
                </div>
              <% end %>
            </section>
          </section>

          <section id="session-inspector" aria-labelledby="inspector-title" class="management-panel">
            <%= if @selected do %>
              <div class="management-panel-header">
                <div class="management-inspector-heading">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Inspection</p>
                  <h2 id="inspector-title" class="font-semibold text-slate-900">
                    {@selected.title || "Untitled session"}
                  </h2>
                  <p class="management-session-key">{@selected.session_key}</p>
                </div>
                <div class="management-header-actions">
                  <.link href={~p"/sessions/#{@selected.session_key}"} class="management-primary-link">
                    Resume chat
                  </.link>
                </div>
              </div>

              <.form
                for={to_form(%{"title" => @selected.title || ""}, as: :metadata)}
                id="session-title-form"
                phx-submit="update-title"
                class="management-title-form"
              >
                <label for="metadata_title" class="text-xs font-medium text-slate-700">Title</label>
                <input
                  id="metadata_title"
                  name="metadata[title]"
                  type="text"
                  maxlength="160"
                  value={@selected.title || ""}
                  placeholder="Add a searchable title"
                  class="management-input"
                />
                <button type="submit" class="management-secondary-button">Save title</button>
              </.form>

              <div class="management-export-row" aria-label="Redacted session exports">
                <span class="text-xs text-slate-500">Always redacted; raw events and secrets omitted.</span>
                <.link
                  href={~p"/manage/sessions/#{@selected.session_key}/export/json"}
                  class="management-secondary-link"
                >
                  Export JSON
                </.link>
                <.link
                  href={~p"/manage/sessions/#{@selected.session_key}/export/markdown"}
                  class="management-secondary-link"
                >
                  Export Markdown
                </.link>
              </div>

              <div id="run-history" class="management-run-list">
                <%= if @history == [] do %>
                  <p class="management-empty">No durable runs are available for this session.</p>
                <% else %>
                  <%= for run <- @history do %>
                    <article id={"run-#{dom_id(run.run_id)}"} class="management-run-card">
                      <header class="management-run-header">
                        <div>
                          <h3 class="font-semibold text-slate-900">Run {run.run_id}</h3>
                          <p class="text-xs text-slate-500">
                            {format_time(run.started_at_ms)} · {run.engine || "unknown engine"} · {run.event_count} events
                          </p>
                        </div>
                        <span class={run_status_class(run.ok)}>{run_status_label(run.ok)}</span>
                      </header>
                      <div class="management-run-section">
                        <h4>Prompt</h4>
                        <p>{run.prompt || "Not recorded."}</p>
                      </div>
                      <div class="management-run-section">
                        <h4>Answer</h4>
                        <p>{run.answer || "Not recorded."}</p>
                      </div>
                      <%= if run.tools != [] do %>
                        <div class="management-tools">
                          <h4>Tool activity ({length(run.tools)})</h4>
                          <%= for {tool, index} <- Enum.with_index(run.tools) do %>
                            <details id={"tool-#{dom_id(run.run_id)}-#{index}"}>
                              <summary>
                                <span>{tool.title || tool.kind || "Tool call"}</span>
                                <span>{tool.phase || "unknown"}</span>
                              </summary>
                              <%= if tool.detail do %>
                                <pre>{format_detail(tool.detail)}</pre>
                              <% end %>
                              <%= if tool.message do %>
                                <p>{format_detail(tool.message)}</p>
                              <% end %>
                            </details>
                          <% end %>
                        </div>
                      <% end %>
                    </article>
                  <% end %>
                <% end %>
              </div>
            <% else %>
              <div class="management-empty-inspector">
                <h2 id="inspector-title" class="font-semibold text-slate-900">Select a session</h2>
                <p class="text-sm text-slate-500">
                  Choose a durable session to inspect its redacted run and tool history.
                </p>
              </div>
            <% end %>
          </section>
        </div>
      </div>
    </main>
    """
  end

  defp refresh_runtime(socket) do
    assign(socket,
      runtime: Health.status(apps: @expected_apps),
      nodes: safe_nodes()
    )
  end

  defp refresh_sessions(socket) do
    result =
      SessionLifecycle.list(
        query: socket.assigns.query,
        archived: archive_filter(socket.assigns.archive_filter),
        limit: @max_sessions
      )

    assign(socket,
      sessions: result.sessions,
      matched_count: result.matched,
      total_count: result.total
    )
  end

  defp refresh_selected(%{assigns: %{selected_key: nil}} = socket) do
    assign(socket, selected: nil, history: [])
  end

  defp refresh_selected(socket) do
    case SessionLifecycle.get(socket.assigns.selected_key) do
      nil ->
        socket
        |> assign(selected: nil, history: [])
        |> assign(:error, socket.assigns.error || "That session no longer exists.")

      selected ->
        assign(socket,
          selected: selected,
          history:
            SessionLifecycle.history(selected.session_key, limit: @max_history, redact: true)
        )
    end
  end

  defp clear_feedback(socket), do: assign(socket, notice: nil, error: nil)

  defp safe_nodes do
    case Process.whereis(NodeRegistry) do
      pid when is_pid(pid) ->
        NodeRegistry.list()
        |> Enum.map(&Map.take(&1, [:id, :name, :connected_at_ms]))

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp toggle_attrs("pinned", session), do: {:ok, %{pinned: not session.pinned}}
  defp toggle_attrs("archived", session), do: {:ok, %{archived: not session.archived}}
  defp toggle_attrs(_field, _session), do: {:error, :invalid_field}

  defp mutation_notice("pinned"), do: "Session pin state updated."
  defp mutation_notice("archived"), do: "Session archive state updated."
  defp mutation_notice(_field), do: "Session metadata updated."

  defp normalize_session_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      session_key -> session_key
    end
  end

  defp normalize_session_key(_value), do: nil

  defp normalize_query(value) when is_binary(value), do: String.trim(value)
  defp normalize_query(_value), do: ""

  defp normalize_archive_filter(value) when value in ["active", "archived", "all"], do: value
  defp normalize_archive_filter(_value), do: "active"

  defp archive_filter("active"), do: false
  defp archive_filter("archived"), do: true
  defp archive_filter(_value), do: :all

  defp parse_prune_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days in 1..3650 -> {:ok, days}
      _ -> {:error, :invalid_prune_days}
    end
  end

  defp parse_prune_days(_value), do: {:error, :invalid_prune_days}

  defp prune_preview_notice(%{candidate_count: 0}), do: "No sessions match the prune policy."

  defp prune_preview_notice(%{candidate_count: count}),
    do: "Previewed #{count} exact candidate(s). Review the list before confirming."

  defp lifecycle_error(:not_found), do: "That session no longer exists."
  defp lifecycle_error(:title_too_long), do: "Titles can contain at most 160 characters."
  defp lifecycle_error(:invalid_title), do: "The title is not valid."
  defp lifecycle_error(:invalid_prune_days), do: "Choose a threshold from 1 to 3650 days."
  defp lifecycle_error(:invalid_field), do: "That session field cannot be changed."
  defp lifecycle_error(:confirmation_required), do: "Preview the exact candidate set first."
  defp lifecycle_error(:confirmation_mismatch), do: "The candidate set changed; preview again."
  defp lifecycle_error(_reason), do: "The session operation could not be completed."

  defp status_label(:ok), do: "Healthy"
  defp status_label(_status), do: "Degraded"

  defp status_dot_class(:ok), do: "management-status-dot management-status-dot-ok"
  defp status_dot_class(_status), do: "management-status-dot management-status-dot-warning"

  defp node_names([]), do: "No named nodes connected"
  defp node_names(nodes), do: nodes |> Enum.map(& &1.name) |> Enum.join(", ")

  defp candidate_names([]), do: "none"
  defp candidate_names(keys), do: Enum.join(keys, ", ")

  defp session_row_class(key, key), do: "management-session-row management-session-row-selected"
  defp session_row_class(_key, _selected), do: "management-session-row"

  defp run_status_class(true), do: "management-run-status management-run-status-ok"
  defp run_status_class(false), do: "management-run-status management-run-status-error"
  defp run_status_class(_value), do: "management-run-status"

  defp run_status_label(true), do: "Succeeded"
  defp run_status_label(false), do: "Failed"
  defp run_status_label(_value), do: "Unknown"

  defp format_time(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
      {:error, _reason} -> "time unavailable"
    end
  end

  defp format_time(_value), do: "time unavailable"

  defp format_detail(value) when is_binary(value), do: value

  defp format_detail(value) when is_map(value) or is_list(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value, pretty: true, limit: 100)
    end
  end

  defp format_detail(value), do: inspect(value, pretty: true, limit: 100)

  defp dom_id(value) do
    value
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end
end
