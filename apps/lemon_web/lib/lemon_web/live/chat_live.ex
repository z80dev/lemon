defmodule LemonWeb.ChatLive do
  @moduledoc """
  Chat workspace: `/` (home: start a session, recent and active sessions) and
  `/chat/:session_key` (one pane, or two with `?split=<other key>`).

  This LiveView owns the workspace chrome — the sessions sidebar, the home
  form and split layout. Each pane is a nested `LemonWeb.Chat.PaneLive`
  (`live_render/3`), its own process with its own session subscription; panes
  report workspace effects back with `{:chat_pane, role, message}`.

  Keyboard and palette integration lives in the `ChatWorkspace`/`ChatPane`
  hooks (priv/static/assets/js/chat.js): they handle `lemon:chat-action`
  CustomEvents on `document.body`.
  """

  use LemonWeb, :live_view

  alias LemonCore.SessionKey
  alias LemonWeb.Chat.{Backend, Setup}
  alias LemonWeb.{Rpc, SessionCwd}

  @poll_ms 5_000
  @sessions_every 4
  @recent_limit 50

  @impl true
  def mount(_params, _session, socket) do
    setup = Setup.status()

    socket =
      socket
      |> assign(
        nav: :chat,
        page_title: "Chat · Lemon",
        session_key: nil,
        split_key: nil,
        sidebar_open: true,
        query: "",
        sessions: [],
        sessions_total: 0,
        sessions_error: nil,
        active: %{},
        sidebar_rename: nil,
        poll_count: 0,
        setup_state: setup,
        setup_ready?: Setup.ready?(setup),
        home: %{prompt: "", cwd: "", profile: "", error: nil},
        intro: nil,
        workspaces: [],
        profiles: [],
        default_cwd: SessionCwd.default()
      )
      |> load_sessions()
      |> load_active()

    socket =
      if connected?(socket) do
        Process.send_after(self(), :poll, @poll_ms)

        socket
        |> start_async(:workspaces, fn -> recent_workspaces() end)
        |> start_async(:profiles, fn -> Backend.profiles() end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :home ->
        {:noreply,
         assign(socket,
           session_key: nil,
           split_key: nil,
           page_title: "Chat · Lemon",
           page_heading: "Chat"
         )}

      :show ->
        key = params["session_key"]

        if valid_key?(key) do
          split = if valid_key?(params["split"]) and params["split"] != key, do: params["split"]
          title = session_title(socket.assigns.sessions, key)

          {:noreply,
           assign(socket,
             session_key: key,
             split_key: split,
             page_title: "#{title} · Lemon",
             page_heading: title
           )}
        else
          {:noreply,
           socket
           |> put_flash(
             :error,
             "That session link is not valid. Pick a session from the sidebar."
           )
           |> push_navigate(to: "/")}
        end
    end
  end

  defp valid_key?(key), do: is_binary(key) and byte_size(key) <= 1024 and SessionKey.valid?(key)

  # ── Data ────────────────────────────────────────────────────────────────

  defp load_sessions(socket) do
    params =
      case String.trim(socket.assigns.query) do
        "" -> %{"limit" => @recent_limit, "archived" => false}
        query -> %{"limit" => @recent_limit, "query" => query}
      end

    case Backend.sessions(params) do
      {:ok, sessions, total} ->
        sessions = Enum.sort_by(sessions, &{not &1.pinned, -(&1.updated_at_ms || 0)})
        assign(socket, sessions: sessions, sessions_total: total, sessions_error: nil)

      {:error, error} ->
        assign(socket, :sessions_error, Rpc.message(error))
    end
  end

  defp load_active(socket) do
    case Backend.active_sessions() do
      {:ok, active} -> assign(socket, active: active, active_error: nil)
      {:error, _} -> assign(socket, :active_error, "Could not refresh active runs. Retrying.")
    end
  end

  defp recent_workspaces do
    case Backend.sessions(%{"limit" => 40}) do
      {:ok, sessions, _} ->
        sessions
        |> Enum.flat_map(fn session ->
          case SessionCwd.recorded(session.key) do
            {:ok, cwd} -> [cwd]
            :error -> []
          end
        end)
        |> Enum.uniq()
        |> Enum.take(12)

      _ ->
        []
    end
  end

  defp session_title(sessions, key) do
    case Enum.find(sessions, &(&1.key == key)) do
      %{title: title} when is_binary(title) -> title
      _ -> fallback_title(key)
    end
  end

  @doc false
  def fallback_title(key) do
    case SessionKey.parse(key) do
      %{kind: :main, agent_id: agent} ->
        "#{agent} · main"

      %{agent_id: agent} ->
        "#{agent} · #{key |> String.split(":") |> List.last() |> String.slice(0, 12)}"

      _ ->
        String.slice(key, 0, 40)
    end
  rescue
    _ -> "Session"
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle-sidebar", _params, socket),
    do: {:noreply, update(socket, :sidebar_open, &(not &1))}

  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, socket |> assign(:query, String.slice(query, 0, 200)) |> load_sessions()}

  def handle_event("new-session", _params, socket), do: {:noreply, push_patch(socket, to: "/")}

  def handle_event("nav-session", %{"dir" => dir}, socket) do
    keys = Enum.map(socket.assigns.sessions, & &1.key)
    index = Enum.find_index(keys, &(&1 == socket.assigns.session_key))

    target =
      case {dir, index} do
        {_, nil} -> List.first(keys)
        {"prev", i} -> Enum.at(keys, max(i - 1, 0))
        {"next", i} -> Enum.at(keys, min(i + 1, length(keys) - 1))
        _ -> nil
      end

    if target && target != socket.assigns.session_key,
      do: {:noreply, push_patch(socket, to: chat_path(target, socket.assigns.split_key))},
      else: {:noreply, socket}
  end

  def handle_event("toggle-split", _params, socket), do: {:noreply, toggle_split(socket)}

  def handle_event("open-split", %{"key" => key}, socket) do
    cond do
      not valid_key?(key) ->
        {:noreply, socket}

      socket.assigns.session_key in [nil, key] ->
        {:noreply, push_patch(socket, to: chat_path(key, nil))}

      true ->
        {:noreply, push_patch(socket, to: chat_path(socket.assigns.session_key, key))}
    end
  end

  def handle_event("close-split", _params, socket),
    do: {:noreply, push_patch(socket, to: chat_path(socket.assigns.session_key, nil))}

  def handle_event("sidebar-rename", %{"key" => key}, socket),
    do: {:noreply, assign(socket, :sidebar_rename, if(known?(socket, key), do: key))}

  def handle_event("sidebar-rename-cancel", _params, socket),
    do: {:noreply, assign(socket, :sidebar_rename, nil)}

  def handle_event("sidebar-rename-save", %{"key" => key, "title" => title}, socket) do
    title = String.trim(title)

    socket =
      if known?(socket, key) do
        metadata(socket, key, %{
          "title" => if(title == "", do: nil, else: String.slice(title, 0, 160))
        })
      else
        socket
      end

    {:noreply, assign(socket, :sidebar_rename, nil)}
  end

  def handle_event("sidebar-pin", %{"key" => key, "value" => value}, socket),
    do:
      {:noreply,
       if(known?(socket, key),
         do: metadata(socket, key, %{"pinned" => value == "true"}),
         else: socket
       )}

  def handle_event("sidebar-archive", %{"key" => key, "value" => value}, socket),
    do:
      {:noreply,
       if(known?(socket, key),
         do: metadata(socket, key, %{"archived" => value == "true"}),
         else: socket
       )}

  def handle_event("sidebar-fork", %{"key" => key} = params, socket) do
    if known?(socket, key) do
      cwd = SessionCwd.resolve(key)

      case Backend.fork(key, cwd) do
        {:ok, child} ->
          SessionCwd.remember(child, cwd)
          split = if params["split"] == "true", do: child
          base = if split, do: socket.assigns.session_key || key, else: child

          {:noreply,
           socket
           |> load_sessions()
           |> put_flash(:info, "Forked into a new session.")
           |> push_patch(to: chat_path(base, if(base == child, do: nil, else: split)))}

        {:error, {:outcome_unknown, _}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Lemon could not confirm the fork. Check Sessions before trying again."
           )}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, Rpc.message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Home ────────────────────────────────────────────────────────────────

  def handle_event("refresh-setup", _params, socket) do
    state = Setup.status()
    {:noreply, assign(socket, setup_state: state, setup_ready?: Setup.ready?(state))}
  end

  def handle_event("home-change", %{"home" => home}, socket) do
    {:noreply,
     assign(socket, :home, %{
       socket.assigns.home
       | prompt: home["prompt"] || "",
         cwd: home["cwd"] || "",
         profile: home["profile"] || ""
     })}
  end

  def handle_event("home-start", %{"home" => home}, socket) do
    prompt = String.trim(home["prompt"] || "")
    cwd = String.trim(home["cwd"] || "")
    profile = home["profile"] || ""
    form = %{prompt: home["prompt"] || "", cwd: home["cwd"] || "", profile: profile, error: nil}
    socket = assign(socket, :home, form)

    cond do
      not socket.assigns.setup_ready? ->
        {:noreply, assign(socket, :home, %{form | error: Setup.message()})}

      prompt == "" ->
        {:noreply,
         assign(socket, :home, %{form | error: "Describe the work to start a session."})}

      cwd != "" and not (Path.type(cwd) == :absolute and File.dir?(cwd)) ->
        {:noreply,
         assign(socket, :home, %{
           form
           | error: "The workspace must be an existing absolute directory."
         })}

      profile != "" and not Enum.any?(socket.assigns.profiles, &(&1.id == profile)) ->
        {:noreply, assign(socket, :home, %{form | error: "Choose a profile from the list."})}

      true ->
        agent_id = if profile == "", do: "default", else: profile
        key = new_session_key(agent_id)
        cwd = if cwd == "", do: nil, else: Path.expand(cwd)
        opts = [cwd: cwd, agent_id: agent_id]

        case Backend.send_prompt(key, prompt, opts) do
          {:ok, _run_id} ->
            SessionCwd.remember(key, cwd || SessionCwd.default())

            {:noreply,
             socket
             |> assign(:home, %{form | prompt: ""})
             |> assign(:intro, {key, prompt})
             |> load_sessions()
             |> push_patch(to: chat_path(key, nil))}

          {:error, :outcome_unknown} ->
            {:noreply,
             assign(socket, :home, %{
               form
               | error:
                   "Lemon could not confirm whether the session started. Check recent sessions before trying again."
             })}

          {:error, error} ->
            {:noreply, assign(socket, :home, %{form | error: Rpc.message(error)})}
        end
    end
  end

  defp new_session_key(agent_id) do
    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "web",
      account_id: "browser",
      peer_kind: :unknown,
      peer_id: "tab-" <> Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
    })
  end

  # ── Pane messages & polling ─────────────────────────────────────────────

  @impl true
  def handle_info({:chat_pane, _role, :sessions_changed}, socket),
    do: {:noreply, socket |> load_sessions() |> load_active()}

  def handle_info({:chat_pane, _role, {:open_session, key, mode, _cwd}}, socket) do
    cond do
      not valid_key?(key) ->
        {:noreply, socket}

      mode == :split ->
        {:noreply,
         socket
         |> load_sessions()
         |> push_patch(to: chat_path(socket.assigns.session_key || key, key))}

      true ->
        {:noreply, socket |> load_sessions() |> push_patch(to: chat_path(key, nil))}
    end
  end

  def handle_info({:chat_pane, _role, {:toggle_split, _key, _role2}}, socket),
    do: {:noreply, toggle_split(socket)}

  def handle_info({:chat_pane, "secondary", {:close_pane, _}}, socket),
    do: {:noreply, push_patch(socket, to: chat_path(socket.assigns.session_key, nil))}

  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    count = socket.assigns.poll_count + 1
    socket = socket |> assign(:poll_count, count) |> load_active()
    {:noreply, if(rem(count, @sessions_every) == 0, do: load_sessions(socket), else: socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:workspaces, {:ok, workspaces}, socket),
    do: {:noreply, assign(socket, :workspaces, workspaces)}

  def handle_async(:workspaces, _, socket), do: {:noreply, socket}

  def handle_async(:profiles, {:ok, {:ok, profiles}}, socket),
    do: {:noreply, assign(socket, :profiles, profiles)}

  def handle_async(:profiles, _, socket), do: {:noreply, socket}

  defp toggle_split(socket) do
    cond do
      socket.assigns.session_key == nil ->
        socket

      socket.assigns.split_key ->
        push_patch(socket, to: chat_path(socket.assigns.session_key, nil))

      other = Enum.find(socket.assigns.sessions, &(&1.key != socket.assigns.session_key)) ->
        push_patch(socket, to: chat_path(socket.assigns.session_key, other.key))

      true ->
        put_flash(socket, :error, "There is no other session to open beside this one.")
    end
  end

  defp metadata(socket, key, patch) do
    case Backend.metadata_patch(key, patch) do
      :ok -> load_sessions(socket)
      {:error, error} -> put_flash(socket, :error, Rpc.message(error))
    end
  end

  defp known?(socket, key), do: Enum.any?(socket.assigns.sessions, &(&1.key == key))

  defp chat_path(key, nil), do: "/chat/" <> URI.encode_www_form(key)
  defp chat_path(key, split), do: chat_path(key, nil) <> "?split=" <> URI.encode_www_form(split)

  defp pane_id(key, role),
    do:
      "pane-#{role}-" <>
        (:crypto.hash(:sha256, key) |> Base.url_encode64(padding: false) |> binary_part(0, 10))

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-workspace" class="relative flex h-full min-h-0" phx-hook="ChatWorkspace" data-split={to_string(@split_key != nil)}>
      <aside
        id="chat-sidebar"
        aria-label="Sessions"
        class={[
          "peer fixed inset-y-0 left-0 z-40 flex w-72 -translate-x-full flex-col border-r border-line bg-surface transition-transform duration-150",
          "data-[mobile-open=true]:translate-x-0 data-[mobile-open=true]:shadow-overlay",
          "md:static md:z-auto md:w-64 md:translate-x-0 md:bg-surface/40 lg:w-72",
          !@sidebar_open && "md:hidden"
        ]}
      >
        <div class="flex h-11 shrink-0 items-center gap-1 border-b border-line px-2">
          <h2 class="px-1 text-[13px] font-semibold">Sessions</h2>
          <span class="text-2xs text-subtle">{@sessions_total}</span>
          <.button
            size="sm"
            variant="ghost"
            icon="plus"
            class="ml-auto"
            patch="/"
            title="New session (⌘⇧O)"
            id="sidebar-new-session"
          >
            New
          </.button>
          <button
            type="button"
            class="btn btn-ghost btn-icon btn-sm md:hidden"
            phx-click={JS.dispatch("lemon:chat-action", to: "body", detail: %{action: "toggle-sidebar"})}
            aria-label="Close sessions"
          >
            <.icon name="x" class="h-4 w-4" />
          </button>
        </div>
        <form id="session-search-form" phx-change="search" phx-submit="search" class="shrink-0 p-2" role="search">
          <label for="session-search" class="sr-only">Search sessions</label>
          <div class="relative">
            <.icon name="search" class="pointer-events-none absolute left-2 top-2 h-3.5 w-3.5 text-subtle" />
            <input
              id="session-search"
              name="query"
              value={@query}
              phx-debounce="250"
              class="input h-7 pl-7 text-xs"
              placeholder="Search sessions…"
              autocomplete="off"
            />
          </div>
        </form>
        <.callout :if={@sessions_error} tone="warning" class="mx-2 mb-2" id="sessions-unavailable">
          Sessions are unavailable: {@sessions_error}
        </.callout>
        <.callout :if={@active_error} tone="warning" class="mx-2 mb-2" id="active-runs-unavailable">
          {@active_error}
        </.callout>
        <nav class="min-h-0 flex-1 overflow-y-auto px-1.5 pb-3 scroll-thin" aria-label="Session list" id="session-list" phx-hook="ListNav">
          <p :if={@sessions == [] and !@sessions_error} class="px-2 py-6 text-center text-xs text-muted">
            {if @query == "", do: "No sessions yet.", else: "No sessions match."}
          </p>
          <ul class="space-y-px">
            <li :for={session <- @sessions} id={"session-item-" <> item_id(session.key)} class="group/item relative">
              <form :if={@sidebar_rename == session.key} phx-submit="sidebar-rename-save" class="flex items-center gap-1 px-1 py-0.5">
                <input type="hidden" name="key" value={session.key} />
                <input
                  name="title"
                  value={session.title}
                  maxlength="160"
                  class="input h-7 text-xs"
                  aria-label="Session title"
                  phx-mounted={JS.focus()}
                  phx-keydown="sidebar-rename-cancel"
                  phx-key="Escape"
                />
              </form>
              <.link
                :if={@sidebar_rename != session.key}
                patch={chat_path(session.key, nil)}
                class={[
                  "flex items-center gap-2 rounded-md py-1.5 pl-2 pr-8 text-[13px] transition-colors",
                  if(session.key in [@session_key, @split_key],
                    do: "bg-surface-2 text-fg",
                    else: "text-muted hover:bg-surface-2/70 hover:text-fg"
                  )
                ]}
                aria-current={session.key == @session_key && "page"}
                data-session-key={session.key}
                data-list-item
              >
                <.status_dot :if={Map.has_key?(@active, session.key)} tone="info" pulse />
                <span :if={Map.has_key?(@active, session.key)} class="sr-only">Running</span>
                <.icon :if={!Map.has_key?(@active, session.key) && session.pinned} name="pin" class="h-3 w-3 shrink-0 text-accent-text" />
                <.icon :if={!Map.has_key?(@active, session.key) && !session.pinned} name="message-square" class="h-3 w-3 shrink-0 text-subtle" />
                <span class="min-w-0 flex-1">
                  <span class="block truncate">{session.title || fallback_title(session.key)}</span>
                  <span class="flex items-center gap-1 text-2xs text-subtle">
                    <span :if={session.agent_id && session.agent_id != "default"} class="truncate font-medium">{session.agent_id} ·</span>
                    <span>{relative_time(session.updated_at_ms)}</span>
                    <span :if={session.key == @split_key}>· split</span>
                  </span>
                </span>
              </.link>
              <.dropdown
                :if={@sidebar_rename != session.key}
                id={"session-menu-" <> item_id(session.key)}
                label={"Actions for #{session.title || fallback_title(session.key)}"}
                class="absolute right-1 top-1.5 opacity-0 focus-within:opacity-100 group-hover/item:opacity-100"
              >
                <:trigger>
                  <span class="btn btn-ghost btn-icon btn-sm h-6 w-6"><.icon name="more-horizontal" class="h-3.5 w-3.5" /></span>
                </:trigger>
                <button type="button" role="menuitem" class="menu-item" phx-click="sidebar-rename" phx-value-key={session.key}>
                  <.icon name="pencil" class="h-3.5 w-3.5" /> Rename
                </button>
                <button type="button" role="menuitem" class="menu-item" phx-click="open-split" phx-value-key={session.key}>
                  <.icon name="columns" class="h-3.5 w-3.5" /> Open in split
                </button>
                <button type="button" role="menuitem" class="menu-item" phx-click="sidebar-fork" phx-value-key={session.key} data-requires-connection>
                  <.icon name="git-fork" class="h-3.5 w-3.5" /> Fork
                </button>
                <button type="button" role="menuitem" class="menu-item" phx-click="sidebar-pin" phx-value-key={session.key} phx-value-value={to_string(!session.pinned)}>
                  <.icon name="pin" class="h-3.5 w-3.5" /> {if session.pinned, do: "Unpin", else: "Pin"}
                </button>
                <button type="button" role="menuitem" class="menu-item" phx-click="sidebar-archive" phx-value-key={session.key} phx-value-value={to_string(!session.archived)}>
                  <.icon name="archive" class="h-3.5 w-3.5" /> {if session.archived, do: "Restore", else: "Archive"}
                </button>
              </.dropdown>
            </li>
          </ul>
          <p :if={@sessions_total > length(@sessions)} class="px-2 pt-2 text-2xs text-subtle">
            Showing {length(@sessions)} of {@sessions_total}.
            <.link navigate="/sessions" class="text-info hover:underline">All sessions</.link>
          </p>
        </nav>
      </aside>
      <div
        class="fixed inset-0 z-30 hidden bg-black/40 peer-data-[mobile-open=true]:block md:!hidden"
        phx-click={JS.dispatch("lemon:chat-action", to: "body", detail: %{action: "toggle-sidebar"})}
        aria-hidden="true"
      >
      </div>

      <div class="flex min-w-0 flex-1">
        <%= if @live_action == :home do %>
          <.home {assigns} />
        <% else %>
          <div class={["flex min-w-0 flex-1", @split_key && "divide-x divide-line"]}>
            <div class="flex min-w-0 flex-1" id={"slot-primary"}>
              {live_render(@socket, LemonWeb.Chat.PaneLive,
                id: pane_id(@session_key, "primary"),
                session: %{
                  "session_key" => @session_key,
                  "role" => "primary",
                  "split" => @split_key != nil,
                  "intro" => intro_for(@intro, @session_key)
                },
                container: {:div, class: "flex min-w-0 flex-1"}
              )}
            </div>
            <div :if={@split_key} class="hidden min-w-0 flex-1 md:flex" id="slot-secondary">
              {live_render(@socket, LemonWeb.Chat.PaneLive,
                id: pane_id(@split_key, "secondary"),
                session: %{"session_key" => @split_key, "role" => "secondary", "split" => true},
                container: {:div, class: "flex min-w-0 flex-1"}
              )}
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # The first prompt sent from home, shown by the new pane until history has it.
  defp intro_for({key, prompt}, key), do: prompt
  defp intro_for(_intro, _key), do: nil

  defp item_id(key),
    do: :crypto.hash(:sha256, key) |> Base.url_encode64(padding: false) |> binary_part(0, 10)

  defp home(assigns) do
    active = Enum.filter(assigns.sessions, &Map.has_key?(assigns.active, &1.key))

    recent =
      assigns.sessions |> Enum.reject(&Map.has_key?(assigns.active, &1.key)) |> Enum.take(8)

    assigns = assign(assigns, active_sessions: active, recent_sessions: recent)

    ~H"""
    <div class="h-full min-w-0 flex-1 overflow-y-auto scroll-thin">
      <div class="mx-auto w-full max-w-2xl px-4 pb-16 pt-8 sm:pt-14">
        <div class="mb-6 flex items-center gap-3">
          <span class="flex h-9 w-9 items-center justify-center rounded-lg bg-accent text-accent-fg shadow-sm">
            <.icon name="lemon" class="h-5 w-5" />
          </span>
          <div>
            <h1 class="text-xl font-semibold tracking-tight">What should Lemon work on?</h1>
            <p class="text-[13px] text-muted">Start a session in a workspace. Lemon streams its work and asks before risky steps.</p>
          </div>
        </div>

        <Setup.gate :if={!@setup_ready?} state={@setup_state} />
        <.callout :if={@active_error} tone="warning" id="home-active-runs-unavailable">
          {@active_error}
        </.callout>

        <form
          id="home-form"
          phx-change="home-change"
          phx-submit="home-start"
          class="mt-4 rounded-xl border border-line bg-surface shadow-sm focus-within:border-ring focus-within:ring-2 focus-within:ring-ring/25"
        >
          <label for="home-prompt" class="sr-only">First message</label>
          <textarea
            id="home-prompt"
            name="home[prompt]"
            rows="3"
            phx-hook="Composer"
            data-pane="home"
            phx-debounce="300"
            placeholder="Describe a task, e.g. “Add a --json flag to the export command and test it”"
            disabled={!@setup_ready?}
            class="block min-h-[5.5rem] w-full resize-none rounded-t-xl border-0 bg-transparent px-3.5 py-3 text-[14px] leading-relaxed text-fg placeholder:text-subtle focus:outline-none focus:ring-0 disabled:opacity-60"
          >{@home.prompt}</textarea>
          <div class="flex flex-wrap items-end gap-2 border-t border-line/70 px-2.5 py-2">
            <div class="min-w-[12rem] flex-1">
              <label for="home-cwd" class="mb-0.5 flex items-center gap-1 text-2xs font-medium text-subtle">
                <.icon name="folder" class="h-3 w-3" /> Workspace
              </label>
              <input
                id="home-cwd"
                name="home[cwd]"
                value={@home.cwd}
                list="home-workspaces"
                class="input h-7 font-mono text-xs"
                placeholder={@default_cwd}
                autocomplete="off"
                spellcheck="false"
              />
              <datalist id="home-workspaces">
                <option :for={cwd <- @workspaces} value={cwd}></option>
              </datalist>
            </div>
            <div :if={@profiles != []} class="w-40">
              <label for="home-profile" class="mb-0.5 flex items-center gap-1 text-2xs font-medium text-subtle">
                <.icon name="user" class="h-3 w-3" /> Profile
              </label>
              <select id="home-profile" name="home[profile]" class="input h-7 text-xs">
                <option value="">Default</option>
                <option :for={profile <- @profiles} value={profile.id} selected={@home.profile == profile.id}>{profile.name}</option>
              </select>
            </div>
            <.button type="submit" variant="primary" icon="send" id="home-start" mutation disabled={!@setup_ready?}>
              Start
            </.button>
          </div>
        </form>
        <p :if={@home.error} id="home-error" role="alert" class="mt-2 text-xs text-danger">{@home.error}</p>
        <div :if={@workspaces != []} class="mt-2 flex flex-wrap items-center gap-1.5">
          <span class="text-2xs text-subtle">Recent:</span>
          <button
            :for={cwd <- Enum.take(@workspaces, 5)}
            type="button"
            class="max-w-[16rem] truncate rounded-md border border-line bg-surface px-1.5 py-0.5 font-mono text-2xs text-muted hover:border-line-strong hover:text-fg"
            phx-click={JS.set_attribute({"value", cwd}, to: "#home-cwd") |> JS.dispatch("input", to: "#home-cwd")}
            title={cwd}
          >
            {Path.basename(cwd)}
            <span :if={Enum.count(@workspaces, &(Path.basename(&1) == Path.basename(cwd))) > 1} class="text-subtle">
              — {Path.dirname(cwd)}
            </span>
          </button>
        </div>

        <section :if={@active_sessions != []} class="mt-10" aria-labelledby="home-active">
          <h2 id="home-active" class="mb-2 flex items-center gap-2 text-2xs font-semibold uppercase tracking-wide text-subtle">
            <.status_dot tone="info" pulse /> Active now
          </h2>
          <ul class="grid gap-2 sm:grid-cols-2">
            <li :for={session <- @active_sessions}><.session_card session={session} active /></li>
          </ul>
        </section>

        <section class="mt-10" aria-labelledby="home-recent">
          <div class="mb-2 flex items-center justify-between">
            <h2 id="home-recent" class="text-2xs font-semibold uppercase tracking-wide text-subtle">Recent sessions</h2>
            <.link navigate="/sessions" class="text-xs text-info hover:underline">All sessions</.link>
          </div>
          <.callout :if={@sessions_error} tone="warning">Sessions are unavailable: {@sessions_error}</.callout>
          <p :if={@recent_sessions == [] and !@sessions_error} class="rounded-lg border border-dashed border-line px-4 py-6 text-center text-xs text-muted">
            No sessions yet — your first one will appear here.
          </p>
          <ul class="grid gap-2 sm:grid-cols-2">
            <li :for={session <- @recent_sessions}><.session_card session={session} /></li>
          </ul>
        </section>

        <div class="mt-10 flex flex-wrap gap-x-4 gap-y-1 text-2xs text-subtle">
          <span class="flex items-center gap-1"><.kbd keys="mod+shift+o" /> new session</span>
          <span class="flex items-center gap-1"><.kbd keys="mod+k" /> command palette</span>
          <span class="flex items-center gap-1"><.kbd keys="mod+b" /> sessions</span>
          <span class="flex items-center gap-1"><.kbd keys="?" /> all shortcuts</span>
        </div>
      </div>
    </div>
    """
  end

  attr(:session, :map, required: true)
  attr(:active, :boolean, default: false)

  defp session_card(assigns) do
    ~H"""
    <.link
      patch={chat_path(@session.key, nil)}
      class="flex items-start gap-2.5 rounded-lg border border-line bg-surface px-3 py-2.5 shadow-sm transition-colors hover:border-line-strong hover:bg-surface-2/40"
    >
      <.icon name={if @session.pinned, do: "pin", else: "message-square"} class={["mt-0.5 h-3.5 w-3.5 shrink-0", if(@session.pinned, do: "text-accent-text", else: "text-subtle")]} />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[13px] font-medium text-fg">{@session.title || fallback_title(@session.key)}</span>
        <span class="flex items-center gap-1 text-2xs text-subtle">
          <span :if={@active} class="font-medium text-info">running ·</span>
          <span :if={@session.agent_id && @session.agent_id != "default"}>{@session.agent_id} ·</span>
          {relative_time(@session.updated_at_ms)} · {@session.run_count} {if @session.run_count == 1, do: "run", else: "runs"}
        </span>
      </span>
    </.link>
    """
  end
end
