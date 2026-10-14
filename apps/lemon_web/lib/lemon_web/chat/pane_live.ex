defmodule LemonWeb.Chat.PaneLive do
  @moduledoc """
  One chat pane: header, transcript, approvals, composer and inspector for a
  single session. `LemonWeb.ChatLive` nests one pane (or two in split view)
  with `live_render/3`; each pane is its own process with its own session
  subscription, so two sessions stream side by side independently.

  Session contract (`live_render` session): `"session_key"` (validated
  here again), `"role"` (`"primary"` or `"secondary"`) and `"split"`.

  Lifecycle rules (apps/lemon_web/AGENTS.md):

    * subscribe only when connected; events are scoped to the session topic and
      approvals to the session key;
    * history comes from `chat.history` with full text (private chat);
    * the active run is reconciled on mount and before every active control;
      only an explicit "no run" answer means idle, lookup failures keep the
      last known running/stopping state and the draft;
    * deltas are coalesced (~40 ms) and only the streaming message is
      re-inserted; a run's final answer is appended only when nothing was
      streamed for it, so completion never duplicates the reply;
    * setup readiness is checked before uploads are consumed or any call is made.
  """

  use LemonWeb, :live_view

  require Logger

  alias LemonCore.{Bus, NodeRegistry, SessionKey}
  alias LemonControlPlane.EventBridge

  alias LemonWeb.Chat.{
    Backend,
    Components,
    Inspector,
    Setup,
    Subagents,
    Tool,
    Transcript,
    Uploads
  }

  alias LemonWeb.{Rpc, SessionCwd}

  on_mount({__MODULE__, :require_operator})

  @doc """
  Operator check for a nested pane. Only the root LiveView can read
  `connect_info`, so a pane relies on its parent (`LemonWeb.ChatLive`, which
  `LemonWeb.LiveAuth` verifies on every mount):

    * disconnected render: the parent's verified `operator_access` is
      inherited through `assign_new/3`;
    * connected mount: the signed child token binds the pane to the parent
      process that rendered it (LiveView refuses the join when that parent is
      gone), so a live `parent_pid` means an authenticated parent.

  A pane rendered or joined any other way is refused.
  """
  def on_mount(:require_operator, _params, _session, socket) do
    socket = Phoenix.Component.assign_new(socket, :operator_access, fn -> nil end)

    cond do
      socket.assigns.operator_access in [:token, :tokenless_loopback] ->
        {:cont, socket}

      connected?(socket) and is_pid(socket.parent_pid) and Process.alive?(socket.parent_pid) ->
        {:cont, Phoenix.Component.assign(socket, :operator_access, :inherited)}

      true ->
        {:halt, redirect(socket, to: "/login")}
    end
  end

  @flush_ms 40
  @subagent_refresh_ms 2_000
  @control_modes [:followup, :steer, :redirect]
  @thinking_levels ~w(off minimal low medium high xhigh auto)
  @tool_profiles [
    {"full_access", "Full access", "All tools"},
    {"safe_mode", "Safe mode", "No dangerous tools"},
    {"read_only", "Read only", "Read and search tools only"},
    {"minimal_core", "Minimal core", "Core file and shell tools"},
    {"no_external", "No external", "No network tools"},
    {"subagent_restricted", "Subagent restricted", "Edits need approval"}
  ]
  @approval_tools ~w(bash write edit patch)

  # ── Mount ───────────────────────────────────────────────────────────────

  @impl true
  def mount(:not_mounted_at_router, session, socket) do
    key = session["session_key"]

    if is_binary(key) and SessionKey.valid?(key) do
      {:ok, init(socket, key, session)}
    else
      {:ok, assign(socket, invalid: true, dom_key: "invalid"), layout: false}
    end
  end

  defp init(socket, key, session) do
    connected? = connected?(socket)

    if connected? do
      Bus.subscribe(Bus.session_topic(key))
      Bus.subscribe("exec_approvals")
      Bus.subscribe("system")
    end

    setup = Setup.status()
    {cwd, cwd_recorded?} = resolve_cwd(key)

    history =
      case Backend.history(key, cwd) do
        {:ok, rows} -> {:ok, Transcript.from_history(rows)}
        {:error, error} -> {:error, Rpc.message(error)}
      end

    {items, history_error} =
      case history do
        {:ok, items} -> {with_intro(items, session["intro"]), nil}
        {:error, message} -> {with_intro([], session["intro"]), message}
      end

    run =
      case Backend.active_run(key) do
        {:ok, run_id} -> %{status: :running, run_id: run_id, started_at_ms: nil, model: nil}
        :none -> idle_run()
        :unavailable -> %{idle_run() | status: :unavailable}
      end

    socket
    |> assign(
      invalid: false,
      session_key: key,
      dom_key: dom_key(key),
      role: session["role"] || "primary",
      split: session["split"] == true,
      agent_id: SessionKey.agent_id(key) || "default",
      cwd: cwd,
      cwd_recorded?: cwd_recorded?,
      setup_state: setup,
      setup_ready?: Setup.ready?(setup),
      meta: load_meta(key),
      tool_policy: Backend.tool_policy(key),
      run: run,
      last_run_id: run.run_id,
      resumed_runs: if(run.run_id, do: MapSet.new([run.run_id]), else: MapSet.new()),
      segments: %{},
      dirty: MapSet.new(),
      flush_timer: nil,
      streamed_runs: MapSet.new(),
      last_seq: %{},
      tools: Map.new(for(%{kind: :tool} = tool <- items, do: {tool.id, tool})),
      history_error: history_error,
      transcript_empty?: items == [],
      approvals: load_approvals(key),
      approval_notice: nil,
      plan: %{mode: nil, path: nil, content: nil, error: nil},
      plan_exit_confirm: false,
      context: %{status: :idle, data: nil, error: nil},
      compacting: false,
      subagents: %{status: :available, nodes: [], truncated?: false, active_count: 0},
      inspector_open: false,
      inspector_tab: "context",
      draft: "",
      control_mode: :followup,
      control_notice: nil,
      submit_error: nil,
      queued: [],
      models: nil,
      model_picker: false,
      model_filter: "",
      renaming: false,
      toast: nil
    )
    |> Uploads.allow()
    |> stream_configure(:items, dom_id: & &1.id)
    |> stream(:items, items, limit: -Transcript.max_items())
    |> then(fn socket ->
      if connected? do
        socket
        |> load_plan()
        |> load_context()
        |> refresh_subagents()
        |> schedule_subagent_refresh()
      else
        socket
      end
    end)
  end

  # A session started from home may mount before its first prompt reaches
  # history; show that prompt once, without duplicating it later.
  defp with_intro(items, intro) when is_binary(intro) and intro != "" do
    if Enum.any?(items, &(&1.kind == :user and String.trim(&1.text) == String.trim(intro))),
      do: items,
      else: items ++ [Transcript.user_item(intro)]
  end

  defp with_intro(items, _intro), do: items

  defp idle_run, do: %{status: :idle, run_id: nil, started_at_ms: nil, model: nil}

  # A brand-new session records its workspace when its first run starts.
  defp ensure_cwd(%{assigns: %{cwd_recorded?: true}} = socket), do: socket

  defp ensure_cwd(socket) do
    {cwd, recorded?} = resolve_cwd(socket.assigns.session_key)
    assign(socket, cwd: cwd, cwd_recorded?: recorded?)
  end

  defp resolve_cwd(key) do
    case SessionCwd.recorded(key) do
      {:ok, cwd} -> {cwd, true}
      :error -> {SessionCwd.default(), false}
    end
  end

  defp load_meta(key) do
    case Backend.session_meta(key) do
      {:ok, meta} -> meta
      {:error, _} -> empty_meta()
    end
  end

  defp empty_meta do
    %{
      title: nil,
      pinned: false,
      archived: false,
      model: nil,
      model_override: nil,
      provider: nil,
      context_window: nil,
      thinking_level: nil,
      agent_id: nil
    }
  end

  defp load_approvals(key) do
    case Backend.pending_approvals(key) do
      {:ok, pending} ->
        pending
        |> Enum.map(&Components.approval_view/1)
        |> Enum.filter(&is_binary(&1.id))
        |> Enum.sort_by(& &1.requested_at_ms)

      {:error, _} ->
        []
    end
  end

  # ── Events: composer ────────────────────────────────────────────────────

  @impl true
  def handle_event("composer-change", params, socket) do
    chat = params["chat"] || %{}

    socket =
      socket
      |> assign(:draft, chat["prompt"] || socket.assigns.draft)
      |> maybe_assign_mode(chat["mode"])

    {:noreply, socket}
  end

  def handle_event("set-mode", %{"mode" => mode}, socket),
    do: {:noreply, maybe_assign_mode(socket, mode)}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, socket |> cancel_upload(:files, ref) |> assign(:submit_error, nil)}

  def handle_event("refresh-setup", _params, socket), do: {:noreply, refresh_setup(socket)}

  def handle_event("send", params, socket) do
    chat = params["chat"] || %{}
    raw = chat["prompt"] || ""
    prompt = String.trim(raw)
    mode = normalize_mode(chat["mode"])
    socket = socket |> assign(:draft, raw) |> ensure_cwd()

    cond do
      not socket.assigns.setup_ready? ->
        {:noreply, assign(socket, :submit_error, Setup.message())}

      socket.assigns.run.status == :unavailable ->
        {:noreply,
         socket
         |> assign(:submit_error, nil)
         |> notice(
           :warning,
           "Lemon must confirm this session's run status before sending. Check status and try again."
         )}

      socket.assigns.run.status in [:running, :stopping] and mode in @control_modes ->
        submit_control(socket, prompt, mode)

      socket.assigns.run.status in [:running, :stopping] ->
        submit_control(socket, prompt, :followup)

      true ->
        submit_prompt(socket, prompt)
    end
  end

  def handle_event("refresh-run-status", _params, socket) do
    case reconcile(socket) do
      {:ok, socket, _run_id} ->
        {:noreply, notice(socket, :info, "The run is still active.")}

      {:none, socket} ->
        {:noreply, notice(socket, :info, "No run is active. Send a new message to start one.")}

      {:unavailable, socket} ->
        {:noreply,
         notice(
           socket,
           :warning,
           "Lemon could not check the active run. Its last known state is unchanged; try again."
         )}
    end
  end

  def handle_event("stop", _params, socket) do
    target =
      case reconcile(socket) do
        {:ok, socket, run_id} -> {socket, run_id}
        {:none, socket} -> {socket, nil}
        {:unavailable, socket} -> {socket, socket.assigns.run.run_id}
      end

    case target do
      {socket, nil} ->
        {:noreply, notice(socket, :info, "No run is active.")}

      {socket, run_id} ->
        case Backend.abort(run_id) do
          :ok ->
            {:noreply,
             socket
             |> assign(:run, %{socket.assigns.run | status: :stopping, run_id: run_id})
             |> assign(:submit_error, nil)
             |> notice(:info, "Stop requested.")}

          {:error, :outcome_unknown} ->
            {:noreply,
             notice(
               socket,
               :warning,
               "Lemon could not confirm the stop request. Check the run status before trying again."
             )}

          {:error, _} ->
            {:noreply,
             assign(
               socket,
               :submit_error,
               "Lemon could not stop that run. Check its status and try again."
             )}
        end
    end
  end

  def handle_event("dismiss-notice", _params, socket),
    do: {:noreply, assign(socket, :control_notice, nil)}

  def handle_event("dismiss-toast", _params, socket), do: {:noreply, assign(socket, :toast, nil)}

  # ── Events: approvals & plan ────────────────────────────────────────────

  def handle_event("resolve-approval", %{"id" => id, "decision" => decision}, socket)
      when decision in ~w(approve_once approve_session approve_global deny) do
    plan? = Enum.any?(socket.assigns.approvals, &(&1.id == id and &1.plan?))
    text = if plan? and decision != "deny", do: "Plan approved. Lemon is implementing it."
    {:noreply, resolve_approval(socket, id, decision, text)}
  end

  def handle_event("resolve-approval", _params, socket), do: {:noreply, socket}

  def handle_event("refine-plan", %{"id" => id}, socket) do
    socket =
      resolve_approval(
        socket,
        id,
        "deny",
        "Plan sent back. Tell Lemon what to change and send it as a message."
      )

    {:noreply, push_event(socket, "chat:focus-composer", %{pane: socket.assigns.dom_key})}
  end

  def handle_event("toggle-plan", _params, socket) do
    cond do
      socket.assigns.run.status in [:running, :stopping] ->
        {:noreply, toast(socket, :warning, "Stop the current run before toggling plan mode.")}

      socket.assigns.plan.mode == "plan" and is_binary(socket.assigns.plan.content) ->
        {:noreply, assign(socket, :plan_exit_confirm, true)}

      socket.assigns.plan.mode == "plan" ->
        {:noreply, change_plan(socket, "exit")}

      true ->
        {:noreply, change_plan(socket, "enter")}
    end
  end

  def handle_event("confirm-plan-exit", _params, socket),
    do: {:noreply, socket |> assign(:plan_exit_confirm, false) |> change_plan("exit")}

  def handle_event("cancel-plan-exit", _params, socket),
    do: {:noreply, assign(socket, :plan_exit_confirm, false)}

  def handle_event("refresh-plan", _params, socket), do: {:noreply, load_plan(socket)}

  # ── Events: inspector & context ─────────────────────────────────────────

  def handle_event("toggle-inspector", _params, socket) do
    open? = not socket.assigns.inspector_open
    socket = assign(socket, :inspector_open, open?)
    {:noreply, if(open?, do: on_tab_open(socket, socket.assigns.inspector_tab), else: socket)}
  end

  def handle_event("inspector-tab", %{"tab" => tab}, socket) do
    if tab in Inspector.tab_ids() do
      {:noreply, socket |> assign(inspector_open: true, inspector_tab: tab) |> on_tab_open(tab)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close-inspector", _params, socket),
    do: {:noreply, assign(socket, :inspector_open, false)}

  def handle_event("refresh-context", _params, socket), do: {:noreply, load_context(socket)}

  def handle_event("compact", _params, socket) do
    cond do
      socket.assigns.compacting ->
        {:noreply, socket}

      socket.assigns.run.status in [:running, :stopping] ->
        {:noreply, toast(socket, :warning, "Compaction is available when the run finishes.")}

      true ->
        key = socket.assigns.session_key
        cwd = socket.assigns.cwd

        {:noreply,
         socket
         |> assign(:compacting, true)
         |> start_async(:compact, fn -> Backend.compact(key, cwd) end)}
    end
  end

  # ── Events: pickers ─────────────────────────────────────────────────────

  def handle_event("open-model-picker", _params, socket) do
    socket = assign(socket, model_picker: true, model_filter: "")

    socket =
      if is_list(socket.assigns.models),
        do: socket,
        else:
          socket |> assign(:models, :loading) |> start_async(:models, fn -> Backend.models() end)

    {:noreply, socket}
  end

  def handle_event("close-model-picker", _params, socket),
    do: {:noreply, assign(socket, :model_picker, false)}

  def handle_event("model-filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, :model_filter, String.slice(filter, 0, 100))}

  def handle_event("pick-model", %{"model" => model}, socket) do
    if is_list(socket.assigns.models) and
         Enum.any?(socket.assigns.models, &(model_value(&1) == model)) do
      socket = assign(socket, :model_picker, false)

      case Backend.patch(socket.assigns.session_key, %{"model" => model}) do
        :ok ->
          {:noreply,
           socket
           |> reload_meta()
           |> toast(:success, "Model set to #{model}. It applies from the next run.")}

        {:error, error} ->
          {:noreply, toast(socket, :danger, Rpc.message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("set-thinking", %{"level" => level}, socket) when level in @thinking_levels,
    do: {:noreply, set_thinking(socket, level)}

  def handle_event("cycle-thinking", _params, socket) do
    current = socket.assigns.meta.thinking_level
    index = Enum.find_index(@thinking_levels, &(&1 == current))
    next = Enum.at(@thinking_levels, rem((index || -1) + 1, length(@thinking_levels)))
    {:noreply, set_thinking(socket, next)}
  end

  def handle_event("set-tool-profile", %{"profile" => profile}, socket) do
    if Enum.any?(@tool_profiles, &(elem(&1, 0) == profile)),
      do: {:noreply, set_tool_policy(socket, profile, socket.assigns.tool_policy.ask)},
      else: {:noreply, socket}
  end

  def handle_event("toggle-ask", _params, socket) do
    policy = socket.assigns.tool_policy
    {:noreply, set_tool_policy(socket, policy.profile || "full_access", not policy.ask)}
  end

  # ── Events: session actions ─────────────────────────────────────────────

  def handle_event("start-rename", _params, socket),
    do: {:noreply, assign(socket, :renaming, true)}

  def handle_event("cancel-rename", _params, socket),
    do: {:noreply, assign(socket, :renaming, false)}

  def handle_event("rename", %{"title" => title}, socket) do
    title = String.trim(title)
    value = if title == "", do: nil, else: String.slice(title, 0, 160)

    case Backend.metadata_patch(socket.assigns.session_key, %{"title" => value}) do
      :ok ->
        notify_parent(socket, :sessions_changed)

        {:noreply,
         socket
         |> assign(:renaming, false)
         |> assign(:meta, %{socket.assigns.meta | title: value})}

      {:error, error} ->
        {:noreply, socket |> assign(:renaming, false) |> toast(:danger, Rpc.message(error))}
    end
  end

  def handle_event("set-pinned", %{"value" => value}, socket),
    do:
      {:noreply,
       metadata(
         socket,
         %{"pinned" => value == "true"},
         if(value == "true", do: "Pinned.", else: "Unpinned.")
       )}

  def handle_event("set-archived", %{"value" => value}, socket),
    do:
      {:noreply,
       metadata(
         socket,
         %{"archived" => value == "true"},
         if(value == "true", do: "Archived.", else: "Restored.")
       )}

  def handle_event("fork", params, socket) do
    socket = ensure_cwd(socket)

    case Backend.fork(socket.assigns.session_key, socket.assigns.cwd) do
      {:ok, child} ->
        SessionCwd.remember(child, socket.assigns.cwd)

        notify_parent(
          socket,
          {:open_session, child, if(params["split"] == "true", do: :split, else: :replace),
           socket.assigns.cwd}
        )

        notify_parent(socket, :sessions_changed)
        {:noreply, toast(socket, :success, "Forked into a new session.")}

      {:error, {:outcome_unknown, _child}} ->
        {:noreply,
         toast(
           socket,
           :warning,
           "Lemon could not confirm the fork. Check Sessions before trying again."
         )}

      {:error, error} ->
        {:noreply, toast(socket, :danger, Rpc.message(error))}
    end
  end

  def handle_event("toggle-split", _params, socket) do
    notify_parent(socket, {:toggle_split, socket.assigns.session_key, socket.assigns.role})
    {:noreply, socket}
  end

  def handle_event("close-pane", _params, socket) do
    notify_parent(socket, {:close_pane, socket.assigns.role})
    {:noreply, socket}
  end

  def handle_event("focus-pane", _params, socket), do: {:noreply, socket}

  # ── Async results ───────────────────────────────────────────────────────

  @impl true
  def handle_async(:models, {:ok, {:ok, models}}, socket),
    do: {:noreply, assign(socket, :models, models)}

  def handle_async(:models, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, :models, {:error, Rpc.message(error)})}

  def handle_async(:models, {:exit, _}, socket),
    do: {:noreply, assign(socket, :models, {:error, "Models are unavailable."})}

  def handle_async(:context, {:ok, {:ok, data}}, socket),
    do: {:noreply, assign(socket, :context, %{status: :ok, data: data, error: nil})}

  def handle_async(:context, {:ok, {:error, error}}, socket),
    do:
      {:noreply,
       assign(socket, :context, %{
         socket.assigns.context
         | status: :unavailable,
           error: Rpc.message(error)
       })}

  def handle_async(:context, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket, :context, %{socket.assigns.context | status: :unavailable, error: nil})}

  def handle_async(:plan, {:ok, {:ok, plan}}, socket),
    do: {:noreply, assign(socket, :plan, Map.put(plan, :error, nil))}

  def handle_async(:plan, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, :plan, %{socket.assigns.plan | error: Rpc.message(error)})}

  def handle_async(:plan, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket, :plan, %{socket.assigns.plan | error: "Plan status is unavailable."})}

  def handle_async(:compact, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(:compacting, false)
     |> toast(:success, "Context compacted.")
     |> load_context()}
  end

  def handle_async(:compact, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(:compacting, false) |> toast(:danger, Rpc.message(error))}

  def handle_async(:compact, {:exit, _}, socket),
    do:
      {:noreply,
       socket |> assign(:compacting, false) |> toast(:danger, "Compaction did not complete.")}

  # ── Bus events ──────────────────────────────────────────────────────────

  @impl true
  def handle_info(:flush, socket), do: {:noreply, socket |> assign(:flush_timer, nil) |> flush()}

  def handle_info(:refresh_subagents, socket),
    do: {:noreply, socket |> maybe_refresh_subagents() |> schedule_subagent_refresh()}

  def handle_info(%LemonCore.Event{type: type}, socket)
      when type in [:config_reloaded, :secret_changed],
      do: {:noreply, refresh_setup(socket)}

  def handle_info(%LemonCore.Event{} = event, socket) do
    case safe_project(event) do
      {"chat", %{"type" => "delta"} = payload} ->
        {:noreply, on_delta(socket, payload)}

      {"agent", %{"type" => "started"} = payload} ->
        {:noreply, on_started(socket, payload)}

      {"agent", %{"type" => "tool_use"} = payload} ->
        {:noreply, on_tool(socket, payload)}

      {"agent", %{"type" => "completed"} = payload} ->
        {:noreply, on_completed(socket, payload, event)}

      {"exec.approval.requested", payload} ->
        {:noreply, on_approval_requested(socket, payload)}

      {"exec.approval.resolved", payload} ->
        {:noreply, on_approval_resolved(socket, payload)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp safe_project(event) do
    EventBridge.project(event)
  rescue
    _ -> nil
  end

  defp mine?(socket, payload) do
    case payload["sessionKey"] do
      nil -> true
      key -> key == socket.assigns.session_key
    end
  end

  defp on_delta(socket, payload) do
    run_id = payload["runId"] || socket.assigns.run.run_id || "run"
    text = payload["text"]
    seq = payload["seq"]
    last = Map.get(socket.assigns.last_seq, run_id)

    cond do
      not mine?(socket, payload) or not is_binary(text) or text == "" ->
        socket

      is_integer(seq) and is_integer(last) and seq <= last ->
        socket

      true ->
        segment = socket.assigns.segments[run_id] || Transcript.assistant_item(run_id, "", true)
        segment = %{segment | text: segment.text <> text}

        socket
        |> assign(
          segments: Map.put(socket.assigns.segments, run_id, segment),
          dirty: MapSet.put(socket.assigns.dirty, run_id),
          streamed_runs: MapSet.put(socket.assigns.streamed_runs, run_id),
          last_seq:
            if(is_integer(seq),
              do: Map.put(socket.assigns.last_seq, run_id, seq),
              else: socket.assigns.last_seq
            )
        )
        |> mark_running(run_id)
        |> schedule_flush()
    end
  end

  defp on_started(socket, payload) do
    run_id = payload["runId"]

    cond do
      not mine?(socket, payload) or not is_binary(run_id) ->
        socket

      payload["parentRunId"] not in [nil, ""] ->
        refresh_subagents(socket)

      true ->
        queued =
          if run_id != socket.assigns.run.run_id,
            do: Enum.drop(socket.assigns.queued, 1),
            else: socket.assigns.queued

        socket
        |> assign(
          run: %{status: :running, run_id: run_id, started_at_ms: now(), model: payload["model"]},
          last_run_id: run_id,
          queued: queued,
          control_notice: nil,
          approval_notice: nil
        )
        |> ensure_cwd()
        |> refresh_subagents()
    end
  end

  defp mark_running(socket, run_id) do
    case socket.assigns.run do
      %{status: status}
      when status in [:idle, :unavailable] and is_binary(run_id) and run_id != "run" ->
        assign(socket,
          run: %{status: :running, run_id: run_id, started_at_ms: now(), model: nil},
          last_run_id: run_id
        )

      _ ->
        socket
    end
  end

  defp on_tool(socket, payload) do
    action = payload["action"] || %{}
    kind = to_string(Tool.f(action, :kind) || "")
    run_id = payload["runId"] || socket.assigns.run.run_id || "run"

    cond do
      not mine?(socket, payload) ->
        socket

      kind == "approval" ->
        socket

      kind == "reasoning" ->
        on_reasoning(socket, run_id, action, payload)

      true ->
        case Tool.from_live(payload, now()) do
          nil ->
            socket

          tool ->
            socket =
              if tool.phase == "started", do: close_segment(socket, run_id), else: flush(socket)

            merged = Tool.merge(socket.assigns.tools[tool.id], tool)

            socket
            |> assign(:tools, Map.put(socket.assigns.tools, tool.id, merged))
            |> mark_running(payload["runId"])
            |> insert(merged)
        end
    end
  end

  defp on_reasoning(socket, run_id, action, payload) do
    reasoning = Tool.f(Tool.f(action, :detail) || %{}, :reasoning) || %{}
    text = Tool.f(reasoning, :text)
    action_id = to_string(Tool.f(action, :id) || "reasoning")

    if is_binary(text) and String.trim(text) != "" do
      done? = payload["phase"] in [:completed, "completed"]
      insert(socket, Transcript.thinking_item(run_id, action_id, text, not done?))
    else
      socket
    end
  end

  defp on_completed(socket, payload, event) do
    run_id = payload["runId"] || socket.assigns.run.run_id || "run"

    if mine?(socket, payload) do
      answer = full_answer(event) || payload["answer"]
      streamed? = MapSet.member?(socket.assigns.streamed_runs, run_id)
      segment = socket.assigns.segments[run_id]

      socket =
        cond do
          # Joined mid-run (mount/reconnect): replace the partial tail with the
          # whole answer instead of appending it a second time.
          segment && MapSet.member?(socket.assigns.resumed_runs, run_id) && is_binary(answer) &&
            answer != segment.text && String.ends_with?(answer, segment.text) ->
            socket
            |> assign(
              :segments,
              Map.put(socket.assigns.segments, run_id, %{segment | text: answer})
            )
            |> assign(:dirty, MapSet.put(socket.assigns.dirty, run_id))
            |> close_segment(run_id)

          true ->
            socket = close_segment(socket, run_id)

            if not streamed? and is_binary(answer) and String.trim(answer) != "" and
                 payload["ok"] != false,
               do: insert(socket, Transcript.assistant_item(run_id, answer, false)),
               else: socket
        end

      ok? = payload["ok"] == true
      current? = socket.assigns.run.run_id in [nil, run_id]

      socket =
        socket
        |> maybe_failure_notice(ok?, payload, event)
        |> insert(
          Transcript.run_item(run_id, %{
            ok: ok?,
            model:
              payload["model"] || (current? && socket.assigns.run.model) ||
                socket.assigns.meta.model,
            duration_ms: payload["durationMs"],
            usage: payload["usage"]
          })
        )
        |> assign(
          streamed_runs: MapSet.delete(socket.assigns.streamed_runs, run_id),
          resumed_runs: MapSet.delete(socket.assigns.resumed_runs, run_id),
          last_seq: Map.delete(socket.assigns.last_seq, run_id)
        )

      socket =
        if current?,
          do: assign(socket, run: idle_run(), control_notice: nil, last_run_id: run_id),
          else: socket

      notify_parent(socket, :sessions_changed)

      socket
      |> ensure_cwd()
      |> refresh_subagents()
      |> then(fn socket ->
        if connected?(socket), do: socket |> load_context() |> load_plan(), else: socket
      end)
    else
      socket
    end
  end

  defp full_answer(%LemonCore.Event{payload: payload}) do
    completed = Tool.f(payload, :completed) || payload

    case Tool.f(completed, :answer) do
      answer when is_binary(answer) -> answer
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_failure_notice(socket, true, _payload, _event), do: socket

  defp maybe_failure_notice(socket, _ok, payload, event) do
    if payload["cancelled"] == true or cancelled_reason?(event),
      do: insert(socket, Transcript.notice_item("info", "Run stopped.")),
      else: insert(socket, Transcript.notice_item("danger", failure_text(event)))
  end

  defp cancelled_reason?(event), do: failure_reason(event) == :cancelled

  defp failure_text(event) do
    case failure_reason(event) do
      :runtime ->
        "The run could not start because the execution runtime is unavailable. Check runtime status and try again."

      :timeout ->
        "The run timed out before it finished. Try again or use a smaller request."

      _ ->
        "The run did not finish. Check runtime status and try again."
    end
  end

  @cancel_reasons [
    :aborted,
    :cancelled,
    :canceled,
    :acp_cancel,
    :user_requested,
    :assistant_aborted,
    "aborted",
    "cancelled",
    "canceled",
    "acp_cancel",
    "user_requested",
    "assistant_aborted",
    "Cancelled by user",
    "Cancelled: acp_cancel",
    "Cancelled: user_requested"
  ]

  defp failure_reason(%LemonCore.Event{payload: payload}) do
    completed = Tool.f(payload, :completed) || payload
    error = Tool.f(completed, :error)
    reason = Tool.f(error, :reason) || Tool.f(error, :type) || error

    cond do
      reason in @cancel_reasons ->
        :cancelled

      reason in [
        :runtime_unavailable,
        :runtime_submission_failed,
        "runtime_unavailable",
        "runtime_submission_failed"
      ] ->
        :runtime

      reason in [:timeout, :timed_out, "timeout", "timed_out"] ->
        :timeout

      true ->
        :other
    end
  rescue
    _ -> :other
  end

  defp on_approval_requested(socket, payload) do
    approval = Components.approval_view(payload)

    cond do
      payload["sessionKey"] != socket.assigns.session_key ->
        socket

      not is_binary(approval.id) ->
        socket

      Enum.any?(socket.assigns.approvals, &(&1.id == approval.id)) ->
        socket

      true ->
        assign(socket, approvals: socket.assigns.approvals ++ [approval], approval_notice: nil)
    end
  end

  defp on_approval_resolved(socket, payload) do
    id = payload["approvalId"]

    if Enum.any?(socket.assigns.approvals, &(&1.id == id)) do
      socket
      |> drop_approval(id)
      |> assign(:approval_notice, resolved_elsewhere(payload["decision"]))
    else
      socket
    end
  end

  defp resolved_elsewhere("timeout"), do: "An approval request expired."
  defp resolved_elsewhere("cancelled"), do: "An approval request was withdrawn."
  defp resolved_elsewhere(_), do: "An approval was answered elsewhere."

  # ── Streaming helpers ───────────────────────────────────────────────────

  defp schedule_flush(%{assigns: %{flush_timer: nil}} = socket),
    do: assign(socket, :flush_timer, Process.send_after(self(), :flush, @flush_ms))

  defp schedule_flush(socket), do: socket

  defp flush(socket) do
    _ = if socket.assigns.flush_timer, do: Process.cancel_timer(socket.assigns.flush_timer)

    socket.assigns.dirty
    |> Enum.reduce(socket, fn run_id, socket ->
      case socket.assigns.segments[run_id] do
        nil -> socket
        segment -> insert(socket, segment)
      end
    end)
    |> assign(dirty: MapSet.new(), flush_timer: nil)
  end

  # A tool starting ends the text segment before it: later deltas open a new
  # reply below the tool card, in the order the agent produced them.
  defp close_segment(socket, run_id) do
    socket = flush(socket)

    case Map.pop(socket.assigns.segments, run_id) do
      {nil, _} ->
        socket

      {segment, rest} ->
        socket |> assign(:segments, rest) |> insert(%{segment | streaming: false})
    end
  end

  defp insert(socket, item) do
    socket
    |> stream_insert(:items, item, limit: -Transcript.max_items())
    |> assign(:transcript_empty?, false)
  end

  defp notice_item(socket, tone, text), do: insert(socket, Transcript.notice_item(tone, text))

  # ── Submission ──────────────────────────────────────────────────────────

  defp submit_control(socket, prompt, mode) do
    cond do
      prompt == "" ->
        {:noreply, assign(socket, :submit_error, "Enter guidance for the active run.")}

      byte_size(prompt) > NodeRegistry.max_control_text_bytes() ->
        {:noreply,
         assign(
           socket,
           :submit_error,
           "Active-run guidance must be 16 KB or less. Shorten the message and try again."
         )}

      Uploads.entries?(socket) ->
        {:noreply,
         assign(
           socket,
           :submit_error,
           "Active-run guidance is text only. Remove the attachment or send it after the run finishes."
         )}

      true ->
        case reconcile(socket) do
          {:ok, socket, active_run_id} ->
            case Backend.send_prompt(
                   socket.assigns.session_key,
                   prompt,
                   send_opts(socket, queue_mode: mode)
                 ) do
              {:ok, _submission_id} ->
                # The original run stays the stop target, not the submission id.
                socket =
                  socket
                  |> insert(Transcript.user_item(prompt, [], mode))
                  |> assign(:run, %{socket.assigns.run | run_id: active_run_id})
                  |> assign(:submit_error, nil)
                  |> clear_composer()
                  |> notice(:success, control_success(mode))

                socket =
                  if mode == :followup,
                    do:
                      assign(
                        socket,
                        :queued,
                        socket.assigns.queued ++
                          [%{id: System.unique_integer([:positive]), text: prompt}]
                      ),
                    else: socket

                {:noreply, socket}

              {:error, :outcome_unknown} ->
                {:noreply,
                 notice(
                   socket,
                   :warning,
                   "Lemon could not confirm whether that guidance was sent. Check the transcript before sending it again."
                 )}

              {:error, _} ->
                {:noreply,
                 notice(
                   socket,
                   :danger,
                   "Lemon refused that active-run request. The message was not sent."
                 )}
            end

          {:none, socket} ->
            {:noreply,
             notice(
               socket,
               :warning,
               "That run has already finished. Your message was not sent; send it as a new message instead."
             )}

          {:unavailable, socket} ->
            {:noreply,
             notice(
               socket,
               :warning,
               "Lemon could not confirm whether that run is still active. Your message was not sent; check status and try again."
             )}
        end
    end
  end

  defp submit_prompt(socket, prompt) do
    if Uploads.in_progress?(socket) do
      {:noreply,
       assign(socket, :submit_error, "Please wait for uploads to finish before sending.")}
    else
      if prompt == "" and not Uploads.entries?(socket) do
        {:noreply, assign(socket, :submit_error, "Enter a message or attach a file.")}
      else
        case Uploads.consume(socket) do
          {:ok, attachments} -> do_submit(socket, prompt, attachments)
          {:error, message} -> {:noreply, assign(socket, :submit_error, message)}
        end
      end
    end
  end

  defp do_submit(socket, prompt, attachments) do
    names = Uploads.display_names(attachments)
    text = Uploads.submission_prompt(prompt, attachments)
    opts = send_opts(socket, images: attachments.images)

    case Backend.send_prompt(socket.assigns.session_key, text, opts) do
      {:ok, run_id} ->
        notify_parent(socket, :sessions_changed)

        {:noreply,
         socket
         |> insert(
           Transcript.user_item(if(prompt == "", do: "(attachments)", else: prompt), names)
         )
         |> assign(
           run: %{status: :running, run_id: run_id, started_at_ms: now(), model: nil},
           last_run_id: run_id,
           submit_error: nil,
           control_notice: nil
         )
         |> clear_composer()}

      {:error, :outcome_unknown} ->
        {:noreply,
         notice(
           socket,
           :warning,
           "Lemon could not confirm whether that message was sent. Check the transcript before sending it again."
         )}

      {:error, error} ->
        Logger.info("chat.send refused code=#{inspect(error.code)}")

        {:noreply,
         socket
         |> notice_item(
           "danger",
           "Lemon could not start that run. Check runtime status and try again."
         )
         |> assign(
           :submit_error,
           "Lemon could not start that run. Check runtime status and try again."
         )}
    end
  end

  # A canonical profile session runs in the profile's own workspace; other
  # sessions keep their recorded workspace on every turn.
  defp send_opts(socket, extra) do
    cwd =
      if socket.assigns.cwd_recorded? and not SessionKey.main?(socket.assigns.session_key),
        do: socket.assigns.cwd

    Keyword.merge([cwd: cwd], extra)
  end

  defp clear_composer(socket) do
    socket
    |> assign(:draft, "")
    |> push_event("chat:composer-reset", %{pane: socket.assigns.dom_key})
  end

  defp reconcile(socket) do
    case Backend.active_run(socket.assigns.session_key) do
      {:ok, run_id} ->
        run = socket.assigns.run

        status =
          if run.status == :stopping and run.run_id == run_id, do: :stopping, else: :running

        {:ok, assign(socket, :run, %{run | status: status, run_id: run_id}), run_id}

      :none ->
        {:none, assign(socket, :run, idle_run())}

      :unavailable ->
        run = socket.assigns.run

        socket =
          if run.status in [:running, :stopping] and is_binary(run.run_id),
            do: socket,
            else: assign(socket, :run, %{idle_run() | status: :unavailable})

        {:unavailable, socket}
    end
  end

  defp control_success(:followup),
    do: "Follow-up queued. It runs after the current work finishes."

  defp control_success(:steer), do: "Steer sent to the active run."
  defp control_success(:redirect), do: "Redirect sent. Completed tool work is kept."

  defp maybe_assign_mode(socket, mode) do
    case normalize_mode(mode) do
      mode when mode in @control_modes -> assign(socket, :control_mode, mode)
      _ -> socket
    end
  end

  defp normalize_mode("followup"), do: :followup
  defp normalize_mode("steer"), do: :steer
  defp normalize_mode("redirect"), do: :redirect
  defp normalize_mode(_), do: :collect

  # ── Approvals ───────────────────────────────────────────────────────────

  # The pending store, not the rendered list, decides whether an approval
  # belongs to this session, so a forged id for another session is refused.
  defp resolve_approval(socket, id, decision, success_text) do
    key = socket.assigns.session_key

    pending? =
      case Backend.pending_approvals(key) do
        {:ok, pending} -> Enum.any?(pending, &(&1["id"] == id))
        {:error, _} -> :unavailable
      end

    case pending? do
      true ->
        case Backend.resolve_approval(id, decision) do
          :ok ->
            socket
            |> drop_approval(id)
            |> assign(:approval_notice, success_text || decision_text(decision))

          {:error, error} ->
            assign(socket, :approval_notice, Rpc.message(error))
        end

      false ->
        socket
        |> drop_approval(id)
        |> assign(:approval_notice, "That approval is no longer pending for this session.")

      :unavailable ->
        assign(socket, :approval_notice, "Lemon could not check that approval. Try again.")
    end
  end

  defp drop_approval(socket, id),
    do: assign(socket, :approvals, Enum.reject(socket.assigns.approvals, &(&1.id == id)))

  defp decision_text("approve_once"), do: "Approved once."
  defp decision_text("approve_session"), do: "Approved for this session."
  defp decision_text("approve_global"), do: "Approved for all future matching calls."
  defp decision_text("deny"), do: "Denied. Lemon will not run that tool call."

  # ── Plan / context / subagents ──────────────────────────────────────────

  defp load_plan(socket) do
    socket = ensure_cwd(socket)
    key = socket.assigns.session_key
    cwd = socket.assigns.cwd
    start_async(socket, :plan, fn -> Backend.plan(key, cwd, "status") end)
  end

  defp change_plan(socket, action) do
    socket = ensure_cwd(socket)

    case Backend.plan(socket.assigns.session_key, socket.assigns.cwd, action) do
      {:ok, plan} ->
        text =
          if plan.mode == "plan",
            do: "Plan mode on — the agent works read-only and asks before executing a plan.",
            else: "Plan mode off. Nothing was approved or executed."

        socket |> assign(:plan, Map.put(plan, :error, nil)) |> toast(:info, text)

      {:error, %{details: %{"reason" => "busy"}}} ->
        toast(socket, :warning, "Stop the current run before toggling plan mode.")

      {:error, error} ->
        toast(socket, :danger, "Plan mode did not change: " <> Rpc.message(error))
    end
  end

  defp load_context(socket) do
    socket = ensure_cwd(socket)
    key = socket.assigns.session_key
    cwd = socket.assigns.cwd

    socket
    |> assign(:context, %{socket.assigns.context | status: :loading})
    |> start_async(:context, fn -> Backend.context(key, cwd) end)
  end

  defp on_tab_open(socket, "subagents"), do: refresh_subagents(socket)
  defp on_tab_open(socket, "plan"), do: load_plan(socket)

  defp on_tab_open(socket, "context") do
    if socket.assigns.context.status in [:loading], do: socket, else: load_context(socket)
  end

  defp on_tab_open(socket, _tab), do: socket

  defp refresh_subagents(socket) do
    run_id = socket.assigns.run.run_id || socket.assigns.last_run_id
    assign(socket, :subagents, Subagents.snapshot(socket.assigns.session_key, run_id))
  end

  defp maybe_refresh_subagents(socket) do
    if socket.assigns.run.status in [:running, :stopping] or
         (socket.assigns.inspector_open and socket.assigns.inspector_tab == "subagents"),
       do: refresh_subagents(socket),
       else: socket
  end

  defp schedule_subagent_refresh(socket) do
    _ =
      if connected?(socket),
        do: Process.send_after(self(), :refresh_subagents, @subagent_refresh_ms)

    socket
  end

  # ── Routing settings ────────────────────────────────────────────────────

  defp set_thinking(socket, level) do
    case Backend.patch(socket.assigns.session_key, %{"thinkingLevel" => level}) do
      :ok ->
        socket
        |> assign(:meta, %{socket.assigns.meta | thinking_level: level})
        |> toast(:info, "Thinking: #{level}")

      {:error, error} ->
        toast(socket, :danger, Rpc.message(error))
    end
  end

  defp set_tool_policy(socket, profile, ask?) do
    policy =
      %{"profile" => profile}
      |> then(fn policy ->
        if ask?,
          do: Map.put(policy, "approvals", Map.new(@approval_tools, &{&1, "always"})),
          else: policy
      end)

    case Backend.patch(socket.assigns.session_key, %{"toolPolicy" => policy}) do
      :ok ->
        socket
        |> assign(:tool_policy, %{profile: profile, ask: ask?})
        |> toast(
          :info,
          "Tool policy: #{profile_label(profile)}#{if ask?, do: " · ask before commands and edits"}"
        )

      {:error, error} ->
        toast(socket, :danger, Rpc.message(error))
    end
  end

  defp reload_meta(socket), do: assign(socket, :meta, load_meta(socket.assigns.session_key))

  defp metadata(socket, patch, text) do
    case Backend.metadata_patch(socket.assigns.session_key, patch) do
      :ok ->
        notify_parent(socket, :sessions_changed)
        socket |> reload_meta() |> toast(:success, text)

      {:error, error} ->
        toast(socket, :danger, Rpc.message(error))
    end
  end

  # ── Misc helpers ────────────────────────────────────────────────────────

  defp refresh_setup(socket) do
    state = Setup.status()
    assign(socket, setup_state: state, setup_ready?: Setup.ready?(state), submit_error: nil)
  end

  defp notice(socket, tone, text), do: assign(socket, :control_notice, %{tone: tone, text: text})

  defp toast(socket, tone, text),
    do: assign(socket, :toast, %{tone: tone, text: text, id: System.unique_integer([:positive])})

  # Workspace-level effects (navigation, split, sidebar refresh) belong to the
  # parent `LemonWeb.ChatLive`.
  defp notify_parent(socket, message) do
    if is_pid(socket.parent_pid),
      do: send(socket.parent_pid, {:chat_pane, socket.assigns.role, message})

    :ok
  end

  defp now, do: System.system_time(:millisecond)

  defp dom_key(key),
    do: :crypto.hash(:sha256, key) |> Base.url_encode64(padding: false) |> binary_part(0, 10)

  defp model_value(model), do: "#{model.provider}:#{model.id}"

  defp profile_label(profile) do
    case Enum.find(@tool_profiles, &(elem(&1, 0) == profile)) do
      {_, label, _} -> label
      nil -> "Default"
    end
  end

  defp filtered_models(models, filter) do
    filter = String.downcase(String.trim(filter))

    models
    |> Enum.filter(fn model ->
      filter == "" or
        String.contains?(String.downcase("#{model.provider}:#{model.id} #{model.name}"), filter)
    end)
    |> Enum.take(200)
  end

  defp current_model?(meta, model) do
    meta.model in [model.id, model_value(model), "#{model.provider}/#{model.id}"]
  end

  defp context_percent(%{data: %{"percentUsed" => pct}}) when is_number(pct), do: pct
  defp context_percent(_), do: nil

  defp gauge_tone(pct) when is_number(pct) and pct >= 90, do: "bg-danger"
  defp gauge_tone(pct) when is_number(pct) and pct >= 70, do: "bg-warning"
  defp gauge_tone(_), do: "bg-accent"

  defp run_state(%{approvals: [_ | _]}), do: "approval"
  defp run_state(%{run: %{status: status}}) when status in [:running, :stopping], do: "running"
  defp run_state(_), do: "idle"

  defp status_badge(assigns) do
    ~H"""
    <span
      :if={@run.status == :running}
      id={"run-status-#{@dom_key}"}
      class="badge badge-info"
      role="status"
    >
      <.status_dot tone="info" pulse /> Running
    </span>
    <span :if={@run.status == :stopping} id={"run-status-#{@dom_key}"} class="badge badge-warning" role="status">
      <.icon name="loader" class="h-3 w-3 animate-spin" /> Stopping
    </span>
    <span :if={@run.status == :unavailable} id={"run-status-#{@dom_key}"} class="badge badge-warning" role="status">
      <.icon name="alert-triangle" class="h-3 w-3" /> Status unavailable
    </span>
    <span :if={@approvals != []} class="badge badge-warning">
      <.icon name="shield-alert" class="h-3 w-3" /> Needs approval
    </span>
    """
  end

  defp placeholder(%{run: %{status: :running}, control_mode: :followup}),
    do: "Queue a follow-up for after this run…"

  defp placeholder(%{run: %{status: :running}, control_mode: :steer}),
    do: "Steer the current run…"

  defp placeholder(%{run: %{status: :running}, control_mode: :redirect}),
    do: "Redirect: what should Lemon do instead?"

  defp placeholder(%{run: %{status: :stopping}}), do: "Waiting for the run to stop…"
  defp placeholder(%{run: %{status: :unavailable}}), do: "Check run status before sending…"

  defp placeholder(%{plan: %{mode: "plan"}}),
    do: "Describe what to plan… (read-only until you approve)"

  defp placeholder(_), do: "Ask Lemon to do work…"

  defp send_label(%{run: %{status: status}, control_mode: mode})
       when status in [:running, :stopping] do
    case mode do
      :followup -> "Queue"
      :steer -> "Steer"
      :redirect -> "Redirect"
    end
  end

  defp send_label(%{run: %{status: :unavailable}}), do: "Check status first"
  defp send_label(_), do: "Send"

  defp composer_disabled?(assigns),
    do: not assigns.setup_ready? or assigns.run.status == :unavailable

  defp tone_class(:success), do: "border-success/30 bg-success/[0.07] text-success"
  defp tone_class(:info), do: "border-info/30 bg-info/[0.07] text-info"
  defp tone_class(:warning), do: "border-warning/30 bg-warning/[0.07] text-warning"
  defp tone_class(_), do: "border-danger/30 bg-danger/[0.07] text-danger"

  defp tone_role(tone) when tone in [:warning, :danger], do: "alert"
  defp tone_role(_), do: "status"

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(%{invalid: true} = assigns) do
    ~H"""
    <div class="flex h-full items-center justify-center p-6">
      <.empty_state icon="alert-circle" title="Invalid session" description="That session key is not valid." />
    </div>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        tool_profiles: @tool_profiles,
        thinking_levels: @thinking_levels,
        tabs: Inspector.tabs(),
        ctx_pct: context_percent(assigns.context),
        title: assigns.meta.title || short_title(assigns.session_key)
      )

    ~H"""
    <div
      id={"pane-#{@dom_key}"}
      class="chat-pane flex h-full min-h-0 min-w-0 flex-1 bg-bg"
      phx-hook="ChatPane"
      data-pane={@dom_key}
      data-role={@role}
      data-run-state={run_state(assigns)}
      data-title={@title}
      phx-drop-target={@uploads.files.ref}
    >
      <section class="flex min-w-0 flex-1 flex-col" aria-label={"Chat: #{@title}"}>
        <%!-- Header --%>
        <header class="relative z-20 shrink-0 border-b border-line bg-surface">
          <div class="flex h-11 items-center gap-1.5 px-2 sm:px-3">
            <button
              :if={@role == "primary"}
              type="button"
              class="btn btn-ghost btn-icon btn-sm"
              phx-click={JS.dispatch("lemon:chat-action", to: "body", detail: %{action: "toggle-sidebar"})}
              aria-label="Toggle sessions sidebar"
              title="Sessions (⌘B)"
            >
              <.icon name="panel-left" class="h-4 w-4" />
            </button>
            <form :if={@renaming} id={"rename-#{@dom_key}"} phx-submit="rename" class="flex min-w-0 flex-1 items-center gap-1">
              <input
                name="title"
                value={@meta.title}
                maxlength="160"
                class="input h-7 min-w-0 flex-1 text-[13px] font-semibold"
                aria-label="Session title"
                phx-mounted={JS.focus()}
                phx-keydown="cancel-rename"
                phx-key="Escape"
                placeholder="Name this session"
              />
              <.button type="submit" size="sm" variant="primary" mutation>Save</.button>
              <.button size="sm" variant="ghost" phx-click="cancel-rename">Cancel</.button>
            </form>
            <button
              :if={!@renaming}
              type="button"
              id={"title-#{@dom_key}"}
              class="group flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-1 text-left hover:bg-surface-2"
              phx-click="start-rename"
              title="Rename session"
            >
              <.icon :if={@meta.pinned} name="pin" class="h-3.5 w-3.5 shrink-0 text-accent-text" />
              <h2 class="truncate text-[13.5px] font-semibold text-fg">{@title}</h2>
              <.icon name="pencil" class="h-3 w-3 shrink-0 text-subtle opacity-0 group-hover:opacity-100" />
            </button>
            <div :if={!@renaming} class="hidden min-w-0 items-center gap-1.5 sm:flex">
              <.status_badge run={@run} approvals={@approvals} dom_key={@dom_key} />
              <.badge :if={@plan.mode == "plan"} tone="plan" icon="list-checks" id={"plan-indicator-#{@dom_key}"}>Plan</.badge>
            </div>
            <div class="ml-auto flex shrink-0 items-center gap-0.5">
              <button
                type="button"
                id={"plan-toggle-#{@dom_key}"}
                class={["btn btn-ghost btn-sm", @plan.mode == "plan" && "text-plan"]}
                phx-click="toggle-plan"
                aria-pressed={to_string(@plan.mode == "plan")}
                title="Toggle plan mode (⌘⇧P)"
                data-requires-connection
              >
                <.icon name="list-checks" class="h-3.5 w-3.5" /><span class="hidden lg:inline">Plan</span>
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-icon btn-sm hidden md:inline-flex"
                phx-click="toggle-split"
                aria-label={if @split, do: "Close split view", else: "Open split view"}
                title="Split view (⌘\\)"
              >
                <.icon name="columns" class="h-4 w-4" />
              </button>
              <button
                type="button"
                id={"fork-#{@dom_key}"}
                class="btn btn-ghost btn-icon btn-sm"
                phx-click="fork"
                aria-label="Fork session"
                title="Fork session"
                data-requires-connection
              >
                <.icon name="git-fork" class="h-4 w-4" />
              </button>
              <button
                type="button"
                class={["btn btn-ghost btn-icon btn-sm", @inspector_open && "bg-surface-2 text-fg"]}
                phx-click="toggle-inspector"
                aria-label="Toggle inspector"
                aria-pressed={to_string(@inspector_open)}
                title="Inspector (⌘I)"
              >
                <.icon name="panel-right" class="h-4 w-4" />
              </button>
              <.dropdown id={"more-#{@dom_key}"} label="More session actions">
                <:trigger>
                  <span class="btn btn-ghost btn-icon btn-sm"><.icon name="more-horizontal" class="h-4 w-4" /></span>
                </:trigger>
                <button type="button" role="menuitem" class="menu-item" phx-click="fork" phx-value-split="true">
                  <.icon name="columns" class="h-3.5 w-3.5" /> Fork into split
                </button>
                <button type="button" role="menuitem" class="menu-item" phx-click="set-pinned" phx-value-value={to_string(!@meta.pinned)}>
                  <.icon name="pin" class="h-3.5 w-3.5" /> {if @meta.pinned, do: "Unpin", else: "Pin"}
                </button>
                <button type="button" role="menuitem" class="menu-item" phx-click="set-archived" phx-value-value={to_string(!@meta.archived)}>
                  <.icon name="archive" class="h-3.5 w-3.5" /> {if @meta.archived, do: "Restore", else: "Archive"}
                </button>
                <div class="my-1 border-t border-line"></div>
                <a role="menuitem" class="menu-item" href={"/sessions/#{URI.encode_www_form(@session_key)}/export/markdown"}>
                  <.icon name="download" class="h-3.5 w-3.5" /> Export Markdown
                </a>
                <a role="menuitem" class="menu-item" href={"/sessions/#{URI.encode_www_form(@session_key)}/export/json"}>
                  <.icon name="download" class="h-3.5 w-3.5" /> Export JSON
                </a>
                <.link role="menuitem" class="menu-item" navigate={"/sessions/#{URI.encode_www_form(@session_key)}"}>
                  <.icon name="external-link" class="h-3.5 w-3.5" /> Open in session manager
                </.link>
                <button :if={@role == "secondary"} type="button" role="menuitem" class="menu-item" phx-click="close-pane">
                  <.icon name="x" class="h-3.5 w-3.5" /> Close pane
                </button>
              </.dropdown>
            </div>
          </div>

          <%!-- Routing toolbar: model, thinking, tools, context --%>
          <div class="flex h-8 min-w-0 items-center gap-1 border-t border-line/60 px-2 text-xs sm:px-3">
            <button
              type="button"
              id={"model-picker-btn-#{@dom_key}"}
              class="btn btn-ghost btn-sm h-6 max-w-[14rem] gap-1 px-1.5 font-mono text-2xs"
              phx-click="open-model-picker"
              title="Model (⌘⇧M)"
            >
              <.icon name="cpu" class="h-3 w-3" />
              <span class="truncate">{@meta.model || "default model"}</span>
              <.icon name="chevron-down" class="h-3 w-3 text-subtle" />
            </button>
            <.dropdown id={"thinking-#{@dom_key}"} label="Thinking level" align="start">
              <:trigger>
                <span class="btn btn-ghost btn-sm h-6 gap-1 px-1.5 text-2xs" title="Thinking level (⇧Tab in composer)">
                  <.icon name="brain" class="h-3 w-3" /> {@meta.thinking_level || "thinking: default"}
                  <.icon name="chevron-down" class="h-3 w-3 text-subtle" />
                </span>
              </:trigger>
              <button
                :for={level <- @thinking_levels}
                type="button"
                role="menuitemradio"
                aria-checked={to_string(@meta.thinking_level == level)}
                class="menu-item"
                phx-click="set-thinking"
                phx-value-level={level}
              >
                <.icon name={if @meta.thinking_level == level, do: "check", else: "dot"} class="h-3.5 w-3.5" />
                {level}
              </button>
            </.dropdown>
            <.dropdown id={"tools-#{@dom_key}"} label="Tool policy" align="start" menu_class="w-64">
              <:trigger>
                <span class="btn btn-ghost btn-sm h-6 gap-1 px-1.5 text-2xs" title="Tool and approval policy">
                  <.icon name={if @tool_policy.ask, do: "shield-check", else: "wrench"} class="h-3 w-3" />
                  {profile_label(@tool_policy.profile)}{if @tool_policy.ask, do: " · ask"}
                  <.icon name="chevron-down" class="h-3 w-3 text-subtle" />
                </span>
              </:trigger>
              <p class="px-2 pb-1 pt-1.5 text-2xs font-semibold uppercase tracking-wide text-subtle">Tool access</p>
              <button
                :for={{id, label, hint} <- @tool_profiles}
                type="button"
                role="menuitemradio"
                aria-checked={to_string(@tool_policy.profile == id)}
                class="menu-item items-start"
                phx-click="set-tool-profile"
                phx-value-profile={id}
              >
                <.icon name={if @tool_policy.profile == id, do: "check", else: "dot"} class="mt-0.5 h-3.5 w-3.5" />
                <span><span class="block">{label}</span><span class="block text-2xs text-subtle">{hint}</span></span>
              </button>
              <div class="my-1 border-t border-line"></div>
              <button
                type="button"
                role="menuitemradio"
                aria-checked={to_string(@tool_policy.ask)}
                class="menu-item"
                phx-click="toggle-ask"
              >
                <.icon name={if @tool_policy.ask, do: "check", else: "dot"} class="h-3.5 w-3.5" />
                Ask before commands &amp; edits
              </button>
            </.dropdown>
            <div class="flex-1"></div>
            <span :if={@run.status == :running && @run.started_at_ms} class="hidden items-center gap-1 text-2xs tabular-nums text-subtle sm:flex">
              <.icon name="clock" class="h-3 w-3" />
              <span id={"elapsed-#{@dom_key}"} phx-hook="Countdown" data-since={@run.started_at_ms}></span>
            </span>
            <button
              type="button"
              id={"context-gauge-#{@dom_key}"}
              class="btn btn-ghost btn-sm h-6 gap-1.5 px-1.5 text-2xs tabular-nums"
              phx-click="inspector-tab"
              phx-value-tab="context"
              title="Context window"
            >
              <span class="relative h-1.5 w-12 overflow-hidden rounded-full bg-surface-2" aria-hidden="true">
                <span class={["absolute inset-y-0 left-0 rounded-full", gauge_tone(@ctx_pct)]} style={"width: #{min(@ctx_pct || 0, 100)}%"}></span>
              </span>
              {if @ctx_pct, do: Inspector.format_percent(@ctx_pct), else: "ctx"}
            </button>
          </div>
        </header>

        <%!-- Transcript --%>
        <div
          id={"scroller-#{@dom_key}"}
          class="relative min-h-0 flex-1 overflow-y-auto scroll-thin"
          phx-hook="ChatScroll"
        >
          <div class="mx-auto w-full max-w-3xl px-3 pb-6 pt-4 sm:px-5">
            <.callout :if={@history_error} tone="warning" title="History unavailable" class="mb-3">
              {@history_error}
            </.callout>
            <div :if={@transcript_empty? && @approvals == []} class="py-10">
              <.empty_state icon="message-square" title="Start the conversation" description="Ask Lemon to read, change or run something in this workspace. Use Plan mode to get a reviewed plan first." />
            </div>
            <div id={"transcript-#{@dom_key}"} class="transcript space-y-3" phx-update="stream" role="log" aria-live="polite" aria-relevant="additions">
              <Components.item :for={{dom_id, item} <- @streams.items} dom_id={dom_id} item={item} />
            </div>

            <div :if={@approvals != [] or @approval_notice} class="mt-3 space-y-3" id={"approvals-#{@dom_key}"}>
              <p :if={@approval_notice} id={"approval-notice-#{@dom_key}"} role="status" class="approval-notice ml-9 text-xs text-muted">
                {@approval_notice}
              </p>
              <Components.approval_card :for={approval <- @approvals} approval={approval} />
            </div>

            <div :if={@run.status in [:running, :stopping]} class="ml-9 mt-3 flex items-center gap-2 text-xs text-muted" id={"run-line-#{@dom_key}"}>
              <.spinner class="h-3.5 w-3.5" label="Working" />
              <span>{if @run.status == :stopping, do: "Stopping…", else: "Working…"}</span>
              <span :if={@run.model} class="font-mono text-subtle">{@run.model}</span>
            </div>
          </div>
          <button
            type="button"
            class="jump-latest btn btn-secondary btn-sm absolute bottom-3 left-1/2 hidden -translate-x-1/2 shadow-pop"
            data-jump-latest
          >
            <.icon name="arrow-up" class="h-3.5 w-3.5 rotate-180" /> Latest
          </button>
        </div>

        <%!-- Composer --%>
        <div class="shrink-0 border-t border-line bg-surface/60 px-3 pb-3 pt-2 safe-bottom sm:px-5">
          <div class="mx-auto w-full max-w-3xl space-y-2">
            <Setup.gate :if={!@setup_ready?} state={@setup_state} />
            <.callout :if={@run.status == :unavailable} id={"run-unavailable-#{@dom_key}"} tone="warning" title="Run status unavailable">
              Lemon could not confirm whether this session is running. Check status before sending another message.
              <:actions>
                <.button size="sm" icon="refresh" phx-click="refresh-run-status">Check status</.button>
              </:actions>
            </.callout>
            <div
              :if={@control_notice}
              id={"control-notice-#{@dom_key}"}
              role={tone_role(@control_notice.tone)}
              class={["flex items-start gap-2 rounded-md border px-2.5 py-1.5 text-xs", tone_class(@control_notice.tone)]}
            >
              <span class="flex-1">{@control_notice.text}</span>
              <button type="button" class="opacity-70 hover:opacity-100" phx-click="dismiss-notice" aria-label="Dismiss">
                <.icon name="x" class="h-3 w-3" />
              </button>
            </div>
            <ul :if={@queued != []} id={"queued-#{@dom_key}"} class="space-y-1" aria-label="Queued follow-ups">
              <li :for={item <- @queued} class="flex items-center gap-2 rounded-md border border-dashed border-line-strong px-2.5 py-1 text-xs text-muted">
                <.icon name="clock" class="h-3 w-3" /><span class="font-medium text-fg">Queued</span>
                <span class="min-w-0 flex-1 truncate">{item.text}</span>
              </li>
            </ul>

            <form
              id={"composer-form-#{@dom_key}"}
              phx-change="composer-change"
              phx-submit="send"
              class="rounded-xl border border-line bg-surface shadow-sm transition-colors focus-within:border-ring focus-within:ring-2 focus-within:ring-ring/25"
            >
              <input type="hidden" name="chat[mode]" value={if @run.status in [:running, :stopping], do: @control_mode, else: "collect"} />
              <div :if={@run.status in [:running, :stopping]} class="flex items-center gap-2 border-b border-line/70 px-2 py-1.5">
                <div class="segmented" role="group" aria-label="Message mode while running" id={"modes-#{@dom_key}"}>
                  <button
                    :for={{mode, label, hint} <- [{:followup, "Follow-up", "Queue a separate turn after the current run finishes."}, {:steer, "Steer", "Add guidance to the work in progress."}, {:redirect, "Redirect", "Replace the pending direction while keeping completed tool work."}]}
                    type="button"
                    phx-click="set-mode"
                    phx-value-mode={mode}
                    aria-pressed={to_string(@control_mode == mode)}
                    title={hint}
                  >
                    {label}
                  </button>
                </div>
                <span class="hidden truncate text-2xs text-subtle sm:inline">
                  {case @control_mode do
                    :followup -> "Runs after the current work finishes"
                    :steer -> "Adds guidance to the running work"
                    :redirect -> "Changes direction, keeps completed tool work"
                  end}
                </span>
              </div>

              <ul :if={@uploads.files.entries != []} class="flex flex-wrap gap-1.5 px-2.5 pt-2" aria-label="Attachments">
                <li
                  :for={entry <- @uploads.files.entries}
                  id={"upload-#{entry.ref}"}
                  class="flex max-w-[14rem] items-center gap-1.5 rounded-md border border-line bg-surface-2 px-2 py-1 text-xs"
                >
                  <.icon name={if Uploads.image?(entry), do: "image", else: "file"} class="h-3.5 w-3.5 shrink-0 text-subtle" />
                  <span class="min-w-0 truncate">{entry.client_name}</span>
                  <span :if={!entry.done?} class="tabular-nums text-subtle">{entry.progress}%</span>
                  <span :for={err <- upload_errors(@uploads.files, entry)} class="text-danger">{Uploads.error_text(err)}</span>
                  <button type="button" phx-click="cancel-upload" phx-value-ref={entry.ref} aria-label={"Remove #{entry.client_name}"} class="text-subtle hover:text-fg">
                    <.icon name="x" class="h-3 w-3" />
                  </button>
                </li>
              </ul>
              <p :for={err <- upload_errors(@uploads.files)} class="px-2.5 pt-1 text-xs text-danger">{Uploads.error_text(err)}</p>

              <label for={"composer-#{@dom_key}"} class="sr-only">Message</label>
              <textarea
                id={"composer-#{@dom_key}"}
                name="chat[prompt]"
                rows="1"
                phx-hook="Composer"
                phx-debounce="300"
                data-pane={@dom_key}
                placeholder={placeholder(assigns)}
                disabled={composer_disabled?(assigns)}
                class="block max-h-72 min-h-[2.75rem] w-full resize-none border-0 bg-transparent px-3 py-2.5 text-[13.5px] leading-relaxed text-fg placeholder:text-subtle focus:outline-none focus:ring-0 disabled:cursor-not-allowed disabled:opacity-60"
              >{@draft}</textarea>

              <div class="flex items-center gap-1 px-1.5 pb-1.5">
                <label
                  :if={@run.status not in [:running, :stopping]}
                  class={["btn btn-ghost btn-icon btn-sm cursor-pointer", composer_disabled?(assigns) && "pointer-events-none opacity-50"]}
                  title="Attach files or images (or paste / drop)"
                >
                  <.icon name="paperclip" class="h-4 w-4" />
                  <span class="sr-only">Attach files</span>
                  <.live_file_input upload={@uploads.files} class="sr-only" />
                </label>
                <span class="hidden items-center gap-1 text-2xs text-subtle md:flex">
                  <.kbd keys="enter" /> send <.kbd keys="shift+enter" /> newline
                  <span :if={@run.status == :running}>· <.kbd keys="mod+enter" /> steer</span>
                </span>
                <p :if={@submit_error} id={"submit-error-#{@dom_key}"} role="alert" class="min-w-0 flex-1 truncate px-1 text-xs text-danger" title={@submit_error}>
                  {@submit_error}
                </p>
                <div :if={!@submit_error} class="flex-1"></div>
                <.button
                  :if={@run.status in [:running, :stopping]}
                  id={"stop-#{@dom_key}"}
                  size="sm"
                  variant="danger-soft"
                  icon="square"
                  phx-click="stop"
                  mutation
                  disabled={@run.status == :stopping}
                  title="Stop (⌘.)"
                >
                  {if @run.status == :stopping, do: "Stopping", else: "Stop"}
                </.button>
                <.button
                  type="submit"
                  id={"send-#{@dom_key}"}
                  size="sm"
                  variant="primary"
                  icon="send"
                  mutation
                  disabled={composer_disabled?(assigns)}
                >
                  {send_label(assigns)}
                </.button>
              </div>
            </form>
          </div>
        </div>
      </section>

      <%!-- Inspector --%>
      <aside
        :if={@inspector_open}
        id={"inspector-#{@dom_key}"}
        class="inspector fixed inset-0 z-40 flex flex-col bg-surface md:static md:z-auto md:w-80 md:shrink-0 md:border-l md:border-line lg:w-[22rem]"
        aria-label="Inspector"
      >
        <div class="flex h-11 shrink-0 items-center gap-2 border-b border-line px-3">
          <h2 class="text-[13px] font-semibold">Inspector</h2>
          <button type="button" class="btn btn-ghost btn-icon btn-sm ml-auto" phx-click="close-inspector" aria-label="Close inspector">
            <.icon name="x" class="h-4 w-4" />
          </button>
        </div>
        <.tabs active={@inspector_tab} label="Inspector sections" class="shrink-0 px-3">
          <:tab :for={{id, label, _icon} <- @tabs} id={id} label={label} click="inspector-tab" />
        </.tabs>
        <div class="min-h-0 flex-1 overflow-y-auto p-3 scroll-thin" role="tabpanel">
          <Inspector.tab
            tab={@inspector_tab}
            dom_key={@dom_key}
            session_key={@session_key}
            cwd={@cwd}
            agent_id={@agent_id}
            meta={@meta}
            run={@run}
            last_run_id={@last_run_id}
            context={@context}
            compacting={@compacting}
            plan={@plan}
            subagents={@subagents}
          />
        </div>
      </aside>

      <%!-- Model picker --%>
      <.modal :if={@model_picker} id={"model-picker-#{@dom_key}"} show title="Choose a model" description="Applies to this session from the next run." on_cancel={JS.push("close-model-picker")}>
        <form id={"model-filter-#{@dom_key}"} phx-change="model-filter" phx-submit="model-filter" class="mb-3">
          <input
            name="filter"
            value={@model_filter}
            class="input"
            placeholder="Filter models…"
            autocomplete="off"
            aria-label="Filter models"
            phx-mounted={JS.focus()}
          />
        </form>
        <div :if={@models == :loading} class="flex items-center gap-2 py-6 text-xs text-muted"><.spinner /> Loading models…</div>
        <.callout :if={match?({:error, _}, @models)} tone="warning">{elem(@models, 1)}</.callout>
        <ul :if={is_list(@models)} role="listbox" aria-label="Models" class="max-h-[50vh] space-y-px overflow-y-auto scroll-thin" phx-hook="ListNav" id={"model-list-#{@dom_key}"}>
          <li :for={model <- filtered_models(@models, @model_filter)}>
            <button
              type="button"
              role="option"
              aria-selected={to_string(current_model?(@meta, model))}
              class="menu-item justify-between"
              phx-click="pick-model"
              phx-value-model={model_value(model)}
            >
              <span class="min-w-0">
                <span class="block truncate font-mono text-xs">{model.provider}:{model.id}</span>
                <span class="block truncate text-2xs text-subtle">
                  {model.name}{if model.context_window, do: " · #{compact_number(model.context_window)} ctx"}{if model.thinking, do: " · thinking"}{if model.vision, do: " · vision"}
                </span>
              </span>
              <.icon :if={current_model?(@meta, model)} name="check" class="h-3.5 w-3.5 text-accent-text" />
            </button>
          </li>
          <li :if={filtered_models(@models, @model_filter) == []} class="py-4 text-center text-xs text-muted">No models match.</li>
        </ul>
      </.modal>

      <.confirm_dialog
        :if={@plan_exit_confirm}
        id={"plan-exit-#{@dom_key}"}
        title="Exit plan mode?"
        description="This exits plan mode without approving the plan. The agent asks before executing any plan."
        confirm_label="Exit without approving"
        confirm_event="confirm-plan-exit"
        cancel_event="cancel-plan-exit"
        tone="primary"
      />

      <div
        :if={@toast}
        id={"toast-#{@toast.id}"}
        role="status"
        phx-hook="AutoDismiss"
        phx-click="dismiss-toast"
        class={["pointer-events-auto fixed left-1/2 top-16 z-50 flex max-w-[min(28rem,calc(100vw-2rem))] -translate-x-1/2 cursor-pointer items-center gap-2 rounded-lg border bg-elevated px-3 py-2 text-[13px] shadow-pop animate-slide-up", tone_class(@toast.tone)]}
      >
        <span class="text-fg">{@toast.text}</span>
      </div>
    </div>
    """
  end

  defp short_title(key) do
    case SessionKey.parse(key) do
      %{kind: :main, agent_id: agent} ->
        "#{agent} · main"

      %{agent_id: agent} ->
        "#{agent} · #{key |> String.split(":") |> List.last() |> String.slice(0, 12)}"

      _ ->
        String.slice(key, 0, 40)
    end
  rescue
    _ -> String.slice(key, 0, 40)
  end
end
