defmodule LemonWeb.ShellLive do
  @moduledoc """
  The sticky, app-wide productivity layer rendered once by the app layout
  (`live_render(@socket, LemonWeb.ShellLive, id: "lemon-shell", sticky: true)`):

    * **Command palette** (`mod+k`, `lemon:palette`): fuzzy navigation
      (`LemonWeb.Nav`), global and chat-workspace actions, sessions (recent
      first) and a global search mode (`Tab` or a leading `/`) across session
      content, memory and automation. Items run client-side (the `Shell` hook
      in `assets/js/shell.js`); the server ranks and fetches.
    * **Shortcut help** (`?`, `lemon:shortcuts`): every binding registered with
      `window.Lemon.Shortcuts`, grouped, plus palette keys.
    * **Notifications**: run completions (`run_lifecycle`) and approval requests (`exec_approvals`)
      become toasts, a bounded bell history and — when the tab is hidden and
      permission is granted — browser notifications. The session open in the
      foreground is never notified; subagent (`:sub:`) sessions are skipped;
      the browser's `lemon-notify` preferences gate toasts and alerts.

  Being sticky, the view survives live navigation; the hook reports the
  current location and visibility so foreground suppression stays accurate.
  """

  # No layout: the shell is rendered *by* the app layout. A sticky child joins
  # as its own root over the socket, so `use LemonWeb, :live_view` (which
  # sets the app layout) would recursively render the layout inside itself.
  use Phoenix.LiveView

  import LemonWeb.UI

  alias Phoenix.LiveView.JS

  alias LemonControlPlane.EventBridge
  alias LemonCore.{Bus, RunStore}
  alias LemonWeb.Rpc
  alias LemonWeb.ShellLive.Palette

  @max_notifications 20
  @max_toasts 3
  @max_tracked_runs 100
  @max_seen_runs 200
  @max_titles 200
  @max_shortcuts 120
  @run_toast_ms 8_000
  @min_search_chars 2
  @session_limit 6
  @search_limit 8

  @impl true
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign_new(:operator_access, fn -> nil end)
      |> assign(
        palette_open: false,
        palette_mode: :all,
        palette_query: "",
        palette_chat: false,
        palette_recent: [],
        palette_version: 0,
        palette_active: 0,
        sources: %{},
        location: %{path: "/", chat: nil, split: nil, visible: true},
        notifications: [],
        unread: 0,
        toasts: [],
        prefs: %{runs: true, approvals: true},
        permission: "default",
        panel_open: false,
        shortcuts_open: false,
        shortcuts: [],
        runs: %{},
        seen_runs: [],
        titles: %{}
      )

    if connected?(socket) do
      case LemonWeb.LiveAuth.on_mount(:require_operator, %{}, session, socket) do
        {:cont, socket} -> {:ok, subscribe(socket)}
        {:halt, socket} -> {:ok, socket}
      end
    else
      {:ok, socket}
    end
  end

  defp subscribe(socket) do
    Bus.subscribe(Bus.run_lifecycle_topic())
    Bus.subscribe("exec_approvals")
    send(self(), :seed_runs)
    socket
  end

  # ── Palette events ───────────────────────────────────────────────────────

  @impl true
  def handle_event("palette:open", params, socket) do
    socket =
      socket
      |> assign(
        palette_open: true,
        palette_mode: :all,
        palette_query: "",
        palette_chat: params["chat"] == true,
        palette_recent: List.wrap(params["recent"]),
        sources: %{}
      )
      |> put_location(params)
      |> refresh_palette()

    {:noreply, socket}
  end

  def handle_event("palette:active", %{"index" => index}, socket)
      when is_integer(index) and index >= 0 do
    {:noreply, assign(socket, palette_active: index)}
  end

  def handle_event("palette:close", _params, socket) do
    {:noreply, assign(socket, palette_open: false, sources: %{})}
  end

  def handle_event("palette:query", %{"q" => raw}, socket) do
    {mode, query} = Palette.parse_query(raw, socket.assigns.palette_mode)

    {:noreply,
     socket
     |> assign(palette_mode: mode, palette_query: query)
     |> refresh_palette()}
  end

  def handle_event("palette:mode", params, socket) do
    mode = if socket.assigns.palette_mode == :search, do: :all, else: :search
    {_mode, query} = Palette.parse_query(params["q"] || socket.assigns.palette_query, mode)

    {:noreply,
     socket
     |> assign(palette_mode: mode, palette_query: query)
     |> refresh_palette()}
  end

  # ── Location / shortcuts ────────────────────────────────────────────────

  def handle_event("location", params, socket) do
    {:noreply, put_location(socket, params)}
  end

  def handle_event("shortcuts:open", params, socket) do
    {:noreply,
     assign(socket,
       shortcuts_open: true,
       shortcuts: shortcut_groups(params["shortcuts"]),
       palette_open: false
     )}
  end

  def handle_event("shortcuts:close", _params, socket) do
    {:noreply, assign(socket, shortcuts_open: false)}
  end

  # ── Notifications ───────────────────────────────────────────────────────

  def handle_event("notify:init", params, socket) do
    {:noreply,
     assign(socket, prefs: prefs(params["prefs"]), permission: permission(params["permission"]))}
  end

  def handle_event("notify:prefs", params, socket) do
    {:noreply, assign(socket, prefs: prefs(params["prefs"]))}
  end

  def handle_event("notify:pref", %{"kind" => kind}, socket) when kind in ["runs", "approvals"] do
    key = String.to_existing_atom(kind)
    prefs = Map.update!(socket.assigns.prefs, key, &(!&1))

    {:noreply,
     socket
     |> assign(prefs: prefs)
     |> push_event("lemon:notify-prefs", %{runs: prefs.runs, approvals: prefs.approvals})}
  end

  def handle_event("notify:permission", params, socket) do
    {:noreply, assign(socket, permission: permission(params["permission"]))}
  end

  def handle_event("panel:toggle", _params, socket) do
    {:noreply, set_panel(socket, !socket.assigns.panel_open)}
  end

  def handle_event("panel:open", _params, socket), do: {:noreply, set_panel(socket, true)}
  def handle_event("panel:close", _params, socket), do: {:noreply, set_panel(socket, false)}

  def handle_event("notifications:clear", _params, socket) do
    {:noreply, assign(socket, notifications: [], unread: 0)}
  end

  def handle_event("toast:dismiss", %{"id" => id}, socket) do
    {:noreply, assign(socket, toasts: Enum.reject(socket.assigns.toasts, &(&1.id == id)))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The panel lists everything the toasts show (and they overlap on mobile).
  defp set_panel(socket, true), do: assign(socket, panel_open: true, unread: 0, toasts: [])
  defp set_panel(socket, false), do: assign(socket, panel_open: false)

  # ── Async palette sources ───────────────────────────────────────────────

  @impl true
  def handle_async(source, {:ok, {version, result}}, socket) do
    if version == socket.assigns.palette_version and socket.assigns.palette_open do
      {:noreply, assign(socket, sources: Map.put(socket.assigns.sources, source, result))}
    else
      {:noreply, socket}
    end
  end

  def handle_async(source, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       sources: Map.put(socket.assigns.sources, source, {:error, "Search is unavailable."})
     )}
  end

  # ── Bus / telemetry ─────────────────────────────────────────────────────

  @impl true
  def handle_info(:seed_runs, socket) do
    socket =
      case Rpc.call("runs.active.list", %{"limit" => 50}) do
        {:ok, %{"runs" => runs}} when is_list(runs) ->
          Enum.reduce(runs, socket, fn
            %{"runId" => id, "sessionKey" => key}, acc when is_binary(id) and is_binary(key) ->
              track_run(acc, id, key)

            _, acc ->
              acc
          end)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: :run_started, meta: %{run_id: id}} = event, socket) do
    case run_session_key(event, socket, id) do
      key when is_binary(key) -> {:noreply, track_run(socket, id, key)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(%LemonCore.Event{type: :run_failed, meta: %{run_id: id}} = event, socket) do
    {:noreply, finish_run(socket, event, id, %{status: :error, duration: nil})}
  end

  def handle_info(%LemonCore.Event{type: :run_completed, meta: %{run_id: id}} = event, socket) do
    case safe_project(event) do
      {"agent", payload} -> {:noreply, finish_run(socket, event, id, outcome(payload))}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(%LemonCore.Event{type: type} = event, socket)
      when type in [:approval_requested, :approval_resolved] do
    case safe_project(event) do
      {"exec.approval.requested", payload} ->
        {:noreply, approval_requested(socket, payload)}

      {"exec.approval.resolved", %{"approvalId" => id}} ->
        {:noreply,
         assign(socket, toasts: Enum.reject(socket.assigns.toasts, &(&1.id == "approval-#{id}")))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp finish_run(socket, event, id, outcome) do
    key = run_session_key(event, socket, id)

    if is_binary(key) and notifiable_session?(key) and id not in socket.assigns.seen_runs do
      complete_run(socket, id, key, outcome)
    else
      untrack_run(socket, id)
    end
  end

  defp run_session_key(event, socket, id) do
    event.meta[:session_key] || tracked_session(socket, id) ||
      case RunStore.fetch(id) do
        {:ok, %{summary: %{session_key: key}}} -> key
        _ -> nil
      end
  end

  defp tracked_session(socket, id) do
    case Map.get(socket.assigns.runs, id) do
      {key, _order} -> key
      nil -> nil
    end
  end

  defp safe_project(event) do
    EventBridge.project(event)
  rescue
    _ -> nil
  end

  # ── Run tracking ────────────────────────────────────────────────────────

  defp track_run(socket, id, key) do
    runs = socket.assigns.runs

    cond do
      Map.has_key?(runs, id) or id in socket.assigns.seen_runs ->
        socket

      not notifiable_session?(key) ->
        socket

      true ->
        runs = Map.put(runs, id, {key, System.unique_integer([:monotonic])})

        runs =
          if map_size(runs) > @max_tracked_runs do
            {oldest, _} = Enum.min_by(runs, fn {_id, {_key, order}} -> order end)
            Map.delete(runs, oldest)
          else
            runs
          end

        assign(socket, runs: runs)
    end
  end

  defp untrack_run(socket, id) do
    assign(socket, runs: Map.delete(socket.assigns.runs, id))
  end

  # Subagent and cron-owned sessions (`…:sub:<id>`) would flood the bell.
  defp notifiable_session?(key), do: not String.contains?(key, ":sub:")

  defp complete_run(socket, id, key, outcome) do
    socket =
      socket
      |> untrack_run(id)
      |> assign(seen_runs: Enum.take([id | socket.assigns.seen_runs], @max_seen_runs))

    {title, socket} = session_title(socket, key)

    {headline, tone, icon} =
      case outcome.status do
        :ok -> {"Run finished", "success", "check-circle"}
        :cancelled -> {"Run stopped", "neutral", "square"}
        :error -> {"Run failed", "danger", "alert-circle"}
      end

    notify(socket, %{
      id: "run-#{id}",
      kind: :runs,
      session_key: key,
      title: headline,
      body: Enum.join(Enum.filter([title, outcome.duration], &is_binary/1), " · "),
      tone: tone,
      icon: icon,
      href: Palette.chat_path(key),
      sticky: false
    })
  end

  defp outcome(payload) do
    status =
      cond do
        payload["cancelled"] == true -> :cancelled
        payload["ok"] == true -> :ok
        true -> :error
      end

    %{status: status, duration: run_duration(payload["durationMs"])}
  end

  defp run_duration(ms) when is_integer(ms) and ms > 0, do: "took " <> duration(ms)
  defp run_duration(_), do: nil

  defp approval_requested(socket, payload) do
    key = payload["sessionKey"]

    {title, socket} =
      if is_binary(key), do: session_title(socket, key), else: {nil, socket}

    tool = Palette.clean(payload["tool"])

    notify(socket, %{
      id: "approval-#{payload["approvalId"]}",
      kind: :approvals,
      session_key: key,
      title: if(tool, do: "Approval needed: #{tool}", else: "Approval needed"),
      body: title || "A run is waiting for your decision",
      tone: "warning",
      icon: "shield-alert",
      href: if(is_binary(key), do: Palette.chat_path(key)),
      sticky: true
    })
  end

  defp notify(socket, notification) do
    if foreground?(socket, notification.session_key) do
      socket
    else
      notification = Map.put(notification, :at_ms, System.system_time(:millisecond))

      socket =
        assign(socket,
          notifications:
            Enum.take(
              [
                notification
                | Enum.reject(socket.assigns.notifications, &(&1.id == notification.id))
              ],
              @max_notifications
            ),
          unread: if(socket.assigns.panel_open, do: 0, else: socket.assigns.unread + 1)
        )

      if Map.fetch!(socket.assigns.prefs, notification.kind) do
        socket
        |> assign(
          toasts:
            Enum.take(
              [notification | Enum.reject(socket.assigns.toasts, &(&1.id == notification.id))],
              @max_toasts
            )
        )
        |> push_event("lemon:notify", %{
          title: notification.title,
          body: notification.body,
          href: notification.href,
          tag: notification.id
        })
      else
        socket
      end
    end
  end

  @doc false
  # Foreground = the tab is visible and the session is open (main or split pane).
  def foreground?(%{assigns: %{location: location}}, key) when is_binary(key) do
    location.visible and key in [location.chat, location.split]
  end

  def foreground?(_socket, _key), do: false

  defp session_title(socket, key) do
    case Map.fetch(socket.assigns.titles, key) do
      {:ok, title} ->
        {title, socket}

      :error ->
        title =
          case Rpc.call("sessions.get", %{"sessionKey" => key}) do
            {:ok, %{"session" => session}} when is_map(session) ->
              Palette.clean(Map.get(session, :title) || Map.get(session, "title"))

            _ ->
              nil
          end

        title = title || "Untitled session"
        titles = socket.assigns.titles
        titles = if map_size(titles) >= @max_titles, do: %{}, else: titles
        {title, assign(socket, titles: Map.put(titles, key, title))}
    end
  end

  # ── Location ────────────────────────────────────────────────────────────

  defp put_location(socket, params) do
    case params do
      %{"path" => path} when is_binary(path) and byte_size(path) <= 4096 ->
        assign(socket, location: parse_location(path, params["visible"] != false))

      _ ->
        socket
    end
  end

  @doc false
  def parse_location(path, visible) do
    uri = URI.parse(path)

    chat =
      case String.split(uri.path || "/", "/", trim: true) do
        ["chat", key | _] -> URI.decode(key)
        _ -> nil
      end

    split =
      case chat && uri.query && URI.decode_query(uri.query) do
        %{"split" => key} when is_binary(key) and key != "" -> key
        _ -> nil
      end

    %{path: uri.path || "/", chat: chat, split: split, visible: visible}
  rescue
    _ -> %{path: "/", chat: nil, split: nil, visible: visible}
  end

  defp prefs(%{} = prefs) do
    %{runs: Map.get(prefs, "runs") != false, approvals: Map.get(prefs, "approvals") != false}
  end

  defp prefs(_), do: %{runs: true, approvals: true}

  defp permission(value) when value in ["default", "granted", "denied", "unsupported"], do: value
  defp permission(_), do: "default"

  # ── Palette results ─────────────────────────────────────────────────────

  defp refresh_palette(%{assigns: %{palette_open: false}} = socket), do: socket

  defp refresh_palette(socket) do
    version = socket.assigns.palette_version + 1
    socket = assign(socket, palette_version: version, palette_active: 0, sources: %{})
    query = socket.assigns.palette_query

    case socket.assigns.palette_mode do
      :all ->
        params =
          if query == "",
            do: %{"limit" => @session_limit, "archived" => false},
            else: %{"limit" => @session_limit, "query" => query}

        start_source(socket, :sessions, version, fn -> sessions_source(params) end)

      :search when byte_size(query) < @min_search_chars ->
        socket

      :search ->
        socket
        |> start_source(:sessions, version, fn ->
          sessions_source(%{"limit" => @search_limit, "query" => query})
        end)
        |> start_source(:memory, version, fn -> memory_source(query) end)
        |> start_source(:automation, version, fn -> automation_source(query) end)
    end
  end

  defp start_source(socket, name, version, fun) do
    socket
    |> assign(sources: Map.put(socket.assigns.sources, name, :loading))
    |> start_async(name, fn -> {version, fun.()} end)
  end

  defp sessions_source(params) do
    case Rpc.call("sessions.list", params) do
      {:ok, %{"sessions" => rows}} when is_list(rows) -> {:ok, rows}
      {:ok, _} -> {:error, "Sessions are unavailable."}
      {:error, error} -> {:error, Rpc.message(error)}
    end
  end

  defp memory_source(query) do
    case memory_list(%{"query" => query, "limit" => @search_limit}) do
      {:ok, %{items: items}} when is_list(items) ->
        {:ok, Enum.flat_map(items, &List.wrap(Palette.memory_item(&1, query)))}

      _ ->
        {:error, "Memory search is unavailable."}
    end
  end

  defp memory_list(filters) do
    case Application.get_env(:lemon_web, :memory_lifecycle_fun) do
      fun when is_function(fun, 2) -> fun.(:list, [filters])
      _ -> LemonMemory.Lifecycle.list(filters)
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  defp automation_source(query) do
    case Rpc.call("cron.list", %{}) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) ->
        items =
          jobs
          |> Enum.flat_map(&List.wrap(Palette.cron_item(&1)))
          |> Palette.rank(query)
          |> Enum.take(@search_limit)

        {:ok, items}

      {:ok, _} ->
        {:error, "Automation is unavailable."}

      {:error, error} ->
        {:error, Rpc.message(error)}
    end
  end

  @doc false
  # Grouped palette results: `[%{id, label, items, state}]` where `state` is
  # `:ok | :loading | {:error, msg}`. Items are numbered at render time.
  def palette_groups(assigns) do
    %{palette_mode: mode, palette_query: query, sources: sources} = assigns
    current_chat = assigns.location.chat
    opts = [current_chat: current_chat]

    case mode do
      :all ->
        chat = if assigns.palette_chat, do: Palette.chat_items(), else: []

        actions =
          chat ++
            Palette.action_items(
              chat: assigns.palette_chat,
              operator_access: assigns.operator_access
            )

        nav = Palette.nav_items()
        sessions = source_items(sources[:sessions], &Palette.session_item(&1, opts))

        if query == "" do
          recent = Palette.resolve_recent(assigns.palette_recent, actions ++ nav, opts)

          [
            group("recent", "Recent", recent, :ok),
            group("sessions", "Sessions", sessions, source_state(sources[:sessions])),
            group("actions", "Actions", actions, :ok),
            group("nav", "Go to", nav, :ok)
          ]
        else
          [
            group("nav", "Go to", Palette.rank(nav, query), :ok),
            group("actions", "Actions", Palette.rank(actions, query), :ok),
            group("sessions", "Sessions", sessions, source_state(sources[:sessions]))
          ]
        end
        |> drop_empty()

      :search ->
        if byte_size(query) < @min_search_chars do
          []
        else
          [
            group(
              "sessions",
              "Sessions",
              source_items(sources[:sessions], &Palette.session_item(&1, opts)),
              source_state(sources[:sessions])
            ),
            group(
              "memory",
              "Memory",
              source_items(sources[:memory], & &1),
              source_state(sources[:memory])
            ),
            group(
              "automation",
              "Automation",
              source_items(sources[:automation], & &1),
              source_state(sources[:automation])
            )
          ]
          |> drop_empty()
        end
    end
  end

  defp group(id, label, items, state), do: %{id: id, label: label, items: items, state: state}

  defp drop_empty(groups), do: Enum.reject(groups, &(&1.items == [] and &1.state == :ok))

  defp source_items({:ok, rows}, fun), do: Enum.flat_map(rows, &List.wrap(fun.(&1)))
  defp source_items(_source, _fun), do: []

  defp source_state(:loading), do: :loading
  defp source_state({:error, message}), do: {:error, message}
  defp source_state(_), do: :ok

  defp numbered(groups) do
    {groups, _} =
      Enum.map_reduce(groups, 0, fn group, index ->
        items = Enum.with_index(group.items, index)
        {%{group | items: items}, index + length(group.items)}
      end)

    groups
  end

  defp loading?(sources), do: Enum.any?(sources, fn {_name, state} -> state == :loading end)

  # ── Shortcut help ───────────────────────────────────────────────────────

  @group_order ["General", "Navigation", "Chat", "Composer"]

  @palette_keys [
    %{keys: "up", description: "Previous result"},
    %{keys: "down", description: "Next result"},
    %{keys: "enter", description: "Open"},
    %{keys: "mod+enter", description: "Open session in split view (from a chat)"},
    %{keys: "tab", description: "Toggle search everywhere (or type /)"},
    %{keys: "esc", description: "Close"}
  ]

  @doc false
  # Client-registered shortcuts, sanitized, bounded and grouped.
  def shortcut_groups(list) when is_list(list) do
    list
    |> Enum.take(@max_shortcuts)
    |> Enum.flat_map(fn
      %{"keys" => keys, "description" => description} = entry
      when is_binary(keys) and is_binary(description) ->
        keys = keys |> String.trim() |> String.slice(0, 40)
        description = Palette.clean(description)
        group = Palette.clean(entry["group"]) || "General"

        if keys != "" and description,
          do: [%{keys: keys, description: description, group: group}],
          else: []

      _ ->
        []
    end)
    |> Enum.uniq_by(&{&1.keys, &1.description})
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(fn {group, _} ->
      {Enum.find_index(@group_order, &(&1 == group)) || length(@group_order), group}
    end)
    |> Kernel.++([{"Command palette", @palette_keys}])
  end

  def shortcut_groups(_), do: [{"Command palette", @palette_keys}]

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    groups = if assigns.palette_open, do: numbered(palette_groups(assigns)), else: []
    total = Enum.reduce(groups, 0, &(&2 + length(&1.items)))

    assigns =
      assign(assigns,
        groups: groups,
        active: if(total == 0, do: nil, else: min(assigns.palette_active, total - 1)),
        nav_json:
          Jason.encode!(
            Enum.map(
              LemonWeb.Nav.items(),
              &%{label: &1.label, path: &1.path, shortcut: &1.shortcut}
            )
          )
      )

    ~H"""
    <div id="lemon-shell-root" phx-hook="Shell" data-nav={@nav_json}>
      <.bell
        panel_open={@panel_open}
        unread={@unread}
        notifications={@notifications}
        prefs={@prefs}
        permission={@permission}
      />
      <.toasts toasts={@toasts} />
      <.palette
        groups={@groups}
        palette_mode={@palette_mode}
        palette_query={@palette_query}
        palette_version={@palette_version}
        active={@active}
        sources={@sources}
        location={@location}
      />
      <.modal
        :if={@shortcuts_open}
        id="shortcuts-dialog"
        show
        size="xl"
        title="Keyboard shortcuts"
        description="Shortcuts never fire while you type, except where noted."
        on_cancel={JS.push("shortcuts:close")}
      >
        <div class="gap-8 sm:columns-2 lg:columns-3">
          <section :for={{group, entries} <- @shortcuts} aria-label={group} class="mb-5 break-inside-avoid">
            <h3 class="mb-1.5 text-2xs font-semibold uppercase tracking-wider text-subtle">{group}</h3>
            <dl class="divide-y divide-line">
              <div :for={entry <- entries} class="flex items-center justify-between gap-3 py-1.5 text-[13px]">
                <dt class="text-fg">{entry.description}</dt>
                <dd class="flex shrink-0 items-center gap-1 text-2xs text-subtle">
                  <.chord keys={entry.keys} />
                </dd>
              </div>
            </dl>
          </section>
        </div>
      </.modal>
    </div>
    """
  end

  attr(:keys, :string, required: true)

  defp chord(assigns) do
    assigns = assign(assigns, :parts, String.split(assigns.keys, " ", trim: true))

    ~H"""
    <span class="sr-only">{@keys}</span>
    <%= for {part, index} <- Enum.with_index(@parts) do %>
      <span :if={index > 0} aria-hidden="true">then</span>
      <.kbd keys={part} />
    <% end %>
    """
  end

  defp bell(assigns) do
    ~H"""
    <div
      id="shell-notifications"
      class="fixed right-12 top-1.5 z-40 md:left-[168px] md:right-auto md:top-2"
      phx-click-away={@panel_open && "panel:close"}
    >
      <button
        type="button"
        id="shell-bell"
        class="btn btn-ghost btn-icon relative md:btn-sm"
        phx-click="panel:toggle"
        aria-label={if @unread > 0, do: "Notifications, #{@unread} unread", else: "Notifications"}
        aria-expanded={to_string(@panel_open)}
        aria-controls="notifications-panel"
        title="Notifications"
      >
        <.icon name="bell" class="h-4 w-4" />
        <span
          :if={@unread > 0}
          class="absolute -right-0.5 -top-0.5 flex h-4 min-w-[1rem] items-center justify-center rounded-full bg-accent px-1 text-[10px] font-semibold leading-none text-accent-fg"
          aria-hidden="true"
        >
          {if @unread > 9, do: "9+", else: @unread}
        </span>
      </button>

      <section
        :if={@panel_open}
        id="notifications-panel"
        role="dialog"
        aria-label="Notifications"
        class="fixed inset-x-2 top-14 z-50 flex max-h-[min(32rem,calc(100dvh-5rem))] flex-col overflow-hidden rounded-xl border border-line bg-elevated shadow-overlay animate-scale-in md:absolute md:inset-x-auto md:left-0 md:top-10 md:w-[22rem]"
        phx-window-keydown="panel:close"
        phx-key="escape"
      >
        <header class="flex items-center justify-between gap-2 border-b border-line px-3 py-2">
          <h2 class="text-[13px] font-semibold text-fg">Notifications</h2>
          <button
            :if={@notifications != []}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="notifications:clear"
          >
            Clear
          </button>
        </header>

        <ol :if={@notifications != []} class="min-h-0 flex-1 divide-y divide-line overflow-y-auto scroll-thin">
          <li :for={item <- @notifications}>
            <.notification_row item={item} />
          </li>
        </ol>
        <div :if={@notifications == []} class="px-4 py-8 text-center">
          <.icon name="bell" class="mx-auto h-5 w-5 text-subtle" />
          <p class="mt-2 text-[13px] font-medium text-fg">No notifications yet</p>
          <p class="mt-0.5 text-xs text-muted">
            Finished runs and approval requests from other sessions show up here.
          </p>
        </div>

        <footer class="space-y-2 border-t border-line bg-surface/60 px-3 py-2.5">
          <div class="flex items-center justify-between gap-2 text-[13px]">
            <span class="text-muted">Run finished</span>
            <.toggle id="notify-pref-runs" label="Notify when runs finish" checked={@prefs.runs} phx-click="notify:pref" phx-value-kind="runs" />
          </div>
          <div class="flex items-center justify-between gap-2 text-[13px]">
            <span class="text-muted">Approval requested</span>
            <.toggle id="notify-pref-approvals" label="Notify on approval requests" checked={@prefs.approvals} phx-click="notify:pref" phx-value-kind="approvals" />
          </div>
          <div class="flex items-center justify-between gap-2 text-xs">
            <span class="text-subtle">
              <%= case @permission do %>
                <% "granted" -> %>Desktop alerts on while this tab is in the background.
                <% "denied" -> %>Desktop alerts are blocked in browser settings.
                <% "unsupported" -> %>This browser has no desktop alerts.
                <% _ -> %>Desktop alerts are off.
              <% end %>
            </span>
            <button
              :if={@permission == "default"}
              type="button"
              class="btn btn-secondary btn-sm shrink-0"
              data-request-notification-permission
            >
              Enable
            </button>
          </div>
        </footer>
      </section>
    </div>
    """
  end

  attr(:item, :map, required: true)

  defp notification_row(assigns) do
    ~H"""
    <.link
      :if={@item.href}
      navigate={@item.href}
      class="flex items-start gap-2.5 px-3 py-2.5 hover:bg-surface-2 focus:bg-surface-2 focus:outline-none"
      phx-click="panel:close"
    >
      <.notification_body item={@item} />
    </.link>
    <div :if={!@item.href} class="flex items-start gap-2.5 px-3 py-2.5">
      <.notification_body item={@item} />
    </div>
    """
  end

  attr(:item, :map, required: true)

  defp notification_body(assigns) do
    ~H"""
    <.icon name={@item.icon} class={["mt-0.5 h-4 w-4 shrink-0", tone_text(@item.tone)]} />
    <span class="min-w-0 flex-1">
      <span class="block truncate text-[13px] font-medium text-fg">{@item.title}</span>
      <span class="block truncate text-xs text-muted">{@item.body}</span>
    </span>
    <time class="shrink-0 text-2xs text-subtle">{relative_time(@item.at_ms)}</time>
    """
  end

  defp tone_text("success"), do: "text-success"
  defp tone_text("danger"), do: "text-danger"
  defp tone_text("warning"), do: "text-warning"
  defp tone_text(_), do: "text-muted"

  defp run_toast_ms, do: @run_toast_ms

  attr(:toasts, :list, required: true)

  defp toasts(assigns) do
    ~H"""
    <div
      id="shell-toasts"
      class="pointer-events-none fixed right-3 top-14 z-[60] flex w-[min(22rem,calc(100vw-1.5rem))] flex-col gap-2 md:top-3"
      aria-live="polite"
      role="status"
    >
      <div
        :for={toast <- @toasts}
        id={"toast-#{toast.id}"}
        class={[
          "pointer-events-auto flex items-start gap-2.5 rounded-lg border bg-elevated px-3 py-2.5 shadow-pop animate-slide-up",
          if(toast.tone == "danger", do: "border-danger/40", else: "border-line")
        ]}
        phx-hook={!toast.sticky && "AutoDismiss"}
        data-timeout={run_toast_ms()}
        phx-click={!toast.sticky && JS.push("toast:dismiss", value: %{id: toast.id})}
      >
        <.icon name={toast.icon} class={["mt-0.5 h-4 w-4 shrink-0", tone_text(toast.tone)]} />
        <div class="min-w-0 flex-1">
          <p class="text-[13px] font-medium text-fg">{toast.title}</p>
          <p class="truncate text-xs text-muted">{toast.body}</p>
          <.link
            :if={toast.href}
            navigate={toast.href}
            class="mt-1 inline-flex items-center gap-1 text-xs font-medium text-accent-text hover:underline"
            phx-click={JS.push("toast:dismiss", value: %{id: toast.id})}
          >
            Open session <.icon name="arrow-right" class="h-3 w-3" />
          </.link>
        </div>
        <button
          type="button"
          class="btn btn-ghost btn-icon btn-sm -mr-1.5 -mt-1"
          aria-label="Dismiss notification"
          phx-click={JS.push("toast:dismiss", value: %{id: toast.id})}
        >
          <.icon name="x" class="h-3.5 w-3.5" />
        </button>
      </div>
    </div>
    """
  end

  defp palette(assigns) do
    ~H"""
    <div id="palette" class="fixed inset-0 z-[55] hidden" data-palette data-version={@palette_version}>
      <div class="absolute inset-0 bg-black/40 backdrop-blur-[2px]" data-palette-backdrop aria-hidden="true">
      </div>
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        class="relative mx-auto mt-3 flex max-h-[calc(100dvh-1.5rem)] w-[min(40rem,calc(100vw-1.5rem))] flex-col overflow-hidden rounded-xl border border-line bg-elevated shadow-overlay animate-scale-in sm:mt-[12vh] sm:max-h-[70vh]"
      >
        <form
          id="palette-form"
          class="flex h-12 shrink-0 items-center gap-2 border-b border-line px-3"
          phx-change="palette:query"
          phx-submit="palette:noop"
          autocomplete="off"
        >
          <.icon name={if @palette_mode == :search, do: "globe", else: "search"} class="h-4 w-4 shrink-0 text-subtle" />
          <span :if={@palette_mode == :search} class="badge badge-accent shrink-0">Everywhere</span>
          <input
            id="palette-input"
            name="q"
            type="text"
            role="combobox"
            aria-expanded="true"
            aria-controls="palette-listbox"
            aria-autocomplete="list"
            aria-activedescendant={@active && "palette-opt-#{@active}"}
            aria-label={if @palette_mode == :search, do: "Search sessions, memory and automation", else: "Search commands, pages and sessions"}
            placeholder={if @palette_mode == :search, do: "Search session content, memory, automation…", else: "Type a command, page or session…"}
            spellcheck="false"
            autocomplete="off"
            phx-debounce="120"
            class="h-full min-w-0 flex-1 bg-transparent text-[14px] text-fg placeholder:text-subtle focus:outline-none"
          />
          <.spinner :if={loading?(@sources)} class="h-3.5 w-3.5" label="Searching" />
          <.kbd keys="esc" class="hidden sm:inline-flex" />
        </form>

        <div id="palette-listbox" role="listbox" aria-label="Results" class="min-h-0 flex-1 overflow-y-auto p-1.5 scroll-thin">
          <div :for={group <- @groups} role="group" aria-labelledby={"palette-group-#{group.id}"} class="pb-1">
            <p id={"palette-group-#{group.id}"} class="flex items-center gap-2 px-2 pb-1 pt-2 text-2xs font-semibold uppercase tracking-wider text-subtle">
              {group.label}
              <.spinner :if={group.state == :loading} class="h-3 w-3" label={"Loading #{group.label}"} />
            </p>
            <p :if={match?({:error, _}, group.state)} class="flex items-center gap-1.5 px-2 py-1.5 text-xs text-danger" role="alert">
              <.icon name="alert-circle" class="h-3.5 w-3.5" />{elem(group.state, 1)}
            </p>
            <div
              :for={{item, index} <- group.items}
              id={"palette-opt-#{index}"}
              role="option"
              aria-selected={to_string(index == @active)}
              data-palette-item
              data-index={index}
              data-kind={item.kind}
              data-href={item[:href]}
              data-split-href={item[:split_href]}
              data-action={item[:action]}
              data-recent-id={item.id}
              data-recent-label={item.label}
              class="group flex h-10 cursor-pointer items-center gap-2.5 rounded-md px-2 text-[13px] text-fg aria-selected:bg-surface-2"
            >
              <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-md border border-line bg-surface text-muted group-aria-selected:text-fg">
                <.icon name={item.icon} class="h-3.5 w-3.5" />
              </span>
              <span class="min-w-0 flex-1 truncate">
                {item.label}
                <span :if={item[:sublabel] not in [nil, ""]} class="ml-1.5 text-xs text-subtle">{item.sublabel}</span>
              </span>
              <span :if={item[:split_href]} class="hidden items-center gap-1 text-2xs text-subtle group-aria-selected:flex">
                <.kbd keys="mod+enter" /> split
              </span>
              <span :if={item[:hint]} class="hidden shrink-0 items-center gap-1 text-2xs text-subtle sm:flex">
                <.chord keys={item.hint} />
              </span>
            </div>
          </div>

          <div :if={@groups == []} class="px-4 py-10 text-center">
            <%= cond do %>
              <% @palette_mode == :search and byte_size(@palette_query) < 2 -> %>
                <.icon name="globe" class="mx-auto h-5 w-5 text-subtle" />
                <p class="mt-2 text-[13px] font-medium text-fg">Search everywhere</p>
                <p class="mt-0.5 text-xs text-muted">
                  Type at least 2 characters to search session content, memory and automation.
                </p>
              <% loading?(@sources) -> %>
                <p class="text-[13px] text-muted">Searching…</p>
              <% true -> %>
                <p class="text-[13px] font-medium text-fg">No results for “{@palette_query}”</p>
                <p :if={@palette_mode == :all} class="mt-0.5 text-xs text-muted">
                  Press <.kbd keys="tab" /> to search session content, memory and automation.
                </p>
            <% end %>
          </div>
        </div>

        <footer class="hidden shrink-0 items-center gap-4 border-t border-line bg-surface/60 px-3 py-2 text-2xs text-subtle sm:flex">
          <span class="flex items-center gap-1"><.kbd keys="up" /><.kbd keys="down" /> navigate</span>
          <span class="flex items-center gap-1"><.kbd keys="enter" /> open</span>
          <span :if={@location.chat} class="flex items-center gap-1"><.kbd keys="mod+enter" /> split</span>
          <span class="ml-auto flex items-center gap-1">
            <.kbd keys="tab" /> {if @palette_mode == :search, do: "commands", else: "search everywhere"}
          </span>
        </footer>
      </div>
    </div>
    """
  end
end
