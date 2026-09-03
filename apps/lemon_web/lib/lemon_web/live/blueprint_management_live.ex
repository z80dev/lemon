defmodule LemonWeb.BlueprintManagementLive do
  @moduledoc """
  Authenticated, content-free management for portable automation blueprints.

  The LiveView keeps only allowlisted catalog metadata and exact plan fields in
  socket state. Catalog resolution, validation, digest binding, mutation, and
  create-once behavior remain owned by `LemonAutomation.Blueprint.Catalog`.
  """

  use LemonWeb, :live_view

  alias LemonAutomation.Blueprint.Catalog

  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @digest_regex ~r/^[a-f0-9]{64}$/
  @max_bundles 64

  @empty_summary %{
    "bundleCount" => 0,
    "invalidBundleCount" => 0,
    "truncated" => false
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Automation blueprints · Lemon Management")
     |> assign(:bundles, [])
     |> assign(:catalog_summary, @empty_summary)
     |> assign(:catalog_available?, false)
     |> assign(:selected, nil)
     |> assign(:validation, nil)
     |> assign(:profile_draft, "")
     |> assign(:pending_preview, nil)
     |> assign(:activation, nil)
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_catalog()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> clear_plan()
     |> assign(:selected, nil)
     |> assign(:validation, nil)
     |> assign(:activation, nil)
     |> assign(:notice, "Blueprint catalog refreshed. Select a bundle to continue.")
     |> assign(:error, nil)
     |> refresh_catalog()}
  end

  def handle_event("inspect", %{"bundle" => bundle_id}, socket) do
    bundle_id = normalize_id(bundle_id)

    if catalog_bundle?(socket, bundle_id) do
      case catalog_call(:inspect, [bundle_id]) do
        {:ok, payload} ->
          case sanitize_bundle(payload) do
            {:ok, selected} ->
              {:noreply,
               socket
               |> clear_plan()
               |> assign(:selected, selected)
               |> assign(:validation, nil)
               |> assign(:activation, nil)
               |> assign(:notice, "Bundle metadata inspected without loading source content.")
               |> assign(:error, nil)}

            :error ->
              {:noreply, operation_failed(socket, :inspect)}
          end

        {:error, reason} ->
          {:noreply, assign(socket, :error, catalog_error(reason, :inspect))}
      end
    else
      {:noreply, assign(socket, :error, "That catalog bundle is no longer available.")}
    end
  end

  def handle_event("validate", _params, %{assigns: %{selected: nil}} = socket) do
    {:noreply, assign(socket, :error, "Select a catalog bundle before validating it.")}
  end

  def handle_event("validate", _params, socket) do
    bundle_id = socket.assigns.selected.id

    case catalog_call(:validate, [bundle_id]) do
      {:ok, payload} ->
        case sanitize_validation(payload, bundle_id) do
          {:ok, validation} ->
            {:noreply,
             socket
             |> clear_plan()
             |> assign(:validation, validation)
             |> assign(:activation, nil)
             |> assign(
               :notice,
               "Bundle passed manifest, policy, lint, and deterministic audit checks."
             )
             |> assign(:error, nil)}

          :error ->
            {:noreply, operation_failed(socket, :validate)}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_plan()
         |> assign(:error, catalog_error(reason, :validate))}
    end
  end

  def handle_event("change-profile", %{"preview" => params}, socket) do
    profile_id = normalize_draft(params["profile_id"])

    {:noreply,
     socket
     |> assign(:profile_draft, profile_id)
     |> clear_plan()
     |> assign(:activation, nil)
     |> assign(:notice, nil)
     |> assign(:error, nil)}
  end

  def handle_event("preview", _params, %{assigns: %{selected: nil}} = socket) do
    {:noreply, assign(socket, :error, "Select a catalog bundle before previewing activation.")}
  end

  def handle_event("preview", %{"preview" => params}, socket) do
    profile_id = normalize_draft(params["profile_id"])
    socket = assign(socket, :profile_draft, profile_id)

    if Regex.match?(@id_regex, profile_id) do
      bundle_id = socket.assigns.selected.id

      case catalog_call(:preview, [bundle_id, profile_id]) do
        {:ok, payload} ->
          case sanitize_preview(payload, bundle_id, profile_id) do
            {:ok, preview} ->
              notice =
                if preview.can_activate,
                  do: "Exact activation preview is ready. No profile or schedule state changed.",
                  else: "Preview found a collision. Nothing changed."

              {:noreply,
               socket
               |> assign(:pending_preview, preview)
               |> assign(:activation, nil)
               |> assign(:notice, notice)
               |> assign(:error, nil)}

            :error ->
              {:noreply, operation_failed(socket, :preview)}
          end

        {:error, reason} ->
          {:noreply,
           socket
           |> clear_plan()
           |> assign(:error, catalog_error(reason, :preview))}
      end
    else
      {:noreply,
       socket
       |> clear_plan()
       |> assign(
         :error,
         "Enter a profile ID using lowercase letters, numbers, hyphens, or underscores."
       )}
    end
  end

  def handle_event("cancel-preview", _params, socket) do
    {:noreply,
     socket
     |> clear_plan()
     |> assign(:notice, "Preview dismissed. Your profile draft was kept.")
     |> assign(:error, nil)}
  end

  def handle_event("activate", _params, %{assigns: %{pending_preview: nil}} = socket) do
    {:noreply, assign(socket, :error, "Create a fresh activation preview first.")}
  end

  def handle_event("activate", %{"activation" => params}, socket) do
    preview = socket.assigns.pending_preview
    supplied = normalize_digest(params["confirmation_digest"])

    cond do
      not preview.can_activate ->
        {:noreply,
         assign(socket, :error, "This preview contains a collision and cannot be activated.")}

      supplied != preview.confirmation_digest ->
        {:noreply,
         assign(
           socket,
           :error,
           "Exact digest did not match. Nothing changed; your draft and preview were kept."
         )}

      true ->
        apply_activation(socket, preview)
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
            <h1 class="mt-1 text-lg font-semibold text-slate-900 sm:text-xl">
              Automation blueprints
            </h1>
            <p class="mt-1 text-sm text-slate-600">
              Inspect audited local bundles, preview their exact profile plan, then confirm by digest.
            </p>
          </div>
          <nav aria-label="Management sections" class="management-header-actions">
            <.link href={~p"/manage"} class="management-secondary-link">Sessions</.link>
            <.link href={~p"/manage/providers"} class="management-secondary-link">Providers</.link>
            <.link href={~p"/manage/profiles"} class="management-secondary-link">Profiles</.link>
            <.link href={~p"/"} class="management-secondary-link">Open chat</.link>
            <button type="button" phx-click="refresh" class="management-primary-button">
              Refresh catalog
            </button>
          </nav>
        </header>

        <section aria-labelledby="blueprint-status-title" class="management-status-grid">
          <h2 id="blueprint-status-title" class="sr-only">Blueprint catalog status</h2>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Catalog</p>
            <div class="management-status-line">
              <span class={status_dot_class(@catalog_available?)} aria-hidden="true"></span>
              <strong>{if @catalog_available?, do: "Available", else: "Unavailable"}</strong>
            </div>
            <p class="text-xs text-slate-500">Bounded local entries only</p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Bundles</p>
            <p class="management-status-value">{@catalog_summary["bundleCount"]} valid</p>
            <p class="text-xs text-slate-500">
              {@catalog_summary["invalidBundleCount"]} invalid hidden from selection
            </p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Activation</p>
            <p class="management-status-value">Preview first</p>
            <p class="text-xs text-slate-500">Fresh 64-character digest required</p>
          </div>
        </section>

        <div id="blueprint-feedback" aria-live="polite" class="management-feedback">
          <%= if @notice do %>
            <p class="management-notice">{@notice}</p>
          <% end %>
          <%= if @error do %>
            <p role="alert" class="management-error">{@error}</p>
          <% end %>
        </div>

        <%= if @pending_preview do %>
          <section id="blueprint-activation-preview" aria-labelledby="blueprint-preview-title" class="blueprint-preview">
            <div class="blueprint-preview-summary">
              <p class="text-xs font-medium uppercase tracking-wide text-amber-700">Exact preview</p>
              <h2 id="blueprint-preview-title" class="font-semibold text-slate-950">
                {@pending_preview.bundle_id} → {@pending_preview.profile_id}
              </h2>
              <p class="mt-1 text-sm text-slate-700">
                {preview_sentence(@pending_preview)}
              </p>
              <dl class="blueprint-plan-facts">
                <div><dt>Skills</dt><dd>{length(@pending_preview.skills)}</dd></div>
                <div><dt>Schedule action</dt><dd>{@pending_preview.automation.action}</dd></div>
                <div><dt>Can activate</dt><dd>{yes_no(@pending_preview.can_activate)}</dd></div>
              </dl>
            </div>
            <%= if @pending_preview.can_activate do %>
              <.form
                for={to_form(%{"confirmation_digest" => ""}, as: :activation)}
                id="blueprint-activation-form"
                phx-submit="activate"
                class="blueprint-confirmation-form"
              >
                <label for="activation_confirmation_digest" class="provider-label">
                  Type this exact digest to activate
                </label>
                <code id="blueprint-confirmation-digest" class="blueprint-digest">
                  {@pending_preview.confirmation_digest}
                </code>
                <input
                  id="activation_confirmation_digest"
                  name="activation[confirmation_digest]"
                  type="text"
                  autocomplete="off"
                  autocapitalize="none"
                  spellcheck="false"
                  minlength="64"
                  maxlength="64"
                  pattern="[a-f0-9]{64}"
                  aria-describedby="blueprint-confirmation-digest"
                  class="management-input blueprint-digest-input"
                />
                <div class="provider-form-actions">
                  <button type="submit" class="management-primary-button">Activate exact plan</button>
                  <button type="button" phx-click="cancel-preview" class="management-secondary-button">
                    Keep profile, cancel preview
                  </button>
                </div>
              </.form>
            <% else %>
              <div class="blueprint-collision" role="status">
                Resolve the existing destination or schedule collision, then preview again.
                <button type="button" phx-click="cancel-preview" class="management-secondary-button">
                  Dismiss preview
                </button>
              </div>
            <% end %>
          </section>
        <% end %>

        <%= if @activation do %>
          <section id="blueprint-activation-result" aria-labelledby="activation-result-title" class="management-panel blueprint-result">
            <div class="management-panel-header">
              <div>
                <p class="text-xs font-medium uppercase tracking-wide text-emerald-700">Activation result</p>
                <h2 id="activation-result-title" class="font-semibold text-slate-900">
                  {@activation.bundle_id} for {@activation.profile_id}
                </h2>
              </div>
              <span class="blueprint-result-badge">{@activation.automation_status}</span>
            </div>
            <p class="blueprint-result-copy">
              {activation_sentence(@activation)} A replay of identical content remains duplicate-safe.
            </p>
          </section>
        <% end %>

        <div class="blueprint-management-grid">
          <section aria-labelledby="catalog-title" class="management-panel blueprint-catalog-panel">
            <div class="management-panel-header">
              <div>
                <h2 id="catalog-title" class="font-semibold text-slate-900">Local catalog</h2>
                <p class="text-xs text-slate-500">Invalid and symlinked entries are never selectable.</p>
              </div>
            </div>
            <ul id="blueprint-catalog-list" class="blueprint-catalog-list">
              <%= if @bundles == [] do %>
                <li class="management-empty">No valid portable blueprints are available.</li>
              <% else %>
                <%= for bundle <- @bundles do %>
                  <li id={"blueprint-#{bundle.id}"} class={blueprint_row_class(@selected, bundle.id)}>
                    <div class="blueprint-row-copy">
                      <strong>{bundle.id}</strong>
                      <span>{bundle.skill_count} skill(s) · {bundle.automation_count} automation</span>
                    </div>
                    <button
                      type="button"
                      phx-click="inspect"
                      phx-value-bundle={bundle.id}
                      class="management-secondary-button"
                    >
                      Inspect
                    </button>
                  </li>
                <% end %>
              <% end %>
            </ul>
          </section>

          <section aria-labelledby="bundle-detail-title" class="management-panel blueprint-detail-panel">
            <%= if @selected do %>
              <div class="management-panel-header">
                <div>
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Selected bundle</p>
                  <h2 id="bundle-detail-title" class="font-semibold text-slate-900">{@selected.id}</h2>
                </div>
                <button type="button" phx-click="validate" class="management-secondary-button">
                  Validate again
                </button>
              </div>
              <div class="blueprint-detail-body">
                <%= if @validation do %>
                  <div id="blueprint-validation" class="blueprint-validation" role="status">
                    <strong>Audit {@validation.audit_status}</strong>
                    <span>Trust: {@validation.trust_level}</span>
                    <span>Commands: blocked</span>
                    <span>Secrets: blocked</span>
                  </div>
                <% end %>
                <section aria-labelledby="bundle-skills-title">
                  <h3 id="bundle-skills-title" class="blueprint-subheading">Skills</h3>
                  <ul class="blueprint-chip-list">
                    <%= for skill <- @selected.skills do %>
                      <li>{skill.key}</li>
                    <% end %>
                  </ul>
                </section>
                <section aria-labelledby="bundle-automation-title">
                  <h3 id="bundle-automation-title" class="blueprint-subheading">Schedule</h3>
                  <%= for automation <- @selected.automations do %>
                    <dl class="blueprint-automation-facts">
                      <div><dt>ID</dt><dd>{automation.id}</dd></div>
                      <div><dt>Schedule</dt><dd>{automation.schedule}</dd></div>
                      <div><dt>Timezone</dt><dd>{automation.timezone}</dd></div>
                      <div><dt>Initially enabled</dt><dd>{yes_no(automation.enabled)}</dd></div>
                    </dl>
                  <% end %>
                </section>
                <.form
                  for={to_form(%{"profile_id" => @profile_draft}, as: :preview)}
                  id="blueprint-preview-form"
                  phx-change="change-profile"
                  phx-submit="preview"
                  class="blueprint-profile-form"
                >
                  <label for="preview_profile_id" class="provider-label">Target profile ID</label>
                  <input
                    id="preview_profile_id"
                    name="preview[profile_id]"
                    type="text"
                    value={@profile_draft}
                    maxlength="64"
                    pattern="[a-z0-9][a-z0-9_-]{0,63}"
                    autocomplete="off"
                    autocapitalize="none"
                    spellcheck="false"
                    placeholder="operator"
                    class="management-input"
                  />
                  <p class="text-xs text-slate-500">
                    Preview reads destination state but does not copy skills or create a schedule.
                  </p>
                  <button type="submit" class="management-primary-button">Preview exact activation</button>
                </.form>
              </div>
            <% else %>
              <div class="management-empty management-empty-inspector">
                <h2 id="bundle-detail-title" class="font-semibold text-slate-800">Choose a blueprint</h2>
                <p class="mt-2 text-sm">Inspect its content-free metadata before targeting a profile.</p>
              </div>
            <% end %>
          </section>
        </div>
      </div>
    </main>
    """
  end

  defp apply_activation(socket, preview) do
    case catalog_call(:activate, [
           preview.bundle_id,
           preview.profile_id,
           preview.confirmation_digest
         ]) do
      {:ok, payload} ->
        case sanitize_activation(payload, preview.bundle_id, preview.profile_id) do
          {:ok, activation} ->
            status = activation.automation_status

            notice =
              if status == "unchanged",
                do:
                  "Blueprint was already active with identical content; no duplicate was created.",
                else: "Blueprint activated through the existing profile and scheduler services."

            {:noreply,
             socket
             |> clear_plan()
             |> assign(:activation, activation)
             |> assign(:notice, notice)
             |> assign(:error, nil)}

          :error ->
            {:noreply, operation_failed(socket, :activate) |> clear_plan()}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_plan()
         |> assign(:activation, nil)
         |> assign(:error, catalog_error(reason, :activate))}
    end
  end

  defp refresh_catalog(socket) do
    case catalog_call(:list, []) do
      {:ok, payload} ->
        case sanitize_catalog(payload) do
          {:ok, bundles, summary} ->
            assign(socket,
              bundles: bundles,
              catalog_summary: summary,
              catalog_available?: true
            )

          :error ->
            unavailable_catalog(socket)
        end

      {:error, _reason} ->
        unavailable_catalog(socket)
    end
  end

  defp unavailable_catalog(socket) do
    socket
    |> assign(bundles: [], catalog_summary: @empty_summary, catalog_available?: false)
    |> assign(
      :error,
      socket.assigns.error ||
        "Blueprint catalog is temporarily unavailable. Use the supported catalog workflow to add a bundle."
    )
  end

  defp catalog_call(action, args) do
    result =
      case Application.get_env(:lemon_web, :blueprint_catalog_fun) do
        fun when is_function(fun, 2) -> fun.(action, args)
        _ -> apply(Catalog, action, args ++ [blueprint_opts()])
      end

    case result do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:error, {_code, _message}} = error -> error
      _ -> {:error, {:unavailable, "Blueprint operation failed"}}
    end
  rescue
    _ -> {:error, {:unavailable, "Blueprint operation failed"}}
  catch
    :exit, _ -> {:error, {:unavailable, "Blueprint operation failed"}}
  end

  defp blueprint_opts, do: Application.get_env(:lemon_web, :blueprint_opts, [])

  defp sanitize_catalog(%{"bundles" => bundles, "summary" => summary})
       when is_list(bundles) and is_map(summary) do
    safe_bundles = bundles |> Enum.take(@max_bundles) |> Enum.flat_map(&sanitize_catalog_entry/1)

    safe_summary = %{
      "bundleCount" => length(safe_bundles),
      "invalidBundleCount" => safe_count(summary["invalidBundleCount"]),
      "truncated" => summary["truncated"] == true
    }

    {:ok, safe_bundles, safe_summary}
  end

  defp sanitize_catalog(_), do: :error

  defp sanitize_catalog_entry(payload) do
    case sanitize_bundle(payload) do
      {:ok, bundle} -> [Map.drop(bundle, [:skills, :automations, :validation])]
      :error -> []
    end
  end

  defp sanitize_bundle(payload) when is_map(payload) do
    with {:ok, id} <- safe_id(payload["id"]),
         {:ok, skills} <- sanitize_skills(payload["skills"]),
         {:ok, automations} <- sanitize_automations(payload["automations"]) do
      summary = payload["summary"] || %{}

      {:ok,
       %{
         id: id,
         skill_count: min(length(skills), safe_count(summary["skillCount"])),
         automation_count: min(length(automations), safe_count(summary["automationCount"])),
         skills: skills,
         automations: automations
       }}
    else
      _ -> :error
    end
  end

  defp sanitize_bundle(_), do: :error

  defp sanitize_validation(payload, expected_id) do
    with {:ok, bundle} <- sanitize_bundle(payload),
         true <- bundle.id == expected_id,
         validation when is_map(validation) <- payload["validation"],
         true <- validation["valid"] == true do
      {:ok,
       %{
         valid: true,
         audit_status: safe_enum(validation["auditStatus"], ["pass"], "pass"),
         trust_level: safe_enum(validation["trustLevel"], ["untrusted"], "untrusted")
       }}
    else
      _ -> :error
    end
  end

  defp sanitize_preview(payload, bundle_id, profile_id) when is_map(payload) do
    with ^bundle_id <- payload["bundleId"],
         %{"id" => ^profile_id} <- payload["profile"],
         {:ok, digest} <- safe_digest(payload["confirmationDigest"]),
         {:ok, skills} <- sanitize_plan_skills(payload["skills"]),
         {:ok, automation} <- sanitize_plan_automation(payload["automation"]) do
      {:ok,
       %{
         bundle_id: bundle_id,
         profile_id: profile_id,
         confirmation_digest: digest,
         can_activate: payload["canActivate"] == true,
         skills: skills,
         automation: automation
       }}
    else
      _ -> :error
    end
  end

  defp sanitize_activation(payload, bundle_id, profile_id) when is_map(payload) do
    with ^bundle_id <- payload["bundleId"],
         ^profile_id <- payload["profileId"],
         skills when is_list(skills) <- payload["skills"],
         %{} = automation <- payload["automation"],
         status when status in ["created", "unchanged"] <- automation["status"] do
      {:ok,
       %{
         bundle_id: bundle_id,
         profile_id: profile_id,
         automation_status: status,
         skill_count: min(length(skills), 16)
       }}
    else
      _ -> :error
    end
  end

  defp sanitize_skills(skills) when is_list(skills) do
    skills
    |> Enum.take(16)
    |> Enum.reduce_while({:ok, []}, fn skill, {:ok, acc} ->
      case safe_id(is_map(skill) && skill["key"]) do
        {:ok, key} -> {:cont, {:ok, [%{key: key} | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, safe} -> {:ok, Enum.reverse(safe)}
      :error -> :error
    end
  end

  defp sanitize_skills(_), do: :error

  defp sanitize_automations(automations) when is_list(automations) do
    automations
    |> Enum.take(1)
    |> Enum.reduce_while({:ok, []}, fn automation, {:ok, acc} ->
      with true <- is_map(automation),
           {:ok, id} <- safe_id(automation["id"]),
           {:ok, schedule} <- safe_schedule(automation["schedule"]),
           "UTC" <- automation["timezone"] do
        item = %{
          id: id,
          schedule: schedule,
          timezone: "UTC",
          enabled: automation["enabled"] == true
        }

        {:cont, {:ok, [item | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, safe} -> {:ok, Enum.reverse(safe)}
      :error -> :error
    end
  end

  defp sanitize_automations(_), do: :error

  defp sanitize_plan_skills(skills) when is_list(skills) do
    skills
    |> Enum.take(16)
    |> Enum.reduce_while({:ok, []}, fn skill, {:ok, acc} ->
      with true <- is_map(skill),
           {:ok, key} <- safe_id(skill["key"]),
           action when action in ["create", "replace", "unchanged", "collision"] <-
             skill["action"] do
        {:cont,
         {:ok,
          [
            %{
              key: key,
              action: action,
              file_count: safe_count(skill["fileCount"]),
              bytes: safe_count(skill["bytes"])
            }
            | acc
          ]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, safe} -> {:ok, Enum.reverse(safe)}
      :error -> :error
    end
  end

  defp sanitize_plan_skills(_), do: :error

  defp sanitize_plan_automation(automation) when is_map(automation) do
    with {:ok, id} <- safe_id(automation["id"]),
         {:ok, schedule} <- safe_schedule(automation["schedule"]),
         action when action in ["create", "unchanged", "collision"] <- automation["action"] do
      {:ok,
       %{
         id: id,
         schedule: schedule,
         timezone: "UTC",
         enabled: automation["enabled"] == true,
         action: action
       }}
    else
      _ -> :error
    end
  end

  defp sanitize_plan_automation(_), do: :error

  defp safe_id(value) when is_binary(value) do
    if Regex.match?(@id_regex, value), do: {:ok, value}, else: :error
  end

  defp safe_id(_), do: :error

  defp safe_digest(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value), do: {:ok, value}, else: :error
  end

  defp safe_digest(_), do: :error

  defp safe_schedule(value) when is_binary(value) do
    if byte_size(value) <= 128 and Regex.match?(~r/^[0-9*?,\/ -]+$/, value),
      do: {:ok, value},
      else: :error
  end

  defp safe_schedule(_), do: :error

  defp safe_count(value) when is_integer(value) and value >= 0, do: min(value, 1_000_000)
  defp safe_count(_), do: 0

  defp safe_enum(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)

  defp normalize_id(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, 64)

  defp normalize_id(_), do: ""

  defp normalize_draft(value), do: normalize_id(value)

  defp normalize_digest(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> String.slice(0, 64)
  end

  defp normalize_digest(_), do: ""

  defp catalog_bundle?(socket, bundle_id) do
    bundle_id != "" and Enum.any?(socket.assigns.bundles, &(&1.id == bundle_id))
  end

  defp catalog_error({code, _message}, operation) when is_atom(code) do
    case code do
      :profile_not_found -> "That profile is not available. Your profile draft was kept."
      :confirmation_mismatch -> "The activation plan changed. Preview again before applying it."
      :staged_bundle_changed -> "The catalog bundle changed during activation. Preview again."
      :conflict -> "The destination changed after preview. Preview the exact plan again."
      :skill_collision -> "A profile skill collision prevents activation. Nothing changed."
      :bundle_not_found -> "That catalog bundle is no longer available."
      :invalid_catalog -> "The blueprint catalog is temporarily unavailable."
      :invalid_bundle_id -> "That catalog bundle is not valid."
      :bundle_id_mismatch -> "That catalog entry does not match its manifest identity."
      :symlink_not_allowed -> "Symlinked catalog entries are not supported."
      _ -> operation_error(operation)
    end
  end

  defp catalog_error(_, operation), do: operation_error(operation)

  defp operation_error(:inspect), do: "Bundle inspection is temporarily unavailable."
  defp operation_error(:validate), do: "Bundle validation is temporarily unavailable."
  defp operation_error(:preview), do: "Activation preview is temporarily unavailable."
  defp operation_error(:activate), do: "Blueprint activation was refused. Nothing changed."

  defp operation_failed(socket, operation) do
    socket
    |> assign(:error, operation_error(operation))
    |> assign(:notice, nil)
  end

  defp clear_plan(socket), do: assign(socket, :pending_preview, nil)

  defp preview_sentence(preview) do
    "#{length(preview.skills)} profile skill action(s) and one #{preview.automation.action} schedule action."
  end

  defp activation_sentence(activation) do
    "Schedule status: #{activation.automation_status}; #{activation.skill_count} skill action(s) completed."
  end

  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"

  defp status_dot_class(true), do: "management-status-dot management-status-dot-ok"
  defp status_dot_class(false), do: "management-status-dot management-status-dot-warning"

  defp blueprint_row_class(%{id: id}, id),
    do: "blueprint-catalog-row blueprint-catalog-row-selected"

  defp blueprint_row_class(_, _), do: "blueprint-catalog-row"
end
