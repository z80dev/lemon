defmodule LemonWeb.OpsDashboardLive do
  @moduledoc false

  use LemonWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:checkpoint_preview, nil)
      |> assign_snapshot()

    {:ok, socket}
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

  def handle_event("abort-cron-run", %{"id" => run_id}, socket) do
    socket =
      case LemonWeb.OpsDashboard.abort_cron_run(run_id) do
        :ok ->
          socket
          |> put_flash(:info, "Cron run aborted.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Cron run could not be aborted.")
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

  def handle_event("checkpoint-diff", %{"id" => checkpoint_id}, socket) do
    socket =
      case LemonWeb.OpsDashboard.checkpoint_diff(checkpoint_id) do
        {:ok, preview} ->
          socket
          |> assign(:checkpoint_preview, preview)
          |> put_flash(:info, "Checkpoint diff loaded.")

        {:error, reason} ->
          put_flash(
            socket,
            :error,
            checkpoint_error(reason, "Checkpoint diff could not be loaded.")
          )
      end

    {:noreply, socket}
  end

  def handle_event("checkpoint-restore", %{"id" => checkpoint_id}, socket) do
    socket =
      case LemonWeb.OpsDashboard.checkpoint_restore(checkpoint_id) do
        {:ok, restored} ->
          socket
          |> assign(:checkpoint_preview, nil)
          |> put_flash(:info, "Checkpoint restored #{restored.restored_count} path(s).")
          |> assign_snapshot()

        {:error, reason} ->
          put_flash(socket, :error, checkpoint_error(reason, "Checkpoint could not be restored."))
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

  def handle_event("update-channel-discord-config", params, socket) do
    params =
      params
      |> Map.put("deny_unbound_channels", Map.get(params, "deny_unbound_channels", "false"))
      |> Map.put(
        "message_content_intent_enabled",
        Map.get(params, "message_content_intent_enabled", "false")
      )

    socket =
      case LemonWeb.OpsDashboard.update_channel_discord_config(params) do
        :ok ->
          socket
          |> put_flash(:info, "Discord configuration updated.")
          |> assign_snapshot()

        {:error, _reason} ->
          put_flash(socket, :error, "Discord configuration could not be updated.")
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
          <.metric title="Launch Readiness" value={format_value(@snapshot.readiness.status)} detail={"#{@snapshot.readiness.channels.blocked_count} blocked · #{@snapshot.readiness.channels.warning_count} warning"} />
          <.metric title="Browser" value={browser_label(@snapshot.browser)} detail={browser_detail(@snapshot.browser)} />
          <.metric title="Provider" value={provider_label(@snapshot.provider)} detail={provider_detail(@snapshot.provider)} />
          <.metric title="Usage" value={usage_label(@snapshot.usage)} detail={usage_detail(@snapshot.usage)} />
          <.metric title="Active Sessions" value={length(@snapshot.active_sessions)} detail="session workers with active runs" />
          <.metric title="Pending Approvals" value={length(@snapshot.pending_approvals)} detail="unexpired execution requests" />
          <.metric title="Observed Events" value={@snapshot.activity.total_events} detail="recent introspection entries scanned" />
          <.metric title="Kanban Boards" value={@snapshot.kanban.board_count} detail={"#{@snapshot.kanban.open_task_count} open tasks"} />
          <.metric title="Media Jobs" value={@snapshot.media.summary.count} detail={"#{@snapshot.media.summary.artifact_count} artifacts tracked"} />
          <.metric title="Proof Artifacts" value={@snapshot.proofs.proof_count} detail={"#{@snapshot.proofs.completed_count} passed · #{@snapshot.proofs.failed_count} failed"} />
          <.metric title="Memory Providers" value={@snapshot.memory.enabled_provider_count} detail={"#{@snapshot.memory.provider_count} registered"} />
          <.metric title="Terminal Backends" value={@snapshot.terminal_backends.count} detail={"default #{@snapshot.terminal_backends.default_backend || "unknown"}"} />
          <.metric title="LSP Diagnostics" value={@snapshot.lsp_diagnostics.supported_language_count} detail={"#{@snapshot.lsp_diagnostics.executable_summary.available_count} checkers available"} />
          <.metric title="Extensions" value={@snapshot.extensions.extension_file_count} detail={"#{@snapshot.extensions.existing_directory_count}/#{@snapshot.extensions.directory_count} dirs found"} />
        </section>

        <section class="mt-4 grid gap-4 xl:grid-cols-3">
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

          <.panel title="Browser Worker">
            <div class="space-y-3">
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <div class="flex items-center justify-between gap-3">
                  <p class="text-sm font-medium text-slate-900">Local Playwright driver</p>
                  <span class={status_badge_class(browser_label(@snapshot.browser))}>
                    {browser_label(@snapshot.browser)}
                  </span>
                </div>
                <p class="mt-1 text-xs text-slate-500">
                  requests: {format_value(@snapshot.browser.request_count)}
                  · completed: {format_value(@snapshot.browser.completed_count)}
                  · failed: {format_value(@snapshot.browser.failed_count)}
                  · pending: {format_value(@snapshot.browser.pending_requests)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  started: {format_value(@snapshot.browser.session.started_at)}
                  · last request: {format_value(@snapshot.browser.session.last_request_at)}
                  · pid hash: {format_value(@snapshot.browser.session.driver_pid_hash)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  mode: {format_value(@snapshot.browser.driver_config.mode)}
                  · attach only: {yes_no(@snapshot.browser.driver_config.attach_only)}
                  · launches browser: {yes_no(@snapshot.browser.driver_config.launches_browser)}
                  · endpoint hash: {format_value(@snapshot.browser.driver_config.cdp_endpoint_hash || "none")}
                </p>
                <%= if @snapshot.browser.last_error do %>
                  <p class="mt-1 text-xs text-rose-700">
                    {shorten(@snapshot.browser.last_error)}
                  </p>
                <% end %>
              </div>
              <div class="grid gap-2 sm:grid-cols-2">
                <%= for item <- @snapshot.browser.operator_guidance do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">
                        {format_value(item.message)}
                      </p>
                      <span class={status_badge_class(format_value(item.status))}>
                        {format_value(item.status)}
                      </span>
                    </div>
                    <p class="mt-1 text-xs text-slate-500">
                      next: {format_value(item.action)}
                    </p>
                  </div>
                <% end %>
              </div>
              <div class="grid gap-2 sm:grid-cols-2">
                <%= for capability <- @snapshot.browser.capabilities do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">
                        {capability.name}
                      </p>
                      <span class={status_badge_class(format_value(capability.status))}>
                        {format_value(capability.status)}
                      </span>
                    </div>
                  </div>
                <% end %>
              </div>
              <div>
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Artifacts</p>
                <code class="mt-1 block overflow-x-auto rounded-lg bg-slate-950 px-3 py-2 text-xs text-slate-100">
                  {format_value(@snapshot.browser.artifacts_dir)}
                </code>
                <p class="mt-2 text-xs text-slate-500">
                  {format_value(@snapshot.browser.artifact_summary.count)} files · {format_bytes(@snapshot.browser.artifact_summary.total_bytes)}
                  · cleanup: {format_value(@snapshot.browser.artifact_summary.cleanup.policy)}
                </p>
                <%= if @snapshot.browser.recent_artifacts == [] do %>
                  <p class="mt-2 text-xs text-slate-500">No recent browser artifacts.</p>
                <% else %>
                  <div class="mt-2 space-y-2">
                    <%= for artifact <- @snapshot.browser.recent_artifacts do %>
                      <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                        <p class="truncate text-sm font-medium text-slate-900">
                          {artifact.name}
                        </p>
                        <p class="mt-1 text-xs text-slate-500">
                          {format_bytes(artifact.bytes)} · {format_datetime(artifact.modified_at)}
                        </p>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </.panel>

          <.panel title="Media Jobs">
            <div class="space-y-3">
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Queue Metadata
                </p>
                <p class="mt-1 text-sm text-slate-800">
                  jobs: {format_value(@snapshot.media.summary.count)}
                  · artifacts: {format_value(@snapshot.media.summary.artifact_count)}
                  · bytes: {format_bytes(@snapshot.media.summary.artifact_total_bytes)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  cleanup: {format_value(@snapshot.media.summary.cleanup.policy)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  supervisor: {yes_no(@snapshot.media.worker_status.running)}
                  · active: {format_value(@snapshot.media.worker_status.active_jobs)}
                  · workers: {format_value(@snapshot.media.worker_status.workers)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  raw paths: {yes_no(@snapshot.media.summary.cleanup.includes_raw_paths)}
                  · prompts: {yes_no(@snapshot.media.summary.cleanup.includes_prompts)}
                  · bytes embedded: {yes_no(@snapshot.media.summary.cleanup.embeds_artifact_bytes_in_support_bundle)}
                </p>
              </div>
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <div class="flex items-center justify-between gap-3">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                    Provider Proofs
                  </p>
                  <span class={status_badge_class(format_value(@snapshot.media.provider_proofs.status))}>
                    {format_value(@snapshot.media.provider_proofs.status)}
                  </span>
                </div>
                <p class="mt-1 text-sm text-slate-800">
                  completed: {format_value(@snapshot.media.provider_proofs.completed_count)}
                  / {format_value(@snapshot.media.provider_proofs.required_count)}
                  · next: {format_value(@snapshot.media.provider_proofs.next_action)}
                </p>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  <%= for provider <- @snapshot.media.provider_proofs.providers do %>
                    <div class="rounded-lg border border-slate-200 bg-white px-3 py-2">
                      <div class="flex items-center justify-between gap-2">
                        <p class="text-xs font-medium text-slate-900">
                          {format_value(provider.label)}
                        </p>
                        <span class={status_badge_class(format_value(provider.status))}>
                          {format_value(provider.status)}
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        proof: {format_value(provider.proof_status || "missing")}
                        · model: {format_value(provider.model || "none")}
                      </p>
                      <p class="mt-1 text-xs text-slate-500">
                        providers: {format_provider_list(provider.providers || [provider.provider])}
                      </p>
                      <%= if provider.reason_kind do %>
                        <p class="mt-1 text-xs text-slate-500">
                          reason: {format_value(provider.reason_kind)}
                        </p>
                      <% end %>
                      <%= if provider.next_action do %>
                        <p class="mt-1 text-xs text-slate-500">
                          next: {format_value(provider.next_action)}
                        </p>
                      <% end %>
                      <p class="mt-1 text-xs text-slate-500">
                        proof path: {format_value(provider.proof_path)}
                      </p>
                      <code class="mt-2 block overflow-x-auto rounded-md bg-slate-950 px-2 py-1 text-[11px] text-slate-100">
                        {format_value(provider.command)}
                      </code>
                      <code class="mt-2 block overflow-x-auto rounded-md bg-slate-950 px-2 py-1 text-[11px] text-slate-100">
                        {format_value(provider.secret_command)}
                      </code>
                      <%= if Map.get(provider, :provider_commands, []) != [] do %>
                        <div class="mt-2 space-y-2">
                          <%= for command <- provider.provider_commands do %>
                            <div>
                              <p class="text-[11px] font-medium uppercase tracking-wide text-slate-500">
                                {format_value(command.provider)}
                              </p>
                              <code class="mt-1 block overflow-x-auto rounded-md bg-slate-950 px-2 py-1 text-[11px] text-slate-100">
                                {format_value(command.command)}
                              </code>
                              <code class="mt-1 block overflow-x-auto rounded-md bg-slate-950 px-2 py-1 text-[11px] text-slate-100">
                                {format_value(command.secret_command)}
                              </code>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
              <div>
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Job Store</p>
                <code class="mt-1 block overflow-x-auto rounded-lg bg-slate-950 px-3 py-2 text-xs text-slate-100">
                  {format_value(@snapshot.media.jobs_dir)}
                </code>
              </div>
              <%= if @snapshot.media.recent_jobs == [] do %>
                <p class="text-xs text-slate-500">No recent media jobs.</p>
              <% else %>
                <div class="space-y-2">
                  <%= for job <- @snapshot.media.recent_jobs do %>
                    <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-sm font-medium text-slate-900">
                          {format_value(job.type)} · {shorten(job.job_id)}
                        </p>
                        <span class={status_badge_class(format_value(job.status))}>
                          {format_value(job.status)}
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        channel: {format_value(Map.get(job, :channel, "unknown"))}
                        · artifact: {format_value(get_in(job, [:artifact, :name]) || "none")}
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </.panel>

          <.panel title="Proof Artifacts">
            <div class="space-y-3">
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Redacted Proof Summary
                </p>
                <p class="mt-1 text-sm text-slate-800">
                  proofs: {format_value(@snapshot.proofs.proof_count)}
                  · passed: {format_value(@snapshot.proofs.completed_count)}
                  · failed: {format_value(@snapshot.proofs.failed_count)}
                  · skipped: {format_value(@snapshot.proofs.skipped_count)}
                  · invalid: {format_value(@snapshot.proofs.invalid_count)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  raw paths: {yes_no(@snapshot.proofs.cleanup.includes_raw_paths)}
                  · filenames: {yes_no(@snapshot.proofs.cleanup.includes_raw_filenames)}
                  · details embedded: {yes_no(@snapshot.proofs.cleanup.embeds_proof_file_contents)}
                </p>
                <div class="mt-3 grid gap-2 sm:grid-cols-3">
                  <div class="rounded-lg border border-slate-200 bg-white px-3 py-2">
                    <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                      reason kinds
                    </p>
                    <p class="mt-1 text-sm text-slate-900">
                      {map_summary(@snapshot.proofs.reason_kind_counts)}
                    </p>
                  </div>
                  <div class="rounded-lg border border-slate-200 bg-white px-3 py-2">
                    <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                      proof scopes
                    </p>
                    <p class="mt-1 text-sm text-slate-900">
                      {map_summary(@snapshot.proofs.proof_scope_counts)}
                    </p>
                  </div>
                  <div class="rounded-lg border border-slate-200 bg-white px-3 py-2">
                    <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                      check names
                    </p>
                    <p class="mt-1 text-sm text-slate-900">
                      {map_summary(@snapshot.proofs.check_name_counts)}
                    </p>
                  </div>
                </div>
              </div>
              <div class="grid gap-2 sm:grid-cols-2">
                <%= for directory <- @snapshot.proofs.directories do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <p class="text-sm font-medium text-slate-900">{directory.label}</p>
                    <p class="mt-1 text-xs text-slate-500">
                      exists: {yes_no(directory.exists)} · files: {format_value(directory.file_count)}
                    </p>
                  </div>
                <% end %>
              </div>
              <%= if @snapshot.proofs.recent_proofs == [] do %>
                <p class="text-xs text-slate-500">No proof artifacts found.</p>
              <% else %>
                <div class="space-y-2">
                  <%= for proof <- @snapshot.proofs.recent_proofs do %>
                    <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-sm font-medium text-slate-900">
                          {proof.provider || proof.model || proof.reason_kind || proof.proof_hash}
                        </p>
                        <span class={status_badge_class(format_value(proof.status))}>
                          {format_value(proof.status)}
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        pass: {format_value(proof.completed_count)}
                        · fail: {format_value(proof.failed_count)}
                        · skip: {format_value(proof.skipped_count)}
                        · generated: {format_value(proof.generated_at)}
                      </p>
                      <%= if proof.reason_kind do %>
                        <p class="mt-1 text-xs text-slate-500">
                          reason: {proof.reason_kind}
                        </p>
                      <% end %>
                      <% redaction = Map.get(proof, :redaction, %{}) || %{} %>
                      <%= if map_size(redaction) > 0 do %>
                        <p class="mt-1 text-xs text-slate-500">
                          redaction: {map_summary(redaction)}
                        </p>
                      <% end %>
                      <% media_proof = Map.get(proof, :media_proof, %{}) || %{} %>
                      <%= if map_size(media_proof) > 0 do %>
                        <p class="mt-1 text-xs text-slate-500">
                          media:
                          {format_value(Map.get(media_proof, :provider))}
                          · {format_value(Map.get(media_proof, :model))}
                          · mime {format_value(Map.get(media_proof, :artifact_mime_type))}
                          · bytes {format_value(Map.get(media_proof, :artifact_bytes))}
                        </p>
                        <p class="mt-1 text-xs text-slate-500">
                          delivery:
                          telegram {yes_no(Map.get(media_proof, :telegram_delivery))}
                          · discord {yes_no(Map.get(media_proof, :discord_delivery))}
                          · document {yes_no(Map.get(media_proof, :telegram_has_document))}
                          · attachments {format_value(Map.get(media_proof, :discord_attachment_count))}
                          · media directive {yes_no(Map.get(media_proof, :media_directive_delivery))}
                          · directive leaked {yes_no(Map.get(media_proof, :directive_leaked))}
                          · marker {yes_no(Map.get(media_proof, :marker_seen))}
                          · hashes {yes_no(Map.get(media_proof, :has_artifact_hash))}
                        </p>
                      <% end %>
                      <% docker_hardening = get_in(proof, [:terminal_hardening, :docker]) || %{} %>
                      <%= if map_size(docker_hardening) > 0 do %>
                        <p class="mt-1 text-xs text-slate-500">
                          docker hardening:
                          rootfs {yes_no(Map.get(docker_hardening, :read_only_rootfs))}
                          · tmpfs noexec {yes_no(Map.get(docker_hardening, :tmpfs_noexec))}
                          · caps dropped {yes_no(Map.get(docker_hardening, :drops_capabilities))}
                          · no-new-privileges {yes_no(Map.get(docker_hardening, :no_new_privileges))}
                        </p>
                        <p class="mt-1 text-xs text-slate-500">
                          cgroups:
                          memory {yes_no(Map.get(docker_hardening, :cgroup_memory_limit))}
                          · cpu {yes_no(Map.get(docker_hardening, :cgroup_cpu_quota))}
                          · pids {yes_no(Map.get(docker_hardening, :cgroup_pids_limit))}
                          · network {format_value(Map.get(docker_hardening, :network))}
                          · pull {format_value(Map.get(docker_hardening, :pull_policy))}
                        </p>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <%= if Map.get(@snapshot.proofs, :latest_checks, []) != [] do %>
                <div class="space-y-2">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                    Latest checks
                  </p>
                  <%= for check <- @snapshot.proofs.latest_checks do %>
                    <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-sm font-medium text-slate-900">
                          {check.name || check.proof_hash}
                        </p>
                        <span class={status_badge_class(format_value(check.status))}>
                          {format_value(check.status)}
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        proof: {format_value(check.proof_object)}
                        ·
                        reason: {format_value(check.reason_kind)}
                        · modified: {format_value(check.modified_at)}
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
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
                    <%= if oauth_authorization_url(approval) do %>
                      <div class="mt-3 rounded-md border border-amber-200 bg-white px-2 py-2">
                        <a
                          href={oauth_authorization_url(approval)}
                          target="_blank"
                          rel="noreferrer"
                          class="inline-flex rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                        >
                          Open OAuth
                        </a>
                        <p class="mt-2 break-all text-xs text-amber-900">
                          resource: {oauth_action_value(approval, :resource) || "unknown"}
                        </p>
                        <p class="mt-1 break-all text-xs text-amber-900">
                          redirect: {oauth_action_value(approval, :redirect_uri) || "unknown"}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          scope: {oauth_action_value(approval, :scope) || "unspecified"}
                        </p>
                      </div>
                    <% end %>
                    <%= if sampling_approval?(approval) do %>
                      <div class="mt-3 rounded-md border border-amber-200 bg-white px-2 py-2">
                        <p class="text-xs font-semibold text-amber-950">MCP sampling request</p>
                        <p class="mt-1 text-xs text-amber-900">
                          model: {approval_action_value(approval, :requested_model) || "unspecified"}
                          · max tokens: {format_value(approval_action_value(approval, :max_tokens))}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          messages: {format_value(approval_action_value(approval, :message_count))}
                          · text chars: {format_value(approval_action_value(approval, :text_char_count))}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          roles: {format_inline_list(approval_action_value(approval, :roles))}
                        </p>
                        <p class="mt-1 text-xs text-amber-900">
                          content: {format_action_map(approval_action_value(approval, :content_kinds))}
                        </p>
                        <p class="mt-1 break-all text-xs text-amber-900">
                          request: {approval_action_value(approval, :request_hash) || "unknown"}
                        </p>
                      </div>
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
          <.panel title="Launch Readiness">
            <div class="space-y-3">
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <div class="flex items-center justify-between gap-3">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                    Compact Gate Summary
                  </p>
                  <span class={status_badge_class(format_value(@snapshot.readiness.status))}>
                    {format_value(@snapshot.readiness.status)}
                  </span>
                </div>
                <p class="mt-1 text-sm text-slate-800">
                  doctor: {format_value(@snapshot.readiness.doctor.overall)}
                  · channels: {format_value(@snapshot.readiness.channels.status)}
                  · media: {format_value(@snapshot.readiness.media_provider.status)}
                  · proofs: {format_value(@snapshot.readiness.proofs.proof_count)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  gates:
                  {format_value(@snapshot.readiness.channels.passed_count)} passed ·
                  {format_value(@snapshot.readiness.channels.warning_count)} warning ·
                  {format_value(@snapshot.readiness.channels.blocked_count)} blocked ·
                  {format_value(@snapshot.readiness.channels.skipped_count)} skipped
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  proof gates:
                  {format_value(Map.get(@snapshot.readiness.proof_gate_summary, "passedCount", 0))} passed ·
                  {format_value(Map.get(@snapshot.readiness.proof_gate_summary, "warningCount", 0))} warning ·
                  {format_value(Map.get(@snapshot.readiness.proof_gate_summary, "blockedCount", 0))} blocked
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  raw ids: {yes_no(@snapshot.readiness.cleanup.includes_chat_ids or @snapshot.readiness.cleanup.includes_channel_ids)}
                  · prompts: {yes_no(@snapshot.readiness.cleanup.includes_raw_prompts)}
                  · provider responses: {yes_no(@snapshot.readiness.cleanup.includes_raw_provider_responses)}
                  · proof details: {yes_no(@snapshot.readiness.cleanup.includes_raw_proof_details)}
                  · secrets: {yes_no(@snapshot.readiness.cleanup.includes_secret_values)}
                </p>
              </div>
              <div class="grid gap-2 sm:grid-cols-2">
                <%= for {gate_id, gate} <- @snapshot.readiness.proof_gates do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">
                        {format_value(gate_id)}
                      </p>
                      <span class={status_badge_class(format_value(Map.get(gate, "status")))}>
                        {format_value(Map.get(gate, "status"))}
                      </span>
                    </div>
                    <p class="mt-1 text-xs text-slate-500">
                      reason: {format_value(Map.get(gate, "reasonKind", "none"))}
                    </p>
                  </div>
                <% end %>
              </div>
              <%= if @snapshot.readiness.unresolved_gates == [] do %>
                <.empty text="No unresolved readiness gates in the compact summary." />
              <% else %>
                <div class="space-y-2">
                  <%= for gate <- @snapshot.readiness.unresolved_gates do %>
                    <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-sm font-medium text-slate-900">
                          {format_value(gate.id)}
                        </p>
                        <span class={status_badge_class(format_value(gate.status))}>
                          {format_value(gate.status)}
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        evidence: {format_value(gate.evidence)}
                        · reason: {format_value(gate.reason_kind)}
                        <%= if Map.get(gate, :reason_kinds, []) != [] do %>
                          · reasons: {format_value(gate.reason_kinds)}
                        <% end %>
                      </p>
                      <p class="mt-1 text-xs text-slate-500">
                        next: {format_value(gate.next_action)}
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </.panel>

          <.panel title="Usage and Quotas">
            <div class="space-y-3">
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <div class="flex items-center justify-between gap-3">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                    Current Aggregate
                  </p>
                  <span class={status_badge_class(format_value(@snapshot.usage.status))}>
                    {format_value(@snapshot.usage.status)}
                  </span>
                </div>
                <p class="mt-1 text-sm text-slate-800">
                  cost: {format_money(@snapshot.usage.total_cost)}
                  · requests: {format_value(@snapshot.usage.total_requests)}
                  · tokens: {format_value(@snapshot.usage.total_tokens.total)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  input: {format_value(@snapshot.usage.total_tokens.input)}
                  · output: {format_value(@snapshot.usage.total_tokens.output)}
                  · providers: {format_value(@snapshot.usage.provider_count)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  prompts: {yes_no(@snapshot.usage.cleanup.includes_prompts)}
                  · responses: {yes_no(@snapshot.usage.cleanup.includes_responses)}
                  · message bodies: {yes_no(@snapshot.usage.cleanup.includes_message_bodies)}
                  · credentials: {yes_no(@snapshot.usage.cleanup.includes_credentials)}
                  · secrets: {yes_no(@snapshot.usage.cleanup.includes_secret_values)}
                </p>
              </div>
              <div class="grid gap-2 sm:grid-cols-3">
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Run Limit</p>
                  <p class="mt-1 text-sm text-slate-900">
                    {format_value(@snapshot.usage.quotas.runs_limit || "unlimited")}
                  </p>
                </div>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Token Limit</p>
                  <p class="mt-1 text-sm text-slate-900">
                    {format_value(@snapshot.usage.quotas.tokens_limit || "unlimited")}
                  </p>
                </div>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Cost Limit</p>
                  <p class="mt-1 text-sm text-slate-900">
                    {format_money(@snapshot.usage.quotas.cost_limit)}
                  </p>
                </div>
              </div>
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Today
                </p>
                <p class="mt-1 text-sm text-slate-800">
                  {format_value(@snapshot.usage.today.date)}
                  · {format_money(@snapshot.usage.today.cost)}
                  · {format_value(@snapshot.usage.today.requests)} requests
                </p>
              </div>
              <%= if @snapshot.usage.providers == [] do %>
                <.empty text="No usage provider rows recorded." />
              <% else %>
                <div class="space-y-2">
                  <%= for provider <- @snapshot.usage.providers do %>
                    <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-sm font-medium text-slate-900">
                          {format_value(provider.provider)}
                        </p>
                        <span class={status_badge_class("ok")}>
                          {format_value(provider.requests)} req
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        cost: {format_money(provider.cost)}
                        · input: {format_value(provider.input_tokens)}
                        · output: {format_value(provider.output_tokens)}
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </.panel>

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
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Runtime Provider Readiness
                </p>
                <p class="mt-1 text-sm text-slate-800">
                  ready: {format_value(@snapshot.provider.readiness.ready_count)}
                  / {format_value(@snapshot.provider.readiness.count)}
                  · default: {format_value(@snapshot.provider.readiness.default_provider)}
                  · model: {format_value(@snapshot.provider.readiness.default_model)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  raw keys: {yes_no(@snapshot.provider.readiness.cleanup.includes_raw_api_keys)}
                  · secret names: {yes_no(@snapshot.provider.readiness.cleanup.includes_secret_names)}
                  · base URLs: {yes_no(@snapshot.provider.readiness.cleanup.includes_raw_base_urls)}
                  · env names: {yes_no(@snapshot.provider.readiness.cleanup.includes_env_var_names)}
                </p>
                <div class="mt-2 rounded-md bg-white px-2 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="text-xs font-medium text-slate-800">
                      Routing Preview
                    </p>
                    <span class={status_badge_class(if @snapshot.provider.readiness.routing.enabled?, do: "ok", else: "disabled")}>
                      {@snapshot.provider.readiness.routing.decision || "unavailable"}
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-500">
                    requested: {format_value(@snapshot.provider.readiness.routing.requested_provider)}
                    · selected: {format_value(@snapshot.provider.readiness.routing.selected_provider)}
                    · fallbacks: {format_provider_list(@snapshot.provider.readiness.routing.fallback_providers)}
                  </p>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <%= for candidate <- @snapshot.provider.readiness.routing.candidate_providers do %>
                      <span class={provider_candidate_class(candidate)}>
                        {candidate.provider || "unknown"} · {candidate.role || "candidate"} · {if candidate.credential_ready?, do: "ready", else: "not ready"}
                      </span>
                    <% end %>
                  </div>
                  <p class="mt-2 text-xs text-slate-500">
                    credential refs: {format_value(length(@snapshot.provider.readiness.routing.credential_pool.providers))}
                    providers tracked · routing raw keys: {yes_no(@snapshot.provider.readiness.routing.cleanup.includes_raw_api_keys)}
                  </p>
                </div>
                <div class="mt-2 rounded-md bg-white px-2 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="text-xs font-medium text-slate-800">
                      Live Fallback Proof
                    </p>
                    <span class={status_badge_class(format_value(@snapshot.provider.live_proofs.fallback.status))}>
                      {format_value(@snapshot.provider.live_proofs.fallback.status)}
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-500">
                    primary: {format_value(@snapshot.provider.live_proofs.fallback.primary_provider)}
                    · fallback: {format_value(@snapshot.provider.live_proofs.fallback.fallback_provider)}
                    · final: {format_value(@snapshot.provider.live_proofs.fallback.final_provider)}
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    proof: {format_value(@snapshot.provider.live_proofs.fallback.proof_object)}
                    · result: {format_value(@snapshot.provider.live_proofs.fallback.proof_status)}
                    · modified: {format_value(@snapshot.provider.live_proofs.fallback.modified_at)}
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    next: {format_value(@snapshot.provider.live_proofs.fallback.next_action)}
                    · hash: {shorten(@snapshot.provider.live_proofs.fallback.proof_hash)}
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    raw keys: {yes_no(@snapshot.provider.live_proofs.cleanup.includes_raw_api_keys)}
                    · prompts: {yes_no(@snapshot.provider.live_proofs.cleanup.includes_raw_prompts)}
                    · answers: {yes_no(@snapshot.provider.live_proofs.cleanup.includes_provider_answers)}
                  </p>
                </div>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  <%= for provider <- @snapshot.provider.readiness.providers do %>
                    <div class="rounded-md bg-white px-2 py-2">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-xs font-medium text-slate-800">
                          {provider.provider}
                        </p>
                        <span class={run_badge_class(provider.credential_ready?)}>
                          {if provider.credential_ready?, do: "ready", else: "not ready"}
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        configured: {yes_no(provider.configured?)}
                        · env: {yes_no(provider.env_configured?)}
                        · key ref: {yes_no(provider.api_key_secret_configured? || provider.oauth_secret_configured?)}
                        · base URL: {yes_no(provider.base_url_configured?)}
                      </p>
                    </div>
                  <% end %>
                </div>
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
              <span>{@snapshot.cron.active_run_count} active</span>
              <span>{@snapshot.cron.failed_run_count} failed recent runs</span>
              <span>{@snapshot.cron.retry_run_count} retry runs</span>
              <span>{@snapshot.cron.suppressed_run_count} suppressed slots</span>
              <span>{@snapshot.cron.stale_recovery_count} stale recoveries</span>
              <span>{@snapshot.cron.retry_scheduled_count} retries scheduled</span>
              <span>next {format_ts(@snapshot.cron.next_run_at_ms)}</span>
              <span>last {format_ts(@snapshot.cron.last_run_at_ms)}</span>
            </div>
            <%= if @snapshot.cron.recent_audit_events != [] do %>
              <div class="mb-3 rounded-lg border border-slate-200 bg-white px-3 py-2">
                <p class="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Recent Lifecycle Audit
                </p>
                <div class="mt-2 grid gap-1">
                  <%= for audit <- @snapshot.cron.recent_audit_events do %>
                    <div class="min-w-0 rounded-md border border-slate-100 bg-slate-50 px-2 py-1 text-xs">
                      <div class="flex min-w-0 flex-wrap items-center gap-2">
                        <span class="font-medium text-slate-800">{audit.action}</span>
                        <span class="text-slate-500">{format_ts(audit.ts_ms)}</span>
                        <%= if audit.status do %>
                          <span class={status_badge_class(audit.status)}>{audit.status}</span>
                        <% end %>
                      </div>
                      <p class="mt-1 truncate text-slate-500">
                        {audit.triggered_by || audit.source || "cron"} · job {audit.job_id || "unknown"}
                        <%= if audit.run_id do %>
                          · run {audit.run_id}
                        <% end %>
                      </p>
                      <%= if audit.changed_fields != [] do %>
                        <p class="mt-1 truncate text-slate-500">
                          fields {Enum.join(audit.changed_fields, ", ")}
                        </p>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
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
                <input
                  name="max_retries"
                  type="number"
                  min="0"
                  value="0"
                  aria-label="Max retries"
                  class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                />
                <input
                  name="retry_backoff_ms"
                  type="number"
                  min="0"
                  value="30000"
                  aria-label="Retry backoff milliseconds"
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
                    <%= if job.latest_run_status do %>
                      <div class="mt-2 flex flex-wrap items-center gap-2 text-xs text-slate-500">
                        <span class={status_badge_class(job.latest_run_status)}>
                          {job.latest_run_status}
                        </span>
                        <span>{job.latest_run_triggered_by || "unknown"}</span>
                        <span>{format_ts(job.latest_run_started_at_ms)}</span>
                        <%= if job.latest_run_retry_attempt > 0 do %>
                          <span>retry {job.latest_run_retry_attempt}</span>
                        <% end %>
                      </div>
                    <% end %>
                    <%= if job.recent_runs != [] do %>
                      <div class="mt-2 grid gap-1">
                        <%= for run <- job.recent_runs do %>
                          <div class="flex min-w-0 items-center justify-between gap-2 rounded-md border border-slate-200 bg-white px-2 py-1 text-xs">
                            <div class="flex min-w-0 items-center gap-2">
                              <span class={status_badge_class(run.status)}>{run.status}</span>
                              <span class="truncate text-slate-500">
                                {run.triggered_by || "unknown"} · {format_ts(run.started_at_ms)}
                              </span>
                            </div>
                            <%= if run.retry_attempt > 0 do %>
                              <span class="shrink-0 text-slate-500">retry {run.retry_attempt}</span>
                            <% end %>
                            <%= if cron_run_active?(run) do %>
                              <button
                                type="button"
                                phx-click="abort-cron-run"
                                phx-value-id={run.id}
                                class="shrink-0 rounded-md bg-rose-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
                              >
                                Abort
                              </button>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
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
                        <input
                          name="max_retries"
                          type="number"
                          min="0"
                          value={job.max_retries}
                          aria-label="Max retries"
                          class="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
                        />
                        <input
                          name="retry_backoff_ms"
                          type="number"
                          min="0"
                          value={job.retry_backoff_ms}
                          aria-label="Retry backoff milliseconds"
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
                          {if job.enabled?, do: "Pause", else: "Resume"}
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

          <.panel title="Memory Providers">
            <div class="space-y-3">
              <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <div class="flex items-center justify-between gap-3">
                  <p class="text-sm font-medium text-slate-900">Search and ingest providers</p>
                  <span class={status_badge_class(if @snapshot.memory.enabled_provider_count > 0, do: "ok", else: "empty")}>
                    {@snapshot.memory.enabled_provider_count}/{@snapshot.memory.provider_count} enabled
                  </span>
                </div>
                <p class="mt-1 text-xs text-slate-500">
                  memory contents: {yes_no(@snapshot.memory.cleanup.includes_memory_contents)}
                  · raw config: {yes_no(@snapshot.memory.cleanup.includes_raw_provider_config)}
                  · secrets: {yes_no(@snapshot.memory.cleanup.includes_secret_values)}
                </p>
                <p class="mt-1 text-xs text-slate-500">
                  Read-only provider shape is exposed through
                  <code class="rounded bg-white px-1 py-0.5">memory.status</code>
                  and support-bundle
                  <code class="rounded bg-white px-1 py-0.5">memory_diagnostics.json</code>.
                </p>
              </div>
              <%= if @snapshot.memory.providers == [] do %>
                <.empty text="No memory providers registered." />
              <% else %>
                <div class="space-y-2">
                  <%= for provider <- @snapshot.memory.providers do %>
                    <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                      <div class="flex items-center justify-between gap-3">
                        <p class="truncate text-sm font-medium text-slate-900">
                          {provider.id || "unknown"}
                        </p>
                        <span class={status_badge_class(if provider.enabled, do: "ok", else: "disabled")}>
                          <%= if provider.enabled do %>enabled<% else %>disabled<% end %>
                        </span>
                      </div>
                      <p class="mt-1 text-xs text-slate-500">
                        source: {format_value(provider.source)}
                        · scopes: {format_provider_list(provider.scopes || [])}
                        · timeout: {format_value(provider.timeout_ms)}ms
                        · module loaded: {yes_no(provider.module_loaded)}
                      </p>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </.panel>

          <.panel title="Extensions">
            <div class="mb-3 flex flex-wrap gap-2 text-xs text-slate-500">
              <span>{@snapshot.extensions.extension_file_count} extension files</span>
              <span>{@snapshot.extensions.valid_manifest_count}/{@snapshot.extensions.manifest_count} manifests valid</span>
              <span>{@snapshot.extensions.nested_lib_file_count} nested lib files</span>
              <span>{@snapshot.extensions.configured_extension_path_count} configured paths</span>
            </div>
            <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <div class="flex items-center justify-between gap-3">
                <p class="text-sm font-medium text-slate-900">Directory diagnostics</p>
                <span class={status_badge_class(@snapshot.extensions.status)}>
                  {@snapshot.extensions.status}
                </span>
              </div>
              <p class="mt-1 text-xs text-slate-500">
                raw paths: {yes_no(@snapshot.extensions.cleanup.includes_raw_source_paths)}
                · file contents: {yes_no(@snapshot.extensions.cleanup.includes_file_contents)}
                · load messages: {yes_no(@snapshot.extensions.cleanup.includes_load_error_messages)}
                · manifest contents: {yes_no(@snapshot.extensions.cleanup.includes_manifest_contents)}
                · distribution URLs: {yes_no(@snapshot.extensions.cleanup.includes_distribution_urls)}
                · code loaded: {yes_no(@snapshot.extensions.cleanup.loads_extension_code)}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                enabled: {yes_no(@snapshot.extensions.execution.enabled)}
                ·
                default dirs auto-load: {yes_no(@snapshot.extensions.execution.auto_load_default_paths)}
                · diagnostics-only: {yes_no(@snapshot.extensions.execution.default_directories_diagnostics_only)}
                · configured execution paths: {@snapshot.extensions.execution.configured_extension_path_count}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                host runtime: degraded {@snapshot.extensions.host_runtime.degraded_host_count}
                · manifest-only {@snapshot.extensions.host_runtime.manifest_only_host_count}
                · health loads code: {yes_no(@snapshot.extensions.host_runtime.runtime_health_loads_extension_code)}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                telemetry proof: {@snapshot.extensions.execution_telemetry.proof_status}
                · check {@snapshot.extensions.execution_telemetry.telemetry_check_status}
                · redacted start/stop/exception: {yes_no(@snapshot.extensions.execution_telemetry.emits_redacted_start_stop_exception)}
                · disabled explicit paths: {yes_no(@snapshot.extensions.execution_telemetry.blocks_disabled_explicit_paths)}
                · proof hash: {format_value(@snapshot.extensions.execution_telemetry.proof_hash)}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                WASM telemetry proof: {@snapshot.extensions.wasm_telemetry.proof_status}
                · success/error/exception checks: {@snapshot.extensions.wasm_telemetry.success_check_status}/{@snapshot.extensions.wasm_telemetry.error_check_status}/{@snapshot.extensions.wasm_telemetry.exception_check_status}
                · redacted wrapper events: {yes_no(@snapshot.extensions.wasm_telemetry.emits_redacted_start_stop_exception)}
                · proof hash: {format_value(@snapshot.extensions.wasm_telemetry.proof_hash)}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                WASM policy proof: {@snapshot.extensions.wasm_policy.proof_status}
                · risky capabilities approval: {yes_no(@snapshot.extensions.wasm_policy.capability_approval_defaults)}
                · explicit override: {yes_no(@snapshot.extensions.wasm_policy.explicit_override_supported)}
                · proof hash: {format_value(@snapshot.extensions.wasm_policy.proof_hash)}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                Registry audit proof: {@snapshot.extensions.registry_audit.proof_status}
                · install/update workflow: {yes_no(@snapshot.extensions.registry_audit.registry_workflow_supported)}
                · installable/blocked: {@snapshot.extensions.registry_audit.registry_boundary.installable_count}/{@snapshot.extensions.registry_audit.registry_boundary.blocked_count}
                · proof hash: {format_value(@snapshot.extensions.registry_audit.proof_hash)}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                WASM lifecycle proof: {@snapshot.extensions.wasm_lifecycle.proof_status}
                · lifecycle: {yes_no(@snapshot.extensions.wasm_lifecycle.lifecycle_supported)}
                · discover/invoke: {@snapshot.extensions.wasm_lifecycle.discover_check_status}/{@snapshot.extensions.wasm_lifecycle.invoke_check_status}
                · stop: {@snapshot.extensions.wasm_lifecycle.stop_check_status}
                · proof hash: {format_value(@snapshot.extensions.wasm_lifecycle.proof_hash)}
              </p>
              <p class="mt-1 text-xs text-slate-500">
                Deep load, conflict, provider, and WASM shape is exposed through read-only
                <code class="rounded bg-white px-1 py-0.5">extensions.status</code>.
              </p>
            </div>
            <div class="mt-3 grid gap-2 sm:grid-cols-2">
              <.extension_count_group title="Capabilities" counts={@snapshot.extensions.capability_counts} />
              <.extension_count_group title="Provider Types" counts={@snapshot.extensions.provider_type_counts} />
              <.extension_count_group title="Host Types" counts={@snapshot.extensions.host_type_counts} />
              <.extension_count_group title="Distribution" counts={@snapshot.extensions.distribution_source_counts} />
            </div>
            <%= if @snapshot.extensions.directories == [] do %>
              <.empty text="No extension directories inspected." />
            <% else %>
              <div class="mt-3 space-y-2">
                <%= for directory <- @snapshot.extensions.directories do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">
                        {directory.path_hash}
                      </p>
                      <span class={status_badge_class(if directory.exists, do: "ok", else: "empty")}>
                        <%= if directory.exists do %>exists<% else %>missing<% end %>
                      </span>
                    </div>
                    <p class="mt-1 text-xs text-slate-500">
                      files: {format_value(directory.extension_file_count)}
                      · nested lib: {format_value(directory.nested_lib_file_count)}
                      · manifests: {format_value(directory.valid_manifest_count)}
                      / {format_value(directory.manifest_file_count)}
                      · file hashes: {format_value(length(directory.extension_file_hashes || []))}
                    </p>
                  </div>
                <% end %>
              </div>
            <% end %>
          </.panel>

          <.panel title="Channel Config">
            <div class="mb-3 text-xs text-slate-500">
              {@snapshot.channels.enabled_count} enabled transports · {@snapshot.channels.running_count || 0} running · {length(@snapshot.channels.bindings)} bindings
            </div>
            <%= if Map.get(@snapshot.channels, :readiness, %{}) != %{} do %>
              <div class="mb-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                <div class="flex items-center justify-between gap-3">
                  <p class="text-sm font-medium text-slate-900">Launch gates</p>
                  <span class={status_badge_class(format_value(@snapshot.channels.readiness.status))}>
                    {format_value(@snapshot.channels.readiness.status)}
                  </span>
                </div>
                <p class="mt-1 text-xs text-slate-500">
                  {format_value(@snapshot.channels.readiness.passed_count)} passed · {format_value(@snapshot.channels.readiness.warning_count)} warning · {format_value(@snapshot.channels.readiness.blocked_count)} blocked · {format_value(@snapshot.channels.readiness.skipped_count)} skipped
                </p>
              </div>
            <% end %>
            <%= if Map.get(@snapshot.channels, :failure_drilldown, []) != [] do %>
              <div class="mb-3 grid gap-2 sm:grid-cols-2">
                <%= for failure <- @snapshot.channels.failure_drilldown do %>
                  <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                    <div class="flex items-center justify-between gap-3">
                      <p class="truncate text-sm font-medium text-slate-900">{failure.label}</p>
                      <span class={status_badge_class(format_value(failure.status))}>
                        {format_value(failure.status)}
                      </span>
                    </div>
                    <p class="mt-1 text-xs text-slate-500">{failure.evidence}</p>
                    <p class="mt-1 text-xs text-slate-500">
                      next: {failure.next_action}
                    </p>
                    <p class="mt-1 text-xs text-slate-500">
                      source: {format_value(failure.source)}
                    </p>
                  </div>
                <% end %>
              </div>
            <% end %>
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
            <form phx-submit="update-channel-discord-config" class="mb-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <label class="text-xs font-medium uppercase tracking-wide text-slate-500">
                Discord Access
              </label>
              <input
                name="bot_token_secret"
                type="text"
                placeholder="discord_bot_token"
                value={@snapshot.channels.discord.bot_token_secret}
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
              />
              <input
                name="allowed_guild_ids"
                type="text"
                placeholder="guild id, guild id"
                value={Enum.join(@snapshot.channels.discord.allowed_guild_ids || [], ", ")}
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
              />
              <input
                name="allowed_channel_ids"
                type="text"
                placeholder="channel id, channel id"
                value={Enum.join(@snapshot.channels.discord.allowed_channel_ids || [], ", ")}
                class="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-900"
              />
              <div class="mt-2 flex flex-wrap items-center gap-2">
                <label class="inline-flex items-center gap-1 text-xs text-slate-600">
                  <input
                    type="checkbox"
                    name="deny_unbound_channels"
                    value="true"
                    checked={@snapshot.channels.discord.deny_unbound_channels?}
                    class="rounded border-slate-300"
                  />
                  Deny Unbound
                </label>
                <label class="inline-flex items-center gap-1 text-xs text-slate-600">
                  <input
                    type="checkbox"
                    name="message_content_intent_enabled"
                    value="true"
                    checked={@snapshot.channels.discord.message_content_intent_enabled?}
                    class="rounded border-slate-300"
                  />
                  Message Content Intent Declared
                </label>
                <button
                  type="submit"
                  class="rounded-md bg-slate-900 px-2 py-1 text-xs font-medium text-white shadow-sm"
                >
                  Save Discord
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

          <.panel title="Checkpoints">
            <div class="grid gap-2 sm:grid-cols-3">
              <.metric title="Total" value={@snapshot.checkpoints.count} detail="All known checkpoints" />
              <.metric
                title="Filesystem"
                value={@snapshot.checkpoints.filesystem_count}
                detail="Restorable file checkpoints"
              />
              <.metric
                title="Invalid"
                value={@snapshot.checkpoints.invalid_count}
                detail="Unreadable checkpoint records"
              />
            </div>
            <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-2">
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Store</dt>
                <dd class="mt-1 truncate text-slate-900">{@snapshot.checkpoints.store_dir || "unknown"}</dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Cleanup</dt>
                <dd class="mt-1 text-slate-900">{@snapshot.checkpoints.cleanup.policy || "unknown"}</dd>
              </div>
            </dl>
            <div class="mt-3 space-y-2">
              <%= for checkpoint <- @snapshot.checkpoints.recent do %>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <p class="truncate text-sm font-medium text-slate-900">
                    {checkpoint.checkpoint_id}
                  </p>
                  <p class="mt-1 text-xs text-slate-600">
                    {checkpoint.kind || "session"} - {checkpoint.tool || "unknown"} - {checkpoint.path_count || 0} paths
                  </p>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <button
                      type="button"
                      phx-click="checkpoint-diff"
                      phx-value-id={checkpoint.checkpoint_id}
                      class="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 shadow-sm"
                    >
                      Preview Diff
                    </button>
                    <button
                      type="button"
                      phx-click="checkpoint-restore"
                      phx-value-id={checkpoint.checkpoint_id}
                      class="rounded-md bg-rose-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
                    >
                      Restore All
                    </button>
                  </div>
                  <%= if checkpoint.rollback do %>
                    <div class="mt-2 grid gap-2 text-xs lg:grid-cols-2">
                      <div>
                        <p class="font-medium uppercase tracking-wide text-slate-500">Diff</p>
                        <code class="mt-1 block overflow-x-auto rounded bg-white px-2 py-1 text-slate-700">
                          {checkpoint.rollback.tui_diff}
                        </code>
                        <code class="mt-1 block overflow-x-auto rounded bg-white px-2 py-1 text-slate-700">
                          {checkpoint.rollback.control_plane_diff}
                        </code>
                      </div>
                      <div>
                        <p class="font-medium uppercase tracking-wide text-slate-500">Restore</p>
                        <code class="mt-1 block overflow-x-auto rounded bg-white px-2 py-1 text-slate-700">
                          {checkpoint.rollback.tui_restore}
                        </code>
                        <code class="mt-1 block overflow-x-auto rounded bg-white px-2 py-1 text-slate-700">
                          {checkpoint.rollback.control_plane_restore}
                        </code>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <%= if Enum.empty?(@snapshot.checkpoints.recent) do %>
                <p class="text-sm text-slate-600">No recent checkpoints.</p>
              <% end %>
            </div>
            <%= if @checkpoint_preview do %>
              <div class="mt-3 rounded-lg border border-slate-200 bg-white px-3 py-2">
                <p class="text-sm font-medium text-slate-900">
                  Diff preview: {@checkpoint_preview.checkpoint_id}
                </p>
                <p class="mt-1 text-xs text-slate-600">
                  Changed paths: {@checkpoint_preview.changed_count}
                </p>
                <pre class="mt-2 max-h-64 overflow-auto rounded bg-slate-950 p-3 text-xs text-slate-100"><code>{@checkpoint_preview.output}</code></pre>
              </div>
            <% end %>
          </.panel>

          <.panel title="Goals">
            <div class="grid gap-2 sm:grid-cols-4">
              <.metric title="Total" value={@snapshot.goals.count} detail="Known goal records" />
              <.metric title="Active" value={@snapshot.goals.active_count} detail="Runnable objectives" />
              <.metric title="Paused" value={@snapshot.goals.paused_count} detail="Held objectives" />
              <.metric title="Complete" value={@snapshot.goals.completed_count} detail="Finished goals" />
            </div>
            <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-2">
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Objective Text</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.goals.cleanup.includes_objectives do %>
                    visible
                  <% else %>
                    redacted
                  <% end %>
                </dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Session IDs</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.goals.cleanup.includes_raw_session_ids do %>
                    visible
                  <% else %>
                    hashed
                  <% end %>
                </dd>
              </div>
            </dl>
            <div class="mt-3 space-y-2">
              <%= for goal <- @snapshot.goals.recent do %>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="truncate text-sm font-medium text-slate-900">{goal.goal_id}</p>
                    <span class="rounded-full bg-slate-200 px-2 py-0.5 text-xs font-medium text-slate-700">
                      {goal.status || "unknown"}
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-600">
                    {goal.agent_id || "unassigned"} - {goal.objective_bytes || 0} bytes - {goal.continuation_count || 0}/{goal.max_continuations || "unlimited"} continuations
                  </p>
                  <%= if goal.loop_status do %>
                    <p class="mt-1 text-xs text-slate-600">
                      loop {goal.loop_status}<%= if goal.loop_last_action do %> - last verdict {goal.loop_last_action}<% end %>
                    </p>
                  <% end %>
                  <p class="mt-1 truncate text-xs text-slate-500">
                    session {goal.session_hash || "unknown"}
                  </p>
                </div>
              <% end %>
              <%= if Enum.empty?(@snapshot.goals.recent) do %>
                <p class="text-sm text-slate-600">No goal records yet.</p>
              <% end %>
            </div>
          </.panel>

          <.panel title="Kanban Boards">
            <div class="grid gap-2 sm:grid-cols-4">
              <.metric title="Boards" value={@snapshot.kanban.board_count} detail="Known boards" />
              <.metric title="Active" value={@snapshot.kanban.active_board_count} detail="Runnable boards" />
              <.metric title="Tasks" value={@snapshot.kanban.task_count} detail="Recent task rows" />
              <.metric title="Open" value={@snapshot.kanban.open_task_count} detail="Not done" />
            </div>
            <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-2">
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Task Text</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.kanban.cleanup.includes_titles or @snapshot.kanban.cleanup.includes_descriptions do %>
                    visible
                  <% else %>
                    redacted
                  <% end %>
                </dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Session IDs</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.kanban.cleanup.includes_raw_session_ids do %>
                    visible
                  <% else %>
                    redacted
                  <% end %>
                </dd>
              </div>
            </dl>
            <div class="mt-3 space-y-2">
              <%= for board <- @snapshot.kanban.recent_boards do %>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="truncate text-sm font-medium text-slate-900">{board.board_id}</p>
                    <span class="rounded-full bg-slate-200 px-2 py-0.5 text-xs font-medium text-slate-700">
                      {board.status || "unknown"}
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-600">
                    {board.task_count || 0} tasks - {board.open_task_count || 0} open - {board.leased_task_count || 0} leased
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    columns: {Enum.join(board.columns || [], ", ")} - workspace {board.workspace_hash || "unknown"}
                  </p>
                  <%= if board.tasks != [] do %>
                    <div class="mt-2 space-y-1">
                      <%= for task <- board.tasks do %>
                        <div class="rounded-md bg-white px-2 py-1">
                          <div class="flex items-center justify-between gap-2">
                            <p class="truncate text-xs font-medium text-slate-700">{task.task_id}</p>
                            <span class="text-xs text-slate-500">{task.status || "unknown"}</span>
                          </div>
                          <p class="mt-1 text-xs text-slate-500">
                            {task.priority || "normal"} - {task.worker_profile || task.assignee || "unassigned"} - {task.comment_count || 0} comments
                            <%= if Map.get(task, :leased?) do %> - leased<% end %>
                          </p>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
              <%= if Enum.empty?(@snapshot.kanban.recent_boards) do %>
                <p class="text-sm text-slate-600">No kanban boards yet.</p>
              <% end %>
            </div>
          </.panel>

          <.panel title="Terminal Backends">
            <div class="grid gap-2 sm:grid-cols-3">
              <.metric title="Backends" value={@snapshot.terminal_backends.count} detail="Registered" />
              <.metric title="Default" value={@snapshot.terminal_backends.default_backend || "unknown"} detail="Selected when omitted" />
              <.metric
                title="Policy"
                value={if @snapshot.terminal_backends.policy.backend_allowlist_configured, do: "allowlist", else: "default"}
                detail={"#{length(@snapshot.terminal_backends.policy.denied_backends || [])} denied / #{length(@snapshot.terminal_backends.policy.approval_required_backends || [])} approval"}
              />
            </div>
            <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-3">
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Commands</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.terminal_backends.cleanup.includes_commands do %>visible<% else %>redacted<% end %>
                </dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Environment</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.terminal_backends.cleanup.includes_environment do %>visible<% else %>redacted<% end %>
                </dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Process Output</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.terminal_backends.cleanup.includes_process_output do %>visible<% else %>redacted<% end %>
                </dd>
              </div>
            </dl>
            <div class="mt-3 space-y-2">
              <%= for backend <- @snapshot.terminal_backends.backends do %>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="truncate text-sm font-medium text-slate-900">
                      {backend.label || backend.id || "unknown"}
                    </p>
                    <span class="rounded-full bg-slate-200 px-2 py-0.5 text-xs font-medium text-slate-700">
                      <%= if backend.available do %>available<% else %>unavailable<% end %>
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-600">
                    id {backend.id || "unknown"} - transport {backend.transport || "unknown"} - isolation {backend.isolation || "unknown"}
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    supervised {format_value(backend.supervised)} - pty {format_value(backend.pty)} - capabilities {Enum.join(backend.capabilities || [], ", ")}
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    policy {if backend.policy.allowed, do: "allowed", else: "blocked"} - denylisted {format_value(backend.policy.denylisted)}
                  </p>
                </div>
              <% end %>
              <%= if Enum.empty?(@snapshot.terminal_backends.backends) do %>
                <p class="text-sm text-slate-600">No terminal backends registered.</p>
              <% end %>
            </div>
          </.panel>

          <.panel title="LSP Diagnostics">
            <div class="grid gap-2 sm:grid-cols-3">
              <.metric
                title="Languages"
                value={@snapshot.lsp_diagnostics.supported_language_count}
                detail="Extension groups"
              />
              <.metric
                title="Checkers"
                value={@snapshot.lsp_diagnostics.executable_summary.available_count}
                detail={"#{@snapshot.lsp_diagnostics.executable_summary.missing_count} missing"}
              />
              <.metric
                title="Timeout"
                value={"#{@snapshot.lsp_diagnostics.default_timeout_ms}ms"}
                detail={format_value(@snapshot.lsp_diagnostics.status)}
              />
            </div>
            <div class="mt-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
              <div class="flex items-center justify-between gap-3">
                <p class="text-sm font-medium text-slate-900">Language-server manager</p>
                <span class={status_badge_class(if @snapshot.lsp_diagnostics.server_manager.running, do: "ok", else: "missing")}>
                  <%= if @snapshot.lsp_diagnostics.server_manager.running do %>running<% else %>unavailable<% end %>
                </span>
              </div>
              <p class="mt-1 text-xs text-slate-600">
                mode {format_value(@snapshot.lsp_diagnostics.server_manager.mode)} -
                registry {@snapshot.lsp_diagnostics.server_manager.registry.count} servers -
                active {@snapshot.lsp_diagnostics.server_manager.active_count}
              </p>
       <p class="mt-1 text-xs text-slate-500">
         refreshed {format_value(@snapshot.lsp_diagnostics.server_manager.refreshed_at)}
       </p>
       <%= if @snapshot.lsp_diagnostics.server_manager.active_servers != [] do %>
         <div class="mt-2 space-y-1">
           <%= for session <- @snapshot.lsp_diagnostics.server_manager.active_servers do %>
             <p class="rounded border border-slate-200 bg-white px-2 py-1 text-xs text-slate-600">
               {session.session_hash} - {session.label} - {format_value(session.status)} -
               init {if session.initialized, do: "yes", else: "no"} -
               requests {session.request_count || 0}/{session.response_count || 0} -
               notifications {session.notification_count || 0} -
               diagnostics {session.diagnostic_count || 0}/{session.diagnostic_batch_count || 0} -
               docs {session.open_document_count || 0}/{session.document_count || 0} -
               pending {session.pending_request_count || 0} - cwd {session.cwd_hash || "none"}
             </p>
           <% end %>
         </div>
       <% end %>
            </div>
            <div class="mt-3 rounded-lg border border-slate-200 bg-white px-3 py-2">
              <div class="flex items-center justify-between gap-3">
                <p class="text-sm font-medium text-slate-900">LSP proof artifacts</p>
                <span class={status_badge_class(if @snapshot.lsp_diagnostics.proofs.proof_count > 0, do: "ok", else: "missing")}>
                  {@snapshot.lsp_diagnostics.proofs.proof_count} proof(s)
                </span>
              </div>
              <p class="mt-1 text-xs text-slate-500">
                latest LSP checks {@snapshot.lsp_diagnostics.proofs.check_count} -
                paths <%= if @snapshot.lsp_diagnostics.proofs.cleanup.includes_raw_paths do %>visible<% else %>redacted<% end %> -
                contents <%= if @snapshot.lsp_diagnostics.cleanup.includes_file_contents do %>visible<% else %>omitted<% end %>
              </p>
              <%= if @snapshot.lsp_diagnostics.proofs.error do %>
                <p class="mt-2 rounded border border-amber-200 bg-amber-50 px-2 py-1 text-xs text-amber-800">
                  proof scan: {format_value(@snapshot.lsp_diagnostics.proofs.error)}
                </p>
              <% end %>
              <%= if @snapshot.lsp_diagnostics.proofs.recent_proofs != [] do %>
                <div class="mt-2 space-y-1">
                  <%= for proof <- @snapshot.lsp_diagnostics.proofs.recent_proofs do %>
                    <p class="rounded border border-slate-200 bg-slate-50 px-2 py-1 text-xs text-slate-600">
                      {format_value(proof.proof_object)} -
                      {format_value(proof.status)} -
                      pass {format_value(proof.completed_count)} -
                      fail {format_value(proof.failed_count)} -
                      skip {format_value(proof.skipped_count)} -
                      generated {format_value(proof.generated_at)}
                    </p>
                  <% end %>
                </div>
              <% end %>
              <%= if @snapshot.lsp_diagnostics.proofs.latest_checks != [] do %>
                <div class="mt-2 flex flex-wrap gap-1">
                  <%= for check <- @snapshot.lsp_diagnostics.proofs.latest_checks do %>
                    <span class="rounded bg-slate-100 px-2 py-1 text-xs text-slate-600">
                      {format_value(check.name)}: {format_value(check.status)}
                    </span>
                  <% end %>
                </div>
              <% end %>
            </div>
            <dl class="mt-3 grid gap-2 text-xs sm:grid-cols-4">
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Paths</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.lsp_diagnostics.cleanup.includes_raw_paths do %>visible<% else %>redacted<% end %>
                </dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Contents</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.lsp_diagnostics.cleanup.includes_file_contents do %>visible<% else %>omitted<% end %>
                </dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Output</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.lsp_diagnostics.cleanup.includes_diagnostics_output do %>visible<% else %>omitted<% end %>
                </dd>
              </div>
              <div>
                <dt class="font-medium uppercase tracking-wide text-slate-500">Roots</dt>
                <dd class="mt-1 text-slate-900">
                  <%= if @snapshot.lsp_diagnostics.cleanup.includes_workspace_roots do %>visible<% else %>redacted<% end %>
                </dd>
              </div>
            </dl>
            <div class="mt-3 space-y-2">
              <%= for language <- @snapshot.lsp_diagnostics.supported_languages do %>
                <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="truncate text-sm font-medium text-slate-900">
                      {format_value(language.language)}
                    </p>
                    <span class={status_badge_class(if language.available, do: "ok", else: "missing")}>
                      <%= if language.available do %>available<% else %>missing<% end %>
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-600">
                    {language.source} - extensions {Enum.join(language.extensions || [], ", ")}
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    checkers <%= for executable <- language.executables do %><span class="mr-2">{executable.name}: {yes_no(executable.available)}</span><% end %>
                  </p>
                  <%= if language.workspace_markers != [] do %>
                    <p class="mt-1 text-xs text-slate-500">
                      workspace markers {Enum.join(language.workspace_markers || [], ", ")}
                    </p>
                  <% end %>
                </div>
              <% end %>
              <%= if Enum.empty?(@snapshot.lsp_diagnostics.supported_languages) do %>
                <p class="text-sm text-slate-600">No diagnostics languages registered.</p>
              <% end %>
            </div>
            <div class="mt-3 space-y-2">
              <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Language servers</p>
              <%= for server <- @snapshot.lsp_diagnostics.server_manager.registry.servers do %>
                <div class="rounded-lg border border-slate-200 bg-white px-3 py-2">
                  <div class="flex items-center justify-between gap-3">
                    <p class="truncate text-sm font-medium text-slate-900">
                      {server.label}
                    </p>
                    <span class={status_badge_class(if server.available, do: "ok", else: "missing")}>
                      <%= if server.available do %>available<% else %>missing<% end %>
                    </span>
                  </div>
                  <p class="mt-1 text-xs text-slate-600">
                    {format_value(server.language)} - command {server.command} - protocol {format_value(server.protocol)}
                  </p>
                  <p class="mt-1 text-xs text-slate-500">
                    {server.install_hint}
                  </p>
                </div>
              <% end %>
              <%= if Enum.empty?(@snapshot.lsp_diagnostics.server_manager.registry.servers) do %>
                <p class="text-sm text-slate-600">No language servers registered.</p>
              <% end %>
            </div>
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

  attr(:title, :string, required: true)
  attr(:counts, :map, required: true)

  defp extension_count_group(assigns) do
    ~H"""
    <div class="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2">
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500">{@title}</p>
      <%= if map_size(@counts) == 0 do %>
        <p class="mt-1 text-xs text-slate-500">none declared</p>
      <% else %>
        <div class="mt-2 flex flex-wrap gap-1">
          <%= for {name, count} <- Enum.sort_by(@counts, fn {name, _count} -> name end) do %>
            <span class="rounded-full bg-white px-2 py-1 text-xs font-medium text-slate-700">
              {name}: {count}
            </span>
          <% end %>
        </div>
      <% end %>
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

  defp checkpoint_error(:not_found, _fallback), do: "Checkpoint not found."

  defp checkpoint_error(:not_filesystem_checkpoint, _fallback),
    do: "Checkpoint is not restorable."

  defp checkpoint_error(:invalid_checkpoint, fallback), do: fallback

  defp checkpoint_error({:path_not_in_checkpoint, _path}, _fallback),
    do: "Path is not in checkpoint."

  defp checkpoint_error(_reason, fallback), do: fallback

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

  defp browser_label(%{running?: true}), do: "running"
  defp browser_label(%{available?: true}), do: "idle"
  defp browser_label(_), do: "unavailable"

  defp browser_detail(%{last_error: error}) when is_binary(error) and error != "", do: error

  defp browser_detail(%{
         pending_requests: pending,
         completed_count: completed,
         failed_count: failed
       }) do
    "#{format_value(pending)} pending, #{format_value(completed)} completed, #{format_value(failed)} failed"
  end

  defp browser_detail(_), do: "browser status unavailable"

  defp provider_label(%{ok?: true}), do: "ok"
  defp provider_label(%{ok?: false}), do: "check"
  defp provider_label(_), do: "unknown"

  defp provider_detail(%{readiness: %{ready_count: ready, count: count}})
       when is_integer(ready) and is_integer(count),
       do: "#{ready}/#{count} providers ready"

  defp provider_detail(%{checks: checks}) when is_list(checks),
    do: "#{length(checks)} provider checks"

  defp provider_detail(%{error: error}) when is_binary(error), do: error
  defp provider_detail(_), do: "provider status unavailable"

  defp usage_label(%{total_cost: cost}), do: format_money(cost)
  defp usage_label(_), do: "unknown"

  defp usage_detail(%{
         total_requests: requests,
         total_tokens: %{total: tokens},
         provider_count: providers
       }) do
    "#{format_value(requests)} requests, #{format_value(tokens)} tokens, #{format_value(providers)} providers"
  end

  defp usage_detail(%{error: error}) when is_binary(error), do: error
  defp usage_detail(_), do: "usage status unavailable"

  defp run_badge_class(true),
    do: "rounded-full bg-emerald-100 px-2 py-1 text-xs font-medium text-emerald-700"

  defp run_badge_class(_),
    do: "rounded-full bg-rose-100 px-2 py-1 text-xs font-medium text-rose-700"

  defp status_badge_class("ok"), do: run_badge_class(true)
  defp status_badge_class("pending"), do: run_badge_class(true)
  defp status_badge_class("running"), do: run_badge_class(true)
  defp status_badge_class("ready"), do: run_badge_class(true)
  defp status_badge_class("supported"), do: run_badge_class(true)
  defp status_badge_class("proven"), do: run_badge_class(true)
  defp status_badge_class("within_limits"), do: run_badge_class(true)
  defp status_badge_class("unlimited"), do: run_badge_class(true)

  defp status_badge_class("idle"),
    do: "rounded-full bg-slate-100 px-2 py-1 text-xs font-medium text-slate-700"

  defp status_badge_class("active"),
    do: "rounded-full bg-sky-100 px-2 py-1 text-xs font-medium text-sky-700"

  defp status_badge_class("preview"),
    do: "rounded-full bg-violet-100 px-2 py-1 text-xs font-medium text-violet-700"

  defp status_badge_class("seeded"),
    do: "rounded-full bg-amber-100 px-2 py-1 text-xs font-medium text-amber-700"

  defp status_badge_class("check"),
    do: "rounded-full bg-amber-100 px-2 py-1 text-xs font-medium text-amber-700"

  defp status_badge_class("blocked"),
    do: "rounded-full bg-rose-100 px-2 py-1 text-xs font-medium text-rose-700"

  defp status_badge_class("over_limit"),
    do: "rounded-full bg-rose-100 px-2 py-1 text-xs font-medium text-rose-700"

  defp status_badge_class(_), do: run_badge_class(false)

  defp cron_run_active?(%{status: status}) when status in ["pending", "running"], do: true
  defp cron_run_active?(_), do: false

  defp provider_candidate_class(%{selected?: true}),
    do: "rounded-full bg-emerald-100 px-2 py-1 text-xs font-medium text-emerald-700"

  defp provider_candidate_class(%{credential_ready?: true}),
    do: "rounded-full bg-sky-100 px-2 py-1 text-xs font-medium text-sky-700"

  defp provider_candidate_class(_),
    do: "rounded-full bg-slate-100 px-2 py-1 text-xs font-medium text-slate-700"

  defp approval_button_class("danger") do
    "rounded-md bg-rose-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
  end

  defp approval_button_class(_) do
    "rounded-md bg-amber-700 px-2 py-1 text-xs font-medium text-white shadow-sm"
  end

  defp oauth_authorization_url(approval) do
    approval_action_value(approval, :authorization_url)
  end

  defp oauth_action_value(approval, key), do: approval_action_value(approval, key)

  defp sampling_approval?(approval) do
    approval_action_value(approval, :type) == "mcp_sampling"
  end

  defp approval_action_value(%{action: action}, key) when is_map(action) do
    Map.get(action, key) || Map.get(action, Atom.to_string(key))
  end

  defp approval_action_value(_, _), do: nil

  defp format_inline_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "none"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_inline_list(_), do: "none"

  defp format_action_map(values) when is_map(values) and map_size(values) > 0 do
    values
    |> Enum.map(fn {key, value} -> "#{key}: #{value}" end)
    |> Enum.join(", ")
  end

  defp format_action_map(_), do: "none"

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

  defp map_summary(map) when is_map(map) and map != %{} do
    map
    |> Enum.sort_by(fn {_key, count} -> count end, :desc)
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {key, count} -> "#{key}: #{count}" end)
  end

  defp map_summary(_), do: "none"

  defp format_value(nil), do: "unknown"
  defp format_value(value), do: to_string(value)

  defp format_money(nil), do: "unlimited"
  defp format_money(value) when is_integer(value), do: format_money(value * 1.0)

  defp format_money(value) when is_float(value) do
    "$#{:erlang.float_to_binary(value, decimals: 4)}"
  end

  defp format_money(_), do: "unknown"

  defp format_provider_list([]), do: "none"

  defp format_provider_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp format_provider_list(_), do: "unknown"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "unknown"

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
  defp format_datetime(value) when is_binary(value), do: value
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
