defmodule LemonWeb.OpsDashboardLive do
  @moduledoc false

  use LemonWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_snapshot(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_snapshot(socket)}
  end

  def handle_event("resolve-approval", %{"id" => approval_id, "decision" => decision}, socket) do
    socket =
      case LemonWeb.OpsDashboard.resolve_approval(approval_id, decision) do
        :ok ->
          socket
          |> put_flash(:info, "Approval resolved.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Approval could not be resolved.")
      end

    {:noreply, socket}
  end

  def handle_event("create-cron-job", params, socket) do
    params = Map.put(params, "enabled", Map.get(params, "enabled", "false"))

    socket =
      case LemonWeb.OpsDashboard.create_cron_job(params) do
        :ok ->
          socket
          |> put_flash(:info, "Cron schedule created.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Cron schedule could not be created.")
      end

    {:noreply, socket}
  end

  def handle_event("update-cron-job", %{"cron_id" => job_id} = params, socket) do
    socket =
      case LemonWeb.OpsDashboard.update_cron_job(job_id, params) do
        :ok ->
          socket
          |> put_flash(:info, "Cron schedule updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Cron schedule could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("delete-cron-job", %{"id" => job_id}, socket) do
    socket =
      case LemonWeb.OpsDashboard.delete_cron_job(job_id) do
        :ok ->
          socket
          |> put_flash(:info, "Cron schedule deleted.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Cron schedule could not be deleted.")
      end

    {:noreply, socket}
  end

  def handle_event("set-cron-enabled", %{"id" => job_id, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    socket =
      case LemonWeb.OpsDashboard.set_cron_enabled(job_id, enabled?) do
        :ok ->
          socket
          |> put_flash(:info, "Cron schedule updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Cron schedule could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("run-cron-now", %{"id" => job_id}, socket) do
    socket =
      case LemonWeb.OpsDashboard.run_cron_now(job_id) do
        :ok ->
          socket
          |> put_flash(:info, "Cron run submitted.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Cron run could not be submitted.")
      end

    {:noreply, socket}
  end

  def handle_event("set-skill-enabled", %{"key" => skill_key, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    socket =
      case LemonWeb.OpsDashboard.set_skill_enabled(skill_key, enabled?) do
        :ok ->
          socket
          |> put_flash(:info, "Skill updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Skill could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("update-default-config", params, socket) do
    socket =
      case LemonWeb.OpsDashboard.update_default_config(params) do
        :ok ->
          socket
          |> put_flash(:info, "Default configuration updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Default configuration could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("update-provider-config", %{"provider_id" => provider_id} = params, socket) do
    socket =
      case LemonWeb.OpsDashboard.update_provider_config(provider_id, params) do
        :ok ->
          socket
          |> put_flash(:info, "Provider configuration updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Provider configuration could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("install-skill", params, socket) do
    source = Map.get(params, "source", "")
    global? = Map.get(params, "scope") != "project"
    force? = truthy_param?(Map.get(params, "force"))

    socket =
      case LemonWeb.OpsDashboard.install_skill(source, global: global?, force: force?) do
        :ok ->
          socket
          |> put_flash(:info, "Skill installed.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Skill could not be installed.")
      end

    {:noreply, socket}
  end

  def handle_event("update-skill", %{"key" => skill_key}, socket) do
    socket =
      case LemonWeb.OpsDashboard.update_skill(skill_key) do
        :ok ->
          socket
          |> put_flash(:info, "Skill updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Skill could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("disconnect-channel", %{"id" => channel_id}, socket) do
    socket =
      case LemonWeb.OpsDashboard.disconnect_channel(channel_id) do
        :ok ->
          socket
          |> put_flash(:info, "Channel disconnected.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Channel could not be disconnected.")
      end

    {:noreply, socket}
  end

  def handle_event("reconnect-channel", %{"id" => channel_id}, socket) do
    socket =
      case LemonWeb.OpsDashboard.reconnect_channel(channel_id) do
        :ok ->
          socket
          |> put_flash(:info, "Channel reconnected.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Channel could not be reconnected.")
      end

    {:noreply, socket}
  end

  def handle_event(
        "set-channel-config-enabled",
        %{"id" => channel_id, "enabled" => enabled},
        socket
      ) do
    enabled? = enabled == "true"

    socket =
      case LemonWeb.OpsDashboard.set_channel_config_enabled(channel_id, enabled?) do
        :ok ->
          socket
          |> put_flash(:info, "Channel configuration updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Channel configuration could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("update-channel-gateway-defaults", params, socket) do
    params = Map.put(params, "auto_resume", Map.get(params, "auto_resume", "false"))

    socket =
      case LemonWeb.OpsDashboard.update_channel_gateway_defaults(params) do
        :ok ->
          socket
          |> put_flash(:info, "Gateway defaults updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Gateway defaults could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("update-channel-telegram-config", params, socket) do
    params = Map.put(params, "deny_unbound_chats", Map.get(params, "deny_unbound_chats", "false"))

    socket =
      case LemonWeb.OpsDashboard.update_channel_telegram_config(params) do
        :ok ->
          socket
          |> put_flash(:info, "Telegram configuration updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Telegram configuration could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("create-channel-binding", params, socket) do
    socket =
      case LemonWeb.OpsDashboard.create_channel_binding(params) do
        :ok ->
          socket
          |> put_flash(:info, "Channel binding created.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Channel binding could not be created.")
      end

    {:noreply, socket}
  end

  def handle_event("update-channel-binding", %{"binding_index" => index} = params, socket) do
    socket =
      case LemonWeb.OpsDashboard.update_channel_binding(index, params) do
        :ok ->
          socket
          |> put_flash(:info, "Channel binding updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Channel binding could not be updated.")
      end

    {:noreply, socket}
  end

  def handle_event("delete-channel-binding", %{"index" => index}, socket) do
    socket =
      case LemonWeb.OpsDashboard.delete_channel_binding(index) do
        :ok ->
          socket
          |> put_flash(:info, "Channel binding deleted.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Channel binding could not be deleted.")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-100">
      <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-6 sm:py-6">
        <header class="rounded-2xl border border-slate-200 bg-white px-4 py-4 shadow-sm">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                Lemon Web Dashboard
              </p>
              <h1 class="mt-1 text-xl font-semibold text-slate-900">Operations</h1>
              <p class="mt-2 text-sm text-slate-600">
                Health, active work, approvals, and support entry points.
              </p>
            </div>
            <button
              type="button"
              phx-click="refresh"
              class="rounded-lg bg-slate-900 px-3 py-2 text-sm font-medium text-white shadow-sm"
            >
              Refresh
            </button>
          </div>
          <p class="mt-3 text-xs text-slate-500">
            generated: {format_datetime(@snapshot.generated_at)}
          </p>
        </header>

        <section class="mt-4 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <.metric title="Runtime" value={runtime_label(@snapshot.runtime)} detail={runtime_detail(@snapshot.runtime)} />
          <.metric title="Build" value={build_label(@snapshot.build)} detail={build_detail(@snapshot.build)} />
          <.metric title="Router" value={router_label(@snapshot.router)} detail={router_detail(@snapshot.router)} />
          <.metric title="Provider" value={provider_label(@snapshot.provider)} detail={provider_detail(@snapshot.provider)} />
          <.metric title="Active Sessions" value={length(@snapshot.active_sessions)} detail="session workers with active runs" />
          <.metric title="Pending Approvals" value={length(@snapshot.pending_approvals)} detail="unexpired execution requests" />
          <.metric title="Observed Events" value={@snapshot.activity.total_events} detail="recent introspection entries scanned" />
        </section>

        <section class="mt-4 grid gap-4 lg:grid-cols-2">
          <.panel title="Active Sessions">
            <%= if @snapshot.active_sessions == [] do %>
              <.empty text="No active sessions." />
            <% else %>
              <div class="space-y-2">
                <%= for session <- @snapshot.active_sessions do %>
                  <.run_row
                    label={shorten(session.session_key)}
                    run_id={session.run_id}
                    detail="active run"
                    status="active"
                  />
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Pending Approvals">
            <%= if @snapshot.pending_approvals == [] do %>
              <.empty text="No pending approvals." />
            <% else %>
              <div class="space-y-3">
                <%= for approval <- @snapshot.pending_approvals do %>
                  <div class="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2">
                    <p class="text-sm font-medium text-amber-950">{approval.tool || "unknown tool"}</p>
                    <p class="mt-1 text-xs text-amber-800">run: {shorten(approval.run_id)}</p>
                    <%= if approval.rationale do %>
                      <p class="mt-1 text-xs text-amber-800">{approval.rationale}</p>
                    <% end %>
                    <div class="mt-3 flex flex-wrap gap-2">
                      <.approval_button approval={approval} decision="approve_once" label="Approve Once" />
                      <.approval_button approval={approval} decision="approve_session" label="Session" />
                      <.approval_button approval={approval} decision="approve_agent" label="Agent" />
                      <.approval_button approval={approval} decision="approve_global" label="Global" />
                      <.approval_button approval={approval} decision="deny" label="Deny" tone="danger" />
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>
        </section>

        <section class="mt-4 grid gap-4 lg:grid-cols-2">
          <.panel title="Provider and Secrets">
            <div class="space-y-3">
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Runtime Metadata
                </p>
                <p class="mt-1 text-sm text-slate-800">
                  version: {format_value(@snapshot.build.lemon_version)}
                  · mode: {format_value(@snapshot.build.runtime_mode)}
                  · release: {format_value(@snapshot.build.release_name)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  git: {format_git(@snapshot.build.git)}
                  · channel: {format_value(@snapshot.build.release_channel)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  elixir: {format_value(@snapshot.build.elixir)}
                  · otp: {format_value(@snapshot.build.otp)}
                </p>
              </div>
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Secrets</p>
                <p class="mt-1 text-sm text-slate-800">
                  configured: {yes_no(@snapshot.provider.secrets[:configured])}
                  · source: {format_value(@snapshot.provider.secrets[:source])}
                  · stored: {format_value(@snapshot.provider.secrets[:secret_count])}
                </p>
              </div>
              <form phx-submit="update-default-config" class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <label class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Default Agent
                </label>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  <input
                    name="provider"
                    type="text"
                    value={@snapshot.config.defaults.provider || "anthropic"}
                    class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                  />
                  <input
                    name="model"
                    type="text"
                    value={@snapshot.config.defaults.model || "claude-sonnet-4-20250514"}
                    class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                  />
                  <input
                    name="thinking_level"
                    type="text"
                    value={@snapshot.config.defaults.thinking_level || "medium"}
                    class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                  />
                  <input
                    name="engine"
                    type="text"
                    value={@snapshot.config.defaults.engine || "lemon"}
                    class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                  />
                </div>
                <button
                  type="submit"
                  class="mt-2 rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                >
                  Save Defaults
                </button>
              </form>
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Provider References
                </p>
                <div class="mt-2 space-y-2">
                  <%= for provider <- @snapshot.config.providers do %>
                    <form phx-submit="update-provider-config" class="rounded-md bg-white px-2 py-2">
                      <input type="hidden" name="provider_id" value={provider.id} />
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-xs font-medium text-slate-800">
                          {provider.display_name}
                        </p>
                        <span class={status_badge_class(if provider.configured?, do: "ok", else: "disabled")}>
                          {if provider.configured?, do: "configured", else: "empty"}
                        </span>
                      </div>
                      <div class="mt-2 grid gap-2 sm:grid-cols-2">
                        <input
                          name="auth_source"
                          type="text"
                          placeholder="api_key or oauth"
                          value={provider.auth_source}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="api_key_secret"
                          type="text"
                          placeholder="api key secret name"
                          value={provider.api_key_secret}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="oauth_secret"
                          type="text"
                          placeholder="oauth secret name"
                          value={provider.oauth_secret}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="base_url"
                          type="text"
                          placeholder="base url"
                          value={provider.base_url}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                      </div>
                      <%= if provider.has_direct_api_key? do %>
                        <p class="mt-1 text-xs text-amber-700">
                          direct key present; value is hidden
                        </p>
                      <% end %>
                      <button
                        type="submit"
                        class="mt-2 rounded-md bg-slate-200 px-2 py-1 text-xs font-medium text-slate-800 shadow-sm"
                      >
                        Save Provider
                      </button>
                    </form>
                  <% end %>
                </div>
              </div>
              <%= if @snapshot.provider.checks == [] do %>
                <.empty text="Provider checks are unavailable." />
              <% else %>
                <%= for check <- @snapshot.provider.checks do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">{check.name}</p>
                      <span class={check_badge_class(check.status)}>{check.status}</span>
                    </div>
                    <p class="mt-1 text-xs text-slate-600">{check.message}</p>
                    <%= if check.remediation do %>
                      <p class="mt-1 text-xs text-slate-500">{check.remediation}</p>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          </.panel>

          <.panel title="Recent Runs">
            <%= if @snapshot.recent_runs == [] do %>
              <.empty text="No completed runs recorded yet." />
            <% else %>
              <div class="space-y-2">
                <%= for run <- @snapshot.recent_runs do %>
                  <.run_row
                    label={shorten(run.run_id)}
                    run_id={run.run_id}
                    detail={run.engine || "unknown engine"}
                    status={if run.ok?, do: "ok", else: "error"}
                  />
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Observed Activity">
            <%= if @snapshot.activity.categories == [] do %>
              <.empty text="No activity data available." />
            <% else %>
              <div class="space-y-3">
                <%= for category <- @snapshot.activity.categories do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="text-sm font-medium capitalize text-slate-900">{category.category}</p>
                      <span class="rounded-full bg-slate-200 px-2 py-1 text-xs font-medium text-slate-700">
                        {category.count}
                      </span>
                    </div>
                    <%= if category.recent == [] do %>
                      <p class="mt-2 text-xs text-slate-500">No recent matching events.</p>
                    <% else %>
                      <div class="mt-2 space-y-2">
                        <%= for event <- category.recent do %>
                          <div class="rounded-md bg-white px-2 py-1">
                            <p class="truncate text-xs font-medium text-slate-700">
                              {event.event_type || "unknown"} · {format_ts(event.ts_ms)}
                            </p>
                            <%= if event.tool do %>
                              <p class="truncate text-xs text-slate-500">tool: {event.tool}</p>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>
        </section>

        <section class="mt-4 grid gap-4 lg:grid-cols-3">
          <.panel title="Cron Schedules">
            <div class="mb-3 flex flex-wrap gap-2 text-xs text-slate-500">
              <span>{@snapshot.cron.enabled_count} enabled</span>
              <span>{@snapshot.cron.failed_run_count} failed recent runs</span>
            </div>
            <form phx-submit="create-cron-job" class="mb-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <label class="text-xs font-medium uppercase tracking-wide text-slate-500" for="cron-name">
                New Schedule
              </label>
              <input
                id="cron-name"
                name="name"
                type="text"
                placeholder="Daily check"
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-sm text-slate-900"
              />
              <div class="mt-2 grid gap-2 sm:grid-cols-2">
                <input
                  name="schedule"
                  type="text"
                  placeholder="0 9 * * *"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="timezone"
                  type="text"
                  value="UTC"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="agent_id"
                  type="text"
                  value="default"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="session_key"
                  type="text"
                  value="agent:web:cron"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
              </div>
              <textarea
                name="prompt"
                rows="2"
                placeholder="Prompt to run"
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
              ></textarea>
              <div class="mt-2 flex flex-wrap items-center gap-2">
                <label class="inline-flex items-center gap-1 text-xs text-slate-600">
                  <input type="checkbox" name="enabled" value="true" checked class="rounded border-slate-300" />
                  Enabled
                </label>
                <button
                  type="submit"
                  class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                >
                  Create
                </button>
              </div>
            </form>
            <%= if @snapshot.cron.jobs == [] do %>
              <.empty text="No cron schedules configured." />
            <% else %>
              <div class="space-y-2">
                <%= for job <- @snapshot.cron.jobs do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">{job.name}</p>
                      <span class={status_badge_class(if job.enabled?, do: "ok", else: "disabled")}>
                        {if job.enabled?, do: "enabled", else: "disabled"}
                      </span>
                    </div>
                    <p class="mt-1 truncate text-xs text-slate-500">
                      {job.schedule || "no schedule"} · {job.timezone || "UTC"}
                    </p>
                    <p class="mt-1 truncate text-xs text-slate-500">
                      next: {format_ts(job.next_run_at_ms)}
                    </p>
                    <form phx-submit="update-cron-job" class="mt-3 space-y-2">
                      <input type="hidden" name="cron_id" value={job.id} />
                      <div class="grid gap-2 sm:grid-cols-2">
                        <input
                          name="name"
                          type="text"
                          value={job.name}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="schedule"
                          type="text"
                          value={job.schedule}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="timezone"
                          type="text"
                          value={job.timezone || "UTC"}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                      </div>
                      <textarea
                        name="prompt"
                        rows="2"
                        class="w-full rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                      >{job.prompt}</textarea>
                      <div class="flex flex-wrap gap-2">
                        <button
                          type="submit"
                          class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                        >
                          Save
                        </button>
                      <button
                        type="button"
                        phx-click="run-cron-now"
                        phx-value-id={job.id}
                        class="rounded-md bg-slate-200 px-2 py-1 text-xs font-medium text-slate-800 shadow-sm"
                      >
                        Run Now
                      </button>
                      <button
                        type="button"
                        phx-click="set-cron-enabled"
                        phx-value-id={job.id}
                        phx-value-enabled={if job.enabled?, do: "false", else: "true"}
                        class="rounded-md bg-slate-200 px-2 py-1 text-xs font-medium text-slate-800 shadow-sm"
                      >
                        {if job.enabled?, do: "Disable", else: "Enable"}
                      </button>
                        <button
                          type="button"
                          phx-click="delete-cron-job"
                          phx-value-id={job.id}
                          class="rounded-md bg-rose-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
                        >
                          Delete
                        </button>
                      </div>
                    </form>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Skill Health">
            <div class="mb-3 flex flex-wrap gap-2 text-xs text-slate-500">
              <span>{@snapshot.skills.installed_count || 0} installed</span>
              <span>{@snapshot.skills.enabled_count || 0} enabled</span>
              <span>{@snapshot.skills.missing_count || 0} missing requirements</span>
              <span>{@snapshot.skills.blocked_count || 0} blocked</span>
            </div>
            <form phx-submit="install-skill" class="mb-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <label class="text-xs font-medium uppercase tracking-wide text-slate-500" for="skill-source">
                Install Source
              </label>
              <input
                id="skill-source"
                name="source"
                type="text"
                placeholder="path, git URL, or registry ref"
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-sm text-slate-900"
              />
              <div class="mt-2 flex flex-wrap items-center gap-2">
                <select
                  name="scope"
                  class="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs text-slate-800"
                >
                  <option value="global">Global</option>
                  <option value="project">Project</option>
                </select>
                <label class="inline-flex items-center gap-1 text-xs text-slate-600">
                  <input type="checkbox" name="force" value="true" class="rounded border-slate-300" />
                  Force
                </label>
                <button
                  type="submit"
                  class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                >
                  Install
                </button>
              </div>
            </form>
            <%= if @snapshot.skills.entries == [] do %>
              <.empty text="No skill health checks available." />
            <% else %>
              <div class="space-y-2">
                <%= for skill <- @snapshot.skills.entries do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">{skill.name}</p>
                      <span class={status_badge_class(skill.activation_state)}>
                        {skill.activation_state}
                      </span>
                    </div>
                    <p class="mt-1 truncate text-xs text-slate-500">
                      {skill.key} · {skill.source_kind} · {skill.trust_level} · audit {skill.audit_status}
                    </p>
                    <%= if skill.source_id do %>
                      <p class="mt-1 truncate text-xs text-slate-500">source: {skill.source_id}</p>
                    <% end %>
                    <%= if skill.required_bins != [] do %>
                      <p class="mt-1 truncate text-xs text-slate-500">
                        bins: {Enum.join(skill.required_bins, ", ")}
                      </p>
                    <% end %>
                    <%= if skill.missing != [] do %>
                      <p class="mt-1 truncate text-xs text-amber-700">
                        missing: {Enum.join(skill.missing, ", ")}
                      </p>
                    <% end %>
                    <div class="mt-3 flex flex-wrap gap-2">
                      <button
                        type="button"
                        phx-click="set-skill-enabled"
                        phx-value-key={skill.key}
                        phx-value-enabled={if skill.enabled?, do: "false", else: "true"}
                        class="rounded-md bg-slate-200 px-2 py-1 text-xs font-medium text-slate-800 shadow-sm"
                      >
                        {if skill.enabled?, do: "Disable", else: "Enable"}
                      </button>
                      <button
                        type="button"
                        phx-click="update-skill"
                        phx-value-key={skill.key}
                        class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                      >
                        Update
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Channel Config">
            <div class="mb-3 text-xs text-slate-500">
              {@snapshot.channels.enabled_count} enabled transports · {@snapshot.channels.running_count || 0} running · {length(@snapshot.channels.bindings)} bindings
            </div>
            <form phx-submit="update-channel-gateway-defaults" class="mb-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <label class="text-xs font-medium uppercase tracking-wide text-slate-500">
                Gateway Defaults
              </label>
              <div class="mt-2 grid gap-2 sm:grid-cols-2">
                <input
                  name="default_engine"
                  type="text"
                  value={@snapshot.channels.gateway.default_engine || "lemon"}
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="default_cwd"
                  type="text"
                  value={@snapshot.channels.gateway.default_cwd || "~/"}
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
              </div>
              <div class="mt-2 flex flex-wrap items-center gap-2">
                <label class="inline-flex items-center gap-1 text-xs text-slate-600">
                  <input
                    type="checkbox"
                    name="auto_resume"
                    value="true"
                    checked={@snapshot.channels.gateway.auto_resume?}
                    class="rounded border-slate-300"
                  />
                  Auto Resume
                </label>
                <button
                  type="submit"
                  class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                >
                  Save Defaults
                </button>
              </div>
            </form>
            <form phx-submit="update-channel-telegram-config" class="mb-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <label class="text-xs font-medium uppercase tracking-wide text-slate-500">
                Telegram Access
              </label>
              <input
                name="bot_token_secret"
                type="text"
                placeholder="telegram_bot_token"
                value={@snapshot.channels.telegram.bot_token_secret}
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
              />
              <input
                name="allowed_chat_ids"
                type="text"
                placeholder="123456789, -1001234567890"
                value={Enum.join(@snapshot.channels.telegram.allowed_chat_ids || [], ", ")}
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
              />
              <div class="mt-2 flex flex-wrap items-center gap-2">
                <label class="inline-flex items-center gap-1 text-xs text-slate-600">
                  <input
                    type="checkbox"
                    name="deny_unbound_chats"
                    value="true"
                    checked={@snapshot.channels.telegram.deny_unbound_chats?}
                    class="rounded border-slate-300"
                  />
                  Deny Unbound
                </label>
                <button
                  type="submit"
                  class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                >
                  Save Telegram
                </button>
              </div>
            </form>
            <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
              <%= for transport <- @snapshot.channels.transports do %>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="truncate text-sm font-medium text-slate-900">{transport.name}</p>
                    <span class={status_badge_class(transport.runtime_status)}>
                      {transport.runtime_status}
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-500">
                    config: {if transport.enabled?, do: "enabled", else: "disabled"} · connected: {yes_no(transport.connected?)}
                  </p>
                  <%= if transport[:config_key] do %>
                    <p class="mt-1 truncate text-xs text-slate-500">
                      key: gateway.{transport.config_key}
                    </p>
                  <% end %>
                  <%= if transport.account_id do %>
                    <p class="mt-1 truncate text-xs text-slate-500">account: {transport.account_id}</p>
                  <% end %>
                  <div class="mt-3 flex flex-wrap gap-2">
                    <%= if transport.configurable? do %>
                      <button
                        type="button"
                        phx-click="set-channel-config-enabled"
                        phx-value-id={transport.name}
                        phx-value-enabled={if transport.enabled?, do: "false", else: "true"}
                        class="rounded-md bg-slate-200 px-2 py-1 text-xs font-medium text-slate-800 shadow-sm"
                      >
                        {if transport.enabled?, do: "Disable Config", else: "Enable Config"}
                      </button>
                    <% end %>
                    <%= if transport.runtime_status == "running" do %>
                      <button
                        type="button"
                        phx-click="disconnect-channel"
                        phx-value-id={transport.name}
                        class="rounded-md bg-slate-200 px-2 py-1 text-xs font-medium text-slate-800 shadow-sm"
                      >
                        Disconnect
                      </button>
                    <% else %>
                      <%= if transport.reconnectable? do %>
                        <button
                          type="button"
                          phx-click="reconnect-channel"
                          phx-value-id={transport.name}
                          class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                        >
                          Reconnect
                        </button>
                      <% end %>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
            <form phx-submit="create-channel-binding" class="mt-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <label class="text-xs font-medium uppercase tracking-wide text-slate-500">
                New Binding
              </label>
              <div class="mt-2 grid gap-2 sm:grid-cols-2">
                <input
                  name="transport"
                  type="text"
                  value="telegram"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="chat_id"
                  type="text"
                  placeholder="chat id"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="topic_id"
                  type="text"
                  placeholder="topic id"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="agent_id"
                  type="text"
                  value="default"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="default_engine"
                  type="text"
                  placeholder="engine"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="project"
                  type="text"
                  placeholder="project"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
              </div>
              <button
                type="submit"
                class="mt-2 rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
              >
                Create Binding
              </button>
            </form>
            <%= if @snapshot.channels.bindings != [] do %>
              <div class="mt-3 space-y-2">
                <%= for binding <- @snapshot.channels.bindings do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <form phx-submit="update-channel-binding" class="space-y-2">
                      <input type="hidden" name="binding_index" value={binding.index} />
                      <div class="grid gap-2 sm:grid-cols-2">
                        <input
                          name="transport"
                          type="text"
                          value={binding.transport || "telegram"}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="chat_id"
                          type="text"
                          value={binding.chat_id}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="topic_id"
                          type="text"
                          value={binding.topic_id}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="agent_id"
                          type="text"
                          value={binding.agent_id || "default"}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="default_engine"
                          type="text"
                          value={binding.default_engine}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="project"
                          type="text"
                          value={binding.project}
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                      </div>
                      <div class="flex flex-wrap gap-2">
                        <button
                          type="submit"
                          class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                        >
                          Save Binding
                        </button>
                        <button
                          type="button"
                          phx-click="delete-channel-binding"
                          phx-value-index={binding.index}
                          class="rounded-md bg-rose-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
                        >
                          Delete
                        </button>
                      </div>
                    </form>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Support Bundle">
            <div class="space-y-3">
              <.link
                href={~p"/ops/support-bundle"}
                class="inline-flex rounded-lg bg-slate-900 px-3 py-2 text-sm font-medium text-white shadow-sm"
              >
                Download Support Bundle
              </.link>
              <div>
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Source-dev</p>
                <code class="mt-1 block overflow-x-auto rounded-lg bg-slate-950 px-3 py-2 text-xs text-slate-100">
                  {@snapshot.support.source_dev}
                </code>
              </div>
              <div>
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Release runtime</p>
                <code class="mt-1 block overflow-x-auto rounded-lg bg-slate-950 px-3 py-2 text-xs text-slate-100">
                  {@snapshot.support.release_runtime}
                </code>
              </div>
            </div>
          </.panel>
        </section>

        <section class="mt-4">
          <.panel title="Next Operations Panels">
            <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              <%= for panel <- @snapshot.planned_panels do %>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <p class="text-sm font-medium text-slate-900">{panel.name}</p>
                  <p class="mt-1 text-xs uppercase tracking-wide text-slate-500">{panel.status}</p>
                </div>
              <% end %>
            </div>
          </.panel>
        </section>
      </div>
    </main>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-sm">
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500">{@title}</p>
      <p class="mt-2 text-2xl font-semibold text-slate-900">{@value}</p>
      <p class="mt-1 text-xs text-slate-500">{@detail}</p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <div class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <h2 class="text-sm font-semibold text-slate-900">{@title}</h2>
      <div class="mt-3">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:run_id, :any, required: true)
  attr(:detail, :string, required: true)
  attr(:status, :string, required: true)

  defp run_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
      <div class="min-w-0">
        <%= if is_binary(@run_id) and @run_id != "" do %>
          <.link navigate={~p"/ops/runs/#{@run_id}"} class="truncate text-sm font-medium text-slate-900 hover:underline">
            {@label}
          </.link>
        <% else %>
          <p class="truncate text-sm font-medium text-slate-900">{@label}</p>
        <% end %>
        <p class="truncate text-xs text-slate-500">{@detail}</p>
      </div>
      <span class={status_badge_class(@status)}>{@status}</span>
    </div>
    """
  end

  attr(:text, :string, required: true)

  defp empty(assigns) do
    ~H"""
    <p class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-500">
      {@text}
    </p>
    """
  end

  attr(:approval, :map, required: true)
  attr(:decision, :string, required: true)
  attr(:label, :string, required: true)
  attr(:tone, :string, default: "default")

  defp approval_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="resolve-approval"
      phx-value-id={@approval.id}
      phx-value-decision={@decision}
      class={approval_button_class(@tone)}
    >
      {@label}
    </button>
    """
  end

  defp assign_snapshot(socket) do
    socket
    |> assign(:page_title, "Lemon Operations")
    |> assign(:snapshot, LemonWeb.OpsDashboard.snapshot())
  end

  defp runtime_label(%{status: status}), do: to_string(status)
  defp runtime_label(_), do: "unknown"

  defp runtime_detail(%{apps: apps, missing: missing}) do
    "#{length(apps)} apps started, #{length(missing)} missing"
  end

  defp runtime_detail(%{error: error}) when is_binary(error), do: error
  defp runtime_detail(_), do: "runtime status unavailable"

  defp build_label(%{runtime_mode: mode}) when is_binary(mode), do: mode
  defp build_label(_), do: "unknown"

  defp build_detail(%{lemon_version: version, git: git}) do
    commit = if is_map(git), do: git[:commit] || git["commit"]
    "version #{format_value(version)} · #{format_value(commit)}"
  end

  defp build_detail(%{error: error}) when is_binary(error), do: error
  defp build_detail(_), do: "build metadata unavailable"

  defp router_label(%{ok: true}), do: "ok"
  defp router_label(%{ok: false}), do: "error"
  defp router_label(_), do: "unknown"

  defp router_detail(%{checks: checks}) when is_list(checks), do: "#{length(checks)} checks"
  defp router_detail(%{error: error}) when is_binary(error), do: error
  defp router_detail(_), do: "router status unavailable"

  defp provider_label(%{ok?: true}), do: "ok"
  defp provider_label(%{ok?: false}), do: "check"
  defp provider_label(_), do: "unknown"

  defp provider_detail(%{checks: checks}) when is_list(checks),
    do: "#{length(checks)} provider checks"

  defp provider_detail(%{error: error}) when is_binary(error), do: error
  defp provider_detail(_), do: "provider status unavailable"

  defp run_badge_class(true),
    do: "rounded-full bg-emerald-100 px-2 py-1 text-xs font-medium text-emerald-700"

  defp run_badge_class(_),
    do: "rounded-full bg-rose-100 px-2 py-1 text-xs font-medium text-rose-700"

  defp status_badge_class("ok"), do: run_badge_class(true)
  defp status_badge_class("running"), do: run_badge_class(true)

  defp status_badge_class("active"),
    do: "rounded-full bg-sky-100 px-2 py-1 text-xs font-medium text-sky-700"

  defp status_badge_class(_), do: run_badge_class(false)

  defp approval_button_class("danger") do
    "rounded-md bg-rose-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
  end

  defp approval_button_class(_) do
    "rounded-md bg-amber-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
  end

  defp check_badge_class("pass"),
    do: "rounded-full bg-emerald-100 px-2 py-1 text-xs font-medium text-emerald-700"

  defp check_badge_class("warn"),
    do: "rounded-full bg-amber-100 px-2 py-1 text-xs font-medium text-amber-700"

  defp check_badge_class("skip"),
    do: "rounded-full bg-sky-100 px-2 py-1 text-xs font-medium text-sky-700"

  defp check_badge_class(_),
    do: "rounded-full bg-rose-100 px-2 py-1 text-xs font-medium text-rose-700"

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no(_), do: "unknown"

  defp truthy_param?(value), do: value in [true, "true", "on", "1", 1]

  defp format_value(nil), do: "unknown"
  defp format_value(value), do: to_string(value)

  defp format_git(git) when is_map(git) do
    commit = git[:commit] || git["commit"] || "unknown"
    branch = git[:branch] || git["branch"]
    dirty? = git[:dirty?] || git["dirty?"]

    [commit, branch, if(dirty?, do: "dirty", else: nil)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp format_git(_), do: "unknown"

  defp shorten(nil), do: "unknown"

  defp shorten(value) when is_binary(value) and byte_size(value) > 24,
    do: String.slice(value, 0, 24) <> "..."

  defp shorten(value) when is_binary(value), do: value
  defp shorten(value), do: inspect(value)

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_), do: "unknown"

  defp format_ts(ts_ms) when is_integer(ts_ms) do
    ts_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  rescue
    _ -> Integer.to_string(ts_ms)
  end

  defp format_ts(_), do: "unknown"
end
