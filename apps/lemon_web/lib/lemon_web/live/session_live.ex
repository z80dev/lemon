defmodule LemonWeb.SessionLive do
  @moduledoc false

  use LemonWeb, :live_view
  require Logger

  alias LemonCore.{Bus, MapHelpers, NodeRegistry, RouterBridge, SessionKey, SessionLifecycle}
  alias LemonCore.Setup.Readiness
  alias LemonWeb.Live.Components.{FileUploadComponent, MessageComponent}

  @max_messages 250
  @max_history_runs 100
  @active_control_modes [:followup, :steer, :redirect]

  @impl true
  def mount(params, _session, socket) do
    session_key = resolve_session_key(params)
    agent_id = SessionKey.agent_id(session_key) || "default"

    if connected?(socket) do
      Bus.subscribe(Bus.session_topic(session_key))
      Bus.subscribe("system")
    end

    setup_state = setup_readiness()
    messages = history_messages(session_key)
    {last_run_id, run_status} = active_run_state(session_key)

    socket =
      socket
      |> assign(:page_title, "Lemon Dashboard")
      |> assign(:session_key, session_key)
      |> assign(:agent_id, agent_id)
      |> assign(:prompt, "")
      |> assign(:messages, messages)
      |> assign(:last_run_id, last_run_id)
      |> assign(:run_status, run_status)
      |> assign(:control_mode, :followup)
      |> assign(:control_notice, nil)
      |> assign(:setup_state, setup_state)
      |> assign(:setup_ready?, Readiness.ready?(setup_state))
      |> assign(:submit_error, nil)
      |> allow_upload(:files,
        accept: :any,
        max_entries: 5,
        max_file_size: 20_000_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"chat" => chat}, socket) when is_map(chat) do
    socket =
      socket
      |> assign(:prompt, chat["prompt"] || "")
      |> maybe_assign_control_mode(chat["mode"])

    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    socket =
      socket
      |> cancel_upload(:files, ref)
      |> assign(:submit_error, nil)

    {:noreply, socket}
  end

  def handle_event("refresh-setup", _params, socket) do
    {:noreply, refresh_setup_readiness(socket)}
  end

  def handle_event("refresh-run-status", _params, socket) do
    case reconcile_active_run(socket) do
      {:ok, socket, _run_id} ->
        message =
          if socket.assigns.run_status == :stopping,
            do: "The stop request is still pending.",
            else: "The active run is ready for guidance."

        {:noreply, assign_control_notice(socket, :info, message)}

      {:none, socket} ->
        {:noreply,
         assign_control_notice(
           socket,
           :warning,
           "No active run is available. Send a new message to start one."
         )}

      {:unavailable, socket} ->
        {:noreply,
         assign_control_notice(
           socket,
           :warning,
           "Lemon could not check the active run. Its last known state is unchanged; try again."
         )}
    end
  end

  def handle_event("stop-run", _params, %{assigns: %{last_run_id: run_id}} = socket)
      when is_binary(run_id) do
    case abort_run(run_id) do
      :ok ->
        socket =
          socket
          |> assign(:run_status, :stopping)
          |> assign(:submit_error, nil)
          |> assign(:control_notice, nil)
          |> maybe_append_system("Stop requested.")

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         assign(
           socket,
           :submit_error,
           "Lemon could not stop that run. Check its status and try again."
         )}
    end
  end

  def handle_event("stop-run", _params, socket), do: {:noreply, socket}

  def handle_event("submit", %{"chat" => chat}, socket) when is_map(chat) do
    prompt = String.trim(chat["prompt"] || "")
    mode = normalize_submit_mode(chat["mode"])
    socket = assign(socket, :prompt, chat["prompt"] || "")

    cond do
      not Map.get(socket.assigns, :setup_ready?, true) ->
        {:noreply, assign(socket, :submit_error, setup_recovery_message())}

      Map.get(socket.assigns, :run_status, :idle) == :unavailable ->
        {:noreply,
         socket
         |> assign(:submit_error, nil)
         |> assign_control_notice(
           :warning,
           "Lemon must confirm this session's run status before sending. Check status and try again."
         )}

      mode in @active_control_modes ->
        submit_active_control(socket, prompt, mode)

      true ->
        submit_prompt(socket, prompt)
    end
  end

  defp submit_active_control(socket, prompt, mode) do
    cond do
      prompt == "" ->
        {:noreply,
         socket
         |> assign(:submit_error, "Enter guidance for the active run.")
         |> assign(:control_notice, nil)}

      byte_size(prompt) > NodeRegistry.max_control_text_bytes() ->
        {:noreply,
         socket
         |> assign(
           :submit_error,
           "Active-run guidance must be 16 KB or less. Shorten the message and try again."
         )
         |> assign(:control_notice, nil)}

      upload_entries?(socket) ->
        {:noreply,
         socket
         |> assign(
           :submit_error,
           "Active-run guidance is text only. Remove the attachment or wait and send it with a new message."
         )
         |> assign(:control_notice, nil)}

      true ->
        do_submit_active_control(socket, prompt, mode)
    end
  end

  defp do_submit_active_control(socket, prompt, mode) do
    case reconcile_active_run(socket) do
      {:ok, socket, active_run_id} ->
        case submit_run(
               socket.assigns.session_key,
               socket.assigns.agent_id,
               prompt,
               [],
               mode
             ) do
          {:ok, _submission_run_id} ->
            socket =
              socket
              |> append_message(%{
                id: message_id("user"),
                kind: :user,
                content: prompt,
                control_mode: mode,
                ts_ms: now_ms()
              })
              |> assign(:prompt, "")
              |> assign(:last_run_id, active_run_id)
              |> assign(:run_status, :running)
              |> assign(:submit_error, nil)
              |> assign_control_notice(:success, control_success_message(mode))

            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:submit_error, nil)
             |> assign_control_notice(:error, control_refusal_message(reason))}
        end

      {:none, socket} ->
        {:noreply,
         socket
         |> assign(:submit_error, nil)
         |> assign_control_notice(
           :warning,
           "That run has already finished. Your message was not sent; send it as a new message instead."
         )}

      {:unavailable, socket} ->
        {:noreply,
         socket
         |> assign(:submit_error, nil)
         |> assign_control_notice(
           :warning,
           "Lemon could not confirm whether that run is still active. Your message was not sent; check status and try again."
         )}
    end
  end

  defp submit_prompt(socket, prompt) do
    if uploads_in_progress?(socket) do
      {:noreply,
       assign(socket, :submit_error, "Please wait for uploads to finish before submitting.")}
    else
      case persist_uploads(socket) do
        {:ok, uploads} ->
          if prompt == "" and uploads == [] do
            {:noreply,
             assign(socket, :submit_error, "Enter a prompt or upload at least one file.")}
          else
            submission_prompt = build_submission_prompt(prompt, uploads)
            user_text = build_user_message(prompt, uploads)

            socket =
              socket
              |> append_message(%{
                id: message_id("user"),
                kind: :user,
                content: user_text,
                ts_ms: now_ms()
              })
              |> assign(:prompt, "")
              |> assign(:submit_error, nil)
              |> assign(:control_notice, nil)

            case submit_run(
                   socket.assigns.session_key,
                   socket.assigns.agent_id,
                   submission_prompt,
                   uploads,
                   :collect
                 ) do
              {:ok, run_id} ->
                {:noreply,
                 socket
                 |> assign(:last_run_id, run_id)
                 |> assign(:run_status, :running)}

              {:error, _reason} ->
                notice = "Lemon could not start that run. Check runtime status and try again."

                socket =
                  socket
                  |> append_message(%{
                    id: message_id("system"),
                    kind: :system,
                    content: notice,
                    ts_ms: now_ms()
                  })
                  |> assign(:submit_error, notice)

                {:noreply, socket}
            end
          end

        {:error, failures} ->
          {:noreply, assign(socket, :submit_error, upload_failure_message(failures))}
      end
    end
  end

  @impl true
  def handle_info(%LemonCore.Event{type: :run_started} = event, socket) do
    run_id = read(event.payload, :run_id) || read(event.meta, :run_id)
    engine = read(event.payload, :engine)

    socket =
      socket
      |> assign(:last_run_id, run_id || socket.assigns.last_run_id)
      |> assign(:run_status, :running)
      |> assign(:control_notice, nil)
      |> maybe_append_system("Run started#{if is_binary(engine), do: " (#{engine})", else: ""}.")

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: :delta, payload: payload, meta: meta}, socket) do
    run_id = read(payload, :run_id) || read(meta, :run_id) || socket.assigns.last_run_id
    text = read(payload, :text) || ""

    socket =
      if is_binary(text) and text != "" do
        upsert_assistant_delta(socket, run_id, text)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: :engine_action, payload: payload}, socket) do
    socket =
      append_message(socket, %{
        id: message_id("tool"),
        kind: :tool_call,
        event: payload,
        ts_ms: now_ms()
      })

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: :run_completed, payload: payload, meta: meta}, socket) do
    run_id = read(meta, :run_id) || read(payload, :run_id) || socket.assigns.last_run_id
    completed = read(payload, :completed) || payload
    answer = read(completed, :answer)
    ok? = read(completed, :ok)
    error = read(completed, :error)

    socket =
      socket
      |> finalize_assistant_message(run_id, answer)
      |> maybe_append_run_completion(ok?, error)
      |> assign(:last_run_id, nil)
      |> assign(:run_status, :idle)
      |> assign(:control_notice, nil)

    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{type: type}, socket)
      when type in [:config_reloaded, :secret_changed] do
    {:noreply, refresh_setup_readiness(socket)}
  end

  def handle_info(%{type: :coalesced_output}, socket) do
    {:noreply, socket}
  end

  def handle_info(%LemonCore.Event{}, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" class="min-h-screen bg-slate-100">
      <div class="mx-auto flex min-h-screen w-full max-w-3xl flex-col px-3 py-4 sm:px-6 sm:py-6">
        <header class="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-sm">
          <div class="flex items-start justify-between gap-4">
            <div>
              <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon</p>
              <h1 class="mt-1 text-lg font-semibold text-slate-900 sm:text-xl">Chat</h1>
              <p class="mt-1 text-sm text-slate-600">Your local agent workspace.</p>
            </div>
            <div class="flex flex-col items-end gap-2">
              <span class={setup_badge_class(@setup_ready?)} data-testid="setup-status">
                <span class="h-2 w-2 rounded-full bg-current" aria-hidden="true"></span>
                {if @setup_ready?, do: "Ready", else: "Setup needed"}
              </span>
              <.link href={~p"/manage"} class="text-xs font-medium text-slate-600 underline">
                Manage sessions
              </.link>
            </div>
          </div>
          <details class="mt-3 text-xs text-slate-500">
            <summary class="cursor-pointer rounded font-medium focus:outline-none focus:ring">Session details</summary>
            <div class="mt-2 space-y-1 border-l-2 border-slate-200 pl-3">
              <p>Session: <code class="break-all rounded bg-slate-100 px-1 py-0.5">{@session_key}</code></p>
              <p>Agent: <code class="rounded bg-slate-100 px-1 py-0.5">{@agent_id}</code></p>
            </div>
          </details>
        </header>

        <%= unless @setup_ready? do %>
          <section
            id="setup-readiness"
            role="alert"
            aria-labelledby="setup-title"
            class="mt-4 rounded-2xl border border-amber-300 bg-amber-50 p-4 shadow-sm"
          >
            <h2 id="setup-title" class="font-semibold text-amber-950">Finish setup before chatting</h2>
            <p class="mt-1 text-sm text-amber-900">
              Lemon is running, but it still needs the items below. Run <code class="rounded bg-amber-100 px-1 py-0.5 font-semibold">lemon setup</code>
              in a terminal, then refresh this check.
            </p>
            <ul class="mt-3 list-disc space-y-2 pl-5 text-sm text-amber-950">
              <%= for step <- Readiness.pending_steps(@setup_state) do %>
                <li>
                  <strong>{setup_step_title(step)}</strong> — {setup_step_help(step, @setup_state)}
                </li>
              <% end %>
            </ul>
            <div class="mt-4 flex flex-wrap items-center gap-3">
              <button
                type="button"
                phx-click="refresh-setup"
                class="rounded-lg bg-amber-950 px-3 py-2 text-sm font-medium text-white transition hover:bg-amber-800 focus:outline-none focus:ring focus:ring-amber-400"
              >
                Check again
              </button>
              <p class="text-xs text-amber-800">
                Still stuck? Run <code class="rounded bg-amber-100 px-1 py-0.5">lemon doctor</code>.
              </p>
            </div>
          </section>
        <% end %>

        <section
          id="messages"
          aria-label="Conversation"
          aria-live="polite"
          class="mt-4 flex-1 space-y-3 overflow-y-auto rounded-2xl border border-slate-200 bg-slate-50 p-3 sm:p-4"
        >
          <%= if @messages == [] do %>
            <div class="mx-auto max-w-md py-8 text-center">
              <p class="font-medium text-slate-800">Start with a small task</p>
              <p class="mt-1 text-sm text-slate-500">
                Ask a question, explain what you are working on, or attach files for Lemon to inspect.
              </p>
            </div>
          <% else %>
            <%= for message <- @messages do %>
              <MessageComponent.message message={message} />
            <% end %>
          <% end %>
        </section>

        <section
          aria-labelledby="composer-title"
          class="mt-4 rounded-2xl border border-slate-200 bg-white p-3 shadow-sm sm:p-4"
        >
          <h2 id="composer-title" class="sr-only">Message composer</h2>

          <%= if @run_status in [:running, :stopping] and is_binary(@last_run_id) do %>
            <div
              id="active-run-status"
              class="active-run-status"
              role="status"
              aria-live="polite"
            >
              <span class="active-run-status-dot" aria-hidden="true"></span>
              <div>
                <p class="active-run-status-title">
                  {if @run_status == :stopping, do: "Stopping active run", else: "Run active"}
                </p>
                <p class="active-run-status-copy">
                  <%= if @run_status == :stopping do %>
                    Waiting for Lemon to stop safely.
                  <% else %>
                    Choose how this message should affect the work already in progress.
                  <% end %>
                </p>
              </div>
            </div>
          <% end %>

          <%= if @run_status == :unavailable do %>
            <div
              id="run-status-unavailable"
              class="active-run-status border-amber-300 bg-amber-50"
              role="status"
              aria-live="polite"
            >
              <span class="active-run-status-dot bg-amber-500" aria-hidden="true"></span>
              <div>
                <p class="active-run-status-title text-amber-950">Run status unavailable</p>
                <p class="active-run-status-copy text-amber-900">
                  Lemon could not check whether this session has active work. Check status before sending another message.
                </p>
              </div>
            </div>
          <% end %>

          <.form
            for={
              to_form(
                %{"prompt" => @prompt, "mode" => Atom.to_string(@control_mode)},
                as: :chat
              )
            }
            id="chat-form"
            phx-change="validate"
            phx-submit="submit"
            multipart
            class="space-y-3"
          >
            <%= if @run_status == :running and is_binary(@last_run_id) do %>
              <fieldset id="active-run-controls" class="active-run-controls">
                <legend class="active-run-controls-legend">Use this message as</legend>
                <div class="active-run-control-grid">
                  <label class={control_option_class(@control_mode, :followup)}>
                    <input
                      type="radio"
                      name="chat[mode]"
                      value="followup"
                      checked={@control_mode == :followup}
                      class="active-run-control-input"
                    />
                    <span class="active-run-control-name">Follow-up</span>
                    <span class="active-run-control-description">
                      Queue a separate turn after the current run finishes.
                    </span>
                  </label>

                  <label class={control_option_class(@control_mode, :steer)}>
                    <input
                      type="radio"
                      name="chat[mode]"
                      value="steer"
                      checked={@control_mode == :steer}
                      class="active-run-control-input"
                    />
                    <span class="active-run-control-name">Steer</span>
                    <span class="active-run-control-description">
                      Add guidance to the work in progress without replacing its direction.
                    </span>
                  </label>

                  <label class={control_option_class(@control_mode, :redirect)}>
                    <input
                      type="radio"
                      name="chat[mode]"
                      value="redirect"
                      checked={@control_mode == :redirect}
                      class="active-run-control-input"
                    />
                    <span class="active-run-control-name">Redirect</span>
                    <span class="active-run-control-description">
                      Replace the pending direction while keeping completed tool work.
                    </span>
                  </label>
                </div>
              </fieldset>
            <% else %>
              <input type="hidden" name="chat[mode]" value="collect" />
            <% end %>

            <label for="chat_prompt" class="text-xs font-medium uppercase tracking-wide text-slate-500">
              {if @run_status == :running, do: "Guidance", else: "Prompt"}
            </label>
            <textarea
              id="chat_prompt"
              name="chat[prompt]"
              rows="4"
              value={@prompt}
              placeholder={composer_placeholder(@run_status, @control_mode)}
              disabled={!@setup_ready? or @run_status in [:stopping, :unavailable]}
              aria-describedby="composer-help"
              class="w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none transition focus:border-slate-500 focus:ring disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-500"
            ></textarea>

            <%= if @setup_ready? and @run_status == :idle do %>
              <FileUploadComponent.file_upload upload={@uploads.files} />
            <% else %>
              <%= if @setup_ready? and @run_status in [:running, :stopping] do %>
                <p class="active-run-text-note">
                  Active-run guidance is text only. Attach files after the current run finishes.
                </p>
              <% else %>
                <%= if @setup_ready? and @run_status == :unavailable do %>
                  <p class="active-run-text-note">
                    Attachments are unavailable until Lemon can confirm the session's run status.
                  </p>
                <% else %>
                  <p class="rounded-xl border border-slate-200 bg-slate-50 p-3 text-sm text-slate-500">
                    Attachments become available after setup is complete.
                  </p>
                <% end %>
              <% end %>
            <% end %>

            <%= if is_map(@control_notice) do %>
              <p
                id="control-notice"
                role={if @control_notice.tone == :error, do: "alert", else: "status"}
                aria-live="polite"
                class={control_notice_class(@control_notice.tone)}
              >
                {@control_notice.message}
              </p>
            <% end %>

            <%= if is_binary(@submit_error) and @submit_error != "" do %>
              <p role="alert" class="rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700">
                {@submit_error}
              </p>
            <% end %>

            <div class="flex flex-wrap items-center justify-between gap-3">
              <p id="composer-help" class="text-xs text-slate-500">
                <%= if @run_status in [:running, :stopping, :unavailable] do %>
                  {composer_help(@run_status, @control_mode)}
                <% else %>
                  Supports up to five files and live streaming updates.
                <% end %>
              </p>
              <div class="composer-actions">
                <%= if @run_status == :unavailable or (@run_status in [:running, :stopping] and is_binary(@last_run_id)) do %>
                  <button
                    type="button"
                    phx-click="refresh-run-status"
                    class="active-run-secondary-button"
                  >
                    Check status
                  </button>
                <% end %>
                <%= if @run_status in [:running, :stopping] and is_binary(@last_run_id) do %>
                  <button
                    type="button"
                    phx-click="stop-run"
                    disabled={@run_status == :stopping}
                    class="rounded-lg border border-rose-300 bg-white px-4 py-2 text-sm font-medium text-rose-700 transition hover:bg-rose-50 focus:outline-none focus:ring disabled:cursor-wait disabled:opacity-50"
                  >
                    {if @run_status == :stopping, do: "Stopping…", else: "Stop"}
                  </button>
                <% end %>
                <.button
                  type="submit"
                  disabled={!@setup_ready? or @run_status in [:stopping, :unavailable]}
                >
                  {submit_label(@run_status, @control_mode)}
                </.button>
              </div>
            </div>
          </.form>
        </section>
      </div>
    </main>
    """
  end

  defp submit_run(session_key, agent_id, prompt, uploads, queue_mode) do
    request = %{
      origin: :control_plane,
      session_key: session_key,
      agent_id: agent_id,
      prompt: prompt,
      queue_mode: queue_mode,
      meta: %{
        source: :lemon_web,
        web_dashboard: true,
        uploads: uploads
      }
    }

    case Application.get_env(:lemon_web, :submit_run_fun) do
      fun when is_function(fun, 1) -> fun.(request)
      _ -> LemonRouter.submit(request)
    end
  end

  defp active_run_state(session_key) do
    case active_run_for_session(session_key) do
      {:ok, run_id} -> {run_id, :running}
      :none -> {nil, :idle}
      {:error, :unavailable} -> {nil, :unavailable}
    end
  end

  defp active_run_for_session(session_key) do
    result =
      case Application.get_env(:lemon_web, :active_run_fun) do
        fun when is_function(fun, 1) -> fun.(session_key)
        _ -> RouterBridge.active_run(session_key)
      end

    case result do
      {:ok, run_id} when is_binary(run_id) and run_id != "" ->
        {:ok, run_id}

      run_id when is_binary(run_id) and run_id != "" ->
        {:ok, run_id}

      {:error, reason} ->
        Logger.warning("active run lookup failed class=#{failure_class(reason)}")

        {:error, :unavailable}

      :none ->
        :none

      unexpected ->
        Logger.warning("active run lookup returned unexpected class=#{failure_class(unexpected)}")
        {:error, :unavailable}
    end
  rescue
    error ->
      Logger.warning("active run lookup raised class=#{failure_class(error)}")
      {:error, :unavailable}
  catch
    :exit, reason ->
      Logger.warning("active run lookup exited class=#{failure_class(reason)}")
      {:error, :unavailable}
  end

  defp reconcile_active_run(socket) do
    case active_run_for_session(socket.assigns.session_key) do
      {:ok, run_id} ->
        run_status =
          if socket.assigns.run_status == :stopping and socket.assigns.last_run_id == run_id,
            do: :stopping,
            else: :running

        socket =
          socket
          |> assign(:last_run_id, run_id)
          |> assign(:run_status, run_status)

        {:ok, socket, run_id}

      :none ->
        socket =
          socket
          |> assign(:last_run_id, nil)
          |> assign(:run_status, :idle)

        {:none, socket}

      {:error, :unavailable} ->
        # Keep a known running/stopping state intact. On an initial mount there
        # is no safe state to preserve, so render an explicit unavailable UI.
        socket =
          if socket.assigns.run_status in [:running, :stopping] and
               is_binary(socket.assigns.last_run_id) do
            socket
          else
            socket
            |> assign(:last_run_id, nil)
            |> assign(:run_status, :unavailable)
          end

        {:unavailable, socket}
    end
  end

  defp abort_run(run_id) do
    case Application.get_env(:lemon_web, :abort_run_fun) do
      fun when is_function(fun, 2) -> fun.(run_id, :user_requested)
      _ -> LemonRouter.abort_run(run_id, :user_requested)
    end
  end

  defp setup_readiness do
    case Application.get_env(:lemon_web, :setup_readiness_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Readiness.status()
    end
  end

  defp refresh_setup_readiness(socket) do
    state = setup_readiness()

    socket
    |> assign(:setup_state, state)
    |> assign(:setup_ready?, Readiness.ready?(state))
    |> assign(:submit_error, nil)
  end

  defp maybe_assign_control_mode(socket, mode) do
    case normalize_submit_mode(mode) do
      mode when mode in @active_control_modes -> assign(socket, :control_mode, mode)
      _ -> socket
    end
  end

  defp normalize_submit_mode(mode) when is_atom(mode) and mode in @active_control_modes,
    do: mode

  defp normalize_submit_mode("followup"), do: :followup
  defp normalize_submit_mode("steer"), do: :steer
  defp normalize_submit_mode("redirect"), do: :redirect
  defp normalize_submit_mode(_), do: :collect

  defp assign_control_notice(socket, tone, message)
       when tone in [:success, :info, :warning, :error] and is_binary(message) do
    assign(socket, :control_notice, %{tone: tone, message: message})
  end

  defp control_success_message(:followup),
    do: "Follow-up queued. It will run after the active work finishes."

  defp control_success_message(:steer),
    do: "Steer request sent to the active run."

  defp control_success_message(:redirect),
    do: "Redirect request sent. Completed tool work will be preserved."

  defp control_refusal_message(:unavailable),
    do: "The active run is no longer available. Check its status and try again."

  defp control_refusal_message(:invalid_run_request),
    do: "Lemon could not accept that guidance. Review the message and try again."

  defp control_refusal_message(_reason),
    do: "Lemon refused that active-run request. The message was not sent."

  defp control_option_class(selected, mode) when selected == mode,
    do: "active-run-control-option active-run-control-option-selected"

  defp control_option_class(_selected, _mode), do: "active-run-control-option"

  defp control_notice_class(:success), do: "active-run-notice active-run-notice-success"
  defp control_notice_class(:info), do: "active-run-notice active-run-notice-info"
  defp control_notice_class(:warning), do: "active-run-notice active-run-notice-warning"
  defp control_notice_class(:error), do: "active-run-notice active-run-notice-error"

  defp composer_placeholder(:running, :followup), do: "What should Lemon do next?"
  defp composer_placeholder(:running, :steer), do: "What should Lemon adjust right now?"
  defp composer_placeholder(:running, :redirect), do: "What should Lemon do instead?"
  defp composer_placeholder(:stopping, _mode), do: "Wait for the current run to stop..."
  defp composer_placeholder(:unavailable, _mode), do: "Check run status before sending..."
  defp composer_placeholder(_status, _mode), do: "Ask Lemon to do work..."

  defp composer_help(:stopping, _mode), do: "Stopping the current run..."

  defp composer_help(:unavailable, _mode),
    do: "Run status must be available before another message can be sent."

  defp composer_help(:running, :followup),
    do: "Follow-up starts as a separate turn after this run."

  defp composer_help(:running, :steer), do: "Steer adds guidance to this run."

  defp composer_help(:running, :redirect),
    do: "Redirect changes the pending direction but keeps completed tool work."

  defp composer_help(_status, _mode), do: "Lemon is working..."

  defp submit_label(:running, :followup), do: "Queue follow-up"
  defp submit_label(:running, :steer), do: "Send steer"
  defp submit_label(:running, :redirect), do: "Request redirect"
  defp submit_label(:unavailable, _mode), do: "Check status first"
  defp submit_label(_status, _mode), do: "Send"

  defp failure_class(%{__exception__: true, __struct__: module}) when is_atom(module),
    do: "exception:" <> inspect(module)

  defp failure_class(reason) when is_atom(reason), do: "atom"
  defp failure_class(reason) when is_tuple(reason), do: "tuple"
  defp failure_class(reason) when is_map(reason), do: "map"
  defp failure_class(reason) when is_list(reason), do: "list"
  defp failure_class(_reason), do: "other"

  defp setup_recovery_message do
    "Finish setup before chatting: run `lemon setup` in a terminal, then check again."
  end

  defp setup_badge_class(true) do
    "inline-flex items-center gap-2 rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1 text-xs font-medium text-emerald-700"
  end

  defp setup_badge_class(false) do
    "inline-flex items-center gap-2 rounded-full border border-amber-300 bg-amber-50 px-3 py-1 text-xs font-medium text-amber-800"
  end

  defp setup_step_title(:config), do: "Configuration"
  defp setup_step_title(:secrets), do: "Secure secret storage"
  defp setup_step_title(:provider), do: "Provider and model"

  defp setup_step_help(:config, _state), do: "create the local Lemon config"
  defp setup_step_help(:secrets, _state), do: "initialize the encrypted credential store"

  defp setup_step_help(:provider, %{provider: %{reason: :missing_default_provider}}),
    do: "choose an AI provider"

  defp setup_step_help(:provider, %{provider: %{reason: :missing_default_model}}),
    do: "choose a default model"

  defp setup_step_help(:provider, %{provider: %{reason: :credential_not_usable}}),
    do: "store a usable provider credential"

  defp setup_step_help(:provider, %{provider: %{reason: :model_provider_mismatch}}),
    do: "choose a model that matches the provider"

  defp setup_step_help(:provider, _state),
    do: "configure a usable provider, model, and credential"

  defp persist_uploads(socket) do
    if persist_fun = Application.get_env(:lemon_web, :upload_persist_fun) do
      persist_fun.(socket)
    else
      persist_uploaded_entries(socket)
    end
  end

  defp persist_uploaded_entries(socket) do
    upload_root = upload_root()

    case File.mkdir_p(upload_root) do
      :ok ->
        entries =
          consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
            filename = sanitize_filename(entry.client_name || "upload")

            destination =
              Path.join(
                upload_root,
                "#{System.system_time(:millisecond)}-#{message_id("file")}-#{filename}"
              )

            case File.cp(path, destination) do
              :ok ->
                {:ok,
                 %{
                   name: entry.client_name,
                   path: destination,
                   content_type: entry.client_type,
                   size: entry.client_size
                 }}

              {:error, reason} ->
                {:ok,
                 %{
                   name: entry.client_name,
                   path: nil,
                   error: format_error(reason)
                 }}
            end
          end)

        failures = Enum.filter(entries, &(not is_binary(read(&1, :path))))

        if failures == [] do
          {:ok, entries}
        else
          {:error, failures}
        end

      {:error, reason} ->
        {:error, [%{name: upload_root, error: format_error(reason)}]}
    end
  end

  defp upload_failure_message(failures) do
    files =
      failures
      |> Enum.map(fn file ->
        name = read(file, :name) || "upload"
        error = read(file, :error) || "could not be saved"
        "#{name}: #{error}"
      end)
      |> Enum.join(", ")

    "Upload failed: #{files}"
  end

  defp upload_root do
    Application.get_env(:lemon_web, :uploads_dir) ||
      Path.join(System.tmp_dir!(), "lemon_web_uploads")
  end

  defp build_submission_prompt(prompt, []), do: prompt

  defp build_submission_prompt(prompt, uploads) do
    files_text =
      uploads
      |> Enum.filter(&is_binary(read(&1, :path)))
      |> Enum.map_join("\n", fn file -> "- #{read(file, :path)}" end)

    cond do
      prompt == "" and files_text != "" ->
        "Process these uploaded files:\n#{files_text}"

      files_text == "" ->
        prompt

      true ->
        prompt <> "\n\nUploaded files:\n" <> files_text
    end
  end

  defp build_user_message(prompt, []) do
    if prompt == "", do: "(uploaded files)", else: prompt
  end

  defp build_user_message(prompt, uploads) do
    files =
      uploads
      |> Enum.map(fn file -> read(file, :name) || "file" end)
      |> Enum.reject(&(&1 in [nil, ""]))

    files_suffix = if files == [], do: "", else: "\n\nFiles: " <> Enum.join(files, ", ")

    case prompt do
      "" -> "(uploaded files)" <> files_suffix
      _ -> prompt <> files_suffix
    end
  end

  defp upsert_assistant_delta(socket, run_id, text) do
    run_id = run_id || "unknown"

    {messages, found?} =
      Enum.map_reduce(socket.assigns.messages, false, fn message, found ->
        if message.kind == :assistant and message.run_id == run_id and
             Map.get(message, :pending, false) do
          {Map.update!(message, :content, &(&1 <> text)), true}
        else
          {message, found}
        end
      end)

    if found? do
      assign(socket, :messages, messages)
    else
      append_message(socket, %{
        id: message_id("assistant"),
        kind: :assistant,
        run_id: run_id,
        content: text,
        pending: true,
        ts_ms: now_ms()
      })
    end
  end

  defp finalize_assistant_message(socket, run_id, answer) do
    run_id = run_id || "unknown"

    {messages, found?} =
      Enum.map_reduce(socket.assigns.messages, false, fn message, found ->
        if message.kind == :assistant and message.run_id == run_id do
          content =
            if message.content in [nil, ""] and is_binary(answer) and answer != "" do
              answer
            else
              message.content
            end

          {%{message | content: content, pending: false}, true}
        else
          {message, found}
        end
      end)

    socket = assign(socket, :messages, messages)

    cond do
      found? ->
        socket

      is_binary(answer) and answer != "" ->
        append_message(socket, %{
          id: message_id("assistant"),
          kind: :assistant,
          run_id: run_id,
          content: answer,
          pending: false,
          ts_ms: now_ms()
        })

      true ->
        socket
    end
  end

  defp maybe_append_run_completion(socket, true, _error), do: socket

  defp maybe_append_run_completion(socket, _ok, error) do
    maybe_append_system(socket, run_failure_notice(error))
  end

  defp run_failure_notice(error) do
    reason = read(error, :reason) || read(error, :type) || error

    case reason do
      reason
      when reason in [:aborted, :cancelled, :canceled, "aborted", "cancelled", "canceled"] ->
        "Run stopped."

      reason
      when reason in [
             :runtime_unavailable,
             :runtime_submission_failed,
             "runtime_unavailable",
             "runtime_submission_failed"
           ] ->
        "The run could not start because the execution runtime is unavailable. Check runtime status and try again."

      reason when reason in [:timeout, :timed_out, "timeout", "timed_out"] ->
        "The run timed out before it finished. Try again or use a smaller request."

      _reason ->
        "The run did not finish. Check runtime status and try again."
    end
  end

  defp maybe_append_system(socket, text) when is_binary(text) and text != "" do
    append_message(socket, %{
      id: message_id("system"),
      kind: :system,
      content: text,
      ts_ms: now_ms()
    })
  end

  defp maybe_append_system(socket, _), do: socket

  defp append_message(socket, message) do
    messages = trim_messages(socket.assigns.messages ++ [message])
    assign(socket, :messages, messages)
  end

  defp trim_messages(messages) when length(messages) <= @max_messages, do: messages
  defp trim_messages(messages), do: Enum.take(messages, -@max_messages)

  defp history_messages(session_key) do
    session_key
    |> SessionLifecycle.history(limit: @max_history_runs, redact: false)
    |> Enum.flat_map(&run_messages/1)
    |> trim_messages()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp run_messages(run) do
    run_id = run.run_id || "unknown"
    ts_ms = run.started_at_ms || 0

    prompt =
      if is_binary(run.prompt) and run.prompt != "" do
        [
          %{
            id: history_message_id(run_id, "user"),
            kind: :user,
            content: run.prompt,
            ts_ms: ts_ms
          }
        ]
      else
        []
      end

    tools =
      run.tools
      |> Enum.with_index()
      |> Enum.map(fn {tool, index} ->
        %{
          id: history_message_id(run_id, "tool-#{index}"),
          kind: :tool_call,
          event: %{
            action: %{
              title: tool.title,
              kind: tool.kind,
              detail: tool.detail
            },
            phase: tool.phase,
            ok: tool.ok,
            message: tool.message
          },
          ts_ms: ts_ms
        }
      end)

    answer =
      if is_binary(run.answer) and run.answer != "" do
        [
          %{
            id: history_message_id(run_id, "assistant"),
            kind: :assistant,
            run_id: run_id,
            content: run.answer,
            pending: false,
            ts_ms: ts_ms
          }
        ]
      else
        []
      end

    prompt ++ tools ++ answer
  end

  defp history_message_id(run_id, suffix) do
    digest = :crypto.hash(:sha256, "#{run_id}:#{suffix}") |> Base.url_encode64(padding: false)
    "history-#{binary_part(digest, 0, 16)}"
  end

  defp resolve_session_key(params) when is_map(params) do
    candidate = params["session_key"]
    agent_id = normalize_agent_id(params["agent_id"])

    cond do
      is_binary(candidate) and candidate != "" and SessionKey.valid?(candidate) ->
        candidate

      true ->
        isolated_session_key(agent_id)
    end
  end

  defp resolve_session_key(_params), do: isolated_session_key("default")

  defp isolated_session_key(agent_id) do
    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "web",
      account_id: "browser",
      peer_kind: :unknown,
      peer_id: "tab-#{session_suffix()}"
    })
  end

  defp session_suffix do
    Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
  end

  defp normalize_agent_id(agent_id) when is_binary(agent_id) do
    agent_id
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9._-]/u, "_")
    |> case do
      "" -> "default"
      value -> value
    end
  end

  defp normalize_agent_id(_), do: "default"

  defp uploads_in_progress?(socket) do
    socket.assigns.uploads.files.entries
    |> Enum.any?(fn entry -> not Map.get(entry, :done?, false) end)
  end

  defp upload_entries?(socket), do: socket.assigns.uploads.files.entries != []

  defp read(map, key), do: MapHelpers.get_key(map, key)

  defp format_error(error) when is_atom(error), do: Atom.to_string(error)

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9._-]/u, "_")
    |> case do
      "" -> "upload"
      value -> value
    end
  end

  defp sanitize_filename(_), do: "upload"

  defp message_id(prefix) when is_binary(prefix) do
    integer = System.unique_integer([:positive])
    "#{prefix}-#{integer}"
  end

  defp now_ms do
    System.system_time(:millisecond)
  end
end
