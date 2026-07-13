defmodule LemonSimUi.HostedLobbyLive do
  @moduledoc false

  use LemonSimUi, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Host Werewolf",
       hosted_enabled: LemonSimUi.HostedGame.enabled?(),
       create_form: to_form(%{}, as: :room),
       join_form: to_form(%{}, as: :join),
       create_token_required:
         is_binary(Application.get_env(:lemon_sim_ui, :hosted_room_create_token))
     )}
  end

  @impl true
  def handle_event("find_room", %{"join" => %{"join_code" => code}}, socket) do
    code = code |> String.trim() |> String.upcase()

    if code =~ ~r/^[A-Z2-9]{10}$/ do
      {:noreply, push_navigate(socket, to: ~p"/join/#{code}")}
    else
      {:noreply, put_flash(socket, :error, "Enter the 10-character room code.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-[#08090d] text-stone-100">
      <section class="relative isolate overflow-hidden border-b border-white/10">
        <img
          src="/assets/werewolf/night_bg.png"
          alt=""
          class="absolute inset-0 -z-20 h-full w-full object-cover opacity-45"
        />
        <div class="absolute inset-0 -z-10 bg-gradient-to-b from-[#090a10]/45 via-[#090a10]/80 to-[#08090d]"></div>
        <div class="mx-auto max-w-6xl px-5 py-16 sm:px-8 sm:py-24">
          <p class="mb-4 text-xs font-bold uppercase tracking-[0.32em] text-amber-300">
            A private village. A public lie.
          </p>
          <h1 class="max-w-3xl font-serif text-5xl font-semibold leading-[0.96] text-white sm:text-7xl">
            Host a night of <span class="text-amber-200">Werewolf</span>
          </h1>
          <p class="mt-6 max-w-2xl text-base leading-7 text-stone-300 sm:text-lg">
            Secure seats, private roles, reconnectable sessions, timed turns, and a shareable
            role-safe broadcast—all in one room.
          </p>
        </div>
      </section>

      <section class="mx-auto grid max-w-6xl gap-6 px-5 py-10 sm:px-8 lg:grid-cols-2 lg:py-16">
        <article :if={!@hosted_enabled} class="rounded-3xl border border-white/10 bg-[#111116]/95 p-8 text-center shadow-2xl shadow-black/30 lg:col-span-2">
          <p class="text-xs font-bold uppercase tracking-[0.24em] text-stone-500">Hosted rooms unavailable</p>
          <h2 class="mt-3 font-serif text-3xl text-white">This deployment is watch-only</h2>
          <p class="mt-3 text-sm text-stone-400">An operator can enable secure hosted rooms in the deployment configuration.</p>
          <.link navigate={~p"/"} class="hosted-secondary mt-6">Browse live arenas</.link>
        </article>

        <article :if={@hosted_enabled} class="rounded-3xl border border-amber-200/20 bg-[#111116]/95 p-6 shadow-2xl shadow-black/30 sm:p-8">
          <div class="mb-7 flex items-start justify-between gap-4">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.24em] text-amber-300">The host</p>
              <h2 class="mt-2 font-serif text-3xl text-white">Open a new room</h2>
            </div>
            <span class="rounded-full border border-amber-200/25 bg-amber-200/10 px-3 py-1 text-xs text-amber-100">
              5–8 seats
            </span>
          </div>

          <.form for={@create_form} action={~p"/rooms"} method="post" class="space-y-5">
            <div class="grid gap-4 sm:grid-cols-2">
              <.field label="Players">
                <select name="room[player_count]" class="hosted-input">
                  <option :for={count <- 5..8} value={count} selected={count == 6}>{count}</option>
                </select>
              </.field>
              <.field label="AI seats">
                <select name="room[ai_seats]" class="hosted-input">
                  <option :for={count <- 0..8} value={count}>{count}</option>
                </select>
              </.field>
              <.field label="Turn timer">
                <select name="room[turn_timeout_seconds]" class="hosted-input">
                  <option value="15">15 seconds</option>
                  <option value="30">30 seconds</option>
                  <option value="60">1 minute</option>
                  <option value="90" selected>90 seconds</option>
                  <option value="180">3 minutes</option>
                </select>
              </.field>
              <.field label="Spectator access">
                <select name="room[visibility]" class="hosted-input">
                  <option value="private">Invite only</option>
                  <option value="public_safe">Public, role-safe</option>
                </select>
              </.field>
            </div>
            <.field label="Rules">
              <select name="room[rules_preset]" class="hosted-input">
                <option value="story" selected>Story mode · meetings, clues, items</option>
                <option value="classic">Classic · roles, night, discussion, vote</option>
              </select>
            </.field>
            <.field :if={@create_token_required} label="Host invite">
              <input
                type="password"
                name="room[create_token]"
                autocomplete="one-time-code"
                required
                class="hosted-input"
                placeholder="Deployment invite token"
              />
            </.field>
            <button class="hosted-primary w-full" type="submit">Create the village</button>
          </.form>
        </article>

        <article :if={@hosted_enabled} class="rounded-3xl border border-sky-200/20 bg-[#111116]/95 p-6 shadow-2xl shadow-black/30 sm:p-8">
          <p class="text-xs font-bold uppercase tracking-[0.24em] text-sky-300">The player</p>
          <h2 class="mt-2 font-serif text-3xl text-white">Enter a room code</h2>
          <p class="mt-3 text-sm leading-6 text-stone-400">
            Your seat creates a signed reconnect session. Your role and private information stay
            scoped to this browser.
          </p>
          <.form for={@join_form} phx-submit="find_room" class="mt-8 space-y-5">
            <.field label="Room code">
              <input
                name="join[join_code]"
                inputmode="text"
                minlength="10"
                maxlength="10"
                required
                class="hosted-input font-mono uppercase tracking-[0.28em]"
                placeholder="NIGHTFALL"
              />
            </.field>
            <button class="hosted-secondary w-full" type="submit">Choose a seat</button>
          </.form>
          <div class="mt-8 grid grid-cols-3 gap-3 text-center text-xs text-stone-400">
            <div class="rounded-2xl border border-white/10 bg-white/[0.03] p-3">Private roles</div>
            <div class="rounded-2xl border border-white/10 bg-white/[0.03] p-3">Auto reconnect</div>
            <div class="rounded-2xl border border-white/10 bg-white/[0.03] p-3">Live story</div>
          </div>
        </article>
      </section>
    </main>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp field(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-2 block text-xs font-bold uppercase tracking-[0.16em] text-stone-400">
        {@label}
      </span>
      {render_slot(@inner_block)}
    </label>
    """
  end
end

defmodule LemonSimUi.HostedJoinLive do
  @moduledoc false

  use LemonSimUi, :live_view

  alias LemonSimUi.HostedGame

  @impl true
  def mount(%{"join_code" => join_code}, _session, socket) do
    case HostedGame.join_view(join_code) do
      {:ok, room} ->
        if connected?(socket), do: LemonCore.Bus.subscribe(HostedGame.topic(room.room_id))

        {:ok,
         assign(socket,
           page_title: "Choose a Werewolf seat",
           join_code: room.join_code,
           room: room,
           join_form: to_form(%{}, as: :player)
         )}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "That room code is not available.")
         |> push_navigate(to: ~p"/play")}
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :hosted_werewolf_updated}, socket) do
    case HostedGame.join_view(socket.assigns.join_code) do
      {:ok, room} ->
        {:noreply, assign(socket, :room, room)}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "That room is no longer available.")
         |> push_navigate(to: ~p"/play")}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-[#08090d] px-5 py-10 text-stone-100 sm:px-8 sm:py-16">
      <p class="sr-only" aria-live="polite">Room {@room.status}; {Enum.count(@room.seats, & &1.available)} seats open.</p>
      <div class="mx-auto max-w-4xl">
        <.link navigate={~p"/play"} class="text-sm text-stone-400 hover:text-white">← Back</.link>
        <div class="mt-6 rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-9">
          <div class="flex flex-wrap items-end justify-between gap-5 border-b border-white/10 pb-7">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.24em] text-amber-300">Room code</p>
              <h1 class="mt-2 font-mono text-3xl tracking-[0.2em] text-white sm:text-5xl">
                {@room.join_code}
              </h1>
            </div>
            <span class="hosted-status">{@room.status}</span>
          </div>

          <h2 :if={@room.status in ["lobby", "paused"]} class="mt-8 font-serif text-3xl text-white">Choose your name in the story</h2>
          <p :if={@room.status in ["lobby", "paused"]} class="mt-2 text-sm text-stone-400">Occupied seats cannot be reclaimed without the host.</p>
          <div :if={@room.status not in ["lobby", "paused"]} class="mt-8 rounded-2xl border border-rose-200/20 bg-rose-950/20 p-6 text-center">
            <h2 class="font-serif text-3xl text-white">This room is closed</h2>
            <p class="mt-2 text-sm text-stone-400">Ask the host for a new room code.</p>
          </div>

          <div :if={@room.status in ["lobby", "paused"]} class="mt-7 grid gap-4 sm:grid-cols-2">
            <article
              :for={seat <- @room.seats}
              class={[
                "rounded-2xl border p-5",
                seat.available && "border-white/10 bg-white/[0.03]",
                !seat.available && "border-white/5 bg-black/20 opacity-55"
              ]}
            >
              <div class="flex items-center justify-between gap-3">
                <h3 class="font-serif text-2xl text-white">{seat.id}</h3>
                <span class={seat.available && "text-emerald-300" || "text-stone-500"}>
                  {if seat.available, do: "Open", else: "Claimed"}
                </span>
              </div>
              <.form
                :if={seat.available}
                for={@join_form}
                action={~p"/rooms/join"}
                method="post"
                class="mt-5 space-y-3"
              >
                <input type="hidden" name="player[join_code]" value={@room.join_code} />
                <input type="hidden" name="player[seat_id]" value={seat.id} />
                <label for={"player-display-name-#{seat.id}"} class="block text-sm font-semibold text-stone-200">
                  Display name
                </label>
                <input
                  id={"player-display-name-#{seat.id}"}
                  name="player[display_name]"
                  required
                  maxlength="40"
                  autocomplete="nickname"
                  class="hosted-input"
                  placeholder="Your display name"
                />
                <button type="submit" class="hosted-secondary w-full">Claim {seat.id}</button>
              </.form>
              <p :if={!seat.available} class="mt-4 text-sm text-stone-500">{seat.display_name}</p>
            </article>
          </div>
        </div>
      </div>
    </main>
    """
  end
end

defmodule LemonSimUi.HostedHostLive do
  @moduledoc false

  use LemonSimUi, :live_view

  alias LemonSimUi.HostedGame

  @impl true
  def mount(%{"room_id" => room_id}, session, socket) do
    token = Map.get(session, HostedGame.host_session_key(room_id))

    case HostedGame.host_view(room_id, token) do
      {:ok, room} ->
        if connected?(socket), do: LemonCore.Bus.subscribe(HostedGame.topic(room_id))

        {:ok,
         socket
         |> Phoenix.LiveView.put_private(:lemon_sim_ui_host_token, token)
         |> assign(
           page_title: "Host · #{room.join_code}",
           room_id: room_id,
           room: room
         )}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "This host session is not available in this browser.")
         |> push_navigate(to: ~p"/play")}
    end
  end

  @impl true
  def handle_event("control", %{"action" => action}, socket) do
    case HostedGame.control(socket.assigns.room_id, host_token(socket), action) do
      :ok -> {:noreply, refresh(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, host_error(reason))}
    end
  end

  def handle_event("seat_kind", %{"seat_id" => seat_id, "kind" => kind}, socket) do
    case HostedGame.configure_seat(
           socket.assigns.room_id,
           host_token(socket),
           seat_id,
           kind
         ) do
      :ok -> {:noreply, refresh(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, host_error(reason))}
    end
  end

  def handle_event("release_seat", %{"seat_id" => seat_id}, socket) do
    case HostedGame.release_seat(socket.assigns.room_id, host_token(socket), seat_id) do
      :ok -> {:noreply, refresh(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, host_error(reason))}
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :hosted_werewolf_updated}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-[#08090d] text-stone-100">
      <header class="border-b border-white/10 bg-[#0d0e13]">
        <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-5 px-5 py-6 sm:px-8">
          <div>
            <p class="text-xs font-bold uppercase tracking-[0.24em] text-amber-300">Host console</p>
            <h1 class="mt-1 font-serif text-3xl text-white">The village of {@room.join_code}</h1>
          </div>
          <div class="flex items-center gap-3">
            <span id="hosted-host-status" class="hosted-status">{@room.status}</span>
            <.link navigate={~p"/rooms/#{@room_id}/watch"} class="hosted-link">Broadcast</.link>
          </div>
        </div>
      </header>

      <p class="sr-only" aria-live="polite">
        Room {@room.status}; {host_phase_label(@room.game.phase)}; {host_actor_name(@room)}.
      </p>

      <div class="mx-auto grid max-w-7xl gap-6 px-5 py-7 sm:px-8 lg:grid-cols-[1fr_20rem]">
        <section class="space-y-6">
          <article :if={@room.status == "stopped"} class="rounded-3xl border border-rose-200/20 bg-rose-950/20 p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-rose-300">Match ended</p>
            <h2 class="mt-3 font-serif text-3xl text-white">
              {cond do
                @room.terminal_reason == "runtime_failure" -> "A runtime failure stopped the match"
                @room.terminal_reason == "host_cancelled" -> "The host cancelled this room"
                true -> "The host ended the match"
              end}
            </h2>
            <p class="mt-2 text-sm text-stone-400">The saved room can be exported or prepared for a rematch.</p>
          </article>

          <article class="rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-8">
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div>
                <p class="text-xs uppercase tracking-[0.2em] text-stone-500">Share this code</p>
                <p id="hosted-room-code" class="mt-2 font-mono text-3xl tracking-[0.2em] text-amber-100 sm:text-5xl">
                  {@room.join_code}
                </p>
              </div>
              <.link navigate={~p"/join/#{@room.join_code}"} class="hosted-secondary">
                Open join page
              </.link>
            </div>
          </article>

          <article class="rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-8">
            <div class="flex items-end justify-between gap-4">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.2em] text-stone-500">Cast</p>
                <h2 class="mt-2 font-serif text-3xl text-white">Seats at the fire</h2>
              </div>
              <p class="text-sm text-stone-400">Match {@room.match_number}</p>
            </div>
            <div class="mt-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              <article :for={seat <- @room.seats} class="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
                <div class="flex items-center justify-between gap-3">
                  <h3 class="font-serif text-xl text-white">{seat.id}</h3>
                  <span class={seat.connected && "text-emerald-300" || "text-stone-600"}>
                    {if seat.connected, do: "● online", else: "○ offline"}
                  </span>
                </div>
                <p class="mt-1 min-h-5 text-sm text-stone-400">{seat.display_name || "Unclaimed"}</p>
                <div class="mt-4 flex gap-2">
                  <button
                    :if={@room.status in ["lobby", "paused"]}
                    phx-click="seat_kind"
                    phx-value-seat_id={seat.id}
                    phx-value-kind={if(seat.kind == "human", do: "ai", else: "human")}
                    class="hosted-mini"
                  >
                    {if seat.kind == "human", do: "Make AI", else: "Make human"}
                  </button>
                  <button
                    :if={@room.status in ["lobby", "paused"] && seat.kind == "human" && seat.claimed}
                    phx-click="release_seat"
                    phx-value-seat_id={seat.id}
                    data-confirm="Release this seat and revoke its reconnect session?"
                    class="hosted-mini text-rose-200"
                  >
                    Replace
                  </button>
                </div>
              </article>
            </div>
          </article>
        </section>

        <aside class="space-y-5">
          <article class="rounded-3xl border border-amber-200/20 bg-[#111116] p-5">
            <p class="text-xs font-bold uppercase tracking-[0.2em] text-amber-300">Game state</p>
            <dl class="mt-5 grid grid-cols-2 gap-4 text-sm">
              <div><dt class="text-stone-500">Phase</dt><dd class="mt-1 text-white">{host_phase_label(@room.game.phase)}</dd></div>
              <div><dt class="text-stone-500">Day</dt><dd class="mt-1 text-white">{@room.game.day_number || "—"}</dd></div>
              <div class="col-span-2"><dt class="text-stone-500">Acting now</dt><dd class="mt-1 font-serif text-xl text-white">{host_actor_name(@room)}</dd></div>
            </dl>
          </article>

          <article class="rounded-3xl border border-white/10 bg-[#111116] p-5">
            <div class="grid gap-3">
              <button id="hosted-start-match" :if={@room.status == "lobby"} phx-click="control" phx-value-action="start" disabled={!@room.can_start} class="hosted-primary disabled:cursor-not-allowed disabled:opacity-40">Start match</button>
              <button :if={@room.status == "lobby"} phx-click="control" phx-value-action="cancel" data-confirm="Cancel this room?" class="hosted-secondary text-rose-100">Cancel room</button>
              <button :if={@room.status == "running"} phx-click="control" phx-value-action="pause" class="hosted-secondary">Pause</button>
              <button :if={@room.status == "paused"} phx-click="control" phx-value-action="resume" disabled={!@room.can_resume} class="hosted-primary disabled:cursor-not-allowed disabled:opacity-40">Resume</button>
              <button :if={@room.status in ["running", "paused"]} phx-click="control" phx-value-action="stop" data-confirm="Stop this match?" class="hosted-secondary text-rose-100">Stop</button>
              <button :if={@room.status in ["completed", "stopped"]} phx-click="control" phx-value-action="rematch" class="hosted-primary">Prepare rematch</button>
              <a :if={@room.can_export} href={~p"/rooms/#{@room_id}/export"} class="hosted-secondary text-center">Export replay</a>
            </div>
            <p :if={@room.status == "lobby" && !@room.can_start} class="mt-4 text-xs leading-5 text-stone-500">
              Every human seat must be claimed before the story can begin.
            </p>
            <p :if={@room.status == "paused" && !@room.can_resume} class="mt-4 text-xs leading-5 text-stone-500">
              Replace or convert every open seat before resuming.
            </p>
            <p :if={@room.persistence_pending} class="mt-4 text-xs leading-5 text-amber-200">
              Saving a terminal recovery record. Rematch and export unlock when storage recovers.
            </p>
          </article>
        </aside>
      </div>
    </main>
    """
  end

  defp refresh(socket) do
    case HostedGame.host_view(socket.assigns.room_id, host_token(socket)) do
      {:ok, room} -> assign(socket, :room, room)
      _ -> socket |> put_flash(:error, "Host access expired.") |> push_navigate(to: ~p"/play")
    end
  end

  defp host_error(:seats_unclaimed), do: "Claim or convert every human seat before starting."
  defp host_error(:invalid_room_status), do: "That control is not available right now."

  defp host_error(:hosted_ai_not_configured),
    do: "AI seats are not configured on this deployment."

  defp host_error(:room_limit_reached), do: "This deployment has reached its active-room limit."
  defp host_error(:persistence_pending), do: "Storage recovery is still in progress."
  defp host_error(:unauthorized), do: "Host access expired."
  defp host_error(_reason), do: "The room could not be updated."

  defp host_token(socket), do: socket.private.lemon_sim_ui_host_token

  defp host_phase_label(nil), do: "Waiting"

  defp host_phase_label(phase) do
    phase |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp host_actor_name(%{status: "lobby"}), do: "Waiting"
  defp host_actor_name(%{terminal_reason: "host_cancelled"}), do: "Waiting"
  defp host_actor_name(%{game: %{active_actor_id: nil}}), do: "Private turn"

  defp host_actor_name(room) do
    actor_id = room.game.active_actor_id

    case Enum.find(room.seats, &(&1.id == actor_id)) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> actor_id
    end
  end
end

defmodule LemonSimUi.HostedPlayerLive do
  @moduledoc false

  use LemonSimUi, :live_view

  alias LemonSimUi.HostedGame

  @impl true
  def mount(%{"room_id" => room_id}, session, socket) do
    token = Map.get(session, HostedGame.player_session_key(room_id))

    case HostedGame.player_view(room_id, token) do
      {:ok, view} ->
        if connected?(socket) do
          LemonCore.Bus.subscribe(HostedGame.topic(room_id))
          _ = HostedGame.connect_player(room_id, token, self())
        end

        {:ok,
         socket
         |> Phoenix.LiveView.put_private(:lemon_sim_ui_player_token, token)
         |> assign(
           page_title: "#{view["seat"]["id"]} · Werewolf",
           room_id: room_id,
           view: view,
           command_id: command_id()
         )}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Your seat is not available in this browser.")
         |> push_navigate(to: ~p"/play")}
    end
  end

  @impl true
  def handle_event("command", params, socket) do
    action = Map.get(params, "action", "")
    command_id = Map.get(params, "command_id", "")
    expected_match_number = parse_integer(Map.get(params, "expected_match_number"))
    expected_version = parse_integer(Map.get(params, "expected_version"))
    action_params = Map.get(params, "params", %{})

    case HostedGame.submit_command(
           socket.assigns.room_id,
           player_token(socket),
           command_id,
           expected_match_number,
           expected_version,
           action,
           action_params
         ) do
      {:ok, _result} ->
        {:noreply, refresh(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh()
         |> put_flash(:error, command_error(reason))}
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :hosted_werewolf_updated}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-[#08090d] text-stone-100">
      <header class="border-b border-white/10 bg-[#0d0e13]">
        <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-5 px-5 py-5 sm:px-8">
          <div>
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-amber-300">Your private seat</p>
            <h1 class="mt-1 font-serif text-3xl text-white">{@view["seat"]["id"]}</h1>
            <p class="text-sm text-stone-400">{@view["seat"]["display_name"]}</p>
          </div>
          <div class="flex items-center gap-3">
            <span id="hosted-player-status" class="hosted-status">{@view["room"]["status"]}</span>
            <.link :if={@view["room"]["visibility"] == "public_safe"} navigate={~p"/rooms/#{@room_id}/watch"} class="hosted-link">Public story</.link>
          </div>
        </div>
      </header>

      <p class="sr-only" aria-live="polite">
        {phase_label(@view["world"]["phase"])}; room {@view["room"]["status"]}; {if @view["legal_actions"] != [], do: "your turn", else: "waiting"}.
      </p>

      <div class="mx-auto grid max-w-7xl gap-6 px-5 py-6 sm:px-8 lg:grid-cols-[20rem_1fr]">
        <aside class="space-y-5">
          <article class="rounded-3xl border border-amber-200/20 bg-gradient-to-b from-amber-100/10 to-[#111116] p-6">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-amber-300">Your role</p>
            <h2 id="hosted-player-role" class="mt-3 font-serif text-4xl capitalize text-white">{@view["role_info"]["your_role"]}</h2>
            <p class="mt-4 text-sm leading-6 text-stone-300">{@view["role_info"]["description"]}</p>
            <div :if={@view["role_info"]["werewolf_partners"]} class="mt-5 rounded-2xl border border-rose-300/20 bg-rose-950/30 p-4">
              <p class="text-xs uppercase tracking-wider text-rose-300">Your pack</p>
              <p class="mt-2 text-sm text-rose-100">{Enum.join(@view["role_info"]["werewolf_partners"], ", ")}</p>
            </div>
            <div :if={Map.get(@view["role_info"], "personality_traits", []) != []} class="mt-5 flex flex-wrap gap-2">
              <span :for={trait <- @view["role_info"]["personality_traits"]} class="rounded-full border border-white/10 bg-black/20 px-3 py-1 text-xs capitalize text-stone-300">
                {String.replace(to_string(trait), "_", " ")}
              </span>
            </div>
          </article>

          <article
            :if={Map.get(@view["role_info"], "your_items", []) != [] || Map.get(@view["role_info"], "your_journal", []) != []}
            class="rounded-3xl border border-white/10 bg-[#111116] p-5"
          >
            <p class="text-xs font-bold uppercase tracking-[0.2em] text-violet-300">Your private kit</p>
            <div :if={Map.get(@view["role_info"], "your_items", []) != []} class="mt-4">
              <p class="text-xs uppercase tracking-wider text-stone-500">Items</p>
              <div class="mt-2 flex flex-wrap gap-2">
                <span :for={item <- @view["role_info"]["your_items"]} class="rounded-full border border-violet-300/20 bg-violet-950/30 px-3 py-1 text-xs capitalize text-violet-100">
                  {String.replace(to_string(item), "_", " ")}
                </span>
              </div>
            </div>
            <div :if={Map.get(@view["role_info"], "your_journal", []) != []} class="mt-4">
              <p class="text-xs uppercase tracking-wider text-stone-500">Journal</p>
              <div class="mt-2 space-y-2">
                <p :for={entry <- Enum.take(@view["role_info"]["your_journal"], -5)} class="rounded-xl bg-black/20 p-3 text-sm leading-5 text-stone-300">
                  {journal_text(entry)}
                </p>
              </div>
            </div>
          </article>

          <article class="rounded-3xl border border-white/10 bg-[#111116] p-5">
            <p class="text-xs font-bold uppercase tracking-[0.2em] text-stone-500">Now</p>
            <dl class="mt-4 space-y-3 text-sm">
              <div class="flex justify-between gap-4"><dt class="text-stone-500">Phase</dt><dd class="text-right text-white">{phase_label(@view["world"]["phase"])}</dd></div>
              <div class="flex justify-between gap-4"><dt class="text-stone-500">Day</dt><dd class="text-white">{@view["world"]["day_number"] || "—"}</dd></div>
              <div class="flex justify-between gap-4"><dt class="text-stone-500">Acting</dt><dd class="font-semibold text-amber-100">{if @view["world"]["status"] == "waiting", do: "Waiting", else: seat_name(@view, @view["world"]["active_player"])}</dd></div>
            </dl>
            <div
              :if={@view["room"]["deadline_at_ms"]}
              id="hosted-turn-countdown"
              phx-hook="HostedCountdown"
              data-deadline={@view["room"]["deadline_at_ms"]}
              class="mt-5 rounded-xl bg-white/[0.04] px-3 py-2 text-center font-mono text-sm text-stone-300"
            >
              Turn timer active
            </div>
          </article>
        </aside>

        <section class="space-y-6">
          <article :if={@view["room"]["status"] == "lobby"} class="rounded-3xl border border-sky-200/20 bg-sky-950/20 p-6 text-center sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-sky-300">The village is gathering</p>
            <h2 class="mt-3 font-serif text-3xl text-white">Waiting for the host to begin</h2>
            <p class="mt-2 text-sm text-stone-400">Your seat and secret role are saved in this browser.</p>
          </article>

          <article :if={@view["room"]["status"] == "paused"} class="rounded-3xl border border-amber-200/20 bg-amber-950/20 p-6 text-center sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-amber-300">Match paused</p>
            <h2 class="mt-3 font-serif text-3xl text-white">The fire is holding</h2>
            <p class="mt-2 text-sm text-stone-400">The host can resume the same turn and remaining timer.</p>
          </article>

          <article :if={@view["room"]["status"] == "completed"} class="rounded-3xl border border-emerald-200/20 bg-emerald-950/20 p-6 text-center sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-emerald-300">Match complete</p>
            <h2 class="mt-3 font-serif text-4xl capitalize text-white">{@view["world"]["winner"] || "The village"} wins</h2>
            <p class="mt-2 text-sm text-stone-400">The host can export the replay or prepare a rematch.</p>
          </article>

          <article :if={@view["room"]["status"] == "stopped"} class="rounded-3xl border border-rose-200/20 bg-rose-950/20 p-6 text-center sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-rose-300">Match ended</p>
            <h2 class="mt-3 font-serif text-3xl text-white">
              {cond do
                @view["room"]["terminal_reason"] == "runtime_failure" -> "A runtime failure stopped the match"
                @view["room"]["terminal_reason"] == "host_cancelled" -> "The host cancelled this room"
                true -> "The host stopped this story"
              end}
            </h2>
            <p class="mt-2 text-sm text-stone-400">Your seat remains safe and available for a rematch.</p>
          </article>

          <article :if={@view["legal_actions"] != [] && @view["room"]["status"] == "running"} class="rounded-3xl border border-amber-200/20 bg-[#111116] p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-amber-300">Your move</p>
            <h2 class="mt-2 font-serif text-3xl text-white">Choose one action</h2>
            <div class="mt-6 grid gap-4 xl:grid-cols-2">
              <.action_form :for={action <- @view["legal_actions"]} action={action} view={@view} match_number={@view["room"]["match_number"]} version={@view["version"]} command_id={@command_id} />
            </div>
          </article>

          <article :if={@view["legal_actions"] == [] && @view["room"]["status"] == "running"} class="rounded-3xl border border-white/10 bg-[#111116] p-6 text-center sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-sky-300">Watching the fire</p>
            <h2 class="mt-3 font-serif text-3xl text-white">
              {if @view["world"]["status"] == "game_over", do: "The story is complete", else: "#{seat_name(@view, @view["world"]["active_player"])} is deciding"}
            </h2>
            <p class="mt-2 text-sm text-stone-400">Your view will update when the story moves.</p>
          </article>

          <article
            :if={Map.get(@view["role_info"], "investigation_history", []) != [] || Map.get(@view["role_info"], "night_sightings", []) != []}
            class="rounded-3xl border border-violet-200/20 bg-violet-950/15 p-6 sm:p-8"
          >
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-violet-300">Private intelligence</p>
            <div class="mt-5 grid gap-3 sm:grid-cols-2">
              <div :for={check <- Map.get(@view["role_info"], "investigation_history", [])} class="rounded-2xl border border-violet-200/15 bg-black/20 p-4">
                <p class="text-sm text-stone-400">{seat_name(@view, check["target"])}</p>
                <p class="mt-1 font-serif text-2xl capitalize text-violet-100">{check["role"]}</p>
              </div>
              <div :for={sighting <- Map.get(@view["role_info"], "night_sightings", [])} class="rounded-2xl border border-violet-200/15 bg-black/20 p-4">
                <p class="text-xs uppercase tracking-wider text-stone-500">Night {sighting["day"]}</p>
                <p class="mt-2 text-sm leading-6 text-violet-100">{sighting["description"]}</p>
              </div>
            </div>
          </article>

          <article
            :if={Map.get(@view["role_info"], "wolf_chat_transcript", []) != [] || Map.get(@view["role_info"], "wolf_chat_history", []) != []}
            class="rounded-3xl border border-rose-200/20 bg-rose-950/15 p-6 sm:p-8"
          >
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-rose-300">Pack channel · private</p>
            <div class="mt-5 space-y-3">
              <div :for={entry <- Enum.take(Map.get(@view["role_info"], "wolf_chat_history", []) ++ Map.get(@view["role_info"], "wolf_chat_transcript", []), -20)} class="rounded-2xl border border-rose-200/10 bg-black/20 p-4">
                <p class="text-xs font-bold uppercase tracking-wider text-rose-200">{seat_name(@view, entry["player"])}</p>
                <p class="mt-2 text-sm leading-6 text-stone-300">{entry["message"]}</p>
              </div>
            </div>
          </article>

          <article
            :if={@view["discussion"]["current_meeting"] || @view["discussion"]["meeting_transcripts"] != []}
            class="rounded-3xl border border-sky-200/20 bg-sky-950/15 p-6 sm:p-8"
          >
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-sky-300">Private meetings</p>
            <div class="mt-5 space-y-4">
              <div :for={meeting <- meeting_views(@view["discussion"])} class="rounded-2xl border border-sky-200/10 bg-black/20 p-4">
                <p class="text-xs uppercase tracking-wider text-sky-200">
                  {Enum.map_join(meeting["pair"], " + ", &seat_name(@view, &1))}
                </p>
                <div class="mt-3 space-y-2">
                  <p :for={message <- meeting["messages"]} class="text-sm leading-6 text-stone-300">
                    <strong class="text-white">{seat_name(@view, message["player"])}:</strong> {message["message"]}
                  </p>
                  <p :if={meeting["messages"] == []} class="text-sm text-stone-500">No private messages yet.</p>
                </div>
              </div>
            </div>
          </article>

          <article :if={@view["recent_events"] != []} class="rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.2em] text-stone-500">What just happened</p>
            <div class="mt-5 grid gap-3 sm:grid-cols-2">
              <div :for={event <- Enum.take(@view["recent_events"], -12)} class="rounded-2xl border border-white/10 bg-black/20 p-4">
                <p class="text-xs font-bold uppercase tracking-wider text-amber-200">{event_label(event)}</p>
                <p class="mt-2 text-sm leading-6 text-stone-300">{event_summary(event, @view)}</p>
              </div>
            </div>
          </article>

          <article class="rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.2em] text-stone-500">
              {if map_size(@view["final_roles"]) > 0, do: "Final roles revealed", else: "The village"}
            </p>
            <div class="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
              <div :for={player <- @view["world"]["players"]} class="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
                <div class="flex items-center justify-between gap-3">
                  <span class="font-serif text-xl text-white">{seat_name(@view, player["name"])}</span>
                  <span class={player["status"] == "alive" && "text-emerald-300" || "text-stone-500"}>{player["status"]}</span>
                </div>
                <p :if={player["role"] || @view["final_roles"][player["name"]]} class="mt-2 text-sm capitalize text-stone-400">
                  {player["role"] || @view["final_roles"][player["name"]]}
                </p>
              </div>
            </div>
          </article>

          <article class="rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.2em] text-stone-500">At the council fire</p>
            <div class="mt-5 space-y-3">
              <div :for={entry <- Enum.take(@view["discussion"]["discussion_transcript"], -16)} class="rounded-2xl border border-white/10 bg-black/20 p-4">
                <p class="text-xs font-bold uppercase tracking-wider text-amber-200">{seat_name(@view, entry["player"])}</p>
                <p class="mt-2 text-sm leading-6 text-stone-300">{entry["statement"]}</p>
              </div>
              <p :if={@view["discussion"]["discussion_transcript"] == []} class="text-sm text-stone-500">The village is still quiet.</p>
            </div>
          </article>
        </section>
      </div>
    </main>
    """
  end

  attr(:action, :map, required: true)
  attr(:view, :map, required: true)
  attr(:match_number, :integer, required: true)
  attr(:version, :integer, required: true)
  attr(:command_id, :string, required: true)

  defp action_form(assigns) do
    properties = assigns.action["parameters"]["properties"] || %{}
    assigns = assign(assigns, :properties, properties)

    ~H"""
    <form
      id={"hosted-action-#{@action["name"]}"}
      phx-submit="command"
      class="rounded-2xl border border-white/10 bg-white/[0.025] p-5"
    >
      <input type="hidden" name="action" value={@action["name"]} />
      <input type="hidden" name="command_id" value={@command_id <> "-" <> @action["name"]} />
      <input type="hidden" name="expected_match_number" value={@match_number} />
      <input type="hidden" name="expected_version" value={@version} />
      <h3 class="font-serif text-2xl text-white">{@action["label"]}</h3>
      <p class="mt-2 text-sm leading-6 text-stone-400">{@action["description"]}</p>
      <div class="mt-5 space-y-4">
        <.action_field :for={{key, schema} <- @properties} :if={key != "thought"} name={key} schema={schema} view={@view} />
      </div>
      <button type="submit" class="hosted-primary mt-5 w-full">Commit action</button>
    </form>
    """
  end

  attr(:name, :string, required: true)
  attr(:schema, :map, required: true)
  attr(:view, :map, required: true)

  defp action_field(assigns) do
    ~H"""
    <label class="block">
      <span class="mb-2 block text-xs font-bold uppercase tracking-wider text-stone-500">{String.replace(@name, "_", " ")}</span>
      <select :if={is_list(@schema["enum"])} name={"params[#{@name}]"} class="hosted-input" required>
        <option :for={value <- @schema["enum"]} value={value}>{seat_name(@view, value)}</option>
      </select>
      <textarea :if={!is_list(@schema["enum"])} name={"params[#{@name}]"} maxlength="2000" class="hosted-input min-h-24" required></textarea>
    </label>
    """
  end

  defp refresh(socket) do
    case HostedGame.player_view(socket.assigns.room_id, player_token(socket)) do
      {:ok, view} -> assign(socket, view: view, command_id: command_id())
      _ -> socket |> put_flash(:error, "Seat access expired.") |> push_navigate(to: ~p"/play")
    end
  end

  defp command_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> -1
    end
  end

  defp parse_integer(_value), do: -1

  defp command_error(:stale_state), do: "The story moved first. Your view has been refreshed."
  defp command_error(:not_active_actor), do: "It is not your turn."
  defp command_error(:game_not_running), do: "The match is not running."
  defp command_error(:invalid_parameters), do: "Review the action and try again."
  defp command_error(:turn_expired), do: "Time expired. The story is advancing."
  defp command_error(_reason), do: "That action was not accepted."

  defp player_token(socket), do: socket.private.lemon_sim_ui_player_token

  defp seat_name(_view, nil), do: "Private turn"

  defp seat_name(view, seat_id) do
    case get_in(view, ["seats", seat_id, "display_name"]) do
      name when is_binary(name) and name != "" -> name
      _ -> seat_id
    end
  end

  defp phase_label(nil), do: "Waiting"

  defp phase_label(phase) do
    phase
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp meeting_views(discussion) do
    List.wrap(discussion["current_meeting"]) ++ discussion["meeting_transcripts"]
  end

  defp journal_text(entry) when is_binary(entry), do: entry

  defp journal_text(entry) when is_map(entry) do
    Map.get(entry, :text) || Map.get(entry, "text") || Map.get(entry, :note) ||
      Map.get(entry, "note") || Map.get(entry, :thought) || Map.get(entry, "thought") ||
      "A private note was recorded."
  end

  defp journal_text(entry), do: to_string(entry)

  defp event_label(event), do: event |> event_kind() |> phase_label()

  defp event_summary(event, view) do
    payload = Map.get(event, :payload, Map.get(event, "payload", %{}))

    case event_kind(event) do
      "night_resolved" ->
        value(payload, "summary") || "The night was resolved."

      "investigation_result" ->
        "#{seat_name(view, value(payload, "target"))} is #{value(payload, "role")}."

      "wolf_chat" ->
        "#{seat_name(view, value(payload, "player"))}: #{value(payload, "message")}"

      "make_statement" ->
        "#{seat_name(view, value(payload, "speaker"))}: #{value(payload, "statement")}"

      "make_accusation" ->
        "#{seat_name(view, value(payload, "accuser"))} accused #{seat_name(view, value(payload, "target"))}: #{value(payload, "reason")}"

      "player_eliminated" ->
        "#{seat_name(view, value(payload, "player"))} was eliminated as #{value(payload, "role")}"

      "vote_result" ->
        "The vote selected #{seat_name(view, value(payload, "eliminated"))}."

      "wanderer_result" ->
        value(payload, "description") || "You learned something in the dark."

      "village_event" ->
        value(payload, "description") || "Something changed in the village."

      "item_found" ->
        value(payload, "description") || "You found an item."

      "lantern_result" ->
        value(payload, "description") || "The lantern revealed a clue."

      "anonymous_message" ->
        value(payload, "message") || "An anonymous message arrived."

      "meeting_message" ->
        value(payload, "message") || "A private message was shared."

      _ ->
        "The story advanced."
    end
  end

  defp event_kind(event),
    do: event |> Map.get(:kind, Map.get(event, "kind", "event")) |> to_string()

  defp value(map, key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn {candidate, item} -> if to_string(candidate) == key, do: item end)
  end
