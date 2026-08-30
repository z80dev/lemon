defmodule LemonWeb.MemoryManagementLive do
  @moduledoc "Authenticated, bounded browser for canonical durable memory."

  use LemonWeb, :live_view

  alias LemonMemory.Lifecycle

  @default_filters %{
    "query" => "",
    "scope" => "all",
    "kind" => "all",
    "agent" => "",
    "workspace_digest" => "",
    "limit" => "25"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Lemon Memory")
     |> assign(:filters, @default_filters)
     |> assign(:items, [])
     |> assign(:result_count, 0)
     |> assign(:truncated, false)
     |> assign(:selected, nil)
     |> assign(:delete_preview, nil)
     |> assign(:confirmation, "")
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_list()}
  end

  @impl true
  def handle_event("search", %{"filters" => params}, socket) do
    filters = normalized_form_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_list()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:notice, "Memory index refreshed.")
     |> assign(:error, nil)
     |> refresh_list()
     |> refresh_selected()}
  end

  def handle_event("inspect", %{"id" => doc_id}, socket) do
    case lifecycle_call(:inspect_document, [doc_id]) do
      {:ok, selected} ->
        {:noreply,
         socket
         |> assign(:selected, selected)
         |> assign(:delete_preview, nil)
         |> assign(:confirmation, "")
         |> assign(:notice, nil)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, safe_error(reason))}
    end
  end

  def handle_event("preview-delete", %{"id" => doc_id}, socket) do
    case lifecycle_call(:preview_delete, [doc_id]) do
      {:ok, preview} ->
        {:noreply,
         socket
         |> assign(:selected, preview.document)
         |> assign(:delete_preview, preview)
         |> assign(:confirmation, "")
         |> assign(:notice, "Deletion preview is ready. Retype the exact digest to continue.")
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, safe_error(reason))}
    end
  end

  def handle_event("validate-confirmation", %{"delete" => %{"confirmation" => value}}, socket) do
    {:noreply, assign(socket, :confirmation, normalize_confirmation(value))}
  end

  def handle_event("confirm-delete", _params, %{assigns: %{delete_preview: nil}} = socket) do
    {:noreply, assign(socket, :error, "Preview this exact record before deleting it.")}
  end

  def handle_event("confirm-delete", %{"delete" => params}, socket) do
    preview = socket.assigns.delete_preview
    confirmation = normalize_confirmation(params["confirmation"])

    case lifecycle_call(:delete, [preview.document.id, confirmation]) do
      {:ok, %{status: :deleted}} ->
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:delete_preview, nil)
         |> assign(:confirmation, "")
         |> assign(:notice, "The exact memory record was deleted and verified.")
         |> assign(:error, nil)
         |> refresh_list()}

      {:error, reason} when reason in [:stale, :confirmation_mismatch, :not_found] ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> assign(:confirmation, "")
         |> assign(:error, safe_error(reason))
         |> refresh_list()
         |> refresh_selected()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, safe_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" class="management-page memory-management-page">
      <div class="management-container">
        <header class="management-header">
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon</p>
            <h1 class="mt-1 text-lg font-semibold text-slate-900 sm:text-xl">Durable memory</h1>
            <p class="mt-1 text-sm text-slate-600">
              Search redacted run memory and reviewed learning provenance in the canonical store.
            </p>
          </div>
          <div class="management-header-actions">
            <.link href={~p"/manage"} class="management-secondary-link">Sessions</.link>
            <.link href={~p"/manage/blueprints"} class="management-secondary-link">Blueprints</.link>
            <.link href={~p"/manage/providers"} class="management-secondary-link">Providers</.link>
            <button type="button" phx-click="refresh" class="management-primary-button">Refresh</button>
          </div>
        </header>

        <div id="memory-feedback" aria-live="polite" class="management-feedback">
          <%= if @notice do %><p class="management-notice">{@notice}</p><% end %>
          <%= if @error do %><p role="alert" class="management-error">{@error}</p><% end %>
        </div>

        <section aria-labelledby="memory-filters-title" class="management-panel memory-filter-panel">
          <div class="management-panel-header">
            <div>
              <h2 id="memory-filters-title" class="font-semibold text-slate-900">Find memory</h2>
              <p class="text-xs text-slate-500">
                Up to 50 results from a bounded 200-record window. Workspaces are digest-only.
              </p>
            </div>
          </div>

          <.form
            for={to_form(@filters, as: :filters)}
            id="memory-filters"
            phx-change="search"
            class="memory-filter-grid"
          >
            <label class="memory-field memory-query-field">
              <span>Search</span>
              <input
                type="search"
                name="filters[query]"
                value={@filters["query"]}
                maxlength="256"
                phx-debounce="250"
                placeholder="Search redacted summaries"
                class="management-input"
              />
            </label>
            <label class="memory-field">
              <span>Scope</span>
              <select name="filters[scope]" class="management-select">
                <%= for value <- ~w(all session workspace agent global) do %>
                  <option value={value} selected={@filters["scope"] == value}>{label(value)}</option>
                <% end %>
              </select>
            </label>
            <label class="memory-field">
              <span>Kind</span>
              <select name="filters[kind]" class="management-select">
                <option value="all" selected={@filters["kind"] == "all"}>All memory</option>
                <option value="run" selected={@filters["kind"] == "run"}>Run memory</option>
                <option value="learned_source" selected={@filters["kind"] == "learned_source"}>Reviewed learning</option>
              </select>
            </label>
            <label class="memory-field">
              <span>Agent</span>
              <input
                type="text"
                name="filters[agent]"
                value={@filters["agent"]}
                maxlength="64"
                placeholder="default"
                class="management-input"
              />
            </label>
            <label class="memory-field">
              <span>Workspace digest</span>
              <input
                type="text"
                name="filters[workspace_digest]"
                value={@filters["workspace_digest"]}
                maxlength="64"
                pattern="[a-f0-9]{12}([a-f0-9]{52})?"
                placeholder="12 hex characters"
                class="management-input memory-digest-input"
              />
            </label>
            <label class="memory-field">
              <span>Limit</span>
              <select name="filters[limit]" class="management-select">
                <%= for value <- ~w(10 25 50) do %>
                  <option value={value} selected={@filters["limit"] == value}>{value}</option>
                <% end %>
              </select>
            </label>
          </.form>
        </section>

        <div class="memory-management-grid">
          <section aria-labelledby="memory-results-title" class="management-panel memory-list-panel">
            <div class="management-panel-header">
              <div>
                <h2 id="memory-results-title" class="font-semibold text-slate-900">Records</h2>
                <p class="text-xs text-slate-500">
                  {@result_count} shown<%= if @truncated do %>; refine filters for more<% end %>
                </p>
              </div>
            </div>
            <div id="memory-list" class="memory-list">
              <%= if @items == [] do %>
                <p class="management-empty">No memory records match these filters.</p>
              <% else %>
                <%= for item <- @items do %>
                  <article id={"memory-#{item.id}"} class="memory-row">
                    <div class="memory-row-header">
                      <div class="memory-row-copy">
                        <strong>{kind_label(item.kind)}</strong>
                        <code>{item.id}</code>
                      </div>
                      <span class="memory-scope-badge">{label(item.scope)}</span>
                    </div>
                    <p class="memory-excerpt">{item.excerpt}</p>
                    <dl class="memory-row-facts">
                      <div><dt>Agent</dt><dd>{item.agent}</dd></div>
                      <div><dt>Workspace</dt><dd>{item.workspace_digest || "none"}</dd></div>
                      <div><dt>Outcome</dt><dd>{label(item.outcome)}</dd></div>
                    </dl>
                    <div class="management-row-actions">
                      <button type="button" phx-click="inspect" phx-value-id={item.id} class="management-secondary-button">Inspect</button>
                      <button type="button" phx-click="preview-delete" phx-value-id={item.id} class="management-icon-button">Preview delete</button>
                    </div>
                  </article>
                <% end %>
              <% end %>
            </div>
          </section>

          <section aria-labelledby="memory-detail-title" class="management-panel memory-detail-panel">
            <div class="management-panel-header">
              <div>
                <h2 id="memory-detail-title" class="font-semibold text-slate-900">Redacted preview</h2>
                <p class="text-xs text-slate-500">Content and provenance are bounded before rendering.</p>
              </div>
            </div>

            <%= if @selected do %>
              <article id="memory-detail" class="memory-detail">
                <dl class="memory-detail-facts">
                  <div><dt>Document</dt><dd><code>{@selected.id}</code></dd></div>
                  <div><dt>Record digest</dt><dd><code>{@selected.record_digest}</code></dd></div>
                  <div><dt>Kind</dt><dd>{kind_label(@selected.kind)}</dd></div>
                  <div><dt>Scope</dt><dd>{label(@selected.scope)}</dd></div>
                  <div><dt>Agent</dt><dd>{@selected.agent}</dd></div>
                  <div><dt>Workspace</dt><dd>{@selected.workspace_digest || "none"}</dd></div>
                  <div><dt>Redactions</dt><dd>{@selected.redaction_count}</dd></div>
                </dl>
                <section aria-labelledby="prompt-preview-title" class="memory-preview-block">
                  <h3 id="prompt-preview-title">Prompt summary</h3>
                  <pre>{@selected.prompt_preview}</pre>
                </section>
                <section aria-labelledby="answer-preview-title" class="memory-preview-block">
                  <h3 id="answer-preview-title">Answer summary</h3>
                  <pre>{@selected.answer_preview}</pre>
                </section>
                <%= if @selected.provenance do %>
                  <section id="memory-provenance" aria-labelledby="memory-provenance-title" class="memory-provenance">
                    <h3 id="memory-provenance-title">Reviewed source provenance</h3>
                    <p>Source digest <code>{@selected.provenance.source_digest || "unavailable"}</code></p>
                    <p>{@selected.provenance.source_count} source(s); source text redacted: {yes_no(@selected.provenance.source_text_redacted)}</p>
                    <ul>
                      <%= for source <- @selected.provenance.sources do %>
                        <li>
                          <strong>{label(source.type)}</strong>
                          <span>reference <code>{source.reference_digest || "unavailable"}</code></span>
                          <span>content <code>{source.content_digest || "unavailable"}</code></span>
                          <span>{source.selected_items} item(s), {source.selected_bytes} bytes, {source.redaction_count} redaction(s)</span>
                        </li>
                      <% end %>
                    </ul>
                  </section>
                <% end %>

                <button type="button" phx-click="preview-delete" phx-value-id={@selected.id} class="management-icon-button memory-delete-button">Preview exact delete</button>
              </article>
            <% else %>
              <p class="management-empty">Select a record to inspect its redacted summary.</p>
            <% end %>

            <%= if @delete_preview do %>
              <section id="memory-delete-preview" aria-labelledby="memory-delete-title" class="memory-delete-preview">
                <h3 id="memory-delete-title">Exact deletion confirmation</h3>
                <p>Only <code>{@delete_preview.document.id}</code> is in scope.</p>
                <p>Retype this digest:</p>
                <code id="memory-confirmation-digest" class="memory-confirmation-digest">{@delete_preview.confirmation_digest}</code>
                <.form
                  for={to_form(%{"confirmation" => @confirmation}, as: :delete)}
                  id="memory-delete-form"
                  phx-change="validate-confirmation"
                  phx-submit="confirm-delete"
                >
                  <label class="memory-field">
                    <span>Confirmation digest</span>
                    <input
                      type="text"
                      name="delete[confirmation]"
                      value={@confirmation}
                      minlength="64"
                      maxlength="64"
                      pattern="[a-f0-9]{64}"
                      autocomplete="off"
                      class="management-input memory-digest-input"
                    />
                  </label>
                  <button type="submit" class="management-primary-button">Delete exact record</button>
                </.form>
              </section>
            <% end %>
          </section>
        </div>
      </div>
    </main>
    """
  end

  defp refresh_list(socket) do
    case lifecycle_call(:list, [socket.assigns.filters]) do
      {:ok, result} ->
        safe_filters = stringify_filters(result.filters, socket.assigns.filters)

        socket
        |> assign(:filters, safe_filters)
        |> assign(:items, result.items)
        |> assign(:result_count, result.count)
        |> assign(:truncated, result.truncated)

      {:error, reason} ->
        socket
        |> assign(:items, [])
        |> assign(:result_count, 0)
        |> assign(:truncated, false)
        |> assign(:error, safe_error(reason))
    end
  end

  defp refresh_selected(%{assigns: %{selected: nil}} = socket), do: socket

  defp refresh_selected(socket) do
    case lifecycle_call(:inspect_document, [socket.assigns.selected.id]) do
      {:ok, selected} -> assign(socket, :selected, selected)
      _ -> assign(socket, :selected, nil)
    end
  end

  defp lifecycle_call(action, args) do
    case Application.get_env(:lemon_web, :memory_lifecycle_fun) do
      fun when is_function(fun, 2) -> fun.(action, args)
      _ -> apply(Lifecycle, action, args)
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  defp normalized_form_filters(params) do
    Map.new(@default_filters, fn {key, default} -> {key, Map.get(params, key, default)} end)
  end

  defp stringify_filters(filters, fallback) do
    %{
      "query" => filters.query,
      "scope" => filters.scope,
      "kind" => filters.kind,
      "agent" => filters.agent,
      "workspace_digest" => filters.workspace_digest,
      "limit" => Map.get(fallback, "limit", "25")
    }
  end

  defp normalize_confirmation(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, 64)

  defp normalize_confirmation(_), do: ""

  defp safe_error(:invalid_query), do: "Search text is invalid or too long."
  defp safe_error(:invalid_filter), do: "A memory filter is invalid."
  defp safe_error(:invalid_limit), do: "The result limit is invalid."
  defp safe_error(:not_found), do: "That memory record no longer exists."
  defp safe_error(:stale), do: "The record changed. Preview it again before deleting."

  defp safe_error(:confirmation_mismatch),
    do: "The confirmation is stale or incorrect. Preview again."

  defp safe_error(:invalid_confirmation), do: "The confirmation digest is invalid."
  defp safe_error(_), do: "Durable memory is temporarily unavailable."

  defp label(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp kind_label("learned_source"), do: "Reviewed learning"
  defp kind_label(_), do: "Run memory"
  defp yes_no(true), do: "yes"
  defp yes_no(_), do: "no"
end
