defmodule LemonWeb.ProfileManagementLive do
  @moduledoc """
  Authenticated profile lifecycle management over the control plane's
  `profiles.*` methods (`LemonWeb.Rpc`), the same surface the TUI uses, so every
  write also reloads the router's profile cache.

  The LiveView keeps only operator-facing profile metadata in socket state.
  Derived paths and system prompts are intentionally excluded. Every mutation
  begins with a read-only preview; stale-sensitive actions bind an opaque hash
  of the current canonical profile and recheck it in constant time immediately
  before submitting the write.
  """

  use LemonWeb, :live_view

  alias LemonCore.NodeRegistry
  alias LemonWeb.Rpc

  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @node_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
  @max_profiles 128
  @max_name_bytes 256
  @max_model_bytes 512

  @empty_create %{"id" => "", "name" => "", "model" => "", "node" => "local"}
  @empty_clone %{"id" => "", "name" => "", "model" => "", "node" => ""}
  @empty_rename %{"name" => ""}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(nav: :profiles, page_title: "Profiles · Lemon", page_heading: "Profiles")
     |> assign(:show_create, false)
     |> assign(:profiles, [])
     |> assign(:filtered_profiles, [])
     |> assign(:max_profiles, @max_profiles)
     |> assign(:profile_count, 0)
     |> assign(:availability_counts, %{})
     |> assign(:selected_id, nil)
     |> assign(:selected, nil)
     |> assign(:filter, "")
     |> assign(:create_draft, @empty_create)
     |> assign(:clone_draft, @empty_clone)
     |> assign(:rename_draft, @empty_rename)
     |> assign(:pending_change, nil)
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_profiles()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_change, nil)
     |> assign(:notice, "Profile roster refreshed.")
     |> assign(:error, nil)
     |> refresh_profiles()}
  end

  def handle_event("filter", %{"filter" => params}, socket) do
    filter = bounded_draft(params["query"], 128)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> assign(:filtered_profiles, filter_profiles(socket.assigns.profiles, filter))}
  end

  def handle_event("select", %{"id" => id}, socket) do
    id = normalize_id(id)

    case Enum.find(socket.assigns.profiles, &(&1.id == id)) do
      nil ->
        {:noreply,
         socket
         |> assign(:pending_change, nil)
         |> assign(:error, "That profile is no longer available.")}

      profile ->
        {:noreply,
         socket
         |> assign(:selected_id, profile.id)
         |> assign(:selected, profile)
         |> assign(:rename_draft, %{"name" => profile.name})
         |> assign(:clone_draft, clone_defaults(profile))
         |> assign(:pending_change, nil)
         |> assign(:notice, nil)
         |> assign(:error, nil)}
    end
  end

  def handle_event("preview-create", %{"profile" => params}, socket) do
    draft = normalize_profile_draft(params, @empty_create)
    socket = assign(socket, :create_draft, draft)

    with :ok <- validate_new_profile(draft),
         {:error, :not_found} <- profile_get(draft["id"]) do
      pending = %{
        action: :create,
        label: "Create profile #{draft["id"]}",
        target_id: draft["id"],
        source_id: nil,
        expected_revision: nil,
        attrs: attrs(draft),
        destructive: false,
        confirmation: nil
      }

      {:noreply, preview_ready(socket, pending)}
    else
      {:ok, _profile} ->
        {:noreply, reject_preview(socket, "That profile ID already exists.")}

      {:error, message} when is_binary(message) ->
        {:noreply, reject_preview(socket, message)}

      _ ->
        {:noreply, reject_preview(socket, "Profile service is unavailable.")}
    end
  end

  def handle_event("preview-clone", _params, %{assigns: %{selected: nil}} = socket) do
    {:noreply, reject_preview(socket, "Select a source profile before cloning it.")}
  end

  def handle_event("preview-clone", %{"clone" => params}, socket) do
    draft = normalize_profile_draft(params, @empty_clone)
    socket = assign(socket, :clone_draft, draft)
    source_id = socket.assigns.selected.id

    with :ok <- validate_new_profile(draft),
         {:error, :not_found} <- profile_get(draft["id"]),
         {:ok, source} <- profile_get(source_id) do
      pending = %{
        action: :clone,
        label: "Clone #{source_id} as #{draft["id"]}",
        target_id: draft["id"],
        source_id: source_id,
        expected_revision: profile_revision(source),
        attrs: attrs(draft),
        destructive: false,
        confirmation: nil
      }

      {:noreply, preview_ready(socket, pending)}
    else
      {:ok, _profile} ->
        {:noreply, reject_preview(socket, "That profile ID already exists.")}

      {:error, :not_found} ->
        {:noreply, reject_preview(socket, "The source profile changed. Refresh and try again.")}

      {:error, message} when is_binary(message) ->
        {:noreply, reject_preview(socket, message)}

      _ ->
        {:noreply, reject_preview(socket, "Profile service is unavailable.")}
    end
  end

  def handle_event("preview-rename", _params, %{assigns: %{selected: nil}} = socket) do
    {:noreply, reject_preview(socket, "Select a profile before renaming it.")}
  end

  def handle_event("preview-rename", %{"rename" => params}, socket) do
    draft = %{"name" => bounded_draft(params["name"], @max_name_bytes)}
    socket = assign(socket, :rename_draft, draft)
    id = socket.assigns.selected.id

    with :ok <- validate_name(draft["name"]),
         {:ok, current} <- profile_get(id) do
      pending = %{
        action: :rename,
        label: "Rename profile #{id}",
        target_id: id,
        source_id: nil,
        expected_revision: profile_revision(current),
        attrs: %{"name" => draft["name"]},
        destructive: false,
        confirmation: nil
      }

      {:noreply, preview_ready(socket, pending)}
    else
      {:error, message} when is_binary(message) -> {:noreply, reject_preview(socket, message)}
      _ -> {:noreply, reject_preview(socket, "That profile changed. Refresh and try again.")}
    end
  end

  def handle_event("preview-delete", %{"id" => id}, socket) do
    id = normalize_id(id)

    with %{} <- Enum.find(socket.assigns.profiles, &(&1.id == id)),
         {:ok, current} <- profile_get(id) do
      pending = %{
        action: :delete,
        label: "Delete profile #{id}",
        target_id: id,
        source_id: nil,
        expected_revision: profile_revision(current),
        attrs: %{},
        destructive: true,
        confirmation: id
      }

      {:noreply, preview_ready(socket, pending)}
    else
      _ -> {:noreply, reject_preview(socket, "That profile is no longer available.")}
    end
  end

  def handle_event("cancel-preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_change, nil)
     |> assign(:notice, "Preview dismissed. Your drafts were kept.")
     |> assign(:error, nil)}
  end

  def handle_event("apply-preview", _params, %{assigns: %{pending_change: nil}} = socket) do
    {:noreply, assign(socket, :error, "Preview an exact profile change before applying it.")}
  end

  def handle_event("apply-preview", params, socket) do
    pending = socket.assigns.pending_change

    if pending.destructive and not secure_equal?(pending.confirmation, params["confirmation"]) do
      {:noreply,
       assign(
         socket,
         :error,
         "Exact profile ID did not match. Nothing changed; your preview was kept."
       )}
    else
      apply_pending(socket, pending)
    end
  end

  def handle_event("open-create", _params, socket) do
    {:noreply, assign(socket, :show_create, true)}
  end

  def handle_event("close-create", _params, socket) do
    {:noreply, assign(socket, :show_create, false)}
  end

  def handle_event("dismiss-feedback", _params, socket) do
    {:noreply, assign(socket, notice: nil, error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page wide>
      <.page_header
        title="Profiles"
        icon="users"
        subtitle="Durable specialists with isolated homes and one stable chat each."
      >
        <:meta>
          <.badge>{@profile_count} durable</.badge>
          <.badge tone="accent">{Map.get(@availability_counts, "local", 0)} local</.badge>
          <.badge :if={Map.get(@availability_counts, "online", 0) > 0} tone="success">
            {Map.get(@availability_counts, "online", 0)} online
          </.badge>
          <.badge :if={Map.get(@availability_counts, "offline", 0) > 0} tone="warning">
            {Map.get(@availability_counts, "offline", 0)} offline
          </.badge>
        </:meta>
        <:actions>
          <.button size="sm" variant="ghost" icon="refresh" phx-click="refresh">Refresh</.button>
          <.button size="sm" variant="primary" icon="plus" phx-click="open-create">
            New profile
          </.button>
        </:actions>
      </.page_header>

      <div id="profile-feedback" aria-live="polite">
        <.callout :if={@notice} tone="info" class="mb-3">
          {@notice}
          <:actions>
            <.button
              size="sm"
              variant="ghost"
              icon="x"
              icon_only
              phx-click="dismiss-feedback"
              aria-label="Dismiss"
            />
          </:actions>
        </.callout>
        <.callout :if={@error && !@pending_change} tone="danger" class="mb-3">
          {@error}
          <:actions>
            <.button
              size="sm"
              variant="ghost"
              icon="x"
              icon_only
              phx-click="dismiss-feedback"
              aria-label="Dismiss"
            />
          </:actions>
        </.callout>
      </div>

      <.card :if={@show_create} id="profile-create" class="mb-4">
        <:header>Create a specialist</:header>
        <:actions>
          <.button
            size="sm"
            variant="ghost"
            icon="x"
            icon_only
            phx-click="close-create"
            aria-label="Close"
          />
        </:actions>
        <.form
          for={to_form(@create_draft, as: :profile)}
          id="profile-create-form"
          phx-submit="preview-create"
          class="space-y-3"
        >
          <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <.input
              id="profile_id"
              name="profile[id]"
              value={@create_draft["id"]}
              label="Stable ID"
              hint="Lowercase letters, numbers, - and _."
              maxlength="64"
              pattern="[a-z0-9][a-z0-9_-]{0,63}"
              autocomplete="off"
              required
            />
            <.input
              id="profile_name"
              name="profile[name]"
              value={@create_draft["name"]}
              label="Display name"
              maxlength="256"
              required
            />
            <.input
              id="profile_model"
              name="profile[model]"
              value={@create_draft["model"]}
              label="Model"
              placeholder="Runtime default"
              maxlength="512"
            />
            <.input
              id="profile_node"
              name="profile[node]"
              value={@create_draft["node"]}
              label="Execution node"
              maxlength="128"
              required
            />
          </div>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <p class="text-xs text-muted">
              System prompts and credentials stay in terminal-managed configuration.
            </p>
            <.button type="submit" variant="primary" icon="eye">Preview profile</.button>
          </div>
        </.form>
      </.card>

      <div class="grid gap-4 lg:grid-cols-[20rem_minmax(0,1fr)]">
        <section
          aria-labelledby="profile-list-title"
          class="card flex min-h-0 flex-col lg:self-start"
        >
          <div class="card-header">
            <h2 id="profile-list-title" class="text-[13px] font-semibold text-fg">Roster</h2>
            <span class="text-xs text-muted">{length(@filtered_profiles)} of {@profile_count}</span>
          </div>
          <div class="border-b border-line p-2">
            <.form
              for={to_form(%{"query" => @filter}, as: :filter)}
              id="profile-filter-form"
              phx-change="filter"
            >
              <label for="filter_query" class="sr-only">Filter profiles</label>
              <div class="relative">
                <.icon
                  name="search"
                  class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle"
                />
                <input
                  id="filter_query"
                  name="filter[query]"
                  value={@filter}
                  type="search"
                  maxlength="128"
                  placeholder="Filter by ID, name, model, node"
                  class="input pl-8"
                  phx-debounce="150"
                />
              </div>
            </.form>
          </div>
          <div
            id="profile-list"
            class="max-h-[60vh] overflow-y-auto p-1 scroll-thin lg:max-h-[calc(100vh-15rem)]"
          >
            <p :if={@filtered_profiles == []} class="px-3 py-6 text-center text-xs text-muted">
              {if @profile_count == 0, do: "No profiles yet.", else: "No profiles match this filter."}
            </p>
            <button
              :for={profile <- @filtered_profiles}
              type="button"
              id={"profile-#{profile.id}"}
              phx-click="select"
              phx-value-id={profile.id}
              aria-current={@selected_id == profile.id && "true"}
              class={[
                "flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left transition-colors hover:bg-surface-2",
                @selected_id == profile.id &&
                  "bg-surface-2 shadow-[inset_2px_0_0_rgb(var(--accent))]"
              ]}
            >
              <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-accent/15 text-xs font-semibold uppercase text-accent-text">
                {String.first(profile.name) || "?"}
              </span>
              <span class="min-w-0 flex-1">
                <span class="block truncate text-[13px] font-medium text-fg">{profile.name}</span>
                <span class="block truncate text-2xs text-muted">
                  <span class="font-mono">{profile.id}</span> · {profile.model || "runtime default"}
                </span>
              </span>
              <.status_dot tone={availability_tone(profile.availability)} />
              <span class="sr-only">{profile.availability}</span>
            </button>
          </div>
        </section>

        <section aria-labelledby="profile-detail-title" class="min-w-0 space-y-4">
          <%= if @selected do %>
            <.card>
              <:header>
                <div class="flex min-w-0 items-center gap-2">
                  <h2 id="profile-detail-title" class="truncate text-[15px] font-semibold text-fg">
                    {@selected.name}
                  </h2>
                  <.badge tone={availability_tone(@selected.availability)}>
                    {@selected.availability}
                  </.badge>
                </div>
              </:header>
              <:actions>
                <.button
                  size="sm"
                  icon="download"
                  href={~p"/profiles/#{@selected.id}/export"}
                  download
                  aria-label="Export profile"
                >
                  <span class="hidden sm:inline">Export</span>
                </.button>
                <.button
                  size="sm"
                  variant="primary"
                  icon="message-square"
                  navigate={~p"/chat/#{@selected.canonical_session_key}"}
                >
                  Open chat
                </.button>
              </:actions>
              <.key_value>
                <:item label="Stable ID">
                  <span class="font-mono text-xs">{@selected.id}</span>
                </:item>
                <:item label="Model">{@selected.model || "Runtime default"}</:item>
                <:item label="Node">{@selected.node}</:item>
                <:item label="Status">{@selected.status}</:item>
                <:item label="Stable chat">
                  <code class="break-all font-mono text-xs">{@selected.canonical_session_key}</code>
                </:item>
              </.key_value>
            </.card>

            <div class="grid gap-4 xl:grid-cols-2">
              <.card>
                <:header>Rename</:header>
                <.form
                  for={to_form(@rename_draft, as: :rename)}
                  id="profile-rename-form"
                  phx-submit="preview-rename"
                  class="space-y-3"
                >
                  <.input
                    id="rename_name"
                    name="rename[name]"
                    value={@rename_draft["name"]}
                    label="Display name"
                    hint="Keeps the stable ID and canonical chat."
                    maxlength="256"
                    required
                  />
                  <div class="flex justify-end">
                    <.button type="submit" icon="eye">Preview rename</.button>
                  </div>
                </.form>
              </.card>

              <.card>
                <:header>Clone</:header>
                <.form
                  for={to_form(@clone_draft, as: :clone)}
                  id="profile-clone-form"
                  phx-submit="preview-clone"
                  class="space-y-3"
                >
                  <div class="grid gap-3 sm:grid-cols-2">
                    <.input
                      id="clone_id"
                      name="clone[id]"
                      value={@clone_draft["id"]}
                      label="New ID"
                      maxlength="64"
                      pattern="[a-z0-9][a-z0-9_-]{0,63}"
                      autocomplete="off"
                      required
                    />
                    <.input
                      id="clone_name"
                      name="clone[name]"
                      value={@clone_draft["name"]}
                      label="Display name"
                      maxlength="256"
                      required
                    />
                    <.input
                      id="clone_model"
                      name="clone[model]"
                      value={@clone_draft["model"]}
                      label="Model"
                      placeholder="Runtime default"
                      maxlength="512"
                    />
                    <.input
                      id="clone_node"
                      name="clone[node]"
                      value={@clone_draft["node"]}
                      label="Node"
                      maxlength="128"
                      required
                    />
                  </div>
                  <div class="flex items-center justify-between gap-2">
                    <p class="text-xs text-muted">
                      Copies bootstrap and skill files into a new isolated home.
                    </p>
                    <.button type="submit" icon="copy">Preview clone</.button>
                  </div>
                </.form>
              </.card>
            </div>

            <.card class="border-danger/30">
              <:header><span class="text-danger">Danger zone</span></:header>
              <div class="flex flex-wrap items-center justify-between gap-3">
                <p class="text-xs text-muted">
                  Recoverable delete: the managed home moves to Lemon trash before configuration is removed.
                </p>
                <.button
                  size="sm"
                  variant="danger-soft"
                  icon="trash"
                  phx-click="preview-delete"
                  phx-value-id={@selected.id}
                  mutation
                >
                  Delete profile…
                </.button>
              </div>
            </.card>
          <% else %>
            <.empty_state
              icon="users"
              title="No profile selected"
              description="Create a specialist or choose one from the roster."
            >
              <.button size="sm" variant="primary" icon="plus" phx-click="open-create">
                New profile
              </.button>
            </.empty_state>
          <% end %>
        </section>
      </div>

      <.confirm_dialog
        :if={@pending_change}
        id="profile-change-preview"
        title={@pending_change.label}
        description="Preview ready. No profile or filesystem state changed."
        confirm_label={
          if @pending_change.destructive, do: "Delete profile", else: "Apply exact change"
        }
        confirm_event="apply-preview"
        cancel_event="cancel-preview"
        confirm_text={@pending_change.confirmation}
        tone={if @pending_change.destructive, do: "danger", else: "primary"}
      >
        <p>{preview_sentence(@pending_change)}</p>
        <.callout :if={@error} tone="danger" class="mt-3">{@error}</.callout>
        <.callout
          :if={@pending_change.destructive}
          tone="warning"
          class="mt-3"
          title="Recoverable delete"
        >
          The managed home moves to Lemon trash before configuration is removed.
        </.callout>
      </.confirm_dialog>
    </.page>
    """
  end

  defp apply_pending(socket, %{action: :create} = pending) do
    case profile_get(pending.target_id) do
      {:error, :not_found} -> apply_write(socket, pending, "profiles.create", pending.attrs)
      _ -> stale(socket, "That profile ID is no longer available. Refresh and choose another ID.")
    end
  end

  defp apply_pending(socket, %{action: :clone} = pending) do
    with {:ok, source} <- profile_get(pending.source_id),
         true <- secure_equal?(pending.expected_revision, profile_revision(source)),
         {:error, :not_found} <- profile_get(pending.target_id) do
      apply_write(
        socket,
        pending,
        "profiles.clone",
        Map.put(pending.attrs, "sourceId", pending.source_id)
      )
    else
      _ ->
        stale(socket, "The source or destination changed. Refresh and preview the clone again.")
    end
  end

  defp apply_pending(socket, %{action: :rename} = pending) do
    with {:ok, current} <- profile_get(pending.target_id),
         true <- secure_equal?(pending.expected_revision, profile_revision(current)) do
      apply_write(socket, pending, "profiles.rename", %{
        "id" => pending.target_id,
        "name" => pending.attrs["name"]
      })
    else
      _ -> stale(socket, "That profile changed. Refresh and preview the rename again.")
    end
  end

  defp apply_pending(socket, %{action: :delete} = pending) do
    with {:ok, current} <- profile_get(pending.target_id),
         true <- secure_equal?(pending.expected_revision, profile_revision(current)) do
      apply_write(socket, pending, "profiles.delete", %{
        "id" => pending.target_id,
        "confirm" => pending.target_id
      })
    else
      _ -> stale(socket, "That profile changed. Refresh and preview deletion again.")
    end
  end

  defp apply_write(socket, pending, method, params) do
    case Rpc.call(method, params) do
      {:ok, _result} ->
        action = pending.action

        socket =
          socket
          |> assign(:selected_id, selected_after(action, pending))
          |> assign(:pending_change, nil)
          |> assign(:notice, success_notice(action, pending))
          |> assign(:error, nil)
          |> reset_successful_draft(action)
          |> assign(:show_create, socket.assigns.show_create and action != :create)
          |> refresh_profiles()

        {:noreply, socket}

      {:error, error} ->
        {:noreply, assign(socket, :error, friendly_error(error))}
    end
  end

  defp refresh_profiles(socket) do
    profiles =
      case Rpc.call("profiles.list") do
        {:ok, %{"profiles" => list}} when is_list(list) ->
          list |> Enum.take(@max_profiles) |> Enum.flat_map(&sanitize_profile/1)

        _ ->
          []
      end

    selected_id = choose_selected(socket.assigns.selected_id, profiles)
    selected = Enum.find(profiles, &(&1.id == selected_id))

    socket
    |> assign(:profiles, profiles)
    |> assign(:filtered_profiles, filter_profiles(profiles, socket.assigns.filter))
    |> assign(:profile_count, length(profiles))
    |> assign(:availability_counts, Enum.frequencies_by(profiles, & &1.availability))
    |> assign(:selected_id, selected_id)
    |> assign(:selected, selected)
    |> maybe_seed_selected_drafts(selected)
  end

  defp sanitize_profile(profile) when is_map(profile) do
    with id when is_binary(id) <- profile["id"],
         true <- Regex.match?(@id_regex, id),
         name when is_binary(name) <- profile["name"],
         session when is_binary(session) <- profile["canonicalSessionKey"],
         node when is_binary(node) <- profile["node"],
         true <- Regex.match?(@node_regex, node) do
      [
        %{
          id: id,
          name: bounded_draft(name, @max_name_bytes),
          model: optional_display(profile["model"], @max_model_bytes),
          node: node,
          status: optional_display(profile["status"], 64) || "active",
          canonical_session_key: session,
          availability: availability(node)
        }
      ]
    else
      _ -> []
    end
  end

  defp sanitize_profile(_), do: []

  defp availability("local"), do: "local"

  defp availability(node) do
    if Process.whereis(NodeRegistry) != nil and NodeRegistry.online?(node),
      do: "online",
      else: "offline"
  catch
    :exit, _ -> "offline"
  end

  defp profile_revision(profile) do
    ~w(version id name description avatar model systemPrompt node status createdAt updatedAt canonicalSessionKey)
    |> Enum.map(&Map.get(profile, &1))
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The method's projection carries the same revision fields as the store record.
  defp profile_get(id) do
    case Rpc.call("profiles.get", %{"id" => id}) do
      {:ok, %{"profile" => profile}} when is_map(profile) -> {:ok, profile}
      {:error, %{code: :not_found}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  defp preview_ready(socket, pending) do
    socket
    |> assign(:pending_change, pending)
    |> assign(:notice, nil)
    |> assign(:error, nil)
  end

  defp reject_preview(socket, message) do
    socket
    |> assign(:pending_change, nil)
    |> assign(:notice, nil)
    |> assign(:error, message)
  end

  defp stale(socket, message) do
    drafts = %{
      create: socket.assigns.create_draft,
      clone: socket.assigns.clone_draft,
      rename: socket.assigns.rename_draft
    }

    {:noreply,
     socket
     |> assign(:pending_change, nil)
     |> assign(:notice, nil)
     |> assign(:error, message)
     |> refresh_profiles()
     |> assign(:create_draft, drafts.create)
     |> assign(:clone_draft, drafts.clone)
     |> assign(:rename_draft, drafts.rename)}
  end

  defp validate_new_profile(draft) do
    with :ok <- validate_id(draft["id"]),
         false <- draft["id"] == "default",
         :ok <- validate_name(draft["name"]),
         :ok <- validate_optional(draft["model"], @max_model_bytes, "Model is too long."),
         true <- Regex.match?(@node_regex, draft["node"]) do
      :ok
    else
      true -> {:error, "The default profile is reserved."}
      false -> {:error, "Enter a valid execution node name."}
      {:error, _} = error -> error
    end
  end

  defp validate_id(id) do
    if is_binary(id) and Regex.match?(@id_regex, id),
      do: :ok,
      else: {:error, "Use 1–64 lowercase letters, numbers, hyphens, or underscores for the ID."}
  end

  defp validate_name(name) do
    if is_binary(name) and name != "" and byte_size(name) <= @max_name_bytes,
      do: :ok,
      else: {:error, "Enter a display name up to 256 bytes."}
  end

  defp validate_optional("", _max, _message), do: :ok

  defp validate_optional(value, max, _message) when is_binary(value) and byte_size(value) <= max,
    do: :ok

  defp validate_optional(_value, _max, message), do: {:error, message}

  defp normalize_profile_draft(params, defaults) do
    %{
      "id" => normalize_id(params["id"] || defaults["id"]),
      "name" => bounded_draft(params["name"] || defaults["name"], @max_name_bytes),
      "model" => bounded_draft(params["model"] || defaults["model"], @max_model_bytes),
      "node" => bounded_draft(params["node"] || defaults["node"], 128)
    }
  end

  defp attrs(draft) do
    draft
    |> Enum.reject(fn {key, value} -> key == "model" and value == "" end)
    |> Map.new()
  end

  defp normalize_id(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase() |> String.slice(0, 64)

  defp normalize_id(_), do: ""

  defp bounded_draft(value, max) when is_binary(value) do
    value
    |> String.trim()
    |> then(fn trimmed ->
      if byte_size(trimmed) <= max, do: trimmed, else: binary_part(trimmed, 0, max)
    end)
  rescue
    _ -> ""
  end

  defp bounded_draft(_value, _max), do: ""

  defp optional_display(value, max) when is_binary(value) do
    case bounded_draft(value, max) do
      "" -> nil
      safe -> safe
    end
  end

  defp optional_display(_value, _max), do: nil

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp filter_profiles(profiles, ""), do: profiles

  defp filter_profiles(profiles, filter) do
    query = String.downcase(filter)

    Enum.filter(profiles, fn profile ->
      Enum.any?([profile.id, profile.name, profile.model, profile.node], fn
        value when is_binary(value) -> String.contains?(String.downcase(value), query)
        _ -> false
      end)
    end)
  end

  defp choose_selected(selected_id, profiles) do
    if Enum.any?(profiles, &(&1.id == selected_id)),
      do: selected_id,
      else: profiles |> List.first() |> then(&(&1 && &1.id))
  end

  defp maybe_seed_selected_drafts(socket, nil), do: socket

  defp maybe_seed_selected_drafts(socket, profile) do
    socket
    |> assign(:rename_draft, %{"name" => profile.name})
    |> assign(:clone_draft, clone_defaults(profile))
  end

  defp clone_defaults(profile) do
    %{
      "id" => "",
      "name" => "#{profile.name} copy",
      "model" => profile.model || "",
      "node" => profile.node
    }
  end

  defp reset_successful_draft(socket, :create), do: assign(socket, :create_draft, @empty_create)
  defp reset_successful_draft(socket, :clone), do: assign(socket, :clone_draft, @empty_clone)
  defp reset_successful_draft(socket, _action), do: socket

  defp selected_after(:delete, _pending), do: nil
  defp selected_after(_action, pending), do: pending.target_id

  defp success_notice(:create, pending),
    do: "Profile #{pending.target_id} created with an isolated home and stable chat."

  defp success_notice(:clone, pending),
    do: "Profile #{pending.target_id} cloned into a new isolated home."

  defp success_notice(:rename, pending),
    do: "Profile #{pending.target_id} renamed; its stable chat did not change."

  defp success_notice(:delete, pending),
    do: "Profile #{pending.target_id} deleted; its managed home was moved to Lemon trash."

  # Only the method's fixed error code is interpreted; its text never reaches the page.
  defp friendly_error(%{code: :conflict}),
    do: "That profile ID already exists. Refresh and choose another ID."

  defp friendly_error(%{code: :not_found}),
    do: "That profile is no longer available. Refresh and try again."

  defp friendly_error(%{code: :unavailable}),
    do: "Profile service is unavailable. Nothing changed."

  defp friendly_error(_error), do: "The profile change was refused. Nothing changed."

  defp preview_sentence(%{action: :create}),
    do: "Create one canonical profile, isolated workspace, and stable main chat."

  defp preview_sentence(%{action: :clone}),
    do: "Copy the selected profile metadata and safe regular home files into a new profile."

  defp preview_sentence(%{action: :rename}),
    do: "Change only the display name; keep the stable ID and canonical chat."

  defp preview_sentence(%{action: :delete}),
    do:
      "Remove the profile from active configuration after moving its managed home to recoverable trash."

  defp availability_tone("offline"), do: "warning"
  defp availability_tone("local"), do: "accent"
  defp availability_tone(_), do: "success"
end