end

defmodule LemonSimUi.HostedWatchLive do
  @moduledoc false

  use LemonSimUi, :live_view

  alias LemonSimUi.HostedGame

  @impl true
  def mount(%{"room_id" => room_id}, session, socket) do
    credential =
      case Map.get(session, HostedGame.host_session_key(room_id)) do
        token when is_binary(token) -> {:host, token}
        _ -> nil
      end

    case HostedGame.public_view(room_id, credential) do
      {:ok, view} ->
        if connected?(socket), do: LemonCore.Bus.subscribe(HostedGame.topic(room_id))

        {:ok,
         socket
         |> Phoenix.LiveView.put_private(:lemon_sim_ui_watch_credential, credential)
         |> assign(
           page_title: "Werewolf room broadcast",
           room_id: room_id,
           view: view
         )}

      {:error, :private_room} ->
        {:ok,
         socket
         |> put_flash(:error, "This room's broadcast is private.")
         |> push_navigate(to: ~p"/play")}

      {:error, _reason} ->
        {:ok, socket |> put_flash(:error, "Room not found.") |> push_navigate(to: ~p"/play")}
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :hosted_werewolf_updated}, socket) do
    case HostedGame.public_view(
           socket.assigns.room_id,
           socket.private.lemon_sim_ui_watch_credential
         ) do
      {:ok, view} -> {:noreply, assign(socket, :view, view)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-[#08090d] text-stone-100">
      <header class="relative isolate overflow-hidden border-b border-white/10">
        <img src="/assets/werewolf/night_bg.png" alt="" class="absolute inset-0 -z-20 h-full w-full object-cover opacity-35" />
        <div class="absolute inset-0 -z-10 bg-gradient-to-r from-[#08090d] via-[#08090d]/90 to-[#08090d]/60"></div>
        <div class="mx-auto max-w-7xl px-5 py-10 sm:px-8">
          <p class="text-xs font-bold uppercase tracking-[0.28em] text-sky-300">Role-safe live story</p>
          <h1 id="hosted-watch-heading" class="mt-2 font-serif text-4xl text-white sm:text-6xl">
            {if @view["world"]["status"] == "waiting", do: "Waiting for the village", else: "Day #{@view["world"]["day_number"]} · #{phase_label(@view["world"]["phase"])}"}
          </h1>
          <p class="mt-3 text-stone-300">
            {cond do
              @view["room"]["status"] == "lobby" -> "Seats are gathering before the match begins."
              @view["room"]["terminal_reason"] == "host_cancelled" -> "This room ended before the match began."
              @view["world"]["active_player"] -> "#{seat_name(@view, @view["world"]["active_player"])} holds the floor."
              true -> "A private turn is underway."
            end}
          </p>
        </div>
      </header>

      <p class="sr-only" aria-live="polite">
        {phase_label(@view["world"]["phase"])}; room {@view["room"]["status"]}.
      </p>

      <div class="mx-auto grid max-w-7xl gap-6 px-5 py-7 sm:px-8 lg:grid-cols-[1fr_21rem]">
        <section class="space-y-6">
          <article :if={@view["room"]["status"] in ["completed", "stopped"]} class="rounded-3xl border border-emerald-200/20 bg-emerald-950/20 p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-emerald-300">Final bell</p>
            <h2 class="mt-3 font-serif text-4xl capitalize text-white">
              {cond do
                @view["room"]["status"] == "completed" -> "#{@view["world"]["winner"] || "The village"} wins"
                @view["room"]["terminal_reason"] == "runtime_failure" -> "A runtime failure stopped the match"
                @view["room"]["terminal_reason"] == "host_cancelled" -> "The host cancelled this room"
                true -> "The host stopped the match"
              end}
            </h2>
          </article>

          <article class="rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-amber-300">Council record</p>
            <div class="mt-5 space-y-3">
              <div :for={entry <- Enum.take(@view["discussion"]["discussion_transcript"], -20)} class="rounded-2xl border border-white/10 bg-black/20 p-4">
                <p class="text-xs font-bold uppercase tracking-wider text-amber-200">{seat_name(@view, entry["player"])}</p>
                <p class="mt-2 text-sm leading-6 text-stone-300">{entry["statement"]}</p>
              </div>
              <p :if={@view["discussion"]["discussion_transcript"] == []} class="text-stone-500">No one has spoken publicly yet.</p>
            </div>
          </article>

          <article :if={@view["recent_events"] != []} class="rounded-3xl border border-white/10 bg-[#111116] p-6 sm:p-8">
            <p class="text-xs font-bold uppercase tracking-[0.22em] text-sky-300">Story beats</p>
            <div class="mt-5 grid gap-3 sm:grid-cols-2">
              <div :for={event <- Enum.take(@view["recent_events"], -12)} class="rounded-2xl border border-white/10 bg-black/20 p-4">
                <p class="text-xs font-bold uppercase tracking-wider text-stone-500">{event_label(event)}</p>
                <p class="mt-2 text-sm leading-6 text-stone-300">{public_event_summary(event, @view)}</p>
              </div>
            </div>
          </article>
        </section>
        <aside class="rounded-3xl border border-white/10 bg-[#111116] p-5 lg:self-start">
          <p class="text-xs font-bold uppercase tracking-[0.2em] text-stone-500">Living roster</p>
          <div class="mt-5 space-y-2">
            <div :for={player <- @view["world"]["players"]} class="flex items-center justify-between gap-3 rounded-xl border border-white/10 px-3 py-3">
              <span class="font-serif text-lg text-white">{seat_name(@view, player["name"])}</span>
              <span class={player["status"] == "alive" && "text-emerald-300" || "text-stone-500"}>{player["role"] || player["status"]}</span>
            </div>
          </div>
          <div :if={map_size(@view["final_roles"]) > 0} class="mt-6 border-t border-white/10 pt-5">
            <p class="text-xs uppercase tracking-wider text-amber-300">Final roles revealed</p>
            <dl class="mt-4 space-y-2">
              <div :for={{seat_id, role} <- Enum.sort(@view["final_roles"])} class="flex items-center justify-between gap-3 text-sm">
                <dt class="text-stone-300">{seat_name(@view, seat_id)}</dt>
                <dd class="capitalize text-amber-100">{role}</dd>
              </div>
            </dl>
          </div>
        </aside>
      </div>
    </main>
    """
  end

  defp seat_name(_view, nil), do: "Private turn"

  defp seat_name(view, seat_id) do
    case get_in(view, ["seats", seat_id, "display_name"]) do
      name when is_binary(name) and name != "" -> name
      _ -> seat_id
    end
  end

  defp phase_label(nil), do: "Waiting"

  defp phase_label(phase) do
    phase |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp event_label(event) do
    event |> event_kind() |> phase_label()
  end

  defp public_event_summary(event, view) do
    payload = Map.get(event, :payload, Map.get(event, "payload", %{}))

    case event_kind(event) do
      "night_resolved" ->
        value(payload, "summary") || "The night was resolved."

      "make_statement" ->
        "#{seat_name(view, value(payload, "speaker"))}: #{value(payload, "statement")}"

      "make_accusation" ->
        "#{seat_name(view, value(payload, "accuser"))} accused #{seat_name(view, value(payload, "target"))}."

      "player_eliminated" ->
        "#{seat_name(view, value(payload, "player"))} was eliminated as #{value(payload, "role")}"

      "vote_result" ->
        "The vote selected #{seat_name(view, value(payload, "eliminated"))}."

      "village_event" ->
        value(payload, "description") || "Something changed in the village."

      "anonymous_message" ->
        value(payload, "message") || "An anonymous message arrived."

      _ ->
        "The story advanced."
    end
  end

  defp event_kind(event),
    do: event |> Map.get(:kind, Map.get(event, "kind", "event")) |> to_string()

  defp value(map, key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn {candidate, item} -> if to_string(candidate) == key, do: item end)
  end
end
