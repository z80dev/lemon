defmodule LemonWeb.ProfileManagementLive do
  @moduledoc """
  Authenticated profile lifecycle management over `LemonCore.ProfileStore`.

  The LiveView keeps only operator-facing profile metadata in socket state.
  Derived paths and system prompts are intentionally excluded. Every mutation
  begins with a read-only preview; stale-sensitive actions bind an opaque hash
  of the current canonical profile and recheck it in constant time immediately
  before delegating the write to `ProfileStore`.
  """

  use LemonWeb, :live_view

  alias LemonCore.{NodeRegistry, ProfileStore}

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
     |> assign(:page_title, "Profiles · Lemon Management")
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
         {:error, :not_found} <- profile_call(:get, [draft["id"]]) do
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

      {:error, :not_found} ->
        {:noreply, reject_preview(socket, "Profile service is unavailable.")}

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
         {:error, :not_found} <- profile_call(:get, [draft["id"]]),
         {:ok, source} <- profile_call(:get, [source_id]) do
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
         {:ok, current} <- profile_call(:get, [id]) do
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
         {:ok, current} <- profile_call(:get, [id]) do
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

  def handle_event("apply-preview", event_params, socket) do
    params = Map.get(event_params, "apply", %{})
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

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" class="management-page">
      <div class="management-container">
        <header class="management-header">
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon</p>
            <h1 class="mt-1 text-lg font-semibold text-slate-900 sm:text-xl">Specialist profiles</h1>
            <p class="mt-1 text-sm text-slate-600">
              Create durable specialists, inspect node availability, and return to one stable chat.
            </p>
          </div>
          <nav aria-label="Management sections" class="management-header-actions">
            <.link href={~p"/manage"} class="management-secondary-link">Sessions</.link>
            <.link href={~p"/manage/providers"} class="management-secondary-link">Providers</.link>
            <.link href={~p"/manage/blueprints"} class="management-secondary-link">Blueprints</.link>
            <.link href={~p"/"} class="management-secondary-link">Open chat</.link>
            <button type="button" phx-click="refresh" class="management-primary-button">Refresh</button>
          </nav>
        </header>

        <section aria-labelledby="profile-status-title" class="management-status-grid">
          <h2 id="profile-status-title" class="sr-only">Profile roster status</h2>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Profiles</p>
            <p class="management-status-value">{@profile_count} durable</p>
            <p class="text-xs text-slate-500">Up to {@max_profiles} shown per runtime.</p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Local</p>
            <p class="management-status-value">{Map.get(@availability_counts, "local", 0)}</p>
            <p class="text-xs text-slate-500">Runs in this Lemon instance.</p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Named nodes</p>
            <p class="management-status-value">
              {Map.get(@availability_counts, "online", 0)} online · {Map.get(@availability_counts, "offline", 0)} offline
            </p>
            <p class="text-xs text-slate-500">Live status from the canonical node registry.</p>
          </div>
        </section>

        <div id="profile-feedback" aria-live="polite" class="management-feedback">
          <%= if @notice do %><p class="management-notice">{@notice}</p><% end %>
          <%= if @error do %><p role="alert" class="management-error">{@error}</p><% end %>
        </div>

        <%= if @pending_change do %>
          <section id="profile-change-preview" aria-labelledby="profile-preview-title" class="profile-preview">
            <div>
              <p class="text-xs font-medium uppercase tracking-wide text-amber-700">Exact preview</p>
              <h2 id="profile-preview-title" class="font-semibold text-slate-950">{@pending_change.label}</h2>
              <p class="mt-1 text-sm text-slate-700">{preview_sentence(@pending_change)}</p>
              <%= if @pending_change.destructive do %>
                <p class="mt-2 text-sm text-rose-800">
                  The managed home moves to Lemon trash before configuration is removed. Type
                  <code>{@pending_change.confirmation}</code> exactly to continue.
                </p>
              <% end %>
            </div>
            <.form
              for={to_form(%{"confirmation" => ""}, as: :apply)}
              id="profile-apply-form"
              phx-submit="apply-preview"
              class="profile-apply-form"
            >
              <%= if @pending_change.destructive do %>
                <label for="apply_confirmation" class="provider-label">Exact profile ID</label>
                <input id="apply_confirmation" name="apply[confirmation]" type="text" autocomplete="off" maxlength="64" class="management-input" />
              <% end %>
              <div class="provider-form-actions">
                <button type="submit" class={if @pending_change.destructive, do: "management-danger-button", else: "management-primary-button"}>Apply exact change</button>
                <button type="button" phx-click="cancel-preview" class="management-secondary-button">Keep draft, cancel preview</button>
              </div>
            </.form>
          </section>
        <% end %>

        <div class="profile-management-grid">
          <section aria-labelledby="profile-list-title" class="management-panel">
            <div class="management-panel-header">
              <div>
                <h2 id="profile-list-title" class="font-semibold text-slate-900">Roster</h2>
                <p class="text-xs text-slate-500">Names, models, and availability only.</p>
              </div>
            </div>
            <.form for={to_form(%{"query" => @filter}, as: :filter)} id="profile-filter-form" phx-change="filter" class="management-filter-form profile-filter-form">
              <label for="filter_query" class="sr-only">Filter profiles</label>
              <input id="filter_query" name="filter[query]" value={@filter} type="search" maxlength="128" placeholder="Filter by ID, name, model, or node" class="management-input" phx-debounce="150" />
            </.form>
            <div id="profile-list" class="management-session-list">
              <%= if @filtered_profiles == [] do %>
                <p class="profile-empty">No profiles match this filter.</p>
              <% end %>
              <%= for profile <- @filtered_profiles do %>
                <button type="button" id={"profile-#{profile.id}"} phx-click="select" phx-value-id={profile.id} class={["profile-roster-row", @selected_id == profile.id && "profile-roster-row-selected"]}>
                  <span class="profile-roster-copy">
                    <strong>{profile.name}</strong>
                    <span class="management-session-key">{profile.id}</span>
                    <span class="profile-roster-meta">{profile.model || "runtime default"} · {profile.node}</span>
                  </span>
                  <span class={availability_class(profile.availability)}>{profile.availability}</span>
                </button>
              <% end %>
            </div>
          </section>

          <section aria-labelledby="profile-detail-title" class="management-panel profile-detail-panel">
            <%= if @selected do %>
              <div class="management-panel-header">
                <div class="management-inspector-heading">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Selected profile</p>
                  <h2 id="profile-detail-title" class="font-semibold text-slate-900">{@selected.name}</h2>
                  <p class="management-session-key">{@selected.id}</p>
                </div>
                <.link href={~p"/sessions/#{@selected.canonical_session_key}"} class="management-primary-link">Open canonical chat</.link>
              </div>
              <dl class="profile-facts">
                <div><dt>Model</dt><dd>{@selected.model || "Runtime default"}</dd></div>
                <div><dt>Node</dt><dd>{@selected.node}</dd></div>
                <div><dt>Availability</dt><dd>{@selected.availability}</dd></div>
                <div><dt>Stable chat</dt><dd><code>{@selected.canonical_session_key}</code></dd></div>
              </dl>

              <div class="profile-form-stack">
                <.form for={to_form(@rename_draft, as: :rename)} id="profile-rename-form" phx-submit="preview-rename" class="profile-form-card">
                  <div><h3>Rename</h3><p>Keep the stable ID and canonical chat.</p></div>
                  <label for="rename_name" class="provider-label">Display name</label>
                  <input id="rename_name" name="rename[name]" value={@rename_draft["name"]} type="text" maxlength="256" required class="management-input" />
                  <button type="submit" class="management-secondary-button">Preview rename</button>
                </.form>

                <.form for={to_form(@clone_draft, as: :clone)} id="profile-clone-form" phx-submit="preview-clone" class="profile-form-card">
                  <div><h3>Clone</h3><p>Copy regular bootstrap and skill files into a new isolated home.</p></div>
                  <div class="profile-form-fields">
                    <label for="clone_id" class="provider-label">New ID</label>
                    <input id="clone_id" name="clone[id]" value={@clone_draft["id"]} type="text" maxlength="64" pattern="[a-z0-9][a-z0-9_-]{0,63}" required class="management-input" />
                    <label for="clone_name" class="provider-label">Display name</label>
                    <input id="clone_name" name="clone[name]" value={@clone_draft["name"]} type="text" maxlength="256" required class="management-input" />
                    <label for="clone_model" class="provider-label">Model (optional)</label>
                    <input id="clone_model" name="clone[model]" value={@clone_draft["model"]} type="text" maxlength="512" class="management-input" />
                    <label for="clone_node" class="provider-label">Node</label>
                    <input id="clone_node" name="clone[node]" value={@clone_draft["node"]} type="text" maxlength="128" required class="management-input" />
                  </div>
                  <button type="submit" class="management-secondary-button">Preview clone</button>
                </.form>

                <div class="profile-delete-card">
                  <div><h3>Recoverable delete</h3><p>Move this profile home to Lemon trash before removing configuration.</p></div>
                  <button type="button" phx-click="preview-delete" phx-value-id={@selected.id} class="management-danger-button">Preview delete</button>
                </div>
              </div>
            <% else %>
              <div class="profile-empty-detail"><h2 id="profile-detail-title">No profile selected</h2><p>Create a specialist or choose one from the roster.</p></div>
            <% end %>
          </section>

          <section aria-labelledby="profile-create-title" class="management-panel profile-create-panel">
            <div class="management-panel-header">
              <div><h2 id="profile-create-title" class="font-semibold text-slate-900">Create a specialist</h2><p class="text-xs text-slate-500">System prompts and credential values stay in terminal-managed configuration.</p></div>
            </div>
            <.form for={to_form(@create_draft, as: :profile)} id="profile-create-form" phx-submit="preview-create" class="profile-create-form">
              <div class="profile-form-fields">
                <label for="profile_id" class="provider-label">Stable ID</label>
                <input id="profile_id" name="profile[id]" value={@create_draft["id"]} type="text" maxlength="64" pattern="[a-z0-9][a-z0-9_-]{0,63}" required class="management-input" />
                <label for="profile_name" class="provider-label">Display name</label>
                <input id="profile_name" name="profile[name]" value={@create_draft["name"]} type="text" maxlength="256" required class="management-input" />
                <label for="profile_model" class="provider-label">Model (optional)</label>
                <input id="profile_model" name="profile[model]" value={@create_draft["model"]} type="text" maxlength="512" placeholder="Use runtime default" class="management-input" />
                <label for="profile_node" class="provider-label">Execution node</label>
                <input id="profile_node" name="profile[node]" value={@create_draft["node"]} type="text" maxlength="128" required class="management-input" />
              </div>
              <button type="submit" class="management-primary-button">Preview profile</button>
            </.form>
          </section>
        </div>
      </div>
    </main>
    """
  end

  defp apply_pending(socket, %{action: :create} = pending) do
    case profile_call(:get, [pending.target_id]) do
      {:error, :not_found} -> apply_write(socket, pending, :create, [pending.attrs])
      _ -> stale(socket, "That profile ID is no longer available. Refresh and choose another ID.")
    end
  end

  defp apply_pending(socket, %{action: :clone} = pending) do
    with {:ok, source} <- profile_call(:get, [pending.source_id]),
         true <- secure_equal?(pending.expected_revision, profile_revision(source)),
         {:error, :not_found} <- profile_call(:get, [pending.target_id]) do
      apply_write(socket, pending, :clone, [pending.source_id, pending.attrs])
    else
      _ ->
        stale(socket, "The source or destination changed. Refresh and preview the clone again.")
    end
  end

  defp apply_pending(socket, %{action: :rename} = pending) do
    with {:ok, current} <- profile_call(:get, [pending.target_id]),
         true <- secure_equal?(pending.expected_revision, profile_revision(current)) do
      apply_write(socket, pending, :rename, [pending.target_id, pending.attrs["name"]])
    else
      _ -> stale(socket, "That profile changed. Refresh and preview the rename again.")
    end
  end

  defp apply_pending(socket, %{action: :delete} = pending) do
    with {:ok, current} <- profile_call(:get, [pending.target_id]),
         true <- secure_equal?(pending.expected_revision, profile_revision(current)) do
      apply_write(socket, pending, :delete, [pending.target_id, [confirm: pending.target_id]])
    else
      _ -> stale(socket, "That profile changed. Refresh and preview deletion again.")
    end
  end

  defp apply_write(socket, pending, action, args) do
    case profile_call(action, args) do
      {:ok, result} ->
        selected_id = selected_after(action, pending, result)

        socket =
          socket
          |> assign(:selected_id, selected_id)
          |> assign(:pending_change, nil)
          |> assign(:notice, success_notice(action, pending))
          |> assign(:error, nil)
          |> reset_successful_draft(action)
          |> refresh_profiles()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error, friendly_error(action, reason))}

      _ ->
        {:noreply, assign(socket, :error, "Profile service is unavailable. Nothing changed.")}
    end
  end

  defp refresh_profiles(socket) do
    profiles =
      case profile_call(:list, []) do
        list when is_list(list) ->
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

  defp profile_call(:delete, [id, delete_opts]) do
    call_profile_store(:delete, [id, Keyword.merge(profile_opts(), delete_opts)])
  end

  defp profile_call(action, args) do
    call_profile_store(action, args ++ [profile_opts()])
  end

  defp call_profile_store(action, args) do
    case Application.get_env(:lemon_web, :profile_store_fun) do
      fun when is_function(fun, 2) -> fun.(action, args)
      _ -> apply(ProfileStore, action, args)
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp profile_opts do
    Application.get_env(:lemon_web, :profile_store_opts, [])
  end

  defp preview_ready(socket, pending) do
    socket
    |> assign(:pending_change, pending)
    |> assign(:notice, "Preview ready. No profile or filesystem state changed.")
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

  defp selected_after(:delete, _pending, _result), do: nil
  defp selected_after(_action, pending, _result), do: pending.target_id

  defp success_notice(:create, pending),
    do: "Profile #{pending.target_id} created with an isolated home and stable chat."

  defp success_notice(:clone, pending),
    do: "Profile #{pending.target_id} cloned into a new isolated home."

  defp success_notice(:rename, pending),
    do: "Profile #{pending.target_id} renamed; its stable chat did not change."

  defp success_notice(:delete, pending),
    do: "Profile #{pending.target_id} deleted; its managed home was moved to Lemon trash."

  defp friendly_error(_action, :already_exists),
    do: "That profile ID already exists. Refresh and choose another ID."

  defp friendly_error(_action, :not_found),
    do: "That profile is no longer available. Refresh and try again."

  defp friendly_error(_action, :reserved_profile), do: "The default profile is reserved."

  defp friendly_error(_action, :confirmation_required),
    do: "Exact profile ID confirmation is required."

  defp friendly_error(_action, _reason), do: "The profile change was refused. Nothing changed."

  defp preview_sentence(%{action: :create}),
    do: "Create one canonical profile, isolated workspace, and stable main chat."

  defp preview_sentence(%{action: :clone}),
    do: "Copy the selected profile metadata and safe regular home files into a new profile."

  defp preview_sentence(%{action: :rename}),
    do: "Change only the display name; keep the stable ID and canonical chat."

  defp preview_sentence(%{action: :delete}),
    do:
      "Remove the profile from active configuration after moving its managed home to recoverable trash."

  defp availability_class("offline"), do: "profile-availability profile-availability-offline"
  defp availability_class(_), do: "profile-availability profile-availability-online"
end
