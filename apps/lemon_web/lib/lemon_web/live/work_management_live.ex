defmodule LemonWeb.WorkManagementLive do
  @moduledoc """
  Operator automation workspace: kanban boards, goal loops and cron jobs.

  All controls use canonical services through `LemonWeb.WorkProjection`.
  Confirmation retains only exact safe targets and opaque revisions
  server-side; stale previews never reach a mutation and unknown outcomes are
  never retried. Cron/goal Bus events trigger a debounced refresh; a
  connected-only three-second timer covers the dispatcher, which emits none.
  Prompts and objectives typed into the create/edit forms are passed straight
  to the service and never stored in socket state.
  """
  use LemonWeb, :live_view

  alias LemonCore.Bus
  alias LemonWeb.{CronText, Rpc, WorkProjection}
  alias Phoenix.LiveView.JS

  @tabs [
    {:boards, "Kanban", "kanban"},
    {:goals, "Goals", "target"},
    {:cron, "Cron", "calendar-clock"}
  ]
  @tick_ms 3_000
  @event_debounce_ms 200

  @impl true
  def mount(_params, _session, socket) do
    _ =
      if connected?(socket) do
        Bus.subscribe("cron")
        Bus.subscribe("goals")
        Process.send_after(self(), :work_tick, @tick_ms)
      end

    {:ok,
     assign(socket,
       nav: :automation,
       page_title: "Automation · Lemon",
       tab: :boards,
       work: WorkProjection.snapshot(),
       preview: nil,
       uncertain: MapSet.new(),
       filter: "",
       runs_for: nil,
       cron_form: nil,
       goal_form: nil,
       refresh_pending: false,
       notice: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, tab: parse_tab(params["tab"]) || socket.assigns.tab)}
  end

  @impl true
  def handle_info(:work_tick, socket) do
    Process.send_after(self(), :work_tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  def handle_info(:event_refresh, socket),
    do: {:noreply, socket |> assign(refresh_pending: false) |> refresh()}

  def handle_info(%LemonCore.Event{} = event, socket) do
    case project(event) do
      {name, _payload} when name != "tick" -> {:noreply, schedule_refresh(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp project(event) do
    LemonControlPlane.EventBridge.project(event)
  rescue
    _ -> nil
  end

  defp schedule_refresh(%{assigns: %{refresh_pending: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :event_refresh, @event_debounce_ms)
    assign(socket, refresh_pending: true)
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) do
    case parse_tab(tab) do
      nil ->
        {:noreply, socket}

      key ->
        {:noreply,
         socket
         |> assign(tab: key, preview: nil)
         |> push_patch(to: ~p"/automation?#{[tab: key]}", replace: true)}
    end
  end

  def handle_event("refresh", _, socket), do: {:noreply, refresh(socket)}

  def handle_event("filter", %{"filter" => value}, socket),
    do: {:noreply, assign(socket, filter: value |> to_string() |> String.slice(0, 96))}

  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, notice: nil, error: nil)}
  def handle_event("cancel-preview", _, socket), do: {:noreply, assign(socket, preview: nil)}

  def handle_event("open-runs", %{"id" => id}, socket) do
    case WorkProjection.target(socket.assigns.work, :cron, id) do
      nil -> {:noreply, socket}
      _row -> {:noreply, assign(socket, runs_for: id)}
    end
  end

  # The drawer is hidden while a confirmation is open; a click-away that lands
  # during its exit transition must not discard it.
  def handle_event("close-runs", _, %{assigns: %{preview: nil}} = socket),
    do: {:noreply, assign(socket, runs_for: nil)}

  def handle_event("close-runs", _, socket), do: {:noreply, socket}

  def handle_event("preview", %{"kind" => kind, "id" => id, "action" => action} = params, socket) do
    previous = socket.assigns.work
    socket = refresh(socket)
    kind = parse_kind(kind)
    old = kind && WorkProjection.target(previous, kind, id)
    row = kind && WorkProjection.target(socket.assigns.work, kind, id)
    run_id = params["run"]

    if old && row && allowed?(row, action, run_id) &&
         not MapSet.member?(socket.assigns.uncertain, {kind, id}) do
      {:noreply,
       assign(socket,
         preview: %{row: row, action: action, run_id: run_id},
         error: nil,
         notice: nil
       )}
    else
      {:noreply,
       assign(socket,
         preview: nil,
         error: "This control is unavailable. Refresh and inspect the current state."
       )}
    end
  end

  def handle_event("confirm", _, %{assigns: %{preview: nil}} = socket) do
    {:noreply, assign(socket, error: "Preview the exact action before confirming.")}
  end

  def handle_event("confirm", _, socket) do
    preview = socket.assigns.preview
    socket = refresh(socket) |> assign(preview: nil, notice: nil, error: nil)
    row = WorkProjection.target(socket.assigns.work, preview.row.kind, preview.row.id)

    if row && row.revision == preview.row.revision && row == preview.row &&
         allowed?(row, preview.action, preview.run_id) do
      case WorkProjection.execute(row, preview.action, preview.run_id) do
        :ok ->
          {:noreply,
           socket
           |> refresh()
           |> assign(
             runs_for: if(preview.action == "remove", do: nil, else: socket.assigns.runs_for),
             notice: "#{action_label(preview.action)} accepted by the shared service."
           )}

        {:error, :outcome_unknown} ->
          {:noreply,
           socket
           |> refresh()
           |> assign(
             uncertain: MapSet.put(socket.assigns.uncertain, {row.kind, row.id}),
             error:
               "Outcome unknown. The action may have taken effect; it was not retried. Controls for this target are locked on this page. Inspect live state before taking further action."
           )}

        {:error, :stale} ->
          {:noreply, assign(socket, error: stale_message())}

        {:error, _} ->
          {:noreply,
           assign(socket,
             error: "The shared service refused this action. No automatic retry was made."
           )}
      end
    else
      {:noreply, assign(socket, error: stale_message())}
    end
  end

  # ── Cron create / edit ────────────────────────────────────────────────────

  def handle_event("new-cron", _, socket) do
    values = %{
      "name" => "",
      "schedule" => "daily at 9am",
      "timezone" => "UTC",
      "agent" => "default",
      "timeout_minutes" => "5",
      "enabled" => "true"
    }

    {:noreply,
     socket
     |> assign(cron_form: cron_form(:create, nil, values, agents()), notice: nil, error: nil)}
  end

  def handle_event("edit-cron", %{"id" => id}, socket) do
    socket = refresh(socket)

    case WorkProjection.target(socket.assigns.work, :cron, id) do
      %{runtime: "ready"} = row ->
        if MapSet.member?(socket.assigns.uncertain, {:cron, id}) do
          {:noreply,
           assign(socket, error: "Controls for this job are locked after an unknown outcome.")}
        else
          values = %{
            "name" => row.label,
            "schedule" => row.schedule,
            "timezone" => row.timezone,
            "timeout_minutes" => Integer.to_string(div(row.timeout_ms || 300_000, 60_000)),
            "enabled" => to_string(row.status == "enabled")
          }

          {:noreply,
           assign(socket, cron_form: cron_form(:edit, row, values, []), notice: nil, error: nil)}
        end

      _ ->
        {:noreply, assign(socket, error: "This job is unavailable. Refresh and try again.")}
    end
  end

  def handle_event("close-cron-form", _, socket), do: {:noreply, assign(socket, cron_form: nil)}

  def handle_event(
        "schedule-preset",
        %{"preset" => preset},
        %{assigns: %{cron_form: form}} = socket
      )
      when not is_nil(form) do
    {:noreply,
     assign(socket, cron_form: revalidate(form, Map.put(form.values, "schedule", preset)))}
  end

  def handle_event("validate-cron", %{"cron" => params}, %{assigns: %{cron_form: form}} = socket)
      when not is_nil(form) do
    {:noreply, assign(socket, cron_form: revalidate(form, safe_values(params, form)))}
  end

  def handle_event("save-cron", %{"cron" => params}, %{assigns: %{cron_form: form}} = socket)
      when not is_nil(form) do
    case WorkProjection.validate_cron(params, form.mode) do
      {:error, errors} ->
        {:noreply,
         assign(socket,
           cron_form: %{revalidate(form, safe_values(params, form)) | errors: errors}
         )}

      {:ok, attrs} when form.mode == :create ->
        case WorkProjection.create_cron(attrs) do
          {:ok, _id} ->
            {:noreply,
             socket
             |> assign(cron_form: nil, notice: "Cron job created. Next runs are shown below.")
             |> refresh()
             |> push_patch(to: ~p"/automation?tab=cron", replace: true)}

          {:error, :outcome_unknown} ->
            {:noreply,
             socket
             |> assign(cron_form: nil)
             |> refresh()
             |> assign(
               error:
                 "Outcome unknown. The job may have been created; it was not retried. Check the list before creating it again."
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket, cron_form: %{form | errors: %{form: write_message(reason)}})}
        end

      {:ok, attrs} ->
        save_edit(socket, form, attrs)
    end
  end

  # ── Goals ─────────────────────────────────────────────────────────────────

  def handle_event("new-goal", _, socket) do
    {:noreply,
     assign(socket,
       goal_form: %{
         values: %{"session" => "agent:default:main", "max_continuations" => "10"},
         errors: %{}
       },
       notice: nil,
       error: nil
     )}
  end

  def handle_event("close-goal-form", _, socket), do: {:noreply, assign(socket, goal_form: nil)}

  def handle_event("validate-goal", %{"goal" => params}, %{assigns: %{goal_form: form}} = socket)
      when not is_nil(form) do
    {:noreply, assign(socket, goal_form: %{form | values: goal_values(params)})}
  end

  def handle_event("save-goal", %{"goal" => params}, %{assigns: %{goal_form: form}} = socket)
      when not is_nil(form) do
    case WorkProjection.set_goal(params) do
      {:ok, _session} ->
        {:noreply,
         socket
         |> assign(goal_form: nil, notice: "Goal set. Start its loop when you are ready.")
         |> refresh()
         |> push_patch(to: ~p"/automation?tab=goals", replace: true)}

      {:error, errors} when is_map(errors) ->
        {:noreply,
         assign(socket, goal_form: %{form | values: goal_values(params), errors: errors})}

      {:error, :already_running} ->
        {:noreply,
         assign(socket,
           goal_form: %{
             form
             | values: goal_values(params),
               errors: %{
                 form: "That session's goal has active work. Stop it before replacing the goal."
               }
           }
         )}

      {:error, :outcome_unknown} ->
        {:noreply,
         socket
         |> assign(goal_form: nil)
         |> refresh()
         |> assign(error: "Outcome unknown. The goal may have been set; it was not retried.")}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           goal_form: %{
             form
             | values: goal_values(params),
               errors: %{form: write_message(reason)}
           }
         )}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp save_edit(socket, form, attrs) do
    patch =
      attrs
      |> Enum.reject(fn {key, value} ->
        key != :prompt and Map.get(form.initial, key) == value
      end)
      |> Map.new()

    socket = refresh(socket)
    row = WorkProjection.target(socket.assigns.work, :cron, form.row.id)

    cond do
      patch == %{} ->
        {:noreply, assign(socket, cron_form: nil, notice: "Nothing changed.")}

      is_nil(row) or row.revision != form.row.revision ->
        {:noreply, assign(socket, cron_form: %{form | errors: %{form: stale_message()}})}

      true ->
        case WorkProjection.update_cron(form.row, patch) do
          :ok ->
            {:noreply, socket |> assign(cron_form: nil, notice: "Cron job updated.") |> refresh()}

          {:error, :outcome_unknown} ->
            {:noreply,
             socket
             |> assign(
               cron_form: nil,
               uncertain: MapSet.put(socket.assigns.uncertain, {:cron, row.id}),
               error: "Outcome unknown. The update may have taken effect; it was not retried."
             )
             |> refresh()}

          {:error, reason} ->
            {:noreply,
             assign(socket, cron_form: %{form | errors: %{form: write_message(reason)}})}
        end
    end
  end

  defp cron_form(mode, row, values, agents) do
    form = %{
      mode: mode,
      row: row,
      values: values,
      initial: %{},
      errors: %{},
      schedule: nil,
      agents: agents
    }

    form = revalidate(form, values)

    initial =
      case WorkProjection.validate_cron(values, :edit) do
        {:ok, attrs} when mode == :edit -> attrs
        _ -> %{}
      end

    %{form | initial: initial}
  end

  defp revalidate(form, values) do
    %{
      form
      | values: values,
        errors: %{},
        schedule: WorkProjection.schedule_preview(values["schedule"], values["timezone"])
    }
  end

  # Never retain prompt text: only the non-private draft fields are kept.
  defp safe_values(params, form) do
    keys =
      ~w(name schedule timezone timeout_minutes enabled) ++
        if(form.mode == :create, do: ["agent"], else: [])

    Map.new(keys, fn key ->
      {key, params |> Map.get(key, "") |> to_string() |> String.slice(0, 160)}
    end)
  end

  defp goal_values(params) do
    Map.new(~w(session max_continuations), fn key ->
      {key, params |> Map.get(key, "") |> to_string() |> String.slice(0, 256)}
    end)
  end

  defp agents do
    case Rpc.call("agents.list", %{}) do
      {:ok, payload} -> WorkProjection.agent_ids(payload)
      _ -> []
    end
  end

  # ── Render ────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        tabs: @tabs,
        items: filtered(assigns.work[assigns.tab], assigns.tab, assigns.filter),
        now: System.system_time(:millisecond)
      )

    ~H"""
    <.page wide>
      <div
        id="work-dashboard"
        phx-hook="PageKeys"
        data-tabs="boards,goals,cron"
        data-tab-labels="Kanban,Goals,Cron"
        data-search="work-filter"
        data-group="Automation"
      >
        <.page_header
          title="Automation"
          icon="zap"
          subtitle="Kanban boards, goal loops and scheduled jobs on the shared runtime."
        >
          <:meta>
            <span class="inline-flex items-center gap-1.5 text-xs text-muted">
              <.status_dot tone="success" pulse /> Live · cron and goal events, 3s board refresh
            </span>
          </:meta>
          <:actions>
            <.button id="work-refresh" icon="refresh" phx-click="refresh">Refresh</.button>
            <.button id="work-new-goal" icon="target" phx-click="new-goal" mutation>New goal</.button>
            <.button id="work-new-cron" variant="primary" icon="plus" phx-click="new-cron" mutation>
              New cron job
            </.button>
          </:actions>
        </.page_header>

        <div id="work-feedback" aria-live="polite" class="space-y-2 empty:hidden">
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
        </div>

        <div class="mb-4 flex flex-wrap items-end justify-between gap-3 border-b border-line">
          <.tabs active={Atom.to_string(@tab)} label="Automation sections" class="-mb-px overflow-y-hidden border-b-0">
            <:tab
              :for={{key, label, icon} <- @tabs}
              id={Atom.to_string(key)}
              label={label}
              icon={icon}
              click="tab"
              count={tab_count(@work[key])}
            />
          </.tabs>
          <form id="work-filter-form" phx-change="filter" phx-submit="filter" class="mb-2 w-full sm:w-64" role="search">
            <label for="work-filter" class="sr-only">Filter {tab_label(@tab)}</label>
            <div class="relative">
              <.icon name="search" class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle" />
              <input
                id="work-filter"
                name="filter"
                type="search"
                value={@filter}
                placeholder={"Filter #{String.downcase(tab_label(@tab))}…"}
                autocomplete="off"
                phx-debounce="150"
                class="input h-8 pl-8 pr-8"
              />
              <.kbd keys="/" class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2" />
            </div>
          </form>
        </div>

        <section id={"work-panel-#{@tab}"} role="tabpanel" aria-label={tab_label(@tab)}>
          <.callout
            :if={@work[@tab].state == :unavailable}
            id="work-unavailable"
            tone="warning"
            title="Service unavailable"
            class="mb-4"
          >
            The shared service could not be read. This is not an empty or idle state. Controls are disabled until a successful refresh.
          </.callout>

          <div :if={@work[@tab].state == :ready && @work[@tab].items == []} id="work-empty">
            <.empty_state
              icon={tab_icon(@tab)}
              title={"No #{String.downcase(tab_label(@tab))} yet"}
              description={empty_description(@tab)}
            >
              <.button :if={@tab == :cron} variant="primary" icon="plus" phx-click="new-cron" mutation>New cron job</.button>
              <.button :if={@tab == :goals} icon="target" phx-click="new-goal" mutation>New goal</.button>
              <.button :if={@tab == :boards} icon="message-square" navigate={~p"/"}>Open chat</.button>
            </.empty_state>
          </div>

          <p
            :if={@filter != "" && @work[@tab].items != [] && @items == []}
            class="py-10 text-center text-[13px] text-muted"
          >
            Nothing matches “{@filter}”.
          </p>

          <div :if={@tab == :boards} class="space-y-4">
            <.board :for={board <- @items} board={board} uncertain={@uncertain} filter={@filter} now={@now} />
          </div>

          <div :if={@tab == :goals} class="grid gap-3 md:grid-cols-2 2xl:grid-cols-3">
            <.goal :for={goal <- @items} goal={goal} uncertain={@uncertain} now={@now} />
          </div>

          <div :if={@tab == :cron && @items != []} class="card overflow-hidden">
            <div class="hidden grid-cols-[minmax(0,2fr)_minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1fr)_18rem] gap-4 border-b border-line bg-surface-2/60 px-4 py-2 text-2xs font-semibold uppercase tracking-wider text-subtle lg:grid">
              <span>Job</span><span>Schedule</span><span>Next run</span><span>Last run</span><span class="text-right">Actions</span>
            </div>
            <ul class="divide-y divide-line" aria-label="Cron jobs">
              <.cron_row :for={job <- @items} job={job} uncertain={@uncertain} now={@now} />
            </ul>
          </div>

          <p :if={@work[@tab].state == :ready && @work[@tab].items != []} class="mt-4 text-xs text-subtle">
            Showing {length(@items)} of {length(@work[@tab].items)} · bounded to {WorkProjection.limit(@tab)} records{bound_suffix(@tab)}.
            Private instructions and execution output are never shown here.
          </p>
        </section>
      </div>

      <.runs_drawer
        :if={@runs_for && !@preview && WorkProjection.target(@work, :cron, @runs_for)}
        job={WorkProjection.target(@work, :cron, @runs_for)}
        uncertain={@uncertain}
        now={@now}
      />

      <.confirm_dialog
        :if={@preview}
        id="work-confirm-dialog"
        title={"#{action_label(@preview.action)}?"}
        description={preview_subject(@preview.row)}
        confirm_label={action_label(@preview.action)}
        confirm_event="confirm"
        cancel_event="cancel-preview"
        tone={if destructive?(@preview.action), do: "danger", else: "primary"}
      >
        <div id="work-preview" class="space-y-3">
          <.key_value>
            <:item label="Target"><code class="font-mono text-xs">{@preview.row.id}</code></:item>
            <:item :if={@preview.run_id} label="Invocation"><code class="font-mono text-xs">{@preview.run_id}</code></:item>
            <:item :if={@preview.row.kind == :cron} label="Schedule">{@preview.row.schedule_text}</:item>
            <:item :if={@preview.action == "grant-publish"} label="Publication">{@preview.row.publish_summary}</:item>
            <:item :if={@preview.action == "allow-in-place"} label="Workspace fingerprint"><code class="font-mono text-xs">{String.slice(@preview.row.workspace_digest || "", 0, 12)}</code></:item>
          </.key_value>
          <p class="text-fg">{effect(@preview.row.kind, @preview.action)}</p>
          <p class="text-xs text-muted">
            Nothing has changed yet. Any target or invocation drift rejects this confirmation.
          </p>
        </div>
      </.confirm_dialog>

      <.cron_form_modal :if={@cron_form} form={@cron_form} />
      <.goal_form_modal :if={@goal_form} form={@goal_form} goals={@work.goals} />
    </.page>
    """
  end

  # ── Kanban ────────────────────────────────────────────────────────────────

  attr(:board, :map, required: true)
  attr(:uncertain, :any, required: true)
  attr(:filter, :string, required: true)
  attr(:now, :integer, required: true)

  defp board(assigns) do
    assigns = assign(assigns, cards: filter_cards(assigns.board.cards, assigns.filter))

    ~H"""
    <.card id={"work-board-#{@board.id}"} body_class="p-3">
      <:header>
        <div class="flex min-w-0 flex-wrap items-center gap-2">
          <.icon name="kanban" class="h-4 w-4 text-muted" />
          <span class="truncate">{@board.label}</span>
          <code class="hidden truncate font-mono text-2xs font-normal text-subtle sm:inline">{@board.id}</code>
          <.runtime_badge status={@board.runtime} />
          <.badge :if={@board.status == "archived"} tone="neutral">archived</.badge>
          <.badge :if={Map.get(@board, :authority) == "quarantined"} tone="warning">quarantined</.badge>
          <span class="text-xs font-normal text-muted">{@board.running_count} {if @board.running_count == 1, do: "worker", else: "workers"}</span>
        </div>
      </:header>
      <:actions>
        <.controls row={@board} uncertain={@uncertain} />
      </:actions>
      <.callout :if={Map.get(@board, :last_runtime)} tone="warning" class="mb-3">
        Last known dispatcher: {@board.last_runtime}. Showing retained state; controls disabled.
      </.callout>
      <div class="flex gap-3 overflow-x-auto pb-1 scroll-thin">
        <section
          :for={column <- @board.columns}
          aria-label={column}
          class="flex w-[17rem] shrink-0 flex-col rounded-lg border border-line bg-surface-2/50"
        >
          <h3 class="flex items-center justify-between gap-2 px-3 pb-1.5 pt-2.5 text-xs font-semibold text-muted">
            <span class="truncate capitalize">{column}</span>
            <span class="badge badge-neutral h-4 px-1.5 tabular-nums">{Enum.count(@cards, &(&1.status == column))}</span>
          </h3>
          <div class="flex-1 space-y-2 px-2 pb-2">
            <.kanban_card :for={card <- Enum.filter(@cards, &(&1.status == column))} card={card} now={@now} />
            <p :if={not Enum.any?(@cards, &(&1.status == column))} class="px-1 py-3 text-center text-xs text-subtle">
              No cards
            </p>
          </div>
        </section>
      </div>
      <p class="mt-2 px-1 text-2xs text-subtle">
        Up to {WorkProjection.card_limit()} most recently updated cards
      </p>
    </.card>
    """
  end

  attr(:card, :map, required: true)
  attr(:now, :integer, required: true)

  defp kanban_card(assigns) do
    ~H"""
    <article id={"work-card-#{@card.id}"} class="rounded-md border border-line bg-surface p-2.5 shadow-sm">
      <p class="break-words text-[13px] font-medium leading-snug text-fg">{@card.label}</p>
      <div class="mt-2 flex flex-wrap items-center gap-1.5">
        <.badge :if={@card.priority in ["high", "urgent"]} tone={if @card.priority == "urgent", do: "danger", else: "warning"}>
          {@card.priority}
        </.badge>
        <.badge :if={@card.result} tone={tone(@card.result)}>{@card.result}</.badge>
        <.badge :if={@card.needs_retry} tone="warning" icon="refresh">needs retry</.badge>
        <.badge :if={@card.attempt > 1} tone="neutral">attempt {@card.attempt}</.badge>
      </div>
      <div :if={@card.workflow} class="mt-2 space-y-1 border-t border-line pt-2 text-xs text-muted">
        <p class="flex items-center gap-1.5">
          <.icon name="workflow" class="h-3 w-3" /> {String.replace(@card.workflow.phase, "_", " ")}
          <.badge :if={@card.workflow.approved} tone="success" icon="check">Independent review approved</.badge>
        </p>
        <p :if={@card.workflow.branch} class="flex min-w-0 items-center gap-1.5">
          <.icon name="git-branch" class="h-3 w-3" /><code class="truncate font-mono">{@card.workflow.branch}</code>
        </p>
        <p :if={@card.workflow.commit}>commit <code class="font-mono">{String.slice(@card.workflow.commit, 0, 12)}</code></p>
        <div :if={@card.workflow.review_session} class="flex items-center gap-1.5">
          Independent review <.session_link session={@card.workflow.review_session} />
        </div>
        <a
          :if={@card.workflow.pr_url}
          href={@card.workflow.pr_url}
          rel="noopener noreferrer"
          target="_blank"
          class="inline-flex items-center gap-1 font-medium text-accent-text hover:underline"
        >
          Open pull request <.icon name="external-link" class="h-3 w-3" />
        </a>
      </div>
      <div class="mt-2 flex items-center justify-between gap-2 text-2xs text-subtle">
        <code class="truncate font-mono">{@card.id}</code>
        <span :if={@card.updated_at_ms} class="shrink-0">{relative_time(@card.updated_at_ms, @now)}</span>
      </div>
      <.session_link session={@card.session} class="mt-1.5" />
    </article>
    """
  end

  # ── Goals ─────────────────────────────────────────────────────────────────

  attr(:goal, :map, required: true)
  attr(:uncertain, :any, required: true)
  attr(:now, :integer, required: true)

  defp goal(assigns) do
    ~H"""
    <.card id={"work-goal-#{@goal.id}"} body_class="card-body space-y-3">
      <:header>
        <div class="flex min-w-0 items-center gap-2">
          <.icon name="target" class="h-4 w-4 text-muted" />
          <code class="truncate font-mono text-xs">{@goal.id}</code>
        </div>
      </:header>
      <:actions>
        <.badge tone={tone(@goal.status)}>{@goal.status}</.badge>
        <.runtime_badge status={@goal.runtime} />
      </:actions>
      <div>
        <div class="mb-1.5 flex items-baseline justify-between text-xs">
          <span class="text-muted">Progress</span>
          <span class="tabular-nums text-fg">
            {@goal.continuation_count}{if @goal.max_continuations, do: " / #{@goal.max_continuations}"} continuations
          </span>
        </div>
        <.meter
          :if={@goal.max_continuations}
          value={@goal.continuation_count}
          max={@goal.max_continuations}
          auto_tone
          label="Continuation budget used"
        />
      </div>
      <.key_value class="text-xs">
        <:item label="Loop">
          <span class="inline-flex flex-wrap items-center gap-1.5">
            {humanize(@goal.loop_status || "not started")}
            <.badge :if={@goal.last_action} tone={action_tone(@goal.last_action)}>last verdict: {humanize(@goal.last_action)}</.badge>
          </span>
        </:item>
        <:item label="Verdicts">{@goal.verdict_count}</:item>
        <:item label="Auto restart">{if @goal.auto, do: "on", else: "off"}</:item>
        <:item :if={@goal.agent} label="Agent">{@goal.agent}</:item>
        <:item :if={@goal.result} label="Last run"><.badge tone={tone(@goal.result)}>{@goal.result}</.badge></:item>
        <:item :if={@goal.updated_at_ms} label="Updated">{relative_time(@goal.updated_at_ms, @now)}</:item>
      </.key_value>
      <.callout :if={Map.get(@goal, :last_runtime)} tone="warning">
        Last known loop: {@goal.last_runtime}. Showing retained state; controls disabled.
      </.callout>
      <div class="flex flex-wrap items-center justify-between gap-2 border-t border-line pt-3">
        <.session_link session={@goal.session} />
        <.controls row={@goal} uncertain={@uncertain} />
      </div>
      <p class="text-2xs text-subtle">Objective stays private. Start runs at most 3 loop ticks without enabling automatic restart.</p>
    </.card>
    """
  end

  # ── Cron ──────────────────────────────────────────────────────────────────

  attr(:job, :map, required: true)
  attr(:uncertain, :any, required: true)
  attr(:now, :integer, required: true)

  defp cron_row(assigns) do
    assigns =
      assign(assigns,
        locked: MapSet.member?(assigns.uncertain, {:cron, assigns.job.id}),
        actions: WorkProjection.actions(assigns.job),
        active: Enum.find(assigns.job.runs, & &1.abortable),
        latest: List.first(assigns.job.runs)
      )

    ~H"""
    <li
      id={"work-cron-#{@job.id}"}
      class="grid gap-x-4 gap-y-2 px-4 py-3 lg:grid-cols-[minmax(0,2fr)_minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1fr)_18rem] lg:items-center"
    >
      <div class="min-w-0">
        <div class="flex min-w-0 items-center gap-2">
          <.status_dot tone={if @job.status == "enabled", do: "success", else: "neutral"} pulse={WorkProjection.active_run?(@job)} />
          <span class="truncate text-[13px] font-medium text-fg">{@job.label}</span>
          <.badge :if={@job.status == "paused"} tone="neutral">paused</.badge>
          <.badge :if={WorkProjection.active_run?(@job)} tone="info">running</.badge>
        </div>
        <div class="mt-0.5 flex min-w-0 flex-wrap items-center gap-x-2 text-2xs text-subtle">
          <code class="truncate font-mono">{@job.id}</code>
          <span>{@job.mode}{if @job.agent, do: " · #{@job.agent}"}</span>
          <span :if={@job.model}>Model: {@job.model}</span>
        </div>
      </div>
      <div class="min-w-0 text-[13px]">
        <p class="text-fg">{@job.schedule_text}</p>
        <p class="text-2xs text-subtle"><code class="font-mono">{@job.schedule}</code> · {CronText.zone(@job.timezone)}</p>
      </div>
      <div class="text-[13px]">
        <span class="text-2xs text-subtle lg:hidden">Next </span>
        <span :if={@job.next_run_at_ms} class="text-fg" title={absolute(@job.next_run_at_ms)}>{until(@job.next_run_at_ms, @now)}</span>
        <span :if={!@job.next_run_at_ms} class="text-muted">{if @job.status == "paused", do: "Paused", else: "Not scheduled"}</span>
        <p :if={@job.next_run_at_ms} class="text-2xs text-subtle">{absolute(@job.next_run_at_ms)}</p>
      </div>
      <div class="text-[13px]">
        <span class="text-2xs text-subtle lg:hidden">Last </span>
        <.badge :if={@latest} tone={tone(@latest.status)}>{@latest.status}</.badge>
        <span :if={!@latest && @job.runtime != "unavailable"} class="text-muted">Never</span>
        <span :if={@job.runtime == "unavailable"} class="text-warning">Run status unavailable; controls disabled.</span>
        <p :if={@job.last_run_at_ms} class="text-2xs text-subtle">{relative_time(@job.last_run_at_ms, @now)}</p>
      </div>
      <div class="flex flex-wrap items-center gap-1 lg:flex-nowrap lg:justify-end">
        <.button
          :if={@active}
          id={"work-row-abort-#{@active.id}"}
          size="sm"
          variant="danger-soft"
          icon="square"
          mutation
          disabled={@locked}
          phx-click="preview"
          phx-value-kind="cron"
          phx-value-id={@job.id}
          phx-value-action="abort"
          phx-value-run={@active.id}
        >
          Stop run
        </.button>
        <.action_button :for={action <- Enum.reject(@actions, &(&1 == "remove"))} row={@job} action={action} locked={@locked} />
        <.button
          id={"work-cron-#{@job.id}-runs"}
          size="sm"
          variant="ghost"
          icon="history"
          phx-click="open-runs"
          phx-value-id={@job.id}
          aria-label={"Recent runs for #{@job.label}"}
        >
          Runs
        </.button>
        <.dropdown id={"work-cron-#{@job.id}-menu"} label={"More actions for #{@job.label}"}>
          <:trigger>
            <span class="btn btn-ghost btn-icon btn-sm"><.icon name="more-horizontal" class="h-3.5 w-3.5" /></span>
          </:trigger>
          <button
            type="button"
            role="menuitem"
            class="menu-item"
            phx-click="edit-cron"
            phx-value-id={@job.id}
            disabled={@locked or @job.runtime == "unavailable"}
            data-requires-connection
          >
            <.icon name="pencil" class="h-3.5 w-3.5" /> Edit job…
          </button>
          <button
            :if={"remove" in @actions}
            id={"work-cron-#{@job.id}-remove"}
            type="button"
            role="menuitem"
            class="menu-item text-danger"
            phx-click="preview"
            phx-value-kind="cron"
            phx-value-id={@job.id}
            phx-value-action="remove"
            disabled={@locked}
            data-requires-connection
          >
            <.icon name="trash" class="h-3.5 w-3.5" /> Remove job…
          </button>
        </.dropdown>
      </div>
    </li>
    """
  end

  attr(:job, :map, required: true)
  attr(:uncertain, :any, required: true)
  attr(:now, :integer, required: true)

  defp runs_drawer(assigns) do
    assigns = assign(assigns, locked: MapSet.member?(assigns.uncertain, {:cron, assigns.job.id}))

    ~H"""
    <.drawer
      id="work-runs-drawer"
      show
      title={@job.label}
      description={"#{@job.schedule_text} · #{CronText.zone(@job.timezone)}"}
      on_cancel={JS.push("close-runs")}
    >
      <.key_value class="mb-4">
        <:item label="Job"><code class="font-mono text-xs">{@job.id}</code></:item>
        <:item label="Status">{@job.status}</:item>
        <:item label="Next run">{if @job.next_run_at_ms, do: absolute(@job.next_run_at_ms), else: "—"}</:item>
        <:item :if={@job.session} label="Session"><.session_link session={@job.session} /></:item>
      </.key_value>
      <h3 class="mb-2 text-xs font-semibold uppercase tracking-wider text-subtle">
        Recent runs · up to {WorkProjection.run_limit()}
      </h3>
      <.callout :if={@job.runtime == "unavailable"} tone="warning" class="mb-3">
        Run status unavailable; controls disabled.
      </.callout>
      <ul class="space-y-2" aria-label="Recent runs">
        <li :for={run <- @job.runs} id={"work-run-#{run.id}"} class="rounded-lg border border-line bg-surface p-3">
          <div class="flex items-center justify-between gap-2">
            <div class="flex items-center gap-2">
              <.badge tone={tone(run.status)}>{run.status}</.badge>
              <span :if={run.triggered_by} class="text-xs text-muted">{run.triggered_by}</span>
            </div>
            <.button
              :if={run.abortable}
              id={"work-abort-#{run.id}"}
              size="sm"
              variant="danger-soft"
              icon="square"
              mutation
              disabled={@locked}
              phx-click="preview"
              phx-value-kind="cron"
              phx-value-id={@job.id}
              phx-value-action="abort"
              phx-value-run={run.id}
            >
              Stop run…
            </.button>
          </div>
          <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
            <code class="font-mono text-2xs text-subtle">{run.id}</code>
            <span :if={run.started_at_ms}>{relative_time(run.started_at_ms, @now)}</span>
            <span>{if run.duration_ms > 0, do: duration(run.duration_ms), else: "—"}</span>
            <span>Retry {run.retry_attempt}</span>
          </div>
          <.session_link session={run.session} class="mt-1.5" />
        </li>
      </ul>
      <p :if={@job.runtime != "unavailable" && @job.runs == []} class="py-6 text-center text-[13px] text-muted">No runs yet.</p>
      <:footer>
        <.button
          :if={"run" in WorkProjection.actions(@job)}
          variant="primary"
          size="sm"
          icon="play"
          mutation
          disabled={@locked}
          phx-click="preview"
          phx-value-kind="cron"
          phx-value-id={@job.id}
          phx-value-action="run"
        >
          Run now…
        </.button>
      </:footer>
    </.drawer>
    """
  end

  attr(:form, :map, required: true)

  defp cron_form_modal(assigns) do
    ~H"""
    <.modal
      id="cron-form-modal"
      show
      size="lg"
      title={if @form.mode == :create, do: "New cron job", else: "Edit cron job"}
      description={
        if @form.mode == :create,
          do: "Schedules a prompt for an agent's main session.",
          else: "Changes apply to the exact job revision you opened."
      }
      on_cancel={JS.push("close-cron-form")}
    >
      <.form for={%{}} as={:cron} id="cron-form" phx-change="validate-cron" phx-submit="save-cron" class="space-y-4">
        <.callout :if={@form.errors[:form]} tone="danger">{@form.errors[:form]}</.callout>
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            id="cron-name"
            name="cron[name]"
            label="Name"
            value={@form.values["name"]}
            errors={List.wrap(@form.errors[:name])}
            maxlength="96"
            required
            phx-debounce="250"
            autocomplete="off"
            class="sm:col-span-2"
          />
          <div class="sm:col-span-2">
            <.input
              id="cron-schedule"
              name="cron[schedule]"
              label="Schedule"
              value={@form.values["schedule"]}
              errors={List.wrap(@form.errors[:schedule] || schedule_error(@form.schedule))}
              hint="Cron (0 9 * * 1-5) or shorthand: every 15m, hourly, daily at 9am, weekdays at 09:30."
              maxlength="96"
              required
              phx-debounce="250"
              autocomplete="off"
              spellcheck="false"
              input_class="font-mono"
            />
            <div class="mt-2 flex flex-wrap gap-1.5" role="group" aria-label="Schedule presets">
              <button
                :for={{label, value} <- presets()}
                type="button"
                class="badge badge-neutral cursor-pointer hover:border-line-strong"
                phx-click="schedule-preset"
                phx-value-preset={value}
              >
                {label}
              </button>
            </div>
          </div>
          <.input
            id="cron-timezone"
            name="cron[timezone]"
            type="select"
            label="Timezone"
            value={@form.values["timezone"]}
            options={[{"UTC", "UTC"}, {"Server local time", "local"}]}
          />
          <.input
            id="cron-timeout"
            name="cron[timeout_minutes]"
            type="select"
            label="Timeout"
            value={@form.values["timeout_minutes"]}
            errors={List.wrap(@form.errors[:timeout_minutes])}
            options={timeout_options(@form.values["timeout_minutes"])}
          />
          <div :if={@form.mode == :create} class="sm:col-span-2">
            <label for="cron-agent" class="field-label">Agent</label>
            <input
              id="cron-agent"
              name="cron[agent]"
              value={@form.values["agent"]}
              list="cron-agent-options"
              maxlength="64"
              autocomplete="off"
              spellcheck="false"
              class="input font-mono"
              aria-invalid={@form.errors[:agent] && "true"}
            />
            <p :if={!@form.errors[:agent]} class="field-hint">Runs in agent:{@form.values["agent"]}:main.</p>
            <p :if={@form.errors[:agent]} class="field-error">{@form.errors[:agent]}</p>
            <datalist id="cron-agent-options">
              <option :for={agent <- @form.agents} value={agent} />
            </datalist>
          </div>
          <div :if={@form.mode == :create || @form.row.mode == "agent"} class="sm:col-span-2">
            <label for="cron-prompt" class="field-label">
              {if @form.mode == :create, do: "Prompt", else: "Replace prompt (optional)"}
            </label>
            <div id="cron-prompt-wrap" phx-update="ignore">
              <textarea
                id="cron-prompt"
                name="cron[prompt]"
                rows="4"
                phx-debounce="500"
                class="input min-h-[6rem]"
                placeholder={if @form.mode == :create, do: "What should the agent do each run?", else: "Leave blank to keep the current prompt"}
                required={@form.mode == :create}
              ></textarea>
            </div>
            <p :if={!@form.errors[:prompt]} class="field-hint">
              {if @form.mode == :create,
                do: "Write-only: the prompt is never shown back on this page.",
                else: "The current prompt stays private and is not displayed."}
            </p>
            <p :if={@form.errors[:prompt]} class="field-error">{@form.errors[:prompt]}</p>
          </div>
          <.input
            id="cron-enabled"
            name="cron[enabled]"
            type="checkbox"
            label="Enabled"
            value={@form.values["enabled"]}
            hint="Paused jobs keep their schedule but never fire."
            class="sm:col-span-2"
          />
        </div>

        <div id="cron-schedule-preview" class="rounded-lg border border-line bg-surface-2/60 p-3 text-[13px]" aria-live="polite">
          <%= case @form.schedule do %>
            <% {:ok, preview} -> %>
              <p class="flex items-center gap-2 font-medium text-fg">
                <.icon name="calendar-clock" class="h-4 w-4 text-muted" /> {preview.text}
                <span class="font-normal text-muted">· {preview.zone}</span>
              </p>
              <p class="mt-1 text-xs text-muted">
                Normalized <code class="font-mono text-fg">{preview.expression}</code>
              </p>
              <p :if={preview.next != []} class="mt-2 text-xs text-muted">Next runs</p>
              <ul class="mt-1 space-y-0.5 text-xs tabular-nums text-fg">
                <li :for={ms <- preview.next}>{absolute(ms)}</li>
              </ul>
            <% _ -> %>
              <p class="text-muted">Enter a valid schedule to preview its next runs.</p>
          <% end %>
        </div>
      </.form>
      <:footer>
        <.button phx-click={JS.exec("data-cancel", to: "#cron-form-modal")}>Cancel</.button>
        <.button type="submit" form="cron-form" variant="primary" mutation phx-disable-with="Saving…">
          {if @form.mode == :create, do: "Create job", else: "Save changes"}
        </.button>
      </:footer>
    </.modal>
    """
  end

  attr(:form, :map, required: true)
  attr(:goals, :map, required: true)

  defp goal_form_modal(assigns) do
    assigns =
      assign(assigns,
        replaces:
          assigns.goals.state == :ready and
            Enum.any?(assigns.goals.items, &(&1.session == assigns.form.values["session"]))
      )

    ~H"""
    <.modal
      id="goal-form-modal"
      show
      title="New goal"
      description="A durable objective the goal loop works toward in one session."
      on_cancel={JS.push("close-goal-form")}
    >
      <.form for={%{}} as={:goal} id="goal-form" phx-change="validate-goal" phx-submit="save-goal" class="space-y-4">
        <.callout :if={@form.errors[:form]} tone="danger">{@form.errors[:form]}</.callout>
        <.input
          id="goal-session"
          name="goal[session]"
          label="Session key"
          value={@form.values["session"]}
          errors={List.wrap(@form.errors[:session])}
          hint="The loop posts continuations into this session."
          autocomplete="off"
          spellcheck="false"
          input_class="font-mono"
        />
        <.callout :if={@replaces} tone="warning">
          This session already has a goal. Saving replaces its objective and keeps its history.
        </.callout>
        <div>
          <label for="goal-objective" class="field-label">Objective</label>
          <div id="goal-objective-wrap" phx-update="ignore">
            <textarea id="goal-objective" name="goal[objective]" rows="4" class="input min-h-[6rem]" required phx-debounce="500" placeholder="What does done look like?"></textarea>
          </div>
          <p :if={!@form.errors[:objective]} class="field-hint">Write-only: the objective is never shown back on this page.</p>
          <p :if={@form.errors[:objective]} class="field-error">{@form.errors[:objective]}</p>
        </div>
        <.input
          id="goal-budget"
          name="goal[max_continuations]"
          type="number"
          label="Continuation budget"
          value={@form.values["max_continuations"]}
          errors={List.wrap(@form.errors[:max_continuations])}
          hint="Optional cap on loop continuations (1–1000)."
          min="1"
          max="1000"
        />
      </.form>
      <:footer>
        <.button phx-click={JS.exec("data-cancel", to: "#goal-form-modal")}>Cancel</.button>
        <.button type="submit" form="goal-form" variant="primary" mutation phx-disable-with="Saving…">
          {if @replaces, do: "Replace goal", else: "Set goal"}
        </.button>
      </:footer>
    </.modal>
    """
  end

  # ── Shared bits ───────────────────────────────────────────────────────────

  attr(:row, :map, required: true)
  attr(:uncertain, :any, required: true)

  defp controls(assigns) do
    assigns =
      assign(assigns,
        locked: MapSet.member?(assigns.uncertain, {assigns.row.kind, assigns.row.id})
      )

    ~H"""
    <div class="flex flex-wrap items-center gap-1.5">
      <.action_button :for={action <- WorkProjection.actions(@row)} row={@row} action={action} locked={@locked} />
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:action, :string, required: true)
  attr(:locked, :boolean, required: true)

  defp action_button(assigns) do
    ~H"""
    <.button
      id={"work-#{@row.kind}-#{@row.id}-#{@action}"}
      size="sm"
      variant={if destructive?(@action), do: "danger-soft", else: "secondary"}
      icon={action_icon(@action)}
      mutation
      disabled={@locked}
      phx-click="preview"
      phx-value-kind={@row.kind}
      phx-value-id={@row.id}
      phx-value-action={@action}
    >
      {button_label(@row.kind, @action)}
    </.button>
    """
  end

  attr(:status, :string, required: true)

  defp runtime_badge(assigns) do
    ~H"""
    <span class={["badge", "badge-#{tone(@status)}", "gap-1.5"]}>
      <.status_dot tone={tone(@status)} pulse={@status in ~w(running stopping reconciling)} />{@status}
    </span>
    """
  end

  attr(:session, :string, default: nil)
  attr(:class, :any, default: nil)

  defp session_link(assigns) do
    ~H"""
    <.link
      :if={@session}
      navigate={~p"/chat/#{@session}"}
      class={["inline-flex items-center gap-1 text-xs font-medium text-accent-text hover:underline", @class]}
    >
      <.icon name="message-square" class="h-3 w-3" /> Open session
    </.link>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp refresh(socket), do: assign(socket, work: WorkProjection.snapshot(socket.assigns.work))
  defp parse_kind(value), do: Enum.find([:boards, :goals, :cron], &(Atom.to_string(&1) == value))
  defp parse_tab(value), do: parse_kind(value)

  defp allowed?(%{kind: :cron, runtime: "ready"} = row, "abort", id),
    do: Enum.any?(row.runs, &(&1.id == id and &1.abortable))

  defp allowed?(row, action, nil), do: action in WorkProjection.actions(row)
  defp allowed?(_, _, _), do: false

  defp filtered(%{items: items}, kind, filter) do
    case String.downcase(String.trim(filter)) do
      "" ->
        items

      needle ->
        Enum.filter(items, fn row ->
          haystack =
            [row.id, row.label, Map.get(row, :session), Map.get(row, :agent)] ++
              if(kind == :boards, do: Enum.flat_map(row.cards, &[&1.id, &1.label]), else: [])

          Enum.any?(haystack, &(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
        end)
    end
  end

  defp filter_cards(cards, filter) do
    case String.downcase(String.trim(filter)) do
      "" ->
        cards

      needle ->
        Enum.filter(
          cards,
          &(String.contains?(String.downcase(&1.label), needle) or String.contains?(&1.id, needle))
        )
    end
    |> then(fn
      [] -> if String.trim(filter) == "", do: [], else: cards
      list -> list
    end)
  end

  defp tab_count(%{state: :ready, items: items}), do: length(items)
  defp tab_count(_), do: "!"

  defp tab_label(key), do: Enum.find_value(@tabs, fn {k, label, _} -> k == key && label end)
  defp tab_icon(key), do: Enum.find_value(@tabs, fn {k, _, icon} -> k == key && icon end)

  defp empty_description(:boards),
    do:
      "Create boards with the kanban agent tools in a session. This page observes and controls existing boards."

  defp empty_description(:goals),
    do: "Set a goal for a session, then start a bounded loop that works toward it."

  defp empty_description(:cron),
    do: "Schedule a prompt for an agent: daily summaries, check-ins, recurring chores."

  defp bound_suffix(:cron), do: " and #{WorkProjection.run_limit()} recent runs per job"
  defp bound_suffix(:boards), do: " and #{WorkProjection.card_limit()} cards per board"
  defp bound_suffix(_), do: ""

  defp preview_subject(%{kind: :boards, label: label}), do: "Board · #{label}"
  defp preview_subject(%{kind: :goals, id: id}), do: "Goal · #{id}"
  defp preview_subject(%{kind: :cron, label: label}), do: "Cron job · #{label}"

  defp presets do
    [
      {"Every 15 min", "every 15m"},
      {"Hourly", "hourly"},
      {"Daily 9:00", "daily at 9am"},
      {"Weekdays 9:00", "weekdays at 9am"},
      {"Mondays 8:00", "weekly monday at 8am"}
    ]
  end

  defp timeout_options(current) do
    base = [
      {"1 minute", "1"},
      {"5 minutes", "5"},
      {"15 minutes", "15"},
      {"30 minutes", "30"},
      {"1 hour", "60"},
      {"2 hours", "120"}
    ]

    if Enum.any?(base, &(elem(&1, 1) == current)) or current in [nil, ""],
      do: base,
      else: base ++ [{"#{current} minutes", current}]
  end

  defp schedule_error({:error, message}), do: message
  defp schedule_error(_), do: nil

  defp write_message(:stale), do: stale_message()
  defp write_message(:not_found), do: "That job no longer exists. Refresh the list."
  defp write_message(:invalid_schedule), do: "The scheduler rejected this schedule."
  defp write_message(:invalid), do: "The scheduler rejected these settings."

  defp write_message(_),
    do: "The shared service refused this change. No automatic retry was made."

  defp stale_message,
    do:
      "State changed since preview. Nothing was changed by this confirmation. Preview the current target again."

  defp destructive?(action), do: action in ~w(stop abort remove)

  defp action_label("start"), do: "Start"
  defp action_label("stop"), do: "Stop"
  defp action_label("pause"), do: "Pause"
  defp action_label("resume"), do: "Resume"
  defp action_label("run"), do: "Run now"
  defp action_label("abort"), do: "Stop run"
  defp action_label("remove"), do: "Remove job"
  defp action_label("reauthorize"), do: "Reauthorize"
  defp action_label("grant-publish"), do: "Grant publication"
  defp action_label("allow-in-place"), do: "Allow in-place execution"

  defp button_label(:boards, "start"), do: "Start board…"
  defp button_label(:boards, "stop"), do: "Stop dispatcher…"
  defp button_label(:boards, "reauthorize"), do: "Reauthorize board…"
  defp button_label(:boards, "grant-publish"), do: "Grant publication…"
  defp button_label(:boards, "allow-in-place"), do: "Allow in-place…"
  defp button_label(:goals, "start"), do: "Start loop…"
  defp button_label(:goals, "stop"), do: "Stop loop…"
  defp button_label(_, action), do: action_label(action) <> "…"

  defp action_icon("start"), do: "play"
  defp action_icon("run"), do: "play"
  defp action_icon("resume"), do: "play"
  defp action_icon("pause"), do: "pause"
  defp action_icon("remove"), do: "trash"
  defp action_icon(_), do: "square"

  defp effect(:boards, "stop"),
    do:
      "Stops this dispatcher and requests cancellation of its exact owned runs. Ambiguous cancellations remain reconciling."

  defp effect(:boards, "start"),
    do: "Starts this board with one concurrent worker using the shared dispatcher."

  defp effect(:boards, "reauthorize"),
    do:
      "Grants this board's existing cards full operator tool authority in its current workspace. Kanban, goal and cron stay blocked for workers; publication and in-place execution are not authorized."

  defp effect(:boards, "grant-publish"),
    do:
      "Lets the controller push reviewed commits (and open the pull request) with the server's Git credentials using exactly the settings below. Each card's recorded tool policy must still allow those commands."

  defp effect(:boards, "allow-in-place"),
    do:
      "Lets workers run directly in this board's current workspace (fingerprint below) instead of a Lemon-owned Git worktree. Needed only for non-Git workspaces or boards with worktrees off. Whoever can write that directory can change what workers act on. A workspace change voids this grant."

  defp effect(:goals, "start"),
    do: "Starts at most 3 loop ticks. Does not enable automatic restart."

  defp effect(:goals, "stop"),
    do: "Disables automatic restart and requests a hard stop of this exact goal invocation."

  defp effect(:cron, "pause"),
    do: "Disables future scheduled runs. An already active run is not aborted."

  defp effect(:cron, "abort"),
    do: "Requests cancellation of only the displayed cron run, not a later invocation."

  defp effect(:cron, "run"), do: "Submits one immediate run through the shared scheduler."

  defp effect(:cron, "remove"),
    do: "Permanently removes this job and its schedule. This cannot be undone."

  defp effect(_, "pause"), do: "Pauses this idle goal. Stop an active loop first."
  defp effect(_, "resume"), do: "Re-enables the existing work using its stored configuration."

  defp tone(status) when status in ~w(running active enabled completed done ready), do: "success"
  defp tone(status) when status in ~w(pending scheduled stopping), do: "info"
  defp tone(status) when status in ~w(failed timeout error), do: "danger"

  defp tone(status) when status in ~w(unavailable unknown reconciling outcome_unknown aborted),
    do: "warning"

  defp tone(_), do: "neutral"

  defp action_tone("done"), do: "success"
  defp action_tone("continue"), do: "info"
  defp action_tone(_), do: "warning"

  defp humanize(value), do: String.replace(value, "_", " ")

  defp until(ms, now) do
    diff = div(ms - now, 1000)

    cond do
      diff <= 30 -> "now"
      diff < 3600 -> "in #{max(div(diff, 60), 1)}m"
      diff < 86_400 -> "in #{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
      true -> "in #{div(diff, 86_400)}d"
    end
  end

  defp absolute(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, time} -> Calendar.strftime(time, "%a %b %-d, %H:%M UTC")
      _ -> "—"
    end
  end
end
