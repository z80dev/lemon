defmodule LemonWeb.OmpLive do
  @moduledoc """
  `/omp` and `/omp/:id`: omp (oh-my-pi) delegate sessions the runtime runs.

  Web parity with the TUI `/omp` panel. Everything goes through the
  control-plane `omp.*` methods (`LemonWeb.Rpc`) and the `omp.session` Bus
  event projected by `LemonControlPlane.EventBridge.project/1`, so the page
  sees exactly the bounded, sanitized session snapshots the TUI and CLI see.

    * `omp.status` (async) — availability, version and the live-session cap.
      Not installed is an explicit state; a failed read is reported as such,
      never as "no sessions".
    * `omp.sessions.list` seeds a bounded session store (live first, then
      ended, newest activity first); `omp.session` events upsert it and a
      stale event never rewinds a newer snapshot.
    * Start, resume, send (steer / follow-up / redirect), cancel and close run in
      `start_async` because the control plane dispatches them async. Each
      runs at most once per target at a time. A result that may already have
      taken effect (`OMP_OUTCOME_UNKNOWN`, `retrySafe: false`) is reported and
      never retried automatically.
    * Close ends the omp process, so it goes through a preview dialog whose
      target is held server-side; the confirm event carries no id.

  omp text (titles, activity, todos, output, errors) is untrusted: it is
  rendered as escaped plain text, never raw HTML or Markdown.
  """

  use LemonWeb, :live_view

  alias LemonControlPlane.EventBridge
  alias LemonWeb.Chat.Backend
  alias LemonWeb.Rpc

  import LemonWeb.OmpComponents

  @topic "omp"
  @max_sessions 50
  @max_id_bytes 128
  @discover_limit 30
  @tick_ms 1_000
  @idle_tick_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        nav: :omp,
        page_title: "omp · Lemon",
        status: nil,
        status_state: :loading,
        sessions: %{},
        rows: [],
        list_state: :loading,
        list_truncated?: false,
        selected_id: nil,
        detail_state: :ok,
        filter: "",
        scope: "all",
        now: now_ms(),
        tick_ref: nil,
        pending: MapSet.new(),
        compose: %{mode: "steer", text: "", unconfirmed: false},
        notice: nil,
        start_form: nil,
        close_preview: nil,
        batch_results: [],
        models: nil,
        model_target: nil,
        model_query: "",
        model_free: false,
        configure_form: nil,
        child_transcript: nil,
        resume: nil
      )

    if connected?(socket) do
      LemonCore.Bus.subscribe(@topic)

      {:ok,
       socket
       |> load_status()
       |> load_sessions()}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected =
      case {socket.assigns.live_action, params["id"]} do
        {:show, id} when is_binary(id) and id != "" and byte_size(id) <= @max_id_bytes -> id
        {:show, _id} -> :invalid
        _ -> nil
      end

    socket =
      socket
      |> assign(selected_id: if(selected == :invalid, do: nil, else: selected))
      |> assign(detail_state: if(selected == :invalid, do: :not_found, else: :ok))
      |> reset_compose_on_switch(socket.assigns.selected_id)
      |> ensure_selected_loaded()
      |> assign_page_title()

    {:noreply, socket}
  end

  # ── Events: list ────────────────────────────────────────────────────────

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter = filter |> to_string() |> String.slice(0, 200)
    {:noreply, socket |> assign(filter: filter) |> assign_rows()}
  end

  def handle_event("scope", %{"scope" => scope}, socket) when scope in ~w(all live ended) do
    {:noreply, socket |> assign(scope: scope) |> assign_rows()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(notice: nil)
     |> load_status()
     |> load_sessions()
     |> put_flash(:info, "Refreshed omp sessions.")}
  end

  def handle_event("select_step", %{"delta" => delta}, socket) when delta in [1, -1] do
    rows = socket.assigns.rows

    case rows do
      [] ->
        {:noreply, socket}

      rows ->
        index = Enum.find_index(rows, &(&1["id"] == socket.assigns.selected_id))

        next =
          case index do
            nil -> if delta > 0, do: 0, else: length(rows) - 1
            index -> index + delta
          end
          |> max(0)
          |> min(length(rows) - 1)

        {:noreply, push_patch(socket, to: session_path(Enum.at(rows, next)["id"]))}
    end
  end

  def handle_event("dismiss_notice", _params, socket), do: {:noreply, assign(socket, notice: nil)}

  # ── Events: start ───────────────────────────────────────────────────────

  def handle_event("open_start", _params, socket) do
    if available?(socket) do
      cwd =
        case selected(socket) do
          %{"cwd" => cwd} when is_binary(cwd) -> cwd
          _ -> ""
        end

      form = %{
        "prompt" => "",
        "cwd" => cwd,
        "model" => "",
        "thinking" => "",
        "approvalMode" => "",
        "isolate" => false,
        "batch" => false,
        "errors" => %{},
        "error" => nil
      }

      {:noreply, assign(socket, start_form: form)}
    else
      {:noreply, put_flash(socket, :error, unavailable_text(socket))}
    end
  end

  def handle_event("cancel_start", _params, socket) do
    if MapSet.member?(socket.assigns.pending, :start),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, start_form: nil)}
  end

  def handle_event("start_change", %{"start" => params}, socket) do
    case socket.assigns.start_form do
      nil -> {:noreply, socket}
      form -> {:noreply, assign(socket, start_form: Map.merge(form, start_fields(params)))}
    end
  end

  def handle_event("start", %{"start" => params}, socket) do
    form = Map.merge(socket.assigns.start_form || %{}, start_fields(params))
    errors = start_errors(form)

    cond do
      socket.assigns.start_form == nil or MapSet.member?(socket.assigns.pending, :start) ->
        {:noreply, socket}

      errors != %{} ->
        {:noreply, assign(socket, start_form: %{form | "errors" => errors, "error" => nil})}

      true ->
        payload =
          %{"prompt" => form["prompt"], "cwd" => String.trim(form["cwd"])}
          |> put_present("model", String.trim(form["model"]))
          |> put_present("thinking", form["thinking"])
          |> put_present("approvalMode", form["approvalMode"])
          |> Map.put("isolate", form["isolate"])

        batch? = form["batch"]

        payload =
          if batch?,
            do: %{
              "tasks" =>
                Enum.map(
                  String.split(form["prompt"], ~r/\n\s*\n/, trim: true),
                  &Map.put(payload, "prompt", &1)
                ),
              "isolate" => form["isolate"]
            },
            else: payload

        method = if batch?, do: "omp.sessions.startMany", else: "omp.sessions.start"

        {:noreply,
         socket
         |> assign(start_form: %{form | "errors" => %{}, "error" => nil})
         |> add_pending(:start)
         |> start_async(if(batch?, do: :start_many, else: :start), fn ->
           Rpc.call(method, payload)
         end)}
    end
  end

  def handle_event("open_models", params, socket) do
    target = if params["target"] == "start", do: :start, else: socket.assigns.selected_id

    {:noreply,
     socket
     |> assign(model_target: target, models: :loading, model_query: "", model_free: false)
     |> start_async(:models, fn -> Rpc.call("omp.models", %{"limit" => 100}) end)}
  end

  def handle_event("models_search", params, socket) do
    query = String.slice(to_string(params["query"] || ""), 0, 200)
    free = params["freeOnly"] == "true"

    {:noreply,
     socket
     |> assign(model_query: query, model_free: free, models: :loading)
     |> start_async(:models, fn ->
       Rpc.call("omp.models", %{"query" => query, "freeOnly" => free, "limit" => 100})
     end)}
  end

  def handle_event("close_models", _, socket), do: {:noreply, assign(socket, models: nil)}

  def handle_event("choose_model", %{"selector" => selector}, socket) do
    allowed? =
      is_list(socket.assigns.models) and
        Enum.any?(socket.assigns.models, &(&1["selector"] == selector))

    socket =
      cond do
        !allowed? ->
          socket

        socket.assigns.model_target == :start and socket.assigns.start_form != nil ->
          assign(socket,
            start_form: Map.put(socket.assigns.start_form, "model", selector),
            models: nil
          )

        is_map(socket.assigns.configure_form) ->
          assign(socket,
            configure_form: Map.put(socket.assigns.configure_form, "model", selector),
            models: nil
          )

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("open_configure", _, socket) do
    case actionable(socket, "configure") do
      {:ok, session} ->
        {:noreply,
         assign(socket, configure_form: %{"id" => session["id"], "model" => "", "thinking" => ""})}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("close_configure", _, socket),
    do: {:noreply, assign(socket, configure_form: nil)}

  def handle_event("configure", %{"configure" => params}, socket) do
    case socket.assigns.configure_form do
      %{"id" => id} = form ->
        payload =
          %{"id" => id}
          |> put_present("model", String.trim(to_string(params["model"] || "")))
          |> put_present("thinking", params["thinking"])

        if map_size(payload) > 1 and !MapSet.member?(socket.assigns.pending, {:configure, id}) do
          {:noreply,
           socket
           |> assign(configure_form: Map.merge(form, Map.take(params, ["model", "thinking"])))
           |> add_pending({:configure, id})
           |> start_async({:configure, id}, fn -> Rpc.call("omp.sessions.configure", payload) end)}
        else
          {:noreply, put_flash(socket, :error, "Choose a model or thinking setting.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("subagent", %{"id" => child_id}, socket) do
    case selected(socket) do
      %{"id" => id, "subagents" => children} when is_list(children) ->
        if Enum.any?(children, &(&1["id"] == child_id)) do
          {:noreply,
           socket
           |> assign(child_transcript: %{id: child_id, state: :loading})
           |> start_async({:subagent, id, child_id}, fn ->
             Rpc.call("omp.sessions.subagent", %{
               "id" => id,
               "subagentId" => child_id,
               "limit" => 50
             })
           end)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_subagent", _, socket),
    do: {:noreply, assign(socket, child_transcript: nil)}

  # ── Events: resume / discover ───────────────────────────────────────────

  def handle_event("open_resume", params, socket) do
    if available?(socket) do
      {:noreply, assign(socket, resume: resume_state(socket, params["id"]))}
    else
      {:noreply, put_flash(socket, :error, unavailable_text(socket))}
    end
  end

  def handle_event("cancel_resume", _params, socket) do
    if MapSet.member?(socket.assigns.pending, :resume),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, resume: nil)}
  end

  def handle_event("discover", %{"discover" => %{"cwd" => cwd}}, socket) do
    cwd = cwd |> to_string() |> String.trim()

    cond do
      socket.assigns.resume == nil or MapSet.member?(socket.assigns.pending, :discover) ->
        {:noreply, socket}

      cwd == "" ->
        {:noreply,
         update_resume(socket, cwd: cwd, scan: {:error, "Enter a workspace directory."})}

      true ->
        {:noreply,
         socket
         |> update_resume(cwd: cwd, scan: :loading, target: nil)
         |> add_pending(:discover)
         |> start_async(:discover, fn ->
           Rpc.call("omp.sessions.discover", %{"cwd" => cwd, "limit" => @discover_limit})
         end)}
    end
  end

  def handle_event("pick_resume", %{"omp" => omp_id}, socket) do
    with %{scan: {:ok, rows}} <- socket.assigns.resume,
         %{} = row <- Enum.find(rows, &(&1["ompSessionId"] == omp_id)) do
      {:noreply, update_resume(socket, target: resume_target(row), error: nil)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unpick_resume", _params, socket) do
    {:noreply, update_resume(socket, target: nil, error: nil)}
  end

  def handle_event("resume_change", %{"resume" => params}, socket) do
    {:noreply,
     update_resume(socket,
       message: to_string(params["message"] || ""),
       approval_mode: approval_mode(params["approvalMode"]),
       continue: params["continue"] in [true, "true"]
     )}
  end

  def handle_event("resolve_approval", %{"id" => id, "decision" => decision}, socket)
      when decision in ["approve", "deny"] do
    approvals = (selected(socket) || %{})["pendingApprovals"] || []

    if Enum.any?(approvals, &(&1["id"] == id)) do
      decision = if decision == "approve", do: "approve_once", else: "deny"

      case Backend.resolve_approval(id, decision) do
        :ok -> {:noreply, put_flash(socket, :info, "Approval resolved.")}
        {:error, error} -> {:noreply, put_flash(socket, :error, Rpc.message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("resume", %{"resume" => params}, socket) do
    resume = socket.assigns.resume

    cond do
      resume == nil or resume.target == nil or MapSet.member?(socket.assigns.pending, :resume) ->
        {:noreply, socket}

      true ->
        message = to_string(params["message"] || "")

        payload =
          %{"ompSessionId" => resume.target.omp_session_id, "cwd" => resume.cwd}
          |> put_present("prompt", if(String.trim(message) == "", do: "", else: message))
          |> put_present("approvalMode", approval_mode(params["approvalMode"]))
          |> Map.put(
            "continue",
            String.trim(message) == "" and
              Map.get(resume.target, :interrupted, false) and params["continue"] in [true, "true"]
          )

        {:noreply,
         socket
         |> update_resume(message: message, error: nil)
         |> add_pending(:resume)
         |> start_async(:resume, fn -> Rpc.call("omp.sessions.resume", payload) end)}
    end
  end

  # ── Events: steer / follow-up / cancel / close ──────────────────────────

  def handle_event("compose_mode", %{"mode" => mode}, socket)
      when mode in ~w(steer followUp redirect) do
    case actionable(socket, if(mode == "steer", do: "steer", else: "follow up")) do
      {:ok, _session} ->
        {:reply, %{ok: true}, update(socket, :compose, &%{&1 | mode: mode})}

      {:error, socket} ->
        {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("compose_change", %{"compose" => params}, socket) do
    text = to_string(params["text"] || "")
    mode = compose_mode(params["mode"])
    {:noreply, update(socket, :compose, &%{&1 | text: text, mode: mode})}
  end

  def handle_event("send", %{"compose" => params}, socket) do
    text = to_string(params["text"] || "")
    mode = compose_mode(params["mode"])
    socket = update(socket, :compose, &%{&1 | text: text, mode: mode})

    with {:ok, session} <- actionable(socket, "message"),
         :ok <- not_pending(socket, {:send, session["id"]}) do
      cond do
        String.trim(text) == "" ->
          {:noreply, put_flash(socket, :error, "Write a message first.")}

        byte_size(text) > 16_384 ->
          {:noreply, put_flash(socket, :error, "Messages are limited to 16 KiB.")}

        true ->
          id = session["id"]
          payload = %{"id" => id, "message" => text, "mode" => mode}

          {:noreply,
           socket
           |> update(:compose, &%{&1 | unconfirmed: false})
           |> add_pending({:send, id})
           |> start_async({:send, id, mode}, fn -> Rpc.call("omp.sessions.send", payload) end)}
      end
    else
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("cancel_turn", params, socket) do
    with {:ok, session} <- actionable(socket, "cancel", params["id"]),
         :ok <- busy(socket, session),
         :ok <- not_pending(socket, {:cancel, session["id"]}) do
      id = session["id"]

      {:noreply,
       socket
       |> add_pending({:cancel, id})
       |> start_async({:cancel, id}, fn -> Rpc.call("omp.sessions.cancel", %{"id" => id}) end)}
    else
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("preview_close", params, socket) do
    case actionable(socket, "close", params["id"]) do
      {:ok, session} ->
        preview = %{
          id: session["id"],
          label: label(session),
          status: status_text(session),
          busy?: busy?(session),
          cwd: session["cwd"],
          omp_session_id: session["ompSessionId"]
        }

        {:noreply, assign(socket, close_preview: preview)}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_close", _params, socket),
    do: {:noreply, assign(socket, close_preview: nil)}

  def handle_event("confirm_close", _params, socket) do
    case socket.assigns.close_preview do
      nil ->
        {:noreply, socket}

      %{id: id} ->
        session = Map.get(socket.assigns.sessions, id)

        cond do
          session == nil or ended?(session) ->
            {:noreply,
             socket
             |> assign(close_preview: nil)
             |> put_flash(:error, "That omp session has already ended.")}

          MapSet.member?(socket.assigns.pending, {:close, id}) ->
            {:noreply, socket}

          true ->
            {:noreply,
             socket
             |> assign(close_preview: nil)
             |> add_pending({:close, id})
             |> start_async({:close, id}, fn -> Rpc.call("omp.sessions.close", %{"id" => id}) end)}
        end
    end
  end

  # ── Async results ───────────────────────────────────────────────────────

  @impl true
  def handle_async(:start_many, {:ok, {:ok, %{"results" => results}}}, socket)
      when is_list(results) do
    socket =
      Enum.reduce(results, socket, fn
        %{"session" => session}, acc when is_map(session) -> upsert(acc, session)
        _, acc -> acc
      end)

    {:noreply,
     socket
     |> remove_pending(:start)
     |> assign(start_form: nil, batch_results: Enum.take(results, 8))
     |> load_status()}
  end

  def handle_async(:start_many, result, socket) do
    error = result_error(result)
    details = error[:details] || %{}

    message =
      if details["code"] == "OMP_INVALID_TASK",
        do: "Task index #{details["index"]}: #{Rpc.message(error)}",
        else: Rpc.message(error)

    {:noreply,
     socket
     |> remove_pending(:start)
     |> assign(
       start_form: nil,
       notice: %{
         tone: "warning",
         title: "Batch not confirmed",
         text: message <> " Not retried.",
         id: nil
       }
     )}
  end

  def handle_async(:models, {:ok, {:ok, %{"models" => models}}}, socket) when is_list(models),
    do: {:noreply, assign(socket, models: Enum.take(models, 100))}

  def handle_async(:models, result, socket),
    do: {:noreply, assign(socket, models: {:error, async_error(result)})}

  def handle_async({:configure, id}, {:ok, {:ok, %{"session" => session}}}, socket) do
    {:noreply,
     socket
     |> remove_pending({:configure, id})
     |> upsert(session)
     |> assign(configure_form: nil)
     |> put_flash(:info, "Configuration applied to #{id}.")}
  end

  def handle_async({:configure, id}, result, socket) do
    error = result_error(result)
    details = error[:details] || %{}

    text =
      if details["code"] == "OMP_PARTIALLY_APPLIED",
        do:
          "Partially applied: #{Enum.join(details["applied"] || [], ", ")}. Failed step: #{details["failedStep"]}. Changes were not rolled back. Not retried.",
        else: Rpc.message(error) <> " Not retried."

    {:noreply,
     socket
     |> remove_pending({:configure, id})
     |> assign(
       configure_form: nil,
       notice: %{tone: "warning", title: "Configuration not fully applied", text: text, id: id}
     )
     |> load_sessions()}
  end

  def handle_async({:subagent, id, child_id}, result, socket) do
    if socket.assigns.selected_id == id and socket.assigns.child_transcript != nil and
         socket.assigns.child_transcript.id == child_id do
      state =
        case result do
          {:ok, {:ok, %{"transcript" => transcript}}} -> {:ok, transcript}
          other -> {:error, async_error(other)}
        end

      {:noreply, assign(socket, child_transcript: %{id: child_id, state: state})}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:status, {:ok, {:ok, status}}, socket) when is_map(status) do
    {:noreply, socket |> assign(status: status, status_state: :ok) |> remove_pending(:status)}
  end

  def handle_async(:status, result, socket) do
    {:noreply,
     socket
     |> assign(status_state: {:error, async_error(result)})
     |> remove_pending(:status)}
  end

  def handle_async(:start, {:ok, {:ok, %{"session" => session}}}, socket) when is_map(session) do
    {:noreply,
     socket
     |> remove_pending(:start)
     |> assign(start_form: nil)
     |> upsert(session)
     |> load_status()
     |> put_flash(:info, "Started omp session #{session["id"]}.")
     |> push_patch(to: session_path(session["id"]))}
  end

  def handle_async(:start, result, socket) do
    socket = remove_pending(socket, :start)
    error = result_error(result)

    if outcome_unknown?(error) do
      {:noreply,
       socket
       |> assign(start_form: nil)
       |> unknown_notice(error, "Start not confirmed")
       |> load_sessions()}
    else
      form = socket.assigns.start_form || %{}
      field = error_field(error)

      form =
        if field in ~w(prompt cwd model thinking),
          do: %{form | "errors" => %{field => Rpc.message(error)}, "error" => nil},
          else: %{form | "errors" => %{}, "error" => Rpc.message(error)}

      {:noreply, assign(socket, start_form: form)}
    end
  end

  def handle_async(:discover, result, socket) do
    socket = remove_pending(socket, :discover)

    scan =
      case result do
        {:ok, {:ok, %{"sessions" => rows}}} when is_list(rows) ->
          {:ok, Enum.filter(rows, &(is_map(&1) and is_binary(&1["ompSessionId"])))}

        other ->
          {:error, async_error(other)}
      end

    {:noreply, if(socket.assigns.resume, do: update_resume(socket, scan: scan), else: socket)}
  end

  def handle_async(:resume, {:ok, {:ok, %{"session" => session}}}, socket) when is_map(session) do
    {:noreply,
     socket
     |> remove_pending(:resume)
     |> assign(resume: nil)
     |> upsert(session)
     |> load_status()
     |> put_flash(:info, "Resumed as #{session["id"]}.")
     |> push_patch(to: session_path(session["id"]))}
  end

  def handle_async(:resume, result, socket) do
    socket = remove_pending(socket, :resume)
    error = result_error(result)

    if outcome_unknown?(error) do
      {:noreply,
       socket
       |> assign(resume: nil)
       |> unknown_notice(error, "Resume not confirmed")
       |> load_sessions()}
    else
      {:noreply, update_resume(socket, error: Rpc.message(error))}
    end
  end

  def handle_async({:send, id, mode}, result, socket) do
    socket = remove_pending(socket, {:send, id})

    verb =
      case mode do
        "steer" -> "Steer"
        "redirect" -> "Redirect"
        _ -> "Follow-up"
      end

    current? = socket.assigns.selected_id == id

    case result do
      {:ok, {:ok, %{"accepted" => true} = reply}} ->
        delivery = reply["delivery"]

        as =
          if is_binary(delivery) and delivery != mode, do: " (delivered as #{delivery})", else: ""

        socket =
          if current?,
            do: update(socket, :compose, &%{&1 | text: "", unconfirmed: false}),
            else: socket

        {:noreply, put_flash(socket, :info, "#{verb} accepted by #{id}#{as}.")}

      other ->
        error = result_error(other)

        if outcome_unknown?(error) do
          socket =
            if current?, do: update(socket, :compose, &%{&1 | unconfirmed: true}), else: socket

          {:noreply, unknown_notice(socket, Map.put(error, :id, id), "#{verb} not confirmed")}
        else
          {:noreply, put_flash(socket, :error, "#{verb} to #{id} failed: #{Rpc.message(error)}")}
        end
    end
  end

  def handle_async({:cancel, id}, result, socket) do
    socket = remove_pending(socket, {:cancel, id})

    case result do
      {:ok, {:ok, %{"cancelled" => true}}} ->
        {:noreply, put_flash(socket, :info, "Cancelled the running turn of #{id}.")}

      other ->
        error = result_error(other)

        if outcome_unknown?(error),
          do: {:noreply, unknown_notice(socket, Map.put(error, :id, id), "Cancel not confirmed")},
          else:
            {:noreply, put_flash(socket, :error, "Cancel #{id} failed: #{Rpc.message(error)}")}
    end
  end

  def handle_async({:close, id}, result, socket) do
    socket = remove_pending(socket, {:close, id})

    case result do
      {:ok, {:ok, %{"session" => session}}} when is_map(session) ->
        {:noreply,
         socket
         |> upsert(session)
         |> load_status()
         |> put_flash(:info, "Closed #{id}. Its omp history stays on disk and can be resumed.")}

      other ->
        {:noreply,
         put_flash(socket, :error, "Close #{id} failed: #{Rpc.message(result_error(other))}")}
    end
  end

  # ── Bus events and ticks ────────────────────────────────────────────────

  @impl true
  def handle_info(%LemonCore.Event{} = event, socket) do
    case EventBridge.project(event) do
      {"omp.session", %{"session" => %{"id" => id} = session} = payload} when is_binary(id) ->
        socket = upsert(socket, session)

        socket =
          if payload["reason"] in ["started", "exited"], do: load_status(socket), else: socket

        {:noreply, socket}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(:tick, socket) do
    {:noreply, socket |> assign(tick_ref: nil, now: now_ms()) |> schedule_tick()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        selected: selected(assigns),
        available: available?(assigns),
        counts: counts(assigns.sessions)
      )

    ~H"""
    <div
      id="omp-page"
      phx-hook="OmpKeys"
      class="flex h-full min-h-0 flex-col"
    >
      <div class={[
        "shrink-0 border-b border-line px-4 pb-3 pt-4 sm:px-6",
        @selected_id && "hidden lg:block"
      ]}>
        <.page_header
          title="omp"
          icon="terminal"
          subtitle="Delegate work to omp (oh-my-pi) and watch, steer or stop it."
          class="!mb-0"
        >
          <:meta>
            <.status_meta status={@status} status_state={@status_state} counts={@counts} />
          </:meta>
          <:actions>
            <.button
              id="omp-refresh"
              size="sm"
              variant="ghost"
              icon="refresh"
              phx-click="refresh"
              aria-label="Refresh"
              icon_only
            />
            <.button
              id="omp-open-resume"
              size="sm"
              icon="history"
              phx-click="open_resume"
              disabled={!@available}
              mutation
            >
              Resume…
            </.button>
            <.button
              id="omp-open-start"
              size="sm"
              variant="primary"
              icon="plus"
              phx-click="open_start"
              disabled={!@available}
              mutation
            >
              New session
            </.button>
          </:actions>
        </.page_header>
      </div>

      <div :if={@notice} class="shrink-0 px-4 pt-3 sm:px-6">
        <.callout id="omp-notice" tone={@notice.tone} title={@notice.title}>
          {@notice.text}
          <.link
            :if={@notice[:id]}
            patch={session_path(@notice.id)}
            class="ml-1 font-medium text-accent-text underline-offset-2 hover:underline"
          >
            View {@notice.id}
          </.link>
          <:actions>
            <button type="button" class="btn btn-ghost btn-icon btn-sm" phx-click="dismiss_notice" aria-label="Dismiss">
              <.icon name="x" />
            </button>
          </:actions>
        </.callout>
      </div>
      <.worker_grid results={@batch_results} sessions={@sessions} />

      <div :if={@status_state != :loading && !@available} class="min-h-0 flex-1 overflow-y-auto px-4 py-6 sm:px-6 scroll-thin">
        <.unavailable status={@status} status_state={@status_state} />
        <div :if={@rows != []} class="mx-auto mt-6 max-w-3xl">
          <p class="mb-2 text-xs font-medium text-muted">Sessions from earlier in this runtime</p>
          <.session_list rows={@rows} selected_id={@selected_id} now={@now} />
        </div>
      </div>

      <div
        :if={@status_state == :loading || @available}
        class="grid min-h-0 flex-1 grid-cols-1 lg:grid-cols-[minmax(320px,400px)_1fr]"
      >
        <section
          aria-label="omp sessions"
          class={[
            "min-h-0 flex-col border-line lg:flex lg:border-r",
            if(@selected_id, do: "hidden", else: "flex")
          ]}
        >
          <form id="omp-filter-form" phx-change="filter" phx-submit="filter" class="shrink-0 space-y-2 px-3 pb-2 pt-3" role="search">
            <div class="relative">
              <.icon name="search" class="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-subtle" />
              <label for="omp-filter" class="sr-only">Filter omp sessions</label>
              <input
                id="omp-filter"
                name="filter"
                type="search"
                value={@filter}
                placeholder="Filter by title, id, model, workspace…"
                autocomplete="off"
                phx-debounce="150"
                class="input pl-8 pr-8"
              />
              <span class="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2"><.kbd keys="/" /></span>
            </div>
            <div class="flex items-center justify-between gap-2">
              <div class="segmented" role="group" aria-label="Show sessions">
                <button
                  :for={{scope, label, count} <- [{"all", "All", @counts.total}, {"live", "Live", @counts.live}, {"ended", "Ended", @counts.ended}]}
                  type="button"
                  phx-click="scope"
                  phx-value-scope={scope}
                  aria-pressed={to_string(@scope == scope)}
                >
                  {label} <span class="tabular-nums text-subtle">{count}</span>
                </button>
              </div>
            </div>
          </form>

          <div class="min-h-0 flex-1 overflow-y-auto px-2 pb-4 scroll-thin" id="omp-session-list-scroll">
            <div :if={@list_state == :loading} class="flex items-center gap-2 px-3 py-6 text-[13px] text-muted">
              <.spinner /> Loading omp sessions…
            </div>
            <div :if={match?({:error, _}, @list_state)} class="px-1 py-2">
              <.callout id="omp-list-error" tone="danger" title="Couldn't load omp sessions">
                {elem(@list_state, 1)}
                <:actions>
                  <.button size="sm" phx-click="refresh">Retry</.button>
                </:actions>
              </.callout>
            </div>
            <div :if={@list_state == :ok && @sessions == %{}} class="px-1 py-2">
              <.empty_state
                icon="terminal"
                title="No omp sessions yet"
                description="Start one here, run /omp run in the TUI, or ask Lemon to “run this in omp”."
              >
                <.button
                  size="sm"
                  variant="primary"
                  icon="plus"
                  phx-click="open_start"
                  disabled={!@available}
                  mutation
                >
                  New session
                </.button>
              </.empty_state>
            </div>
            <p :if={@list_state == :ok && @sessions != %{} && @rows == []} class="px-3 py-6 text-center text-[13px] text-muted">
              No sessions match this filter.
            </p>
            <.session_list :if={@rows != []} rows={@rows} selected_id={@selected_id} now={@now} />
            <p :if={@rows != []} class="px-3 pt-2 text-2xs text-subtle">
              Showing {length(@rows)} of {@counts.total}{if @list_truncated?, do: " (latest #{@counts.total} kept)"}. Ended sessions stay listed until the runtime restarts.
            </p>
          </div>
        </section>

        <section
          aria-label="omp session detail"
          class={["min-h-0 flex-col", if(@selected_id, do: "flex", else: "hidden lg:flex")]}
        >
          <div :if={@selected && !ended?(@selected)} class="p-3">
            <.button id="omp-configure-open" phx-click="open_configure">Configure model / thinking</.button>
          </div>
          <.detail
            :if={@selected}
            session={@selected}
            now={@now}
            pending={@pending}
            compose={@compose}
          />
          <div :if={!@selected} class="flex min-h-0 flex-1 items-center justify-center p-6">
            <div :if={@selected_id && @detail_state == :loading} class="flex items-center gap-2 text-[13px] text-muted">
              <.spinner /> Loading session…
            </div>
            <.empty_state
              :if={@selected_id == nil && @detail_state != :not_found}
              icon="terminal"
              title="Select an omp session"
              description="Pick a session to see its activity, tools, todos, usage and output."
              class="w-full max-w-md"
            >
              <span class="flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-xs text-muted">
                <span class="flex items-center gap-1"><.kbd keys="j" /><.kbd keys="k" /> move</span>
                <span class="flex items-center gap-1"><.kbd keys="n" /> new</span>
                <span class="flex items-center gap-1"><.kbd keys="d" /> resume</span>
                <span class="flex items-center gap-1"><.kbd keys="/" /> filter</span>
              </span>
            </.empty_state>
            <div :if={@detail_state == :not_found || match?({:error, _}, @detail_state)} class="w-full max-w-md">
              <.empty_state
                icon="alert-circle"
                title={if @detail_state == :not_found, do: "Session not found", else: "Couldn't load this session"}
                description={detail_error_text(@detail_state)}
              >
                <.button size="sm" patch={~p"/omp"} icon="chevron-left">All sessions</.button>
              </.empty_state>
            </div>
          </div>
        </section>
      </div>

      <.start_dialog :if={@start_form} form={@start_form} sessions={@sessions} starting?={MapSet.member?(@pending, :start)} />
      <.modal :if={@configure_form} id="omp-configure-dialog" show title="Configure omp session" on_cancel={Phoenix.LiveView.JS.push("close_configure")}>
        <form id="omp-configure-form" phx-submit="configure" class="space-y-3">
          <.input name="configure[model]" label="Model (optional)" value={@configure_form["model"]} />
          <.button phx-click="open_models">Browse omp models</.button>
          <.input name="configure[thinking]" type="select" label="Thinking (optional)" value={@configure_form["thinking"]} options={[{"Leave unchanged", ""} | Enum.map(thinking_levels(), &{&1, &1})]} />
          <.button type="submit" id="omp-configure-submit" loading={MapSet.member?(@pending, {:configure, @configure_form["id"]})} mutation>Apply settings</.button>
        </form>
      </.modal>
      <.modal :if={@models != nil} id="omp-models-dialog" show title="omp models" on_cancel={Phoenix.LiveView.JS.push("close_models")}>
        <form id="omp-models-search" phx-submit="models_search" class="space-y-3">
          <.input name="query" label="Search models" value={@model_query} />
          <label><input type="checkbox" name="freeOnly" value="true" checked={@model_free} /> Free models only</label>
          <.button type="submit">Search</.button>
        </form>
        <p :if={@models == :loading}>Loading models…</p>
        <p :if={match?({:error, _}, @models)}>{elem(@models, 1)}</p>
        <div :if={is_list(@models)} class="max-h-96 overflow-y-auto">
          <p :if={@models == []}>No matching models.</p>
          <button :for={model <- @models} type="button" class="block w-full border-b border-line p-2 text-left" phx-click="choose_model" phx-value-selector={model["selector"]}>
            {model["selector"]} <.badge :if={model["free"]} tone="success">FREE</.badge> · input ${model["costInput"] || "unknown"} / output ${model["costOutput"] || "unknown"} per million tokens
          </button>
        </div>
      </.modal>
      <.modal :if={@child_transcript} id="omp-child-transcript" show title={"Subagent #{@child_transcript.id} · transcript tail"} on_cancel={Phoenix.LiveView.JS.push("close_subagent")}>
        <p :if={@child_transcript.state == :loading}>Loading transcript…</p>
        <p :if={match?({:error, _}, @child_transcript.state)}>{elem(@child_transcript.state, 1)}</p>
        <div :if={match?({:ok, _}, @child_transcript.state)} class="max-h-96 overflow-y-auto">
          <article :for={message <- Enum.take(elem(@child_transcript.state, 1)["messages"] || [], -50)}>
            <p class="text-xs font-semibold">{message["role"]} {message["toolName"]}</p>
            <pre class="whitespace-pre-wrap break-words text-xs">{String.slice(message["text"] || "", 0, 16_384)}</pre>
          </article>
        </div>
      </.modal>
      <.resume_dialog :if={@resume} resume={@resume} pending={@pending} now={@now} />
      <.confirm_dialog
        :if={@close_preview}
        id="omp-close-confirm"
        title="Close this omp session?"
        description="Closing ends the omp process. Its session history stays on disk and can be resumed later."
        confirm_label="Close session"
        confirm_event="confirm_close"
        cancel_event="cancel_close"
      >
        <div class="space-y-3">
          <.key_value>
            <:item label="Session">
              <span class="font-medium">{@close_preview.label}</span>
              <span class="ml-1 font-mono text-xs text-muted">{@close_preview.id}</span>
            </:item>
            <:item label="Status">{@close_preview.status}</:item>
            <:item :if={@close_preview.cwd} label="Workspace">
              <span class="break-all font-mono text-xs">{@close_preview.cwd}</span>
            </:item>
            <:item :if={@close_preview.omp_session_id} label="omp session">
              <span class="font-mono text-xs">{@close_preview.omp_session_id}</span>
            </:item>
          </.key_value>
          <.callout :if={@close_preview.busy?} tone="warning" title="A turn is running">
            Closing aborts it and any shell commands omp started for it.
          </.callout>
        </div>
      </.confirm_dialog>
    </div>
    """
  end

  # ── Loading ─────────────────────────────────────────────────────────────

  defp load_status(socket) do
    if MapSet.member?(socket.assigns.pending, :status) do
      socket
    else
      socket
      |> add_pending(:status)
      |> start_async(:status, fn -> Rpc.call("omp.status", %{}) end)
    end
  end

  defp load_sessions(socket) do
    case Rpc.call("omp.sessions.list", %{"includeEnded" => true, "limit" => @max_sessions}) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        sessions = Enum.filter(sessions, &valid_session?/1)
        listed = MapSet.new(sessions, & &1["id"])

        # A complete reply is authoritative about live sessions; ended ones
        # stay (resumable history) until the store bound evicts them.
        kept =
          if length(sessions) < @max_sessions do
            socket.assigns.sessions
            |> Enum.reject(fn {id, s} -> not MapSet.member?(listed, id) and not ended?(s) end)
            |> Map.new()
          else
            socket.assigns.sessions
          end

        store = Enum.reduce(sessions, kept, &accept/2)

        socket
        |> assign(
          sessions: prune(store, socket.assigns.selected_id),
          list_state: :ok,
          list_truncated?: length(sessions) >= @max_sessions
        )
        |> assign_rows()
        |> schedule_tick()

      {:ok, _other} ->
        assign(socket, list_state: {:error, "The runtime returned an unexpected reply."})

      {:error, error} ->
        assign(socket, list_state: {:error, Rpc.message(error)})
    end
  end

  defp ensure_selected_loaded(%{assigns: %{selected_id: nil}} = socket), do: socket

  defp ensure_selected_loaded(%{assigns: %{selected_id: id, sessions: sessions}} = socket) do
    cond do
      Map.has_key?(sessions, id) ->
        socket

      not connected?(socket) ->
        assign(socket, detail_state: :loading)

      true ->
        case Rpc.call("omp.sessions.get", %{"id" => id}) do
          {:ok, %{"session" => session}} when is_map(session) ->
            socket |> assign(detail_state: :ok) |> upsert(session)

          {:error, %{code: :not_found}} ->
            assign(socket, detail_state: :not_found)

          {:error, %{code: :invalid_request}} ->
            assign(socket, detail_state: :not_found)

          {:error, error} ->
            assign(socket, detail_state: {:error, Rpc.message(error)})

          _other ->
            assign(socket, detail_state: {:error, "The runtime returned an unexpected reply."})
        end
    end
  end

  # ── Store ───────────────────────────────────────────────────────────────

  defp upsert(socket, session) do
    if valid_session?(session) do
      sessions =
        socket.assigns.sessions
        |> then(&accept(session, &1))
        |> prune(socket.assigns.selected_id)

      socket
      |> assign(sessions: sessions, now: now_ms())
      |> assign_rows()
      |> schedule_tick()
      |> assign_page_title()
    else
      socket
    end
  end

  # A snapshot older than the one held (an event racing a newer reply) is dropped.
  defp accept(%{"id" => id} = session, store) do
    case Map.get(store, id) do
      %{"updatedAt" => held} when is_integer(held) ->
        case session["updatedAt"] do
          new when is_integer(new) and new < held -> store
          _ -> Map.put(store, id, session)
        end

      _ ->
        Map.put(store, id, session)
    end
  end

  # Bounded: evict ended sessions first, oldest first; never the selected one.
  defp prune(store, _keep) when map_size(store) <= @max_sessions, do: store

  defp prune(store, keep) do
    victim =
      store
      |> Map.values()
      |> Enum.reject(&(&1["id"] == keep))
      |> Enum.sort_by(&{if(ended?(&1), do: 0, else: 1), recency(&1)})
      |> List.first()

    case victim do
      nil -> store
      %{"id" => id} -> prune(Map.delete(store, id), keep)
    end
  end

  defp assign_rows(socket) do
    %{sessions: sessions, filter: filter, scope: scope} = socket.assigns
    needle = filter |> String.trim() |> String.downcase()

    rows =
      sessions
      |> Map.values()
      |> Enum.filter(fn session ->
        case scope do
          "live" -> not ended?(session)
          "ended" -> ended?(session)
          _ -> true
        end
      end)
      |> Enum.filter(&matches?(&1, needle))
      |> Enum.sort_by(&{if(ended?(&1), do: 1, else: 0), -recency(&1)})

    assign(socket, rows: rows)
  end

  defp matches?(_session, ""), do: true

  defp matches?(session, needle) do
    ~w(title id ompSessionId model cwd status activity lastTurn)
    |> Enum.any?(fn key ->
      case session[key] do
        value when is_binary(value) -> String.contains?(String.downcase(value), needle)
        _ -> false
      end
    end)
  end

  # Elapsed counters tick every second while a turn runs; relative "last
  # activity" times only need a slow refresh.
  defp schedule_tick(socket) do
    %{sessions: sessions, tick_ref: pending} = socket.assigns

    interval =
      cond do
        Enum.any?(sessions, fn {_id, s} -> busy?(s) end) -> @tick_ms
        sessions != %{} -> @idle_tick_ms
        true -> nil
      end

    case {connected?(socket), interval, pending} do
      {false, _interval, _pending} ->
        socket

      {true, nil, _pending} ->
        socket

      {true, interval, {_ref, current}} when current <= interval ->
        socket

      {true, interval, pending} ->
        _ = if pending, do: Process.cancel_timer(elem(pending, 0))
        assign(socket, tick_ref: {Process.send_after(self(), :tick, interval), interval})
    end
  end

  # ── Helpers: actions ────────────────────────────────────────────────────

  # The targeted (an explicit row/button id) or selected session, when it
  # still has a process to act on.
  defp actionable(socket, verb, id \\ nil) do
    session =
      case is_binary(id) && Map.get(socket.assigns.sessions, id) do
        %{} = session -> session
        _ -> selected(socket)
      end

    cond do
      session == nil ->
        {:error, put_flash(socket, :error, "Select an omp session to #{verb}.")}

      ended?(session) ->
        {:error, put_flash(socket, :error, "#{session["id"]} has ended — resume it to continue.")}

      true ->
        {:ok, session}
    end
  end

  defp busy(socket, session) do
    if busy?(session),
      do: :ok,
      else: {:error, put_flash(socket, :error, "#{session["id"]} has no running turn to cancel.")}
  end

  defp not_pending(socket, key) do
    if MapSet.member?(socket.assigns.pending, key), do: {:error, socket}, else: :ok
  end

  defp add_pending(socket, key), do: update(socket, :pending, &MapSet.put(&1, key))
  defp remove_pending(socket, key), do: update(socket, :pending, &MapSet.delete(&1, key))

  defp reset_compose_on_switch(socket, previous) do
    if socket.assigns.selected_id != previous,
      do:
        assign(socket,
          compose: %{mode: socket.assigns.compose.mode, text: "", unconfirmed: false},
          child_transcript: nil,
          configure_form: nil,
          models: nil
        ),
      else: socket
  end

  defp unknown_notice(socket, error, title) do
    details = error[:details] || %{}
    id = error[:id] || details["id"]

    assign(socket,
      notice: %{
        tone: "warning",
        title: title,
        text: Rpc.message(error) <> " It was not retried.",
        id: if(is_binary(id) and id != "", do: id)
      }
    )
  end

  defp outcome_unknown?(%{details: %{"code" => "OMP_OUTCOME_UNKNOWN"}}), do: true
  defp outcome_unknown?(%{details: %{"retrySafe" => false}}), do: true
  defp outcome_unknown?(%{code: :outcome_unknown}), do: true
  defp outcome_unknown?(_error), do: false

  defp error_field(%{details: %{"field" => field}}) when is_binary(field), do: field
  defp error_field(_error), do: nil

  defp result_error({:ok, {:error, error}}), do: error

  defp result_error({:ok, _other}),
    do: %{code: :internal_error, message: "Unexpected reply from the runtime.", details: nil}

  defp result_error({:exit, _reason}),
    do: %{
      code: :unavailable,
      message: "The request was interrupted before the runtime answered.",
      details: nil
    }

  defp async_error(result), do: Rpc.message(result_error(result))

  defp compose_mode(mode) when mode in ~w(steer followUp redirect), do: mode
  defp compose_mode(_), do: "steer"
  defp approval_mode(mode) when mode in ~w(always-ask write yolo), do: mode
  defp approval_mode(_), do: ""

  defp start_fields(params) do
    %{
      "prompt" => to_string(params["prompt"] || ""),
      "cwd" => to_string(params["cwd"] || ""),
      "model" => to_string(params["model"] || ""),
      "approvalMode" => approval_mode(params["approvalMode"]),
      "isolate" => params["isolate"] in [true, "true"],
      "batch" => params["batch"] in [true, "true"],
      "thinking" => if(params["thinking"] in thinking_levels(), do: params["thinking"], else: "")
    }
  end

  defp start_errors(form) do
    %{}
    |> then(
      &if(form["batch"] && length(String.split(form["prompt"], ~r/\n\s*\n/, trim: true)) > 8,
        do: Map.put(&1, "prompt", "Use one to eight prompts, separated by blank lines."),
        else: &1
      )
    )
    |> then(
      &if(String.trim(form["prompt"]) == "",
        do: Map.put(&1, "prompt", "Write a prompt for omp."),
        else: &1
      )
    )
    |> then(
      &if(String.trim(form["cwd"]) == "",
        do: Map.put(&1, "cwd", "Choose the workspace omp should run in."),
        else: &1
      )
    )
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp resume_state(socket, id) do
    base = %{
      cwd: "",
      scan: :idle,
      target: nil,
      message: "",
      error: nil,
      direct?: false,
      approval_mode: "",
      continue: false
    }

    case is_binary(id) && Map.get(socket.assigns.sessions, id) do
      %{"ompSessionId" => omp_id, "cwd" => cwd} = session
      when is_binary(omp_id) and is_binary(cwd) ->
        %{
          base
          | cwd: cwd,
            direct?: true,
            target: %{
              omp_session_id: omp_id,
              title: label(session),
              active_elsewhere: false,
              interrupted: session["interrupted"] == true
            }
        }

      _ ->
        cwd =
          case selected(socket) do
            %{"cwd" => cwd} when is_binary(cwd) -> cwd
            _ -> ""
          end

        %{base | cwd: cwd}
    end
  end

  defp resume_target(row) do
    %{
      omp_session_id: row["ompSessionId"],
      title: row["title"] || "(untitled)",
      interrupted: row["interrupted"] == true,
      active_elsewhere: row["activeElsewhere"] == true
    }
  end

  defp update_resume(socket, changes) do
    update(socket, :resume, fn
      nil -> nil
      resume -> Enum.into(changes, resume)
    end)
  end

  # ── Helpers: view ───────────────────────────────────────────────────────

  defp selected(%{assigns: assigns}), do: selected(assigns)
  defp selected(%{selected_id: nil}), do: nil
  defp selected(%{selected_id: id, sessions: sessions}), do: Map.get(sessions, id)

  defp available?(%{assigns: assigns}), do: available?(assigns)
  defp available?(%{status_state: :ok, status: %{"available" => true}}), do: true
  defp available?(_assigns), do: false

  defp unavailable_text(socket) do
    case socket.assigns do
      %{status_state: {:error, message}} ->
        "omp status is unavailable: #{message}"

      %{status_state: :loading} ->
        "Still checking whether omp is installed."

      %{status_state: :ok, status: %{"available" => false}} ->
        "omp is not installed on the Lemon runtime."

      _ ->
        "omp status has not been checked yet."
    end
  end

  defp assign_page_title(socket) do
    title =
      case selected(socket) do
        nil -> "omp · Lemon"
        session -> "#{label(session)} · omp · Lemon"
      end

    assign(socket, page_title: title)
  end
end
