defmodule LemonWeb.BlueprintManagementLive do
  @moduledoc """
  Authenticated, content-free management for portable automation blueprints.

  The LiveView keeps only allowlisted catalog metadata and exact plan fields in
  socket state. Catalog resolution, validation, digest binding, mutation, and
  create-once behavior remain owned by `LemonAutomation.Blueprint.Catalog`.
  """

  use LemonWeb, :live_view

  alias LemonAutomation.Blueprint.Catalog
  alias Phoenix.LiveView.JS

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
     |> assign(:nav, :blueprints)
     |> assign(:page_title, "Blueprints · Lemon")
     |> assign(:bundles, [])
     |> assign(:catalog_summary, @empty_summary)
     |> assign(:catalog_available?, false)
     |> assign(:selected, nil)
     |> assign(:validation, nil)
     |> assign(:profile_draft, "")
     |> assign(:profile_ids, if(connected?(socket), do: profile_ids(), else: []))
     |> assign(:filter, "")
     |> assign(:pending_preview, nil)
     |> assign(:activation, nil)
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> assign(:outcome_unknown, nil)
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

              # A fresh read of an uncertain target is what unlocks it.
              {:noreply,
               socket
               |> assign(:pending_preview, preview)
               |> assign(:activation, nil)
               |> assign(:notice, notice)
               |> assign(:error, nil)
               |> unlock_target(bundle_id, profile_id)}

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
      locked?(socket, preview) ->
        {:noreply, assign(socket, :error, "Preview this target again before activating it.")}

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

  def handle_event("filter", %{"filter" => value}, socket),
    do: {:noreply, assign(socket, :filter, value |> to_string() |> String.slice(0, 64))}

  def handle_event("dismiss", _params, socket),
    do: {:noreply, assign(socket, notice: nil, error: nil)}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, filter_bundles(assigns.bundles, assigns.filter))

    ~H"""
    <.page wide>
      <div id="blueprints-page" phx-hook="PageKeys" data-search="blueprint-filter" data-group="Blueprints">
        <.page_header
          title="Blueprints"
          icon="layers"
          subtitle="Audited bundles of skills and a schedule. Inspect, validate and preview the exact plan, then activate it by digest."
        >
          <:meta>
            <.badge tone={if @catalog_available?, do: "success", else: "warning"}>
              <.status_dot tone={if @catalog_available?, do: "success", else: "warning"} />
              {if @catalog_available?, do: "Catalog available", else: "Catalog unavailable"}
            </.badge>
            <span class="text-xs text-muted">
              {@catalog_summary["bundleCount"]} valid · {@catalog_summary["invalidBundleCount"]} invalid hidden{if @catalog_summary["truncated"], do: " · truncated"}
            </span>
          </:meta>
          <:actions>
            <.button icon="refresh" phx-click="refresh">Refresh catalog</.button>
          </:actions>
        </.page_header>

        <div id="blueprint-feedback" aria-live="polite" class="empty:hidden">
          <.callout :if={@notice} tone="success" class="mb-4">
            {@notice}
            <:actions>
              <.button size="sm" variant="ghost" icon="x" icon_only aria-label="Dismiss" phx-click="dismiss" />
            </:actions>
          </.callout>
          <.callout :if={@error} tone="danger" class="mb-4">
            {@error}
            <:actions>
              <.button size="sm" variant="ghost" icon="x" icon_only aria-label="Dismiss" phx-click="dismiss" />
            </:actions>
          </.callout>
          <.callout :if={@outcome_unknown} id="blueprint-outcome-unknown" tone="warning" title="Activation outcome unknown" class="mb-4">
            Lemon could not confirm whether blueprint <code>{@outcome_unknown.bundle_id}</code> was
            applied to profile <code>{@outcome_unknown.profile_id}</code>. It may have been applied and
            was not retried. Preview the same target again to read its current state before
            activating anything.
          </.callout>
        </div>

        <.callout
          :if={@activation}
          id="blueprint-activation-result"
          tone="success"
          icon="check-circle"
          title={"#{@activation.bundle_id} → #{@activation.profile_id}"}
          class="mb-4"
        >
          Schedule status: <.badge tone={if @activation.automation_status == "created", do: "success", else: "neutral"}>{@activation.automation_status}</.badge>
          · {@activation.skill_count} skill action(s) completed. A replay of identical content remains duplicate-safe.
        </.callout>

        <div class="grid gap-4 lg:grid-cols-[minmax(18rem,22rem)_minmax(0,1fr)]">
          <.card body_class="p-0">
            <:header>Catalog</:header>
            <:actions><span class="text-xs font-normal text-muted">{length(@visible)} of {length(@bundles)}</span></:actions>
            <form id="blueprint-filter-form" phx-change="filter" phx-submit="filter" class="border-b border-line p-2" role="search">
              <label for="blueprint-filter" class="sr-only">Filter blueprints</label>
              <div class="relative">
                <.icon name="search" class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle" />
                <input
                  id="blueprint-filter"
                  name="filter"
                  type="search"
                  value={@filter}
                  placeholder="Filter bundles…"
                  autocomplete="off"
                  phx-debounce="100"
                  class="input h-8 pl-8 pr-8"
                />
                <.kbd keys="/" class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2" />
              </div>
            </form>
            <ul id="blueprint-catalog-list" class="max-h-[60vh] divide-y divide-line overflow-y-auto scroll-thin" aria-label="Blueprint bundles">
              <li :if={@bundles == []} class="p-4">
                <.empty_state
                  icon="layers"
                  title={if @catalog_available?, do: "No blueprints yet", else: "Catalog unavailable"}
                  description={
                    if @catalog_available?,
                      do: "No valid portable blueprints are available. Add bundles with the supported catalog workflow.",
                      else: "The catalog could not be read. This is not an empty catalog."
                  }
                />
              </li>
              <li :if={@bundles != [] && @visible == []} class="px-4 py-8 text-center text-[13px] text-muted">
                Nothing matches “{@filter}”.
              </li>
              <li :for={bundle <- @visible} id={"blueprint-#{bundle.id}"}>
                <button
                  type="button"
                  phx-click="inspect"
                  phx-value-bundle={bundle.id}
                  aria-current={selected?(@selected, bundle.id) && "true"}
                  class={[
                    "flex w-full items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-surface-2",
                    selected?(@selected, bundle.id) && "bg-accent/10 hover:bg-accent/10"
                  ]}
                >
                  <span class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-line bg-surface-2 text-muted">
                    <.icon name="layers" class="h-4 w-4" />
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block truncate font-mono text-[13px] text-fg">{bundle.id}</span>
                    <span class="block text-xs text-muted">
                      {bundle.skill_count} skill(s) · {bundle.automation_count} schedule
                    </span>
                  </span>
                  <.icon name="chevron-right" class="h-4 w-4 text-subtle" />
                </button>
              </li>
            </ul>
          </.card>

          <.card :if={@selected} id="blueprint-detail" body_class="card-body space-y-5">
            <:header>
              <span id="bundle-detail-title" class="font-mono">{@selected.id}</span>
            </:header>
            <:actions>
              <.button size="sm" icon="shield-check" phx-click="validate">
                {if @validation, do: "Validate again", else: "Validate"}
              </.button>
            </:actions>

            <div :if={@validation} id="blueprint-validation" role="status" class="flex flex-wrap items-center gap-2">
              <.badge tone="success" icon="check">Audit {@validation.audit_status}</.badge>
              <.badge tone="neutral">Trust: {@validation.trust_level}</.badge>
              <.badge tone="neutral" icon="lock">Commands: blocked</.badge>
              <.badge tone="neutral" icon="key">Secrets: blocked</.badge>
            </div>
            <p :if={!@validation} class="text-xs text-muted">
              Metadata only; source content is never loaded here. Validate to run manifest, policy, lint and audit checks.
            </p>

            <section aria-labelledby="bundle-skills-title">
              <h3 id="bundle-skills-title" class="mb-2 text-xs font-semibold uppercase tracking-wider text-subtle">
                Skills · {length(@selected.skills)}
              </h3>
              <ul class="flex flex-wrap gap-1.5">
                <li :for={skill <- @selected.skills} class="badge badge-neutral font-mono">
                  <.icon name="sparkles" class="h-3 w-3" />{skill.key}
                </li>
                <li :if={@selected.skills == []} class="text-xs text-muted">No skills</li>
              </ul>
            </section>

            <section aria-labelledby="bundle-automation-title">
              <h3 id="bundle-automation-title" class="mb-2 text-xs font-semibold uppercase tracking-wider text-subtle">
                Schedule
              </h3>
              <p :if={@selected.automations == []} class="text-xs text-muted">No schedule</p>
              <.key_value :for={automation <- @selected.automations}>
                <:item label="ID"><code class="font-mono text-xs">{automation.id}</code></:item>
                <:item label="Schedule">
                  {LemonWeb.CronText.describe(automation.schedule)}
                  <code class="ml-1 font-mono text-xs text-muted">{automation.schedule}</code>
                </:item>
                <:item label="Timezone">{automation.timezone}</:item>
                <:item label="Initially enabled">{yes_no(automation.enabled)}</:item>
              </.key_value>
            </section>

            <.form
              for={to_form(%{"profile_id" => @profile_draft}, as: :preview)}
              id="blueprint-preview-form"
              phx-change="change-profile"
              phx-submit="preview"
              class="rounded-lg border border-line bg-surface-2/50 p-3"
            >
              <label for="preview_profile_id" class="field-label">Target profile ID</label>
              <div class="flex flex-col gap-2 sm:flex-row">
                <input
                  id="preview_profile_id"
                  name="preview[profile_id]"
                  type="text"
                  value={@profile_draft}
                  maxlength="64"
                  pattern="[a-z0-9][a-z0-9_-]{0,63}"
                  list="blueprint-profile-options"
                  autocomplete="off"
                  autocapitalize="none"
                  spellcheck="false"
                  placeholder="operator"
                  class="input font-mono sm:flex-1"
                />
                <datalist id="blueprint-profile-options">
                  <option :for={id <- @profile_ids} value={id} />
                </datalist>
                <.button type="submit" variant="primary" icon="eye">Preview activation</.button>
              </div>
              <p class="field-hint">
                Preview reads destination state but does not copy skills or create a schedule.
              </p>
            </.form>
          </.card>

          <.card :if={!@selected} body_class="p-4">
            <.empty_state
              icon="layers"
              title="Choose a blueprint"
              description="Inspect its content-free metadata before targeting a profile."
            />
          </.card>
        </div>
      </div>

      <.modal
        :if={@pending_preview}
        id="blueprint-activation-modal"
        show
        size="lg"
        title="Activate blueprint"
        description={"#{@pending_preview.bundle_id} → #{@pending_preview.profile_id}"}
        on_cancel={JS.push("cancel-preview")}
      >
        <section id="blueprint-activation-preview" aria-label="Exact activation plan" class="space-y-4 text-[13px]">
          <p class="text-fg">{preview_sentence(@pending_preview)}</p>
          <div class="overflow-hidden rounded-lg border border-line">
            <table class="table">
              <thead>
                <tr><th>Item</th><th>Action</th><th class="text-right">Files</th></tr>
              </thead>
              <tbody>
                <tr :for={skill <- @pending_preview.skills}>
                  <td><span class="font-mono text-xs">{skill.key}</span> <span class="text-xs text-muted">skill</span></td>
                  <td><.badge tone={plan_tone(skill.action)}>{skill.action}</.badge></td>
                  <td class="text-right tabular-nums text-muted">{skill.file_count}</td>
                </tr>
                <tr>
                  <td>
                    <span class="font-mono text-xs">{@pending_preview.automation.id}</span>
                    <span class="text-xs text-muted">{LemonWeb.CronText.describe(@pending_preview.automation.schedule)}</span>
                  </td>
                  <td><.badge tone={plan_tone(@pending_preview.automation.action)}>{@pending_preview.automation.action}</.badge></td>
                  <td class="text-right text-muted">—</td>
                </tr>
              </tbody>
            </table>
          </div>

          <.form
            :if={@pending_preview.can_activate}
            for={to_form(%{"confirmation_digest" => ""}, as: :activation)}
            id="blueprint-activation-form"
            phx-submit="activate"
            class="space-y-3"
          >
            <div>
              <p class="field-label">Exact plan digest</p>
              <code
                id="blueprint-confirmation-digest"
                class="block select-all break-all rounded-md border border-line bg-surface-2 px-2.5 py-2 font-mono text-xs text-fg"
              >{@pending_preview.confirmation_digest}</code>
            </div>
            <div>
              <label for="activation_confirmation_digest" class="field-label">Type the digest to activate</label>
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
                required
                aria-describedby="blueprint-confirmation-digest"
                class="input font-mono text-xs"
              />
              <p class="field-hint">Any change to the bundle or destination after this preview refuses activation.</p>
            </div>
            <div class="flex justify-end gap-2">
              <.button phx-click="cancel-preview">Keep profile, cancel</.button>
              <.button type="submit" variant="primary" icon="check" mutation phx-disable-with="Activating…">
                Activate exact plan
              </.button>
            </div>
          </.form>

          <div :if={!@pending_preview.can_activate} class="space-y-3">
            <.callout tone="warning" title="Collision">
              Resolve the existing destination or schedule collision, then preview again. Nothing changed.
            </.callout>
            <div class="flex justify-end">
              <.button phx-click="cancel-preview">Dismiss preview</.button>
            </div>
          </div>
        </section>
      </.modal>
    </.page>
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

          # Applied by the owner, but the reply is not a well-formed receipt.
          :error ->
            {:noreply,
             socket
             |> clear_plan()
             |> assign(:activation, nil)
             |> assign(:error, nil)
             |> assign(
               :notice,
               "Blueprint applied; details unavailable. It was not retried; the catalog was refreshed."
             )
             |> refresh_catalog()}
        end

      # The call may have created the profile skills and schedule: never claim
      # nothing changed, never retry, and lock the target until it is read again.
      {:error, :outcome_unknown} ->
        {:noreply,
         socket
         |> clear_plan()
         |> assign(:activation, nil)
         |> assign(:notice, nil)
         |> assign(:error, nil)
         |> assign(:outcome_unknown, %{
           bundle_id: preview.bundle_id,
           profile_id: preview.profile_id
         })
         |> refresh_catalog()}

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

  # Only an explicit `{:error, {code, message}}` is a refusal. A raise, exit or
  # non-conforming reply may follow a completed mutation, so it is
  # `:outcome_unknown`, never "not applied".
  defp catalog_call(action, args) do
    result =
      case Application.get_env(:lemon_web, :blueprint_catalog_fun) do
        fun when is_function(fun, 2) -> fun.(action, args)
        _ -> apply(Catalog, action, args ++ [blueprint_opts()])
      end

    case result do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:error, {:outcome_unknown, _message}} -> {:error, :outcome_unknown}
      {:error, {_code, _message}} = error -> error
      _ -> {:error, :outcome_unknown}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    :exit, _ -> {:error, :outcome_unknown}
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

  defp catalog_error(:outcome_unknown, operation), do: unconfirmed(operation)
  defp catalog_error(_, operation), do: operation_error(operation)

  # Inspect, validate and preview are reads; their unconfirmed result is
  # reported as such and they may simply be repeated.
  defp unconfirmed(:inspect),
    do: "Bundle inspection could not be confirmed. Refresh and try again."

  defp unconfirmed(:validate),
    do: "Bundle validation could not be confirmed. Refresh and try again."

  defp unconfirmed(:preview),
    do: "Activation preview could not be confirmed. Refresh and try again."

  defp operation_error(:inspect), do: "Bundle inspection is temporarily unavailable."
  defp operation_error(:validate), do: "Bundle validation is temporarily unavailable."
  defp operation_error(:preview), do: "Activation preview is temporarily unavailable."

  defp operation_error(:activate),
    do: "Blueprint activation was refused. Preview the target again before retrying."

  defp operation_failed(socket, operation) do
    socket
    |> assign(:error, operation_error(operation))
    |> assign(:notice, nil)
  end

  defp clear_plan(socket), do: assign(socket, :pending_preview, nil)

  defp locked?(
         %{assigns: %{outcome_unknown: %{bundle_id: bundle, profile_id: profile}}},
         preview
       ),
       do: preview.bundle_id == bundle and preview.profile_id == profile

  defp locked?(_socket, _preview), do: false

  defp unlock_target(socket, bundle_id, profile_id) do
    if locked?(socket, %{bundle_id: bundle_id, profile_id: profile_id}),
      do: assign(socket, :outcome_unknown, nil),
      else: socket
  end

  defp preview_sentence(preview) do
    "#{length(preview.skills)} profile skill action(s) and one #{preview.automation.action} schedule action."
  end

  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"

  defp selected?(%{id: id}, id), do: true
  defp selected?(_, _), do: false

  defp plan_tone(action) when action in ["create", "replace"], do: "info"
  defp plan_tone("collision"), do: "danger"
  defp plan_tone(_), do: "neutral"

  defp filter_bundles(bundles, filter) do
    case filter |> String.trim() |> String.downcase() do
      "" -> bundles
      needle -> Enum.filter(bundles, &String.contains?(&1.id, needle))
    end
  end

  # Profile IDs for the target-profile suggestions; nothing else is kept.
  defp profile_ids do
    case LemonWeb.Rpc.call("profiles.list", %{}) do
      {:ok, %{"profiles" => profiles}} when is_list(profiles) ->
        profiles
        |> Enum.map(&(is_map(&1) && &1["id"]))
        |> Enum.filter(&(is_binary(&1) and Regex.match?(@id_regex, &1)))
        |> Enum.take(50)

      _ ->
        []
    end
  end
end
