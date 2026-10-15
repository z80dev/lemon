defmodule LemonWeb.ManagementLive do
  @moduledoc """
  Session manager (`/sessions`) and redacted session inspection
  (`/sessions/:session_key`).

  Reads and mutations go through the control-plane session methods
  (`sessions.list`, `sessions.stats`, `sessions.metadata.patch`,
  `sessions.fork`, `sessions.delete`, `sessions.prune`) so the page shares the
  TUI's bounded projections. Inspection uses the always-redacted
  `SessionLifecycle.history/2` projected through `LemonWeb.ManagementText`.

  Destructive operations are preview-then-confirm with the binding held in
  socket assigns: delete re-checks the exact session fingerprint and idle
  state before deleting; prune confirms the server-issued token for the exact
  candidate set, and any mutation from this page discards an open preview.
  """

  use LemonWeb, :live_view

  alias LemonCore.{SessionKey, SessionLifecycle}
  alias LemonWeb.{ManagementText, Rpc, SessionCwd}

  @max_sessions 200
  @max_history 100
  @max_active_runs 40
  @max_agent_options 50
  @max_query_bytes 200
  @default_prune_days 30
  @day_ms 86_400_000
  @refresh_interval_ms 3_000
  @slow_refresh_every 5
  @max_detail_bytes 8_000
  @statuses ~w(active archived all)
  @sorts ~w(activity title runs created agent)
  @model_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,159}\z/
  @phase_rank %{"started" => 0, "updated" => 1, "completed" => 2}

  @impl true
  def mount(_params, _session, socket) do
    _ = if connected?(socket), do: Process.send_after(self(), :tick, @refresh_interval_ms)

    {:ok,
     socket
     |> assign(nav: :sessions, page_title: "Sessions · Lemon", page_heading: "Sessions")
     |> assign(:filters, default_filters())
     |> assign(:sessions, [])
     |> assign(:matched, 0)
     |> assign(:store_total, 0)
     |> assign(:sessions_available?, true)
     |> assign(:stats, nil)
     |> assign(:agent_options, [])
     |> assign(:active_runs, [])
     |> assign(:running, MapSet.new())
     |> assign(:active_runs_available?, true)
     |> assign(:selected_keys, MapSet.new())
     |> assign(:renaming, nil)
     |> assign(:rename_error, nil)
     |> assign(:delete_preview, nil)
     |> assign(:prune, nil)
     |> assign(:forking, nil)
     |> assign(:session_key, nil)
     |> assign(:selected, nil)
     |> assign(:detail_state, :none)
     |> assign(:detail_meta, nil)
     |> assign(:history, [])
     |> assign(:tick, 0)
     |> refresh_active_runs()}
  end

  @impl true
  def handle_params(params, _uri, %{assigns: %{live_action: :show}} = socket) do
    key = normalize_session_key(params["session_key"])

    {:noreply,
     socket
     |> assign(:session_key, key)
     |> assign(:renaming, nil)
     |> load_selected(true)}
  end

  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filters, parse_filters(params))
     |> assign(:session_key, nil)
     |> assign(:selected, nil)
     |> assign(:history, [])
     |> assign(:detail_state, :none)
     |> refresh_sessions()
     |> refresh_stats()
     |> prune_selection()}
  end

  # ── Filters, sorting, selection ──────────────────────────────────────────

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      socket.assigns.filters
      |> Map.put(:q, bounded(params["q"], @max_query_bytes))
      |> Map.put(:agent, normalize_agent(params["agent"]))

    {:noreply, push_patch(socket, to: index_path(filters), replace: true)}
  end

  def handle_event("toggle-pinned-filter", _params, socket) do
    filters = Map.update!(socket.assigns.filters, :pinned, &(!&1))
    {:noreply, push_patch(socket, to: index_path(filters))}
  end

  def handle_event("clear-filters", _params, socket) do
    filters = %{default_filters() | status: socket.assigns.filters.status}
    {:noreply, push_patch(socket, to: index_path(filters))}
  end

  def handle_event("sort", %{"by" => by}, socket) when by in @sorts do
    filters = socket.assigns.filters

    dir =
      cond do
        filters.sort != by -> default_dir(by)
        filters.dir == "asc" -> "desc"
        true -> "asc"
      end

    {:noreply, push_patch(socket, to: index_path(%{filters | sort: by, dir: dir}))}
  end

  def handle_event("toggle-select", %{"key" => key}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_keys, key),
        do: MapSet.delete(socket.assigns.selected_keys, key),
        else: MapSet.put(socket.assigns.selected_keys, key)

    {:noreply, socket |> assign(:selected_keys, selected) |> prune_selection()}
  end

  def handle_event("toggle-select-all", _params, socket) do
    visible = MapSet.new(socket.assigns.sessions, & &1.session_key)

    selected =
      if MapSet.size(visible) > 0 and MapSet.subset?(visible, socket.assigns.selected_keys),
        do: MapSet.new(),
        else: visible

    {:noreply, assign(socket, :selected_keys, selected)}
  end

  def handle_event("clear-selection", _params, socket) do
    {:noreply, assign(socket, :selected_keys, MapSet.new())}
  end

  def handle_event("bulk", %{"action" => action}, socket)
      when action in ~w(pin unpin archive unarchive) do
    {field, value} = bulk_patch(action)
    visible = MapSet.new(socket.assigns.sessions, & &1.session_key)
    keys = socket.assigns.selected_keys |> MapSet.intersection(visible) |> Enum.sort()

    results =
      Enum.map(keys, fn key ->
        Rpc.call("sessions.metadata.patch", %{"sessionKey" => key, field => value})
      end)

    failed = Enum.count(results, &match?({:error, _}, &1))
    done = length(results) - failed

    socket =
      socket
      |> assign(:selected_keys, MapSet.new())
      |> after_mutation()

    socket =
      if failed == 0,
        do: put_flash(socket, :info, "#{bulk_label(action)} #{plural(done, "session")}."),
        else:
          put_flash(
            socket,
            :error,
            "#{bulk_label(action)} #{plural(done, "session")}; #{failed} could not be changed."
          )

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> refresh_active_runs()
     |> refresh_current(true)
     |> put_flash(:info, "Sessions refreshed.")}
  end

  # ── Metadata: pin, archive, rename ───────────────────────────────────────

  def handle_event("set-flag", %{"key" => key, "field" => field, "value" => value}, socket)
      when field in ["pinned", "archived"] and value in ["true", "false"] do
    case Rpc.call("sessions.metadata.patch", %{
           "sessionKey" => key,
           field => value == "true"
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> after_mutation()
         |> put_flash(:info, flag_notice(field, value == "true"))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, Rpc.message(error))}
    end
  end

  def handle_event("start-rename", %{"key" => key}, socket) do
    {:noreply, assign(socket, renaming: key, rename_error: nil)}
  end

  def handle_event("cancel-rename", _params, socket) do
    {:noreply, assign(socket, renaming: nil, rename_error: nil)}
  end

  def handle_event("rename", %{"key" => key, "title" => title}, socket) do
    title =
      case title |> to_string() |> String.trim() do
        "" -> nil
        value -> value
      end

    case Rpc.call("sessions.metadata.patch", %{"sessionKey" => key, "title" => title}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(renaming: nil, rename_error: nil)
         |> after_mutation()
         |> put_flash(:info, if(title, do: "Session renamed.", else: "Session title cleared."))}

      {:error, error} ->
        {:noreply, assign(socket, :rename_error, Rpc.message(error))}
    end
  end

  # ── Fork ─────────────────────────────────────────────────────────────────

  def handle_event("fork", %{"key" => key}, %{assigns: %{forking: nil}} = socket) do
    socket =
      socket
      |> assign(:forking, key)
      |> assign(:prune, clear_prune_preview(socket.assigns.prune))
      |> start_async(:fork, fn ->
        # The workspace is resolved inside the task so it never enters assigns;
        # the child inherits it so chat resumes in the same workspace.
        with cwd when is_binary(cwd) <- SessionCwd.resolve(key),
             {:ok, %{"sessionKey" => child}} = ok when is_binary(child) <-
               Rpc.call("sessions.fork", %{"sessionKey" => key, "cwd" => cwd}) do
          SessionCwd.remember(child, cwd)
          ok
        else
          {:error, :unavailable} ->
            {:error, {:unavailable, "Session workspace is unavailable", nil}}

          other ->
            other
        end
      end)

    {:noreply, socket}
  end

  def handle_event("fork", _params, socket) do
    {:noreply, put_flash(socket, :error, "A fork is already in progress.")}
  end

  # ── Delete (exact-key preview → confirm) ─────────────────────────────────

  def handle_event("preview-delete", %{"key" => key}, socket) do
    case SessionLifecycle.get(key) do
      nil ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> put_flash(:error, "That session no longer exists.")}

      row ->
        session = project_lifecycle(row)

        preview = %{
          session_key: key,
          title: session.title,
          run_count: session.run_count,
          updated_at_ms: session.updated_at_ms,
          pinned: session.pinned,
          running: MapSet.member?(socket.assigns.running, key),
          fingerprint: fingerprint(row)
        }

        {:noreply, assign(socket, :delete_preview, preview)}
    end
  end

  def handle_event("cancel-delete", _params, socket) do
    {:noreply, assign(socket, :delete_preview, nil)}
  end

  def handle_event("confirm-delete", _params, %{assigns: %{delete_preview: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Preview the exact session before deleting it.")}
  end

  def handle_event("confirm-delete", _params, socket) do
    preview = socket.assigns.delete_preview
    key = preview.session_key

    with %{} = row <- SessionLifecycle.get(key),
         true <- fingerprint(row) == preview.fingerprint,
         :idle <- idle_state(key),
         {:ok, _} <- Rpc.call("sessions.delete", %{"sessionKey" => key}) do
      socket =
        socket
        |> assign(:delete_preview, nil)
        |> assign(:selected_keys, MapSet.delete(socket.assigns.selected_keys, key))
        |> put_flash(:info, "Session deleted and verified gone.")

      socket =
        if socket.assigns.live_action == :show,
          do: push_patch(socket, to: index_path(socket.assigns.filters)),
          else: after_mutation(socket)

      {:noreply, socket}
    else
      nil ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> after_mutation()
         |> put_flash(:error, "That session no longer exists.")}

      false ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> after_mutation()
         |> put_flash(
           :error,
           "The session changed after the preview. Nothing was deleted; review it again."
         )}

      :running ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> put_flash(:error, "The session is running. Stop it before deleting.")}

      :unknown ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> put_flash(
           :error,
           "Run status is unavailable, so the session could not be confirmed idle. Nothing was deleted."
         )}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:delete_preview, nil)
         |> after_mutation()
         |> put_flash(:error, Rpc.message(error))}
    end
  end

  # ── Prune (preview → token-bound confirm) ────────────────────────────────

  def handle_event("open-prune", _params, socket) do
    prune = %{
      days: Integer.to_string(@default_prune_days),
      archived_only: true,
      include_pinned: false,
      preview: nil,
      error: nil
    }

    {:noreply, assign(socket, :prune, prune)}
  end

  def handle_event("prune-close", _params, socket) do
    {:noreply, assign(socket, :prune, nil)}
  end

  def handle_event(event, _params, %{assigns: %{prune: nil}} = socket)
      when event in ["prune-edit", "prune-preview"] do
    {:noreply, socket}
  end

  def handle_event("prune-edit", %{"prune" => params}, %{assigns: %{prune: %{}}} = socket) do
    {:noreply, assign(socket, :prune, prune_draft(socket.assigns.prune, params))}
  end

  def handle_event("prune-preview", %{"prune" => params}, %{assigns: %{prune: %{}}} = socket) do
    prune = prune_draft(socket.assigns.prune, params)

    with {:ok, days} <- parse_prune_days(prune.days),
         threshold = System.system_time(:millisecond) - days * @day_ms,
         {:ok, payload} <-
           Rpc.call("sessions.prune", %{
             "olderThanMs" => threshold,
             "archivedOnly" => prune.archived_only,
             "includePinned" => prune.include_pinned,
             "dryRun" => true
           }),
         {:ok, preview} <- project_prune_preview(payload) do
      {:noreply, assign(socket, :prune, %{prune | preview: preview, error: nil})}
    else
      {:error, :invalid_days} ->
        {:noreply,
         assign(socket, :prune, %{
           prune
           | preview: nil,
             error: "Choose a threshold from 1 to 3650 days."
         })}

      {:error, error} ->
        {:noreply, assign(socket, :prune, %{prune | preview: nil, error: Rpc.message(error)})}
    end
  end

  def handle_event(
        "prune-confirm",
        _params,
        %{assigns: %{prune: %{preview: %{} = preview}}} = socket
      ) do
    case Rpc.call("sessions.prune", %{
           "olderThanMs" => preview.older_than_ms,
           "archivedOnly" => preview.archived_only,
           "includePinned" => preview.include_pinned,
           "dryRun" => false,
           "confirmToken" => preview.token
         }) do
      {:ok, result} ->
        deleted = result["deletedSessionKeys"] || []

        {:noreply,
         socket
         |> assign(:prune, nil)
         |> assign(
           :selected_keys,
           MapSet.difference(socket.assigns.selected_keys, MapSet.new(deleted))
         )
         |> after_mutation()
         |> put_flash(
           :info,
           "Pruned #{plural(length(deleted), "session")} and verified deletion."
         )}

      {:error, %{code: :conflict}} ->
        {:noreply,
         socket
         |> assign(:prune, %{
           socket.assigns.prune
           | preview: nil,
             error:
               "The candidate set changed since the preview. Nothing was deleted; preview again."
         })
         |> refresh_current(false)}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:prune, %{socket.assigns.prune | preview: nil, error: Rpc.message(error)})
         |> refresh_current(false)}
    end
  end

  def handle_event("prune-confirm", _params, socket) do
    prune =
      socket.assigns.prune ||
        %{
          days: "#{@default_prune_days}",
          archived_only: true,
          include_pinned: false,
          preview: nil
        }

    {:noreply,
     assign(
       socket,
       :prune,
       Map.put(prune, :error, "Preview the exact candidate set before pruning.")
     )}
  end

  # ── Async + timers ───────────────────────────────────────────────────────

  @impl true
  def handle_async(:fork, {:ok, {:ok, %{"sessionKey" => child}}}, socket) when is_binary(child) do
    {:noreply,
     socket
     |> assign(:forking, nil)
     |> put_flash(:info, "Forked into a new session.")
     |> push_navigate(to: ~p"/chat/#{child}")}
  end

  def handle_async(:fork, {:ok, {:error, %{details: %{"retrySafe" => false}}}}, socket) do
    {:noreply,
     socket
     |> assign(:forking, nil)
     |> refresh_current(false)
     |> put_flash(
       :error,
       "The fork outcome is uncertain. Check the session list before trying again."
     )}
  end

  def handle_async(:fork, {:ok, {:error, error}}, socket) do
    {:noreply, socket |> assign(:forking, nil) |> put_flash(:error, Rpc.message(error))}
  end

  def handle_async(:fork, _result, socket) do
    {:noreply,
     socket
     |> assign(:forking, nil)
     |> put_flash(
       :error,
       "The fork outcome is uncertain. Check the session list before trying again."
     )}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_interval_ms)
    tick = socket.assigns.tick + 1
    slow? = rem(tick, @slow_refresh_every) == 0

    {:noreply,
     socket
     |> assign(:tick, tick)
     |> refresh_active_runs()
     |> refresh_on_tick(slow?)}
  end

  # The legacy tick message name is kept so tests can force a refresh.
  def handle_info(:refresh_live_work, socket) do
    {:noreply, socket |> refresh_active_runs() |> refresh_current(true)}
  end

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <.page wide>
      <nav aria-label="Breadcrumb" class="mb-3 flex items-center gap-1.5 text-xs text-muted">
        <.link patch={index_path(@filters)} class="inline-flex items-center gap-1 hover:text-fg">
          <.icon name="chevron-left" class="h-3.5 w-3.5" /> Sessions
        </.link>
      </nav>

      <%= case @detail_state do %>
        <% :ok -> %>
          {detail(assigns)}
        <% :not_found -> %>
          <.empty_state
            icon="search"
            title="Session not found"
            description="It may have been deleted or pruned."
          >
            <.button patch={index_path(@filters)} icon="list">Back to sessions</.button>
          </.empty_state>
        <% _ -> %>
          <.callout tone="warning" title="Session details are temporarily unavailable">
            The session store could not be read. Try again in a moment.
          </.callout>
      <% end %>
      {dialogs(assigns)}
    </.page>
    """
  end

  def render(assigns) do
    ~H"""
    <.page wide>
      <.page_header
        title="Sessions"
        icon="list"
        subtitle="Search, organize, and clean up every durable conversation."
      >
        <:actions>
          <.button size="sm" variant="ghost" icon="refresh" phx-click="refresh">Refresh</.button>
          <.button size="sm" icon="trash" phx-click="open-prune" mutation>Prune…</.button>
          <.button size="sm" variant="primary" icon="plus" navigate={~p"/"}>New session</.button>
        </:actions>
      </.page_header>

      {working_now(assigns)}

      <.tabs active={@filters.status} label="Session status" class="mb-3">
        <:tab
          id="active"
          label="Active"
          patch={index_path(%{@filters | status: "active"})}
          count={@stats && @stats.active}
        />
        <:tab
          id="archived"
          label="Archived"
          patch={index_path(%{@filters | status: "archived"})}
          count={@stats && @stats.archived}
        />
        <:tab
          id="all"
          label="All"
          patch={index_path(%{@filters | status: "all"})}
          count={@stats && @stats.total}
        />
      </.tabs>

      <form
        id="session-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mb-3 flex flex-wrap items-center gap-2"
        role="search"
      >
        <div class="relative min-w-0 flex-1 basis-56">
          <label for="session-search" class="sr-only">Search sessions</label>
          <.icon
            name="search"
            class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle"
          />
          <input
            id="session-search"
            name="q"
            type="search"
            value={@filters.q}
            maxlength="200"
            autocomplete="off"
            placeholder="Search titles, keys, prompts, answers…"
            phx-debounce="200"
            class="input pl-8 pr-10"
          />
          <.kbd keys="/" class="absolute right-2 top-1/2 -translate-y-1/2" />
        </div>
        <div :if={@agent_options != []} class="w-full sm:w-48">
          <label for="session-agent" class="sr-only">Agent or profile</label>
          <select id="session-agent" name="agent" class="input">
            <option value="">All agents</option>
            <option
              :for={{label, value} <- @agent_options}
              value={value}
              selected={value == @filters.agent}
            >
              {label}
            </option>
          </select>
        </div>
        <button
          type="button"
          id="pinned-filter"
          phx-click="toggle-pinned-filter"
          aria-pressed={to_string(@filters.pinned)}
          class={["btn btn-sm", if(@filters.pinned, do: "btn-primary", else: "btn-secondary")]}
        >
          <.icon name="pin" class="h-3.5 w-3.5" /> Pinned
        </button>
        <.button
          :if={filters_active?(@filters)}
          size="sm"
          variant="ghost"
          icon="x"
          phx-click="clear-filters"
        >
          Clear
        </.button>
      </form>

      <.callout
        :if={not @sessions_available?}
        tone="warning"
        title="Session list unavailable"
        class="mb-3"
      >
        The session store could not be read. Showing the last known sessions.
      </.callout>

      <div
        :if={MapSet.size(@selected_keys) > 0}
        id="bulk-bar"
        class="mb-2 flex flex-wrap items-center gap-2 rounded-lg border border-accent/40 bg-accent/10 px-3 py-2 text-[13px]"
        role="toolbar"
        aria-label="Bulk actions"
      >
        <span class="font-medium text-fg">{MapSet.size(@selected_keys)} selected</span>
        <span class="flex-1"></span>
        <.button size="sm" icon="pin" phx-click="bulk" phx-value-action="pin" mutation>Pin</.button>
        <.button size="sm" phx-click="bulk" phx-value-action="unpin" mutation>Unpin</.button>
        <.button size="sm" icon="archive" phx-click="bulk" phx-value-action="archive" mutation>
          Archive
        </.button>
        <.button size="sm" phx-click="bulk" phx-value-action="unarchive" mutation>Unarchive</.button>
        <.button size="sm" variant="ghost" icon="x" phx-click="clear-selection">Clear</.button>
      </div>

      <section
        id="session-list"
        class="card"
        aria-label="Sessions"
        phx-hook="SessionsTable"
      >
        <div :if={@sessions == []} class="p-4">
          <.empty_state
            icon={if filters_active?(@filters), do: "search", else: "messages"}
            title={empty_title(@filters, @sessions_available?)}
            description={empty_description(@filters)}
          >
            <.button :if={filters_active?(@filters)} size="sm" phx-click="clear-filters">
              Clear filters
            </.button>
            <.button :if={!filters_active?(@filters)} size="sm" variant="primary" navigate={~p"/"}>
              Start a session
            </.button>
          </.empty_state>
        </div>
        <div :if={@sessions != []}>
          <table class="table" id="sessions-table">
            <thead>
              <tr>
                <th class="w-8 !pr-0">
                  <input
                    type="checkbox"
                    id="select-all"
                    aria-label="Select all visible sessions"
                    checked={all_selected?(@sessions, @selected_keys)}
                    phx-click="toggle-select-all"
                    class="h-3.5 w-3.5 rounded border-line-strong bg-surface text-accent focus:ring-ring/40"
                  />
                </th>
                <th aria-sort={aria_sort(@filters, "title")}>
                  <.sort_button filters={@filters} by="title" label="Session" />
                </th>
                <th class="hidden sm:table-cell">Status</th>
                <th class="hidden lg:table-cell" aria-sort={aria_sort(@filters, "agent")}>
                  <.sort_button filters={@filters} by="agent" label="Agent" />
                </th>
                <th class="hidden xl:table-cell">Model</th>
                <th class="hidden text-right sm:table-cell" aria-sort={aria_sort(@filters, "runs")}>
                  <.sort_button filters={@filters} by="runs" label="Runs" />
                </th>
                <th aria-sort={aria_sort(@filters, "activity")}>
                  <.sort_button filters={@filters} by="activity" label="Activity" />
                </th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={session <- @sessions}
                id={"session-#{dom_id(session.session_key)}"}
                data-session-row
                data-key={session.session_key}
                tabindex="-1"
                class={[
                  "outline-none focus:bg-accent/10 focus-visible:shadow-[inset_2px_0_0_rgb(var(--accent))]",
                  MapSet.member?(@selected_keys, session.session_key) && "bg-accent/5"
                ]}
              >
                <td class="w-8 !pr-0">
                  <input
                    type="checkbox"
                    data-select
                    aria-label={"Select #{display_title(session)}"}
                    checked={MapSet.member?(@selected_keys, session.session_key)}
                    phx-click="toggle-select"
                    phx-value-key={session.session_key}
                    class="h-3.5 w-3.5 rounded border-line-strong bg-surface text-accent focus:ring-ring/40"
                  />
                </td>
                <td class="w-full min-w-[7rem] max-w-0 sm:min-w-[12rem]">
                  <%= if @renaming == session.session_key do %>
                    <.rename_form
                      id={"rename-#{dom_id(session.session_key)}"}
                      key={session.session_key}
                      title={session.title}
                      error={@rename_error}
                    />
                  <% else %>
                    <div class="flex min-w-0 items-center gap-1.5">
                      <.status_dot
                        :if={MapSet.member?(@running, session.session_key)}
                        tone="success"
                        pulse
                        class="sm:hidden"
                      />
                      <.icon
                        :if={session.pinned}
                        name="pin"
                        class="h-3.5 w-3.5 text-accent-text"
                        aria-label="Pinned"
                      />
                      <.link
                        patch={~p"/sessions/#{session.session_key}"}
                        data-inspect
                        class={[
                          "truncate font-medium hover:underline",
                          if(session.title, do: "text-fg", else: "text-muted")
                        ]}
                      >
                        {display_title(session)}
                      </.link>
                    </div>
                    <p class="truncate font-mono text-2xs text-subtle">{session.session_key}</p>
                  <% end %>
                </td>
                <td class="hidden whitespace-nowrap sm:table-cell">
                  <.status_badge
                    running={MapSet.member?(@running, session.session_key)}
                    archived={session.archived}
                  />
                </td>
                <td class="hidden whitespace-nowrap text-muted lg:table-cell">
                  {session.agent_id || "—"}
                </td>
                <td class="hidden max-w-[12rem] truncate whitespace-nowrap font-mono text-xs text-muted xl:table-cell">
                  {session.model || "default"}
                </td>
                <td class="hidden whitespace-nowrap text-right tabular-nums text-muted sm:table-cell">
                  {session.run_count}
                </td>
                <td class="whitespace-nowrap text-muted">
                  <time title={format_time(session.updated_at_ms)}>
                    {relative_time(session.updated_at_ms)}
                  </time>
                </td>
                <td class="w-0 whitespace-nowrap text-right">
                  <div class="flex items-center justify-end gap-1">
                    <.button
                      size="sm"
                      variant="ghost"
                      icon="message-square"
                      navigate={~p"/chat/#{session.session_key}"}
                      data-open-chat
                      aria-label={"Open #{display_title(session)} in chat"}
                    >
                      <span class="hidden md:inline">Open</span>
                    </.button>
                    <.row_menu
                      id={"menu-#{dom_id(session.session_key)}"}
                      session={session}
                      forking={@forking}
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="flex flex-wrap items-center justify-between gap-2 border-t border-line px-3 py-2 text-xs text-muted">
          <span id="session-count">
            Showing {length(@sessions)} of {@matched} matching · {@store_total} total
            <span :if={@matched > length(@sessions)}>— refine the search to see more</span>
          </span>
          <span class="hidden items-center gap-3 md:flex" aria-hidden="true">
            <span><.kbd keys="j" /> <.kbd keys="k" /> move</span>
            <span><.kbd keys="enter" /> open</span>
            <span><.kbd keys="i" /> inspect</span>
            <span><.kbd keys="x" /> select</span>
          </span>
        </div>
      </section>
      {dialogs(assigns)}
    </.page>
    """
  end

  defp detail(assigns) do
    ~H"""
    <.page_header title={display_title(@selected)} icon="message-square">
      <:meta>
        <span class="font-mono text-2xs text-subtle">{@selected.session_key}</span>
        <.status_badge
          running={MapSet.member?(@running, @selected.session_key)}
          archived={@selected.archived}
        />
        <.badge :if={@selected.pinned} tone="accent" icon="pin">Pinned</.badge>
      </:meta>
      <:actions>
        <.button
          size="sm"
          variant="primary"
          icon="message-square"
          navigate={~p"/chat/#{@selected.session_key}"}
        >
          Open in chat
        </.button>
        <.button
          size="sm"
          icon="git-fork"
          phx-click="fork"
          phx-value-key={@selected.session_key}
          loading={@forking == @selected.session_key}
          mutation
        >
          Fork
        </.button>
        <.button
          size="sm"
          icon="pin"
          phx-click="set-flag"
          phx-value-key={@selected.session_key}
          phx-value-field="pinned"
          phx-value-value={to_string(!@selected.pinned)}
          mutation
        >
          {if @selected.pinned, do: "Unpin", else: "Pin"}
        </.button>
        <.button
          size="sm"
          icon="archive"
          phx-click="set-flag"
          phx-value-key={@selected.session_key}
          phx-value-field="archived"
          phx-value-value={to_string(!@selected.archived)}
          mutation
        >
          {if @selected.archived, do: "Unarchive", else: "Archive"}
        </.button>
        <.dropdown id="detail-more" label="More session actions">
          <:trigger>
            <span class="btn btn-secondary btn-sm btn-icon">
              <.icon name="more-horizontal" class="h-3.5 w-3.5" />
            </span>
          </:trigger>
          <button
            type="button"
            role="menuitem"
            class="menu-item"
            phx-click="start-rename"
            phx-value-key={@selected.session_key}
          >
            <.icon name="pencil" class="h-3.5 w-3.5" /> Rename
          </button>
          <a
            role="menuitem"
            class="menu-item"
            href={~p"/sessions/#{@selected.session_key}/export/json"}
            download
          >
            <.icon name="download" class="h-3.5 w-3.5" /> Export JSON
          </a>
          <a
            role="menuitem"
            class="menu-item"
            href={~p"/sessions/#{@selected.session_key}/export/markdown"}
            download
          >
            <.icon name="file-text" class="h-3.5 w-3.5" /> Export Markdown
          </a>
          <button
            type="button"
            role="menuitem"
            class="menu-item text-danger"
            phx-click="preview-delete"
            phx-value-key={@selected.session_key}
            data-requires-connection
          >
            <.icon name="trash" class="h-3.5 w-3.5" /> Delete…
          </button>
        </.dropdown>
      </:actions>
    </.page_header>

    <div :if={@renaming == @selected.session_key} class="mb-4 max-w-xl">
      <.rename_form
        id="rename-detail"
        key={@selected.session_key}
        title={@selected.title}
        error={@rename_error}
      />
    </div>

    <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem]">
      <section id="run-history" aria-label="Run history" class="min-w-0 space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="text-[13px] font-semibold text-fg">Runs</h2>
          <p class="text-xs text-muted">
            Redacted inspection · showing {length(@history)} of {@selected.run_count}
          </p>
        </div>
        <.empty_state
          :if={@history == []}
          icon="history"
          title="No recorded runs"
          description="This session has no durable run history yet."
        />
        <article
          :for={{run, index} <- Enum.with_index(@history, 1)}
          id={"run-#{dom_id(run.run_id)}"}
          class="card"
        >
          <header class="card-header flex-wrap gap-y-1.5">
            <div class="flex min-w-0 items-center gap-2">
              <.status_dot tone={run_tone(run.ok)} />
              <span class="whitespace-nowrap text-[13px] font-semibold text-fg">Run {index}</span>
              <time
                class="whitespace-nowrap text-xs text-muted"
                title={format_time(run.started_at_ms)}
              >
                {relative_time(run.started_at_ms)}
              </time>
            </div>
            <div class="flex shrink-0 flex-wrap items-center gap-1.5">
              <.badge :if={run.engine}>{run.engine}</.badge>
              <.badge :if={is_integer(run.duration_ms)} icon="clock">{duration(run.duration_ms)}</.badge>
              <.badge tone={run_tone(run.ok)}>{run_status_label(run.ok)}</.badge>
            </div>
          </header>
          <div class="card-body space-y-3">
            <div>
              <h3 class="mb-1 text-2xs font-semibold uppercase tracking-wide text-subtle">Prompt</h3>
              <p class="whitespace-pre-wrap break-words text-[13px] text-fg" phx-no-format>{run.prompt || "Not recorded."}</p>
            </div>
            <div :if={run.tools != []}>
              <h3 class="mb-1 text-2xs font-semibold uppercase tracking-wide text-subtle">
                Tool activity ({length(run.tools)})
              </h3>
              <ul class="divide-y divide-line rounded-lg border border-line">
                <li :for={{tool, tool_index} <- Enum.with_index(run.tools)}>
                  <details id={"tool-#{dom_id(run.run_id)}-#{tool_index}"} class="group">
                    <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2 text-[13px] hover:bg-surface-2/60">
                      <.icon
                        name="chevron-right"
                        class="h-3.5 w-3.5 text-subtle transition-transform group-open:rotate-90"
                      />
                      <.icon name={tool_icon(tool.kind)} class="h-3.5 w-3.5 text-muted" />
                      <span class="min-w-0 flex-1 truncate text-fg">
                        {tool.title || tool.kind || "Tool call"}
                      </span>
                      <.badge tone={tool_tone(tool)}>{tool_status(tool)}</.badge>
                    </summary>
                    <div class="space-y-2 px-3 pb-3">
                      <.code_block
                        :if={tool.detail}
                        id={"tool-detail-#{dom_id(run.run_id)}-#{tool_index}"}
                        code={tool.detail}
                        language="json"
                        max_height="max-h-72"
                      />
                      <p
                        :if={tool.message}
                        class="whitespace-pre-wrap break-words text-xs text-muted"
                        phx-no-format
                      >{tool.message}</p>
                    </div>
                  </details>
                </li>
              </ul>
            </div>
            <div>
              <h3 class="mb-1 text-2xs font-semibold uppercase tracking-wide text-subtle">Answer</h3>
              <div :if={run.answer} class="md">{LemonWeb.Markdown.to_html(run.answer)}</div>
              <p :if={!run.answer} class="text-[13px] text-muted">Not recorded.</p>
            </div>
            <.callout :if={run.error} tone="danger" title="Run error">
              <span class="whitespace-pre-wrap break-words font-mono text-xs">{run.error}</span>
            </.callout>
          </div>
        </article>
      </section>

      <aside class="space-y-3" aria-label="Session details">
        <.card>
          <:header>Details</:header>
          <.key_value>
            <:item label="Agent">{@selected.agent_id || "—"}</:item>
            <:item label="Origin">{@selected.origin || "—"}</:item>
            <:item label="Model">
              <span class="font-mono text-xs">{detail_model(@detail_meta, @selected)}</span>
            </:item>
            <:item :if={@detail_meta && @detail_meta.thinking} label="Thinking">
              {@detail_meta.thinking}
            </:item>
            <:item label="Runs">{@selected.run_count}</:item>
            <:item label="Created">
              <time title={format_time(@selected.created_at_ms)}>
                {relative_time(@selected.created_at_ms)}
              </time>
            </:item>
            <:item label="Last activity">
              <time title={format_time(@selected.updated_at_ms)}>
                {relative_time(@selected.updated_at_ms)}
              </time>
            </:item>
          </.key_value>
          <:footer>
            <div class="flex items-center gap-2">
              <code id="detail-session-key" class="min-w-0 flex-1 truncate font-mono text-2xs text-muted">
                {@selected.session_key}
              </code>
              <button
                type="button"
                id="copy-session-key"
                class="btn btn-ghost btn-icon btn-sm"
                phx-hook="CopyButton"
                data-copy-target="detail-session-key"
                aria-label="Copy session key"
              >
                <.icon name="copy" class="h-3.5 w-3.5" />
              </button>
            </div>
          </:footer>
        </.card>
        <.card>
          <:header>Export</:header>
          <p class="mb-3 text-xs text-muted">
            Always redacted: credentials, raw events, and private paths are omitted.
          </p>
          <div class="flex flex-wrap gap-2">
            <.button
              size="sm"
              icon="download"
              href={~p"/sessions/#{@selected.session_key}/export/json"}
              download
            >
              JSON
            </.button>
            <.button
              size="sm"
              icon="file-text"
              href={~p"/sessions/#{@selected.session_key}/export/markdown"}
              download
            >
              Markdown
            </.button>
          </div>
        </.card>
        <.card class="border-danger/30">
          <:header><span class="text-danger">Danger zone</span></:header>
          <p class="mb-3 text-xs text-muted">
            Deleting removes the run history, chat state, policy, and metadata for this session.
          </p>
          <.button
            size="sm"
            variant="danger-soft"
            icon="trash"
            phx-click="preview-delete"
            phx-value-key={@selected.session_key}
            mutation
          >
            Delete session…
          </.button>
        </.card>
      </aside>
    </div>
    """
  end

  defp working_now(assigns) do
    ~H"""
    <section id="active-work" aria-labelledby="active-work-title" class="mb-4">
      <div class="mb-2 flex items-center gap-2">
        <h2 id="active-work-title" class="text-[13px] font-semibold text-fg">Working now</h2>
        <.badge :if={@active_runs_available?} tone={if @active_runs == [], do: "neutral", else: "success"}>
          {length(@active_runs)} active
        </.badge>
        <.badge :if={!@active_runs_available?} tone="warning" icon="alert-triangle">Unavailable</.badge>
      </div>
      <.callout :if={!@active_runs_available?} tone="warning" class="mb-2">
        Live run status is unavailable. Last known work is preserved.
      </.callout>
      <p :if={@active_runs_available? and @active_runs == []} class="text-xs text-muted">
        No agents are running right now.
      </p>
      <ul :if={@active_runs != []} class="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
        <li
          :for={run <- @active_runs}
          id={"active-#{dom_id(run.run_id)}"}
          class="card flex min-w-0 items-center gap-3 px-3 py-2"
        >
          <.status_dot tone="success" pulse={@active_runs_available?} />
          <div class="min-w-0 flex-1">
            <p class="truncate text-[13px] font-medium text-fg">
              {active_title(run, @sessions)}
            </p>
            <p class="truncate text-2xs text-muted">
              {run.agent_id} · started {relative_time(run.started_at_ms)} ·
              <span class="font-mono">{run.run_id}</span>
            </p>
          </div>
          <.button
            size="sm"
            variant="ghost"
            icon="message-square"
            navigate={~p"/chat/#{run.session_key}"}
            aria-label="Follow live transcript"
          >
            <span class="hidden sm:inline">Follow</span>
          </.button>
        </li>
      </ul>
    </section>
    """
  end

  defp dialogs(assigns) do
    ~H"""
    <.confirm_dialog
      :if={@delete_preview}
      id="delete-dialog"
      title="Delete this session?"
      description="This permanently removes its history. It cannot be undone."
      confirm_label="Delete session"
      confirm_event="confirm-delete"
      cancel_event="cancel-delete"
    >
      <div class="space-y-3">
        <.key_value>
          <:item label="Title">{@delete_preview.title || "Untitled session"}</:item>
          <:item label="Session key">
            <code class="break-all font-mono text-xs">{@delete_preview.session_key}</code>
          </:item>
          <:item label="Runs">{@delete_preview.run_count}</:item>
          <:item label="Last activity">{relative_time(@delete_preview.updated_at_ms)}</:item>
        </.key_value>
        <.callout :if={@delete_preview.pinned} tone="warning">This session is pinned.</.callout>
        <.callout :if={@delete_preview.running} tone="warning">
          This session is running; deletion will be refused until it stops.
        </.callout>
        <p class="text-xs text-muted">
          The deletion is bound to this exact session. If it changes before you confirm, nothing is deleted.
        </p>
      </div>
    </.confirm_dialog>

    <.modal
      :if={@prune}
      id="prune-dialog"
      show
      size="lg"
      title="Prune old sessions"
      description="Preview the exact sessions that match, then confirm. Nothing is deleted until you confirm."
      on_cancel={JS.push("prune-close")}
    >
      <form id="prune-form" phx-change="prune-edit" phx-submit="prune-preview" class="space-y-3">
        <div class="flex flex-wrap items-end gap-3">
          <.input
            id="prune_days"
            name="prune[days]"
            type="number"
            label="Last activity older than (days)"
            value={@prune.days}
            min="1"
            max="3650"
            required
            class="w-56"
          />
          <.button type="submit" icon="eye">Preview</.button>
        </div>
        <div class="grid gap-2 sm:grid-cols-2">
          <.input
            id="prune_archived_only"
            name="prune[archived_only]"
            type="checkbox"
            value={@prune.archived_only}
            label="Archived sessions only"
            hint="Recommended. Active sessions are never candidates."
          />
          <.input
            id="prune_include_pinned"
            name="prune[include_pinned]"
            type="checkbox"
            value={@prune.include_pinned}
            label="Include pinned sessions"
            hint="Pinned sessions are excluded by default."
          />
        </div>
      </form>

      <.callout :if={@prune.error} tone="danger" class="mt-3">{@prune.error}</.callout>

      <div :if={@prune.preview} id="prune-preview" class="mt-4">
        <p class="mb-2 text-[13px] text-fg">
          <strong>{@prune.preview.count}</strong>
          {if @prune.preview.count == 1, do: "exact candidate", else: "exact candidates"}
          <span class="text-muted">
            · {if @prune.preview.archived_only, do: "archived only", else: "archived and active"} · {if @prune.preview.include_pinned,
              do: "pinned included",
              else: "pinned excluded"}
          </span>
        </p>
        <p :if={@prune.preview.count == 0} class="text-xs text-muted">
          No sessions match this policy.
        </p>
        <ul
          :if={@prune.preview.count > 0}
          class="max-h-60 divide-y divide-line overflow-y-auto rounded-lg border border-line scroll-thin"
        >
          <li :for={key <- @prune.preview.keys} class="px-3 py-1.5">
            <p :if={title_for(key, @sessions)} class="truncate text-[13px] text-fg">
              {title_for(key, @sessions)}
            </p>
            <p class="break-all font-mono text-2xs text-muted">{key}</p>
          </li>
        </ul>
      </div>

      <:footer>
        <.button phx-click="prune-close">Cancel</.button>
        <.button
          id="prune-confirm"
          variant="danger"
          icon="trash"
          phx-click="prune-confirm"
          disabled={is_nil(@prune.preview) or @prune.preview.count == 0}
          mutation
        >
          {prune_confirm_label(@prune.preview)}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp rename_form(assigns) do
    ~H"""
    <form id={@id} phx-submit="rename" class="flex min-w-0 items-start gap-1.5">
      <input type="hidden" name="key" value={@key} />
      <div class="min-w-0 flex-1">
        <label for={"#{@id}-title"} class="sr-only">Session title</label>
        <input
          id={"#{@id}-title"}
          name="title"
          type="text"
          value={@title}
          maxlength="160"
          placeholder="Untitled session"
          autocomplete="off"
          phx-mounted={JS.focus()}
          phx-keydown="cancel-rename"
          phx-key="escape"
          class="input h-7 text-[13px]"
          aria-invalid={@error && "true"}
        />
        <p :if={@error} class="field-error">{@error}</p>
      </div>
      <.button type="submit" size="sm" variant="primary" icon="check" icon_only mutation aria-label="Save title" />
      <.button size="sm" variant="ghost" icon="x" icon_only phx-click="cancel-rename" aria-label="Cancel rename" />
    </form>
    """
  end

  defp row_menu(assigns) do
    ~H"""
    <.dropdown id={@id} label={"Actions for #{display_title(@session)}"}>
      <:trigger>
        <span class="btn btn-ghost btn-sm btn-icon">
          <.icon name="more-horizontal" class="h-3.5 w-3.5" />
        </span>
      </:trigger>
      <.link role="menuitem" class="menu-item" patch={~p"/sessions/#{@session.session_key}"}>
        <.icon name="eye" class="h-3.5 w-3.5" /> Inspect
      </.link>
      <button
        type="button"
        role="menuitem"
        class="menu-item"
        phx-click="start-rename"
        phx-value-key={@session.session_key}
      >
        <.icon name="pencil" class="h-3.5 w-3.5" /> Rename
      </button>
      <button
        type="button"
        role="menuitem"
        class="menu-item"
        phx-click="set-flag"
        phx-value-key={@session.session_key}
        phx-value-field="pinned"
        phx-value-value={to_string(!@session.pinned)}
        data-requires-connection
      >
        <.icon name="pin" class="h-3.5 w-3.5" /> {if @session.pinned, do: "Unpin", else: "Pin"}
      </button>
      <button
        type="button"
        role="menuitem"
        class="menu-item"
        phx-click="set-flag"
        phx-value-key={@session.session_key}
        phx-value-field="archived"
        phx-value-value={to_string(!@session.archived)}
        data-requires-connection
      >
        <.icon name="archive" class="h-3.5 w-3.5" />
        {if @session.archived, do: "Unarchive", else: "Archive"}
      </button>
      <button
        type="button"
        role="menuitem"
        class="menu-item"
        phx-click="fork"
        phx-value-key={@session.session_key}
        disabled={@forking != nil}
        data-requires-connection
      >
        <.icon name="git-fork" class="h-3.5 w-3.5" /> Fork into new session
      </button>
      <a
        role="menuitem"
        class="menu-item"
        href={~p"/sessions/#{@session.session_key}/export/json"}
        download
      >
        <.icon name="download" class="h-3.5 w-3.5" /> Export JSON
      </a>
      <a
        role="menuitem"
        class="menu-item"
        href={~p"/sessions/#{@session.session_key}/export/markdown"}
        download
      >
        <.icon name="file-text" class="h-3.5 w-3.5" /> Export Markdown
      </a>
      <div class="my-1 border-t border-line" role="separator"></div>
      <button
        type="button"
        role="menuitem"
        class="menu-item text-danger"
        phx-click="preview-delete"
        phx-value-key={@session.session_key}
        data-requires-connection
      >
        <.icon name="trash" class="h-3.5 w-3.5" /> Delete…
      </button>
    </.dropdown>
    """
  end

  defp sort_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="sort"
      phx-value-by={@by}
      class="inline-flex items-center gap-1 uppercase tracking-wide hover:text-fg"
    >
      {@label}
      <.icon
        :if={@filters.sort == @by}
        name={if @filters.dir == "asc", do: "chevron-up", else: "chevron-down"}
        class="h-3 w-3"
      />
    </button>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @running -> %>
        <.badge tone="success"><.status_dot tone="success" pulse /> Running</.badge>
      <% @archived -> %>
        <.badge icon="archive">Archived</.badge>
      <% true -> %>
        <span class="text-xs text-subtle">Idle</span>
    <% end %>
    """
  end

  # ── Data loading ─────────────────────────────────────────────────────────

  defp refresh_on_tick(%{assigns: %{live_action: :show}} = socket, slow?) do
    running? = MapSet.member?(socket.assigns.running, socket.assigns.session_key)
    if running? or slow?, do: load_selected(socket, false), else: socket
  end

  defp refresh_on_tick(socket, slow?) do
    # A text query searches run history, so it refreshes on the slow cadence.
    socket =
      if socket.assigns.filters.q == "" or slow?, do: refresh_sessions(socket), else: socket

    if slow?, do: refresh_stats(socket), else: socket
  end

  defp refresh_current(%{assigns: %{live_action: :show}} = socket, meta?),
    do: load_selected(socket, meta?)

  defp refresh_current(socket, _meta?), do: socket |> refresh_sessions() |> refresh_stats()

  defp after_mutation(socket) do
    socket
    |> assign(:prune, clear_prune_preview(socket.assigns.prune))
    |> refresh_current(false)
  end

  defp clear_prune_preview(nil), do: nil
  defp clear_prune_preview(prune), do: %{prune | preview: nil}

  defp refresh_sessions(socket) do
    filters = socket.assigns.filters

    params =
      %{"limit" => @max_sessions}
      |> put_present("query", filters.q)
      |> put_present("agentId", filters.agent)
      |> Map.merge(
        case filters.status do
          "active" -> %{"archived" => false}
          "archived" -> %{"archived" => true}
          _ -> %{}
        end
      )
      |> Map.merge(if filters.pinned, do: %{"pinned" => true}, else: %{})

    case Rpc.call("sessions.list", params) do
      {:ok, %{"sessions" => rows} = payload} when is_list(rows) ->
        sessions = rows |> Enum.flat_map(&project_wire/1) |> sort_rows(filters)

        assign(socket,
          sessions: sessions,
          matched: int(payload["total"]) || length(sessions),
          store_total: int(get_in(payload, ["summary", "storeTotal"])) || length(sessions),
          sessions_available?: true
        )

      _ ->
        assign(socket, :sessions_available?, false)
    end
  end

  defp refresh_stats(socket) do
    case Rpc.call("sessions.stats", %{"groupLimit" => @max_agent_options}) do
      {:ok, %{"totals" => totals} = payload} ->
        agents =
          payload
          |> get_in(["breakdowns", "agents", "entries"])
          |> List.wrap()
          |> Enum.flat_map(fn
            %{"value" => value, "count" => count} when is_binary(value) and value != "unknown" ->
              label = ManagementText.text(value, max_bytes: 64)
              [{"#{label} (#{count})", value}]

            _ ->
              []
          end)

        assign(socket,
          stats: %{
            active: int(totals["activeSessions"]) || 0,
            archived: int(totals["archivedSessions"]) || 0,
            total: int(totals["storeSessions"]) || 0
          },
          agent_options: agents
        )

      _ ->
        socket
    end
  end

  defp load_selected(%{assigns: %{session_key: nil}} = socket, _meta?) do
    assign(socket, selected: nil, history: [], detail_state: :not_found)
  end

  defp load_selected(socket, meta?) do
    key = socket.assigns.session_key

    case SessionLifecycle.get(key) do
      nil ->
        assign(socket, selected: nil, history: [], detail_state: :not_found)

      row ->
        history =
          key
          |> SessionLifecycle.history(limit: @max_history, redact: true)
          |> ManagementText.term()
          |> Enum.map(&project_run/1)

        socket
        |> assign(selected: project_lifecycle(row), history: history, detail_state: :ok)
        |> assign(:page_heading, "Session")
        |> then(&if(meta?, do: assign(&1, :detail_meta, detail_meta(key)), else: &1))
    end
  rescue
    _ -> assign(socket, :detail_state, if(socket.assigns.selected, do: :ok, else: :unavailable))
  catch
    :exit, _ ->
      assign(socket, :detail_state, if(socket.assigns.selected, do: :ok, else: :unavailable))
  end

  defp detail_meta(key) do
    case Rpc.call("session.detail", %{
           "sessionKey" => key,
           "limit" => 1,
           "historyLimit" => 1,
           "eventLimit" => 1,
           "toolCallLimit" => 1
         }) do
      {:ok, %{"session" => session}} when is_map(session) ->
        %{
          model: safe_model(session["model"]),
          source: safe_token(session["modelSource"]),
          thinking: safe_token(session["thinkingLevel"])
        }

      _ ->
        nil
    end
  end

  defp refresh_active_runs(socket) do
    case fetch_active_runs() do
      {:ok, runs} ->
        assign(socket,
          active_runs: runs,
          running: MapSet.new(runs, & &1.session_key),
          active_runs_available?: true
        )

      :error ->
        assign(socket, :active_runs_available?, false)
    end
  end

  defp fetch_active_runs do
    result =
      case Application.get_env(:lemon_web, :active_runs_fun) do
        fun when is_function(fun, 0) ->
          fun.()

        _ ->
          LemonRouter.active_runs()
      end

    case result do
      {:ok, runs} when is_list(runs) ->
        {:ok,
         runs
         |> Enum.filter(&valid_run?/1)
         |> Enum.sort_by(&(&1[:started_at_ms] || 0), :desc)
         |> Enum.take(@max_active_runs)
         |> Enum.map(fn run ->
           %{
             run_id: run.run_id,
             session_key: run.session_key,
             agent_id: SessionKey.agent_id(run.session_key) || "default",
             started_at_ms: int(run[:started_at_ms])
           }
         end)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp valid_run?(run) do
    is_map(run) and is_binary(run[:run_id]) and
      Regex.match?(~r/\Arun_[a-zA-Z0-9_-]+\z/, run.run_id) and
      is_binary(run[:session_key]) and SessionKey.valid?(run.session_key)
  end

  # Only an available lookup without the key means idle; failures are unknown.
  defp idle_state(key) do
    if is_function(Application.get_env(:lemon_web, :active_runs_fun), 0) do
      case fetch_active_runs() do
        {:ok, runs} -> if Enum.any?(runs, &(&1.session_key == key)), do: :running, else: :idle
        :error -> :unknown
      end
    else
      case LemonRouter.run_presence(%{session_key: key}) do
        {:ok, %{presence: %{idle: true}}} -> :idle
        {:ok, %{presence: %{unknown: 0}}} -> :running
        _ -> :unknown
      end
    end
  end

  defp prune_selection(socket) do
    visible = MapSet.new(socket.assigns.sessions, & &1.session_key)
    assign(socket, :selected_keys, MapSet.intersection(socket.assigns.selected_keys, visible))
  end

  # ── Projections (allowlists) ─────────────────────────────────────────────

  defp project_wire(%{"sessionKey" => key} = row) when is_binary(key) and key != "" do
    [
      %{
        session_key: key,
        agent_id: label(row["agentId"]),
        origin: label(row["origin"]),
        created_at_ms: int(row["createdAtMs"]),
        updated_at_ms: int(row["updatedAtMs"]),
        run_count: int(row["runCount"]) || 0,
        title: title(row["title"]),
        pinned: row["pinned"] == true,
        archived: row["archived"] == true,
        model: safe_model(row["model"])
      }
    ]
  end

  defp project_wire(_row), do: []

  defp project_lifecycle(row) do
    %{
      session_key: row.session_key,
      agent_id: label(row.agent_id),
      origin: label(row.origin && to_string(row.origin)),
      created_at_ms: int(row.created_at_ms),
      updated_at_ms: int(row.updated_at_ms),
      run_count: int(row.run_count) || 0,
      title: title(row.title),
      pinned: row.pinned == true,
      archived: row.archived == true,
      model: nil
    }
  end

  defp project_run(run) when is_map(run) do
    %{
      run_id: to_string(run[:run_id] || "run"),
      started_at_ms: int(run[:started_at_ms]),
      engine: label(run[:engine]),
      prompt: text_or_nil(run[:prompt]),
      answer: text_or_nil(run[:answer]),
      ok: run[:ok],
      error: run[:error] && format_detail(run[:error]),
      duration_ms: int(run[:duration_ms]),
      tools: consolidate_tools(List.wrap(run[:tools]))
    }
  end

  # History keeps every phase of a tool call; show one row per invocation
  # with its most advanced phase.
  defp consolidate_tools(tools) do
    tools
    |> Enum.filter(&is_map/1)
    |> Enum.with_index()
    |> Enum.reduce({[], %{}}, fn {tool, index}, {order, by_id} ->
      id = tool[:action_id] || tool[:id] || {:index, index}

      case by_id do
        %{^id => current} ->
          {order, Map.put(by_id, id, merge_tool(current, tool))}

        _ ->
          {[id | order], Map.put(by_id, id, tool)}
      end
    end)
    |> then(fn {order, by_id} -> order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_id, &1)) end)
    |> Enum.take(100)
    |> Enum.map(fn tool ->
      %{
        title: text_or_nil(tool[:title]),
        kind: label(tool[:kind]),
        phase: label(tool[:phase]),
        ok: tool[:ok],
        detail: tool[:detail] && format_detail(tool[:detail]),
        message: text_or_nil(tool[:message])
      }
    end)
  end

  defp merge_tool(current, next) do
    if phase_rank(next[:phase]) >= phase_rank(current[:phase]) do
      next
      |> Map.put(:detail, next[:detail] || current[:detail])
      |> Map.put(:title, next[:title] || current[:title])
    else
      Map.put(current, :detail, current[:detail] || next[:detail])
    end
  end

  defp phase_rank(phase), do: Map.get(@phase_rank, to_string(phase), 0)

  defp project_prune_preview(%{"confirmToken" => token} = payload) when is_binary(token) do
    keys = payload["candidateSessionKeys"] |> List.wrap() |> Enum.filter(&is_binary/1)

    {:ok,
     %{
       token: token,
       older_than_ms: payload["olderThanMs"],
       archived_only: payload["archivedOnly"] != false,
       include_pinned: payload["includePinned"] == true,
       keys: keys,
       count: int(payload["candidateCount"]) || length(keys)
     }}
  end

  defp project_prune_preview(_payload),
    do: {:error, %{code: :internal_error, message: "The prune preview was incomplete."}}

  defp fingerprint(row) do
    {row.updated_at_ms, row.run_count, row.metadata_updated_at_ms, row.pinned, row.archived,
     row.title}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  # ── Params ───────────────────────────────────────────────────────────────

  defp default_filters,
    do: %{q: "", status: "active", pinned: false, agent: nil, sort: "activity", dir: "desc"}

  defp parse_filters(params) do
    sort = if params["sort"] in @sorts, do: params["sort"], else: "activity"

    %{
      q: bounded(params["q"], @max_query_bytes),
      status: if(params["status"] in @statuses, do: params["status"], else: "active"),
      pinned: params["pinned"] == "1",
      agent: normalize_agent(params["agent"]),
      sort: sort,
      dir: if(params["dir"] in ~w(asc desc), do: params["dir"], else: default_dir(sort))
    }
  end

  defp index_path(filters) do
    query =
      [
        q: filters.q,
        status: filters.status != "active" && filters.status,
        pinned: filters.pinned && "1",
        agent: filters.agent,
        sort: filters.sort != "activity" && filters.sort,
        dir: filters.dir != default_dir(filters.sort) && filters.dir
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false, ""] end)

    if query == [], do: ~p"/sessions", else: ~p"/sessions?#{query}"
  end

  defp default_dir(sort) when sort in ~w(title agent), do: "asc"
  defp default_dir(_sort), do: "desc"

  defp filters_active?(filters),
    do: filters.q != "" or filters.pinned or filters.agent != nil

  defp sort_rows(rows, %{sort: "activity", dir: "desc"}) do
    Enum.sort_by(rows, &{not &1.pinned, -(&1.updated_at_ms || 0), &1.session_key})
  end

  defp sort_rows(rows, %{sort: sort, dir: dir}) do
    Enum.sort_by(rows, &sort_value(&1, sort), if(dir == "asc", do: :asc, else: :desc))
  end

  defp sort_value(row, "title"), do: String.downcase(row.title || "~" <> row.session_key)
  defp sort_value(row, "runs"), do: row.run_count
  defp sort_value(row, "created"), do: row.created_at_ms || 0
  defp sort_value(row, "agent"), do: row.agent_id || ""
  defp sort_value(row, _activity), do: row.updated_at_ms || 0

  defp aria_sort(%{sort: sort, dir: dir}, sort),
    do: if(dir == "asc", do: "ascending", else: "descending")

  defp aria_sort(_filters, _sort), do: nil

  defp prune_draft(prune, params) do
    %{
      prune
      | days: bounded(params["days"], 8),
        archived_only: params["archived_only"] != "false",
        include_pinned: params["include_pinned"] == "true",
        preview: nil
    }
  end

  defp parse_prune_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days in 1..3650 -> {:ok, days}
      _ -> {:error, :invalid_days}
    end
  end

  defp normalize_session_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      key -> key
    end
  end

  defp normalize_session_key(_value), do: nil

  defp normalize_agent(value) do
    case bounded(value, 128) do
      "" -> nil
      agent -> agent
    end
  end

  defp bounded(value, max) when is_binary(value) do
    trimmed = String.trim(value)

    if byte_size(trimmed) <= max,
      do: trimmed,
      else: trimmed |> binary_part(0, max) |> String.replace_invalid("")
  end

  defp bounded(_value, _max), do: ""

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ── Display helpers ──────────────────────────────────────────────────────

  defp title(value) when is_binary(value) and value != "",
    do: ManagementText.text(value, max_bytes: 200)

  defp title(_value), do: nil

  defp label(value) when is_binary(value) and value != "",
    do: ManagementText.text(value, max_bytes: 64)

  defp label(value) when is_atom(value) and not is_nil(value), do: label(Atom.to_string(value))
  defp label(_value), do: nil

  defp text_or_nil(value) when is_binary(value) and value != "", do: value
  defp text_or_nil(_value), do: nil

  defp safe_model(value) when is_binary(value) do
    if Regex.match?(@model_regex, value), do: value, else: nil
  end

  defp safe_model(_value), do: nil

  defp safe_token(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9_-]{1,32}\z/i, value), do: value, else: nil
  end

  defp safe_token(value) when is_atom(value) and not is_nil(value),
    do: safe_token(Atom.to_string(value))

  defp safe_token(_value), do: nil

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: nil

  defp display_title(%{title: title}) when is_binary(title), do: title
  defp display_title(_session), do: "Untitled session"

  defp title_for(key, sessions) do
    Enum.find_value(sessions, fn session -> session.session_key == key && session.title end)
  end

  defp active_title(run, sessions), do: title_for(run.session_key, sessions) || run.session_key

  defp detail_model(%{model: model} = meta, _selected) when is_binary(model) do
    if meta.source, do: "#{model} (#{meta.source})", else: model
  end

  defp detail_model(_meta, _selected), do: "default"

  defp all_selected?(sessions, selected),
    do: Enum.all?(sessions, &MapSet.member?(selected, &1.session_key))

  defp empty_title(_filters, false), do: "Sessions are unavailable"

  defp empty_title(filters, true) do
    if filters_active?(filters), do: "No sessions match", else: "No sessions here yet"
  end

  defp empty_description(filters) do
    cond do
      filters_active?(filters) -> "Try a different search or clear the filters."
      filters.status == "archived" -> "Archived sessions appear here."
      true -> "Start a conversation and it will show up here."
    end
  end

  defp prune_confirm_label(%{count: count}) when count > 0,
    do: "Delete #{plural(count, "session")}"

  defp prune_confirm_label(_preview), do: "Delete sessions"

  defp flag_notice("pinned", true), do: "Session pinned."
  defp flag_notice("pinned", false), do: "Session unpinned."
  defp flag_notice("archived", true), do: "Session archived."
  defp flag_notice("archived", false), do: "Session restored from archive."

  defp bulk_patch("pin"), do: {"pinned", true}
  defp bulk_patch("unpin"), do: {"pinned", false}
  defp bulk_patch("archive"), do: {"archived", true}
  defp bulk_patch("unarchive"), do: {"archived", false}

  defp bulk_label("pin"), do: "Pinned"
  defp bulk_label("unpin"), do: "Unpinned"
  defp bulk_label("archive"), do: "Archived"
  defp bulk_label("unarchive"), do: "Unarchived"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp run_tone(true), do: "success"
  defp run_tone(false), do: "danger"
  defp run_tone(_value), do: "neutral"

  defp run_status_label(true), do: "Succeeded"
  defp run_status_label(false), do: "Failed"
  defp run_status_label(_value), do: "Unknown"

  defp tool_status(%{ok: false}), do: "failed"
  defp tool_status(%{phase: phase}) when is_binary(phase), do: phase
  defp tool_status(_tool), do: "unknown"

  defp tool_tone(%{ok: false}), do: "danger"
  defp tool_tone(%{phase: "completed"}), do: "success"
  defp tool_tone(_tool), do: "neutral"

  defp tool_icon(kind) when kind in ["command", "shell", "bash"], do: "terminal"
  defp tool_icon(kind) when kind in ["file_change", "edit", "write", "patch"], do: "file-pen"
  defp tool_icon(kind) when kind in ["web_search", "websearch", "webfetch"], do: "globe"
  defp tool_icon(kind) when kind in ["subagent", "task", "agent"], do: "network"
  defp tool_icon(_kind), do: "wrench"

  defp format_time(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
      {:error, _reason} -> nil
    end
  end

  defp format_time(_value), do: nil

  defp format_detail(value) when is_binary(value), do: bound_text(value)

  defp format_detail(value) when is_map(value) or is_list(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> bound_text(encoded)
      {:error, _reason} -> bound_text(inspect(value, pretty: true, limit: 50))
    end
  end

  defp format_detail(value), do: bound_text(inspect(value, limit: 50))

  defp bound_text(text) when byte_size(text) <= @max_detail_bytes, do: text

  defp bound_text(text),
    do: (text |> binary_part(0, @max_detail_bytes) |> String.replace_invalid("")) <> "\n…"

  defp dom_id(value) do
    value
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end
end
