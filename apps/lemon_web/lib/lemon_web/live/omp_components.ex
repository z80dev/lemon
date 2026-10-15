defmodule LemonWeb.OmpComponents do
  @moduledoc """
  Function components and formatting for `LemonWeb.OmpLive`.

  Inputs are `omp.*` control-plane session wires (camelCase string keys).
  Every string in them is omp output and untrusted: it is rendered as escaped
  plain text, never Markdown.
  """

  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: LemonWeb.Endpoint, router: LemonWeb.Router

  import LemonWeb.UI

  alias Phoenix.LiveView.JS

  @thinking_levels ~w(off minimal low medium high xhigh max auto)
  @closed_todo ~w(completed done abandoned)

  @doc "Thinking levels omp accepts for a new session."
  def thinking_levels, do: @thinking_levels

  attr(:status, :map, default: nil)
  attr(:status_state, :any, required: true)
  attr(:counts, :map, required: true)

  def status_meta(assigns) do
    ~H"""
    <span :if={@status_state == :loading} class="flex items-center gap-1.5 text-xs text-muted">
      <.spinner class="h-3.5 w-3.5" /> Checking omp…
    </span>
    <.badge :if={match?({:error, _}, @status_state)} tone="danger" icon="alert-circle" id="omp-status-badge">
      Status unavailable
    </.badge>
    <%= if @status_state == :ok do %>
      <.badge :if={@status["available"] == true} tone="success" id="omp-status-badge">
        <.status_dot tone="success" /> {@status["version"] || "omp"}
      </.badge>
      <.badge :if={@status["available"] != true} tone="warning" icon="alert-triangle" id="omp-status-badge">
        Not installed
      </.badge>
      <.badge :if={is_integer(@status["live"])} tone={if live_full?(@status), do: "warning", else: "neutral"} id="omp-live-badge">
        {@status["live"]}{if is_integer(@status["maxSessions"]), do: "/#{@status["maxSessions"]}"} live
      </.badge>
      <.badge :if={@counts.busy > 0} tone="accent">
        <.status_dot tone="accent" pulse /> {@counts.busy} running
      </.badge>
    <% end %>
    """
  end

  attr(:status, :map, default: nil)
  attr(:status_state, :any, required: true)

  def unavailable(assigns) do
    ~H"""
    <div id="omp-unavailable" class="mx-auto max-w-3xl">
      <%= if match?({:error, _}, @status_state) do %>
        <.callout tone="danger" title="Couldn't read omp status">
          {elem(@status_state, 1)} This is a problem reaching the runtime, not a sign that omp is missing.
          <:actions>
            <.button size="sm" icon="refresh" phx-click="refresh">Retry</.button>
          </:actions>
        </.callout>
      <% else %>
        <div class="card overflow-hidden">
          <div class="flex flex-col items-center px-6 pb-6 pt-8 text-center">
            <div class="mb-3 flex h-11 w-11 items-center justify-center rounded-full bg-warning/10 text-warning">
              <.icon name="terminal" class="h-5 w-5" />
            </div>
            <h2 class="text-[15px] font-semibold text-fg">omp is not installed</h2>
            <p class="mt-1 max-w-md text-[13px] text-muted">
              The Lemon runtime could not find an <span class="font-mono">omp</span> executable, so there is nothing to delegate to yet.
              Lemon's own agent keeps working as usual.
            </p>
          </div>
          <div class="border-t border-line bg-surface-2/50 px-6 py-5">
            <ol class="space-y-3 text-[13px] text-fg">
              <li class="flex gap-3">
                <span class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-surface text-2xs font-semibold text-muted ring-1 ring-line">1</span>
                <span>
                  Install omp (oh-my-pi) on the machine running Lemon —
                  <a href="https://github.com/can1357/oh-my-pi" target="_blank" rel="noopener noreferrer" class="font-medium text-accent-text hover:underline">
                    github.com/can1357/oh-my-pi <.icon name="external-link" class="inline h-3 w-3" />
                  </a>
                </span>
              </li>
              <li class="flex gap-3">
                <span class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-surface text-2xs font-semibold text-muted ring-1 ring-line">2</span>
                <span>
                  Make it visible to the runtime: put <span class="font-mono">omp</span> on the runtime's <span class="font-mono">PATH</span>,
                  or set <span class="font-mono">LEMON_OMP_BIN</span> to the executable.
                </span>
              </li>
              <li class="flex gap-3">
                <span class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-surface text-2xs font-semibold text-muted ring-1 ring-line">3</span>
                <span>
                  Configure omp with a working model (its own setup and API keys — Lemon never passes its credentials), then check again. Restart Lemon if you changed its environment.
                </span>
              </li>
            </ol>
            <div class="mt-5 flex flex-wrap items-center gap-2">
              <.button size="sm" icon="refresh" phx-click="refresh" id="omp-check-again">Check again</.button>
              <span class="text-xs text-subtle">Verify from a shell with <span class="font-mono">lemon omp status</span>.</span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:rows, :list, required: true)
  attr(:selected_id, :string, default: nil)
  attr(:now, :integer, required: true)

  def session_list(assigns) do
    ~H"""
    <ul id="omp-sessions" class="space-y-1" role="list">
      <li :for={session <- @rows} id={"omp-row-#{session["id"]}"}>
        <.link
          patch={session_path(session["id"])}
          aria-current={@selected_id == session["id"] && "true"}
          class={[
            "group block rounded-lg border px-3 py-2.5 transition-colors",
            if(@selected_id == session["id"],
              do: "border-accent/40 bg-accent/[0.06]",
              else: "border-transparent hover:border-line hover:bg-surface-2/60"
            ),
            ended?(session) && "opacity-80"
          ]}
        >
          <div class="flex items-center gap-2">
            <.status_dot tone={status_tone(session)} pulse={busy?(session)} />
            <span class="min-w-0 flex-1 truncate text-[13px] font-medium text-fg">{label(session)}</span>
            <span :if={busy?(session)} class="shrink-0 text-2xs tabular-nums text-accent-text" title="Running for">
              {elapsed(session, @now)}
            </span>
            <span :if={!busy?(session)} class="shrink-0 text-2xs tabular-nums text-subtle" title="Last activity">
              {relative_time(recency(session), @now)}
            </span>
          </div>
          <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 pl-4 text-xs text-muted">
            <span class={status_text_class(session)}>{status_text(session)}</span>
            <span :if={session["cwd"]} class="flex min-w-0 items-center gap-1" title={session["cwd"]}>
              <.icon name="folder" class="h-3 w-3" /><span class="max-w-[10rem] truncate">{basename(session["cwd"])}</span>
            </span>
            <span :if={session["model"]} class="max-w-[12rem] truncate font-mono text-2xs">{session["model"]}</span>
            <span :if={usage_text(session)} class="tabular-nums">{usage_text(session)}</span>
          </div>
          <p :if={session["activity"]} class="mt-1 truncate pl-4 text-xs text-fg/80">{session["activity"]}</p>
          <p :for={approval <- Enum.take(list(session["pendingApprovals"]), 3)} class="mt-1 pl-4 text-xs font-medium text-warning">
            Waiting for approval: {approval["tool"]}
          </p>
          <p :if={todo_progress(session)} class="mt-1 pl-4 text-2xs text-subtle">
            todos {todo_progress(session)}
          </p>
        </.link>
      </li>
    </ul>
    """
  end

  attr(:session, :map, required: true)
  attr(:now, :integer, required: true)
  attr(:pending, :any, required: true)
  attr(:compose, :map, required: true)

  def detail(assigns) do
    session = assigns.session

    assigns =
      assign(assigns,
        id: session["id"],
        ended?: ended?(session),
        busy?: busy?(session),
        usage: session["usage"] || %{},
        todos: list(session["todos"]),
        active_tools: list(session["activeTools"]),
        recent_tools: list(session["recentTools"]),
        subagents: list(session["subagents"]),
        output: output(session)
      )

    ~H"""
    <div id={"omp-detail-#{@id}"} class="flex min-h-0 flex-1 flex-col">
      <div class="shrink-0 border-b border-line px-4 py-3 sm:px-5">
        <div class="flex flex-wrap items-start gap-x-3 gap-y-2">
          <.button patch={~p"/omp"} size="sm" variant="ghost" icon="chevron-left" icon_only aria-label="All sessions" class="lg:hidden -ml-2" />
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="min-w-0 break-words text-[15px] font-semibold text-fg line-clamp-2" id="omp-detail-title">{label(@session)}</h2>
              <.badge tone={status_tone(@session)} id="omp-detail-status">
                <.status_dot tone={status_tone(@session)} pulse={@busy?} /> {@session["status"]}
              </.badge>
              <.badge :if={@session["lastTurn"] && !@busy?} tone={turn_tone(@session["lastTurn"])}>
                last turn {@session["lastTurn"]}
              </.badge>
              <.badge :if={get_in(@session, ["owner", "kind"]) == "agent"} tone="plan" icon="sparkles">agent</.badge>
            </div>
            <p class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
              <span class="font-mono">{@id}</span>
              <span :if={@session["ompSessionId"]} class="hidden font-mono sm:inline" title="omp session id">omp {@session["ompSessionId"]}</span>
              <span class="flex items-center gap-1 tabular-nums" title={if @busy?, do: "Running for", else: "Active time"}>
                <.icon name="clock" class="h-3 w-3" />{elapsed(@session, @now)}
              </span>
              <span class="tabular-nums">
                {count_text(@session["turns"], "turn")} · {count_text(@session["toolCalls"], "tool call")}
              </span>
            </p>
          </div>
          <div class="flex w-full flex-wrap items-center gap-1.5 pl-8 sm:w-auto sm:pl-0">
            <.button
              :if={@busy?}
              id="omp-cancel-turn"
              size="sm"
              variant="danger-soft"
              icon="square"
              phx-click="cancel_turn"
              phx-value-id={@id}
              loading={MapSet.member?(@pending, {:cancel, @id})}
              mutation
            >
              Cancel turn
            </.button>
            <.button
              :if={!@ended?}
              id="omp-close-session"
              size="sm"
              variant="ghost"
              icon="x-circle"
              phx-click="preview_close"
              phx-value-id={@id}
              loading={MapSet.member?(@pending, {:close, @id})}
              mutation
            >
              Close
            </.button>
            <.button
              :if={@ended? && @session["ompSessionId"] && @session["cwd"]}
              id="omp-resume-session"
              size="sm"
              icon="play"
              phx-click="open_resume"
              phx-value-id={@id}
              mutation
            >
              Resume
            </.button>
          </div>
        </div>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4 sm:px-5 scroll-thin" id="omp-detail-scroll">
        <div class="space-y-4">
          <section :if={list(@session["pendingApprovals"]) != []} class="card border-warning/40" id="omp-approvals" aria-labelledby="omp-approvals-title">
            <div class="card-header">
              <h3 id="omp-approvals-title" class="text-[13px] font-semibold text-warning">Waiting for approval</h3>
            </div>
            <ul class="divide-y divide-line">
              <li :for={approval <- Enum.take(list(@session["pendingApprovals"]), 20)} class="space-y-2 px-4 py-3">
                <p class="break-words font-mono text-xs text-fg">{approval["tool"]}</p>
                <pre :if={approval["details"]} class="max-h-40 overflow-auto whitespace-pre-wrap break-words text-xs text-muted">{approval_details(approval["details"])}</pre>
                <div class="flex flex-wrap gap-2">
                  <.button size="sm" phx-click="resolve_approval" phx-value-id={approval["id"]} phx-value-decision="approve" mutation disabled={@ended?} id={"omp-approve-#{approval["id"]}"}>Approve once</.button>
                  <.button size="sm" variant="danger-soft" phx-click="resolve_approval" phx-value-id={approval["id"]} phx-value-decision="deny" mutation disabled={@ended?} id={"omp-deny-#{approval["id"]}"}>Deny</.button>
                </div>
              </li>
            </ul>
          </section>
          <section :if={is_map(@session["worktree"])} class="card" id="omp-worktree" aria-labelledby="omp-worktree-title">
            <div class="card-header"><h3 id="omp-worktree-title" class="text-[13px] font-semibold text-fg">Isolated worktree</h3></div>
            <div class="card-body space-y-2">
              <p class="break-all font-mono text-xs text-fg">{@session["worktree"]["branch"]}</p>
              <p class="break-all font-mono text-xs text-muted">{@session["worktree"]["path"]}</p>
              <p class="break-all font-mono text-xs text-muted">Base: {@session["worktree"]["base"] || "unknown"}</p>
              <p class="text-xs text-muted">
                Kept: {inspect(@session["worktree"]["kept"])} ·
                Dirty: {inspect(@session["worktree"]["dirty"])} ·
                Commits: {@session["worktree"]["commits"] || "unknown"}
              </p>
              <p :if={@session["worktree"]["branch"]} class="break-all font-mono text-xs">git merge {@session["worktree"]["branch"]}</p>
              <div class="flex flex-wrap gap-2">
                <.badge :if={@session["worktree"]["kept"] == true} tone="warning">Kept</.badge>
                <.badge :if={@session["worktree"]["dirty"] == true} tone="warning">Uncommitted changes</.badge>
              </div>
              <p class="text-xs text-muted">Clean worktrees are removed when the worker closes. Worktrees with changes are kept for review.</p>
            </div>
          </section>
          <.callout :if={@session["error"]} tone="danger" title="omp reported an error" id="omp-detail-error">
            <span class="whitespace-pre-wrap break-words">{@session["error"]}</span>
          </.callout>
          <.callout :if={(@session["declinedPrompts"] || 0) > 0} tone="warning" title="Interactive prompts declined" id="omp-declined">
            omp asked {@session["declinedPrompts"]} interactive question(s). Lemon runs omp headless, so confirmations were answered “no” and other prompts cancelled.
            If omp asks before writing, pick an omp approval mode suited to unattended work.
          </.callout>

          <section aria-labelledby="omp-activity-title" class="card">
            <div class="card-header">
              <h3 id="omp-activity-title" class="text-[13px] font-semibold text-fg">Activity</h3>
            </div>
            <div class="card-body space-y-3">
              <div aria-live="polite" class="flex items-center gap-2 text-[13px]">
                <.spinner :if={@busy?} class="h-3.5 w-3.5" label="Working" />
                <span :if={@session["activity"]} class="text-fg" id="omp-activity">{@session["activity"]}</span>
                <span :if={!@session["activity"]} class="text-muted">{idle_activity(@session)}</span>
              </div>
              <ul :if={@active_tools != []} class="space-y-1.5" aria-label="Running tools">
                <li :for={tool <- @active_tools} class="flex items-start gap-2 rounded-md bg-accent/[0.06] px-2.5 py-1.5 text-xs">
                  <.icon name="loader" class="mt-0.5 h-3.5 w-3.5 animate-spin text-accent-text" />
                  <span class="font-mono font-medium text-fg">{tool["name"]}</span>
                  <span :if={tool["intent"]} class="min-w-0 flex-1 truncate text-muted">{tool["intent"]}</span>
                  <span :if={is_integer(tool["startedAt"])} class="ml-auto shrink-0 tabular-nums text-subtle">
                    {short_elapsed(@now - tool["startedAt"])}
                  </span>
                </li>
              </ul>
              <div :if={@recent_tools != []}>
                <p class="mb-1.5 text-2xs font-semibold uppercase tracking-wider text-subtle">Recent tools</p>
                <ul class="space-y-1" aria-label="Recent tools">
                  <li :for={tool <- Enum.reverse(@recent_tools)} class="flex items-start gap-2 text-xs">
                    <.icon
                      name={if tool["isError"], do: "x-circle", else: "check-circle"}
                      class={["mt-0.5 h-3.5 w-3.5", if(tool["isError"], do: "text-danger", else: "text-success")]}
                    />
                    <span class="font-mono text-fg">{tool["name"]}</span>
                    <span :if={tool["intent"]} class="min-w-0 flex-1 truncate text-muted">{tool["intent"]}</span>
                    <span :if={is_integer(tool["durationMs"])} class="ml-auto shrink-0 tabular-nums text-subtle">
                      {duration(tool["durationMs"])}
                    </span>
                  </li>
                </ul>
              </div>
            </div>
          </section>

          <div class="grid gap-4 xl:grid-cols-2">
            <section :if={@todos != []} aria-labelledby="omp-todos-title" class="card" id="omp-todos">
              <div class="card-header">
                <h3 id="omp-todos-title" class="text-[13px] font-semibold text-fg">Todos</h3>
                <span class="text-xs tabular-nums text-muted">{todo_progress(@session)}</span>
              </div>
              <div class="card-body space-y-3">
                <.meter value={todo_closed(@todos)} max={length(@todos)} label="Todo progress" tone="success" />
                <div :for={{phase, todos} <- todo_phases(@todos)}>
                  <p :if={phase} class="mb-1 text-2xs font-semibold uppercase tracking-wider text-subtle">{phase}</p>
                  <ul class="space-y-1">
                    <li :for={todo <- todos} class="flex items-start gap-2 text-[13px]">
                      <.icon name={todo_icon(todo["status"])} class={["mt-0.5 h-3.5 w-3.5", todo_icon_class(todo["status"])]} />
                      <span class={[
                        "min-w-0 break-words",
                        todo["status"] in ~w(completed done abandoned) && "text-muted line-through decoration-line-strong",
                        todo["status"] == "in_progress" && "font-medium text-fg"
                      ]}>
                        {todo["content"]}
                      </span>
                      <span class="sr-only">({todo["status"]})</span>
                    </li>
                  </ul>
                </div>
              </div>
            </section>

            <section aria-labelledby="omp-usage-title" class="card" id="omp-usage">
              <div class="card-header">
                <h3 id="omp-usage-title" class="text-[13px] font-semibold text-fg">Usage</h3>
                <span class="text-xs text-subtle">omp's own totals</span>
              </div>
              <div class="card-body space-y-3">
                <div class="grid grid-cols-3 gap-3">
                  <div>
                    <p class="text-2xs text-muted">Tokens</p>
                    <p class="text-[15px] font-semibold tabular-nums text-fg">{compact_number(@usage["totalTokens"] || 0)}</p>
                  </div>
                  <div>
                    <p class="text-2xs text-muted">Cost</p>
                    <p class="text-[15px] font-semibold tabular-nums text-fg">{cost(@usage["cost"])}</p>
                  </div>
                  <div>
                    <p class="text-2xs text-muted">Context</p>
                    <p class="text-[15px] font-semibold tabular-nums text-fg">{percent_text(@session["contextPercent"])}</p>
                  </div>
                </div>
                <.meter
                  :if={is_number(@session["contextPercent"])}
                  value={@session["contextPercent"]}
                  max={100}
                  label="Context window used"
                  auto_tone
                />
                <dl class="grid grid-cols-2 gap-x-4 gap-y-1 text-xs sm:grid-cols-4">
                  <div><dt class="text-muted">Input</dt><dd class="tabular-nums text-fg">{compact_number(@usage["input"] || 0)}</dd></div>
                  <div><dt class="text-muted">Output</dt><dd class="tabular-nums text-fg">{compact_number(@usage["output"] || 0)}</dd></div>
                  <div><dt class="text-muted">Cache read</dt><dd class="tabular-nums text-fg">{compact_number(@usage["cacheRead"] || 0)}</dd></div>
                  <div><dt class="text-muted">Cache write</dt><dd class="tabular-nums text-fg">{compact_number(@usage["cacheWrite"] || 0)}</dd></div>
                </dl>
              </div>
            </section>

            <section :if={@subagents != []} aria-labelledby="omp-subagents-title" class="card" id="omp-subagents">
              <div class="card-header">
                <h3 id="omp-subagents-title" class="text-[13px] font-semibold text-fg">Subagents</h3>
                <span class="text-xs tabular-nums text-muted">{length(@subagents)}</span>
              </div>
              <ul class="divide-y divide-line">
                <li :for={sub <- @subagents} class="flex items-start gap-2 px-4 py-2 text-[13px]">
                  <.status_dot tone={subagent_tone(sub["status"])} pulse={sub["status"] == "running"} class="mt-1.5" />
                  <div class="min-w-0 flex-1">
                    <p class="truncate">
                      <span class="font-medium text-fg">{sub["agent"] || "subagent"}</span>
                      <span :if={sub["id"]} class="ml-1 font-mono text-2xs text-subtle">{sub["id"]}</span>
                    </p>
                    <p :if={sub["description"]} class="truncate text-xs text-muted">{sub["description"]}</p>
                  </div>
                  <span class="shrink-0 text-xs text-muted">{sub["status"]}</span>
                </li>
              </ul>
            </section>

            <section aria-labelledby="omp-info-title" class="card" id="omp-info">
              <div class="card-header">
                <h3 id="omp-info-title" class="text-[13px] font-semibold text-fg">Session</h3>
              </div>
              <div class="card-body">
                <.key_value>
                  <:item :if={@session["cwd"]} label="Workspace">
                    <span class="break-all font-mono text-xs">{@session["cwd"]}</span>
                  </:item>
                  <:item label="Model">
                    <span class="font-mono text-xs">{@session["model"] || "omp default"}</span>
                    <span :if={@session["thinking"]} class="ml-1 text-xs text-muted">· thinking {@session["thinking"]}</span>
                  </:item>
                  <:item label="Approval mode">{@session["approvalMode"] || "omp default"}</:item>
                  <:item label="Approvals">
                    Approved {get_in(@session, ["approvals", "approved"]) || 0} ·
                    Denied {get_in(@session, ["approvals", "denied"]) || 0} ·
                    Expired {get_in(@session, ["approvals", "expired"]) || 0}
                  </:item>
                  <:item label="Started">{relative_time(@session["startedAt"], @now)}</:item>
                  <:item :if={@session["endedAt"]} label="Ended">{relative_time(@session["endedAt"], @now)}</:item>
                  <:item label="Owner">
                    <%= if get_in(@session, ["owner", "kind"]) == "agent" do %>
                      Lemon agent session
                      <span :if={is_binary(get_in(@session, ["owner", "sessionKey"]))} class="ml-1 font-mono text-xs text-muted">
                        {get_in(@session, ["owner", "sessionKey"])}
                      </span>
                    <% else %>
                      Operator
                    <% end %>
                  </:item>
                  <:item :if={@session["exit"]} label="Exit">
                    <span id="omp-exit">{exit_text(@session["exit"])}</span>
                  </:item>
                </.key_value>
              </div>
            </section>
          </div>

          <section aria-labelledby="omp-output-title" class="card" id="omp-output">
            <div class="card-header">
              <h3 id="omp-output-title" class="text-[13px] font-semibold text-fg">{elem(@output, 0)}</h3>
              <span class="text-xs text-subtle">untrusted omp output</span>
            </div>
            <div class="card-body">
              <pre :if={elem(@output, 1)} class="max-h-[32rem] overflow-y-auto whitespace-pre-wrap break-words text-[13px] text-fg scroll-thin" id="omp-output-body">{elem(@output, 1)}</pre>
              <p :if={!elem(@output, 1)} class="text-[13px] text-muted">No output yet.</p>
            </div>
          </section>
        </div>
      </div>

      <div class="shrink-0 border-t border-line bg-surface/60 px-4 py-3 sm:px-5">
        <%= if @ended? do %>
          <p class="flex flex-wrap items-center gap-2 text-[13px] text-muted" id="omp-ended-note">
            <.icon name="info" class="h-4 w-4" />
            This omp process has ended.
            <span :if={@session["ompSessionId"]}>Resume it to continue — resuming starts a new invocation.</span>
          </p>
        <% else %>
          <form id="omp-composer" phx-submit="send" phx-change="compose_change" class="space-y-2">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="segmented" role="radiogroup" aria-label="Delivery">
                <label
                  :for={{mode, text, key} <- [{"steer", "Steer", "s"}, {"followUp", "Follow-up", "f"}, {"redirect", "Redirect", "r"}]}
                  class={[
                    "inline-flex h-7 cursor-pointer items-center gap-1.5 rounded px-2.5 text-xs font-medium transition-colors has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring/50",
                    if(@compose.mode == mode, do: "bg-surface text-fg shadow-sm", else: "text-muted hover:text-fg")
                  ]}
                >
                  <input type="radio" name="compose[mode]" value={mode} checked={@compose.mode == mode} class="sr-only" />
                  {text} <.kbd keys={key} class="hidden sm:inline-flex" />
                </label>
              </div>
              <p class="hidden items-center gap-1.5 text-2xs text-subtle sm:flex">
                {compose_hint(@busy?, @compose.mode)} <.kbd keys="mod+enter" /> sends
              </p>
            </div>
            <div class="flex items-end gap-2">
              <label for="omp-composer-input" class="sr-only">Message to omp</label>
              <textarea
                id="omp-composer-input"
                name="compose[text]"
                rows="2"
                maxlength="16384"
                placeholder={case @compose.mode do "steer" -> "Steer omp…"; "redirect" -> "Stop and redirect omp…"; _ -> "Queue a follow-up…" end}
                phx-debounce="200"
                class="input min-h-[2.75rem] flex-1 resize-y"
              >{@compose.text}</textarea>
              <.button
                type="submit"
                variant="primary"
                icon="send"
                id="omp-send"
                loading={MapSet.member?(@pending, {:send, @id})}
                mutation
              >
                Send
              </.button>
            </div>
            <p :if={@compose.unconfirmed} class="flex items-start gap-1.5 text-xs text-warning" role="alert" id="omp-unconfirmed">
              <.icon name="alert-triangle" class="mt-0.5 h-3.5 w-3.5" />
              omp did not confirm the last message — it may already have it. Check the activity above before sending again.
            </p>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:form, :map, required: true)
  attr(:sessions, :map, required: true)
  attr(:starting?, :boolean, required: true)

  def start_dialog(assigns) do
    assigns =
      assign(assigns,
        workspaces: recent_workspaces(assigns.sessions),
        thinking_options: [{"omp default", ""} | Enum.map(@thinking_levels, &{&1, &1})]
      )

    ~H"""
    <.modal id="omp-start-dialog" show size="lg" title="New omp session" description="omp runs as its own process with its own model and credentials." on_cancel={JS.push("cancel_start")}>
      <form id="omp-start-form" phx-submit="start" phx-change="start_change" class="space-y-4">
        <.input
          id="omp-start-prompt"
          phx-mounted={JS.focus()}
          name="start[prompt]"
          type="textarea"
          label="Prompt"
          value={@form["prompt"]}
          rows="5"
          placeholder="Add input validation to lib/parser.ex and its tests."
          errors={List.wrap(@form["errors"]["prompt"])}
          required
        />
        <div>
          <label for="omp-start-cwd" class="field-label">Workspace</label>
          <input
            id="omp-start-cwd"
            name="start[cwd]"
            type="text"
            value={@form["cwd"]}
            placeholder="/path/to/project"
            list="omp-workspaces"
            autocomplete="off"
            spellcheck="false"
            required
            aria-invalid={@form["errors"]["cwd"] && "true"}
            aria-describedby="omp-start-cwd-hint"
            class="input font-mono"
          />
          <datalist id="omp-workspaces">
            <option :for={cwd <- @workspaces} value={cwd}></option>
          </datalist>
          <p :if={!@form["errors"]["cwd"]} id="omp-start-cwd-hint" class="field-hint">
            An existing directory on the machine running Lemon.
          </p>
          <p :if={@form["errors"]["cwd"]} id="omp-start-cwd-hint" class="field-error">{@form["errors"]["cwd"]}</p>
        </div>
        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            id="omp-start-model"
            name="start[model]"
            label="Model (optional)"
            value={@form["model"]}
            placeholder="provider/model"
            errors={List.wrap(@form["errors"]["model"])}
            autocomplete="off"
            spellcheck="false"
            input_class="font-mono"
          />
          <.input
            id="omp-start-thinking"
            name="start[thinking]"
            type="select"
            label="Thinking (optional)"
            value={@form["thinking"]}
            options={@thinking_options}
            errors={List.wrap(@form["errors"]["thinking"])}
          />
        </div>
        <.input
          id="omp-start-approval-mode"
          name="start[approvalMode]"
          type="select"
          label="Tool approval mode"
          value={@form["approvalMode"] || ""}
          options={[{"omp default", ""}, {"Always ask", "always-ask"}, {"Ask before execution (write)", "write"}, {"Allow without asking (yolo)", "yolo"}]}
          errors={List.wrap(@form["errors"]["approvalMode"])}
        />
        <label class="flex items-start gap-2 text-[13px] text-fg" for="omp-start-isolate">
          <input type="hidden" name="start[isolate]" value="false" />
          <input id="omp-start-isolate" type="checkbox" name="start[isolate]" value="true" checked={@form["isolate"] in [true, "true"]} class="mt-1" />
          <span>Use an isolated git worktree <span class="block text-xs text-muted">Requires a git repository. Clean worktrees are removed on close; changed worktrees are kept.</span></span>
        </label>
        <.callout :if={@form["error"]} tone="danger" id="omp-start-error">{@form["error"]}</.callout>
        <div class="flex items-center justify-end gap-2">
          <.button phx-click="cancel_start" disabled={@starting?}>Cancel</.button>
          <.button type="submit" variant="primary" icon="play" loading={@starting?} mutation id="omp-start-submit">
            {if @starting?, do: "Starting…", else: "Start"}
          </.button>
        </div>
      </form>
    </.modal>
    """
  end

  attr(:resume, :map, required: true)
  attr(:pending, :any, required: true)
  attr(:now, :integer, required: true)

  def resume_dialog(assigns) do
    assigns =
      assign(assigns,
        scanning?: MapSet.member?(assigns.pending, :discover),
        resuming?: MapSet.member?(assigns.pending, :resume)
      )

    ~H"""
    <.modal id="omp-resume-dialog" show size="lg" title="Resume an omp session" description="Lists omp's stored sessions for a workspace. Reading them never modifies them." on_cancel={JS.push("cancel_resume")}>
      <%= if @resume.target do %>
        <form id="omp-resume-form" phx-submit="resume" phx-change="resume_change" class="space-y-4">
          <div class="rounded-lg border border-line bg-surface-2/50 px-3 py-2.5">
            <p class="text-[13px] font-medium text-fg">{@resume.target.title}</p>
            <p class="mt-0.5 font-mono text-xs text-muted">omp {@resume.target.omp_session_id}</p>
            <p class="mt-0.5 break-all font-mono text-xs text-subtle">{@resume.cwd}</p>
          </div>
          <.callout :if={@resume.target.active_elsewhere} tone="warning" title="Possibly open elsewhere">
            This session was written to in the last two minutes without a clean exit — another omp may still have it open.
          </.callout>
          <.input
            id="omp-resume-message"
            name="resume[message]"
            type="textarea"
            label="Message (optional)"
            value={@resume.message}
            rows="3"
            placeholder="Continue with the tests"
            hint="Leave empty to reopen the session idle."
          />
          <.input
            id="omp-resume-approval-mode"
            name="resume[approvalMode]"
            type="select"
            label="Tool approval mode"
            value={Map.get(@resume, :approval_mode, "")}
            options={[{"omp default", ""}, {"Always ask", "always-ask"}, {"Ask before execution (write)", "write"}, {"Allow without asking (yolo)", "yolo"}]}
          />
          <label :if={Map.get(@resume.target, :interrupted, false) && String.trim(@resume.message || "") == ""} class="flex items-start gap-2 text-[13px] text-fg" for="omp-resume-continue">
            <input type="hidden" name="resume[continue]" value="false" />
            <input id="omp-resume-continue" type="checkbox" name="resume[continue]" value="true" checked={Map.get(@resume, :continue, false) in [true, "true"]} class="mt-1" />
            <span>Continue the interrupted turn without a new message</span>
          </label>
          <.callout :if={@resume.error} tone="danger" id="omp-resume-error">{@resume.error}</.callout>
          <div class="flex items-center justify-between gap-2">
            <.button :if={!@resume.direct?} phx-click="unpick_resume" variant="ghost" icon="chevron-left" disabled={@resuming?}>Back</.button>
            <span :if={@resume.direct?}></span>
            <div class="flex gap-2">
              <.button phx-click="cancel_resume" disabled={@resuming?}>Cancel</.button>
              <.button type="submit" variant="primary" icon="play" loading={@resuming?} mutation id="omp-resume-submit">
                {if @resuming?, do: "Resuming…", else: "Resume"}
              </.button>
            </div>
          </div>
        </form>
      <% else %>
        <form id="omp-discover-form" phx-submit="discover" class="flex items-end gap-2">
          <.input
            id="omp-discover-cwd"
            name="discover[cwd]"
            label="Workspace"
            value={@resume.cwd}
            placeholder="/path/to/project"
            class="flex-1"
            input_class="font-mono"
            autocomplete="off"
            spellcheck="false"
            required
          />
          <.button type="submit" icon="search" loading={@scanning?} id="omp-discover-submit">Scan</.button>
        </form>
        <div class="mt-4" id="omp-discover-results">
          <p :if={@resume.scan == :idle} class="text-[13px] text-muted">Enter the workspace omp ran in, then scan.</p>
          <div :if={@resume.scan == :loading} class="flex items-center gap-2 text-[13px] text-muted">
            <.spinner /> Scanning omp session files…
          </div>
          <.callout :if={match?({:error, _}, @resume.scan)} tone="danger" title="Discovery failed">
            {elem(@resume.scan, 1)}
          </.callout>
          <%= case @resume.scan do %>
            <% {:ok, []} -> %>
              <.empty_state icon="history" title="No stored omp sessions" description="omp has no recorded sessions for this directory." />
            <% {:ok, rows} -> %>
              <ul class="max-h-[50vh] divide-y divide-line overflow-y-auto rounded-lg border border-line scroll-thin" role="list">
                <li :for={row <- rows} class="flex items-center gap-3 px-3 py-2.5" id={"omp-discovered-#{row["ompSessionId"]}"}>
                  <div class="min-w-0 flex-1">
                    <p class="truncate text-[13px] font-medium text-fg">{row["title"] || "(untitled)"}</p>
                    <p class="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-muted">
                      <span>{row["lastStatus"]}</span>
                      <span :if={row["source"]}>{row["source"]}</span>
                      <span :if={row["interrupted"] == true} class="text-warning">Interrupted</span>
                      <span :if={get_in(row, ["worktree", "branch"])} class="font-mono text-2xs">{row["worktree"]["branch"]}</span>
                      <span>{relative_time(row["updatedAt"] || row["createdAt"], @now)}</span>
                      <span :if={row["model"]} class="font-mono text-2xs">{row["model"]}</span>
                      <span class="font-mono text-2xs text-subtle">{String.slice(row["ompSessionId"], 0, 13)}</span>
                    </p>
                  </div>
                  <.badge :if={row["activeElsewhere"]} tone="warning">open elsewhere</.badge>
                  <%= if is_binary(row["liveId"]) do %>
                    <.button size="sm" patch={session_path(row["liveId"])} phx-click="cancel_resume">Open live</.button>
                  <% else %>
                    <.button size="sm" phx-click="pick_resume" phx-value-omp={row["ompSessionId"]} mutation>Resume</.button>
                  <% end %>
                </li>
              </ul>
            <% _ -> %>
          <% end %>
        </div>
      <% end %>
    </.modal>
    """
  end

  # ── Formatting ──────────────────────────────────────────────────────────

  defp live_full?(%{"live" => live, "maxSessions" => max})
       when is_integer(live) and is_integer(max),
       do: live >= max

  defp live_full?(_status), do: false

  def counts(sessions) do
    values = Map.values(sessions)
    ended = Enum.count(values, &ended?/1)

    %{
      total: length(values),
      live: length(values) - ended,
      ended: ended,
      busy: Enum.count(values, &busy?/1)
    }
  end

  def session_path(id), do: "/omp/" <> URI.encode(id, &URI.char_unreserved?/1)

  def valid_session?(%{"id" => id}) when is_binary(id) and id != "", do: true
  def valid_session?(_session), do: false

  def ended?(%{"status" => status}), do: status in ["closed", "failed"]
  def ended?(_session), do: false

  def busy?(%{"status" => status}), do: status in ["starting", "running"]
  def busy?(_session), do: false

  def recency(session) do
    Enum.find([session["updatedAt"], session["endedAt"], session["startedAt"]], 0, &is_integer/1)
  end

  def label(session) do
    case session["title"] do
      title when is_binary(title) and title != "" -> title
      _ -> session["id"]
    end
  end

  def status_text(session) do
    case session do
      %{"lastTurn" => turn} when is_binary(turn) ->
        if busy?(session), do: session["status"], else: "#{session["status"]} · #{turn}"

      _ ->
        session["status"] || "unknown"
    end
  end

  defp status_tone(%{"status" => "failed"}), do: "danger"
  defp status_tone(%{"status" => status}) when status in ["starting", "running"], do: "accent"
  defp status_tone(%{"status" => "closed"}), do: "neutral"
  defp status_tone(%{"lastTurn" => "error"}), do: "danger"
  defp status_tone(%{"lastTurn" => "aborted"}), do: "warning"
  defp status_tone(%{"status" => "idle"}), do: "success"
  defp status_tone(_session), do: "neutral"

  defp status_text_class(session) do
    case status_tone(session) do
      "danger" -> "text-danger"
      "warning" -> "text-warning"
      "accent" -> "text-accent-text"
      _ -> nil
    end
  end

  defp turn_tone("completed"), do: "success"
  defp turn_tone("error"), do: "danger"
  defp turn_tone("aborted"), do: "warning"
  defp turn_tone(_turn), do: "neutral"

  defp subagent_tone(status) when status in ["running", "started"], do: "accent"
  defp subagent_tone(status) when status in ["completed", "done", "success"], do: "success"
  defp subagent_tone(status) when status in ["failed", "error"], do: "danger"
  defp subagent_tone(_status), do: "neutral"

  defp idle_activity(session) do
    cond do
      session["status"] == "starting" -> "Starting omp…"
      ended?(session) -> "Process ended."
      true -> "Idle — open for follow-ups."
    end
  end

  defp approval_details(value) when is_binary(value), do: String.slice(value, 0, 4096)
  defp approval_details(value), do: inspect(value, limit: 30, printable_limit: 4096)

  defp compose_hint(true, "redirect"),
    do: "Redirect stops the running turn and starts over with this message."

  defp compose_hint(true, "steer"), do: "Steer redirects the running turn."
  defp compose_hint(true, _mode), do: "Follow-up is queued for after the running turn."
  defp compose_hint(false, _mode), do: "The session is idle: a message starts a new turn."

  # Live turns count up; otherwise the time between start and the last
  # activity (or exit), so an idle session does not appear to keep running.
  defp elapsed(%{"startedAt" => started} = session, now) when is_integer(started) do
    finish =
      if busy?(session),
        do: now,
        else: Enum.find([session["endedAt"], session["updatedAt"]], now, &is_integer/1)

    short_elapsed(max(finish - started, 0))
  end

  defp elapsed(_session, _now), do: "—"

  defp short_elapsed(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m#{pad(rem(seconds, 60))}s"
      true -> "#{div(seconds, 3600)}h#{pad(div(rem(seconds, 3600), 60))}m"
    end
  end

  defp short_elapsed(_ms), do: "0s"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp usage_text(session) do
    usage = session["usage"] || %{}
    tokens = usage["totalTokens"]
    cost = usage["cost"]

    parts =
      [
        (is_integer(tokens) and tokens > 0) && "#{compact_number(tokens)} tok",
        (is_number(cost) and cost > 0) && cost(cost)
      ]
      |> Enum.filter(&is_binary/1)

    if parts == [], do: nil, else: Enum.join(parts, " · ")
  end

  defp cost(value) when is_number(value) and value > 0 and value < 0.01,
    do: "$" <> :erlang.float_to_binary(value / 1, decimals: 4)

  defp cost(value) when is_number(value),
    do: "$" <> :erlang.float_to_binary(value / 1, decimals: 2)

  defp cost(_value), do: "—"

  defp percent_text(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: if(value < 10, do: 1, else: 0)) <> "%"

  defp percent_text(_value), do: "—"

  defp todo_closed(todos), do: Enum.count(todos, &(&1["status"] in @closed_todo))

  defp todo_progress(session) do
    case list(session["todos"]) do
      [] -> nil
      todos -> "#{todo_closed(todos)}/#{length(todos)}"
    end
  end

  defp todo_phases(todos) do
    todos
    |> Enum.chunk_by(& &1["phase"])
    |> Enum.map(fn [first | _] = chunk ->
      {if(first["phase"] in [nil, ""], do: nil, else: first["phase"]), chunk}
    end)
  end

  defp todo_icon(status) when status in ["completed", "done"], do: "check-circle"
  defp todo_icon("in_progress"), do: "circle-dot"
  defp todo_icon("abandoned"), do: "x-circle"
  defp todo_icon("blocked"), do: "alert-triangle"
  defp todo_icon(_status), do: "circle"

  defp todo_icon_class(status) when status in ["completed", "done"], do: "text-success"
  defp todo_icon_class("in_progress"), do: "text-accent-text"
  defp todo_icon_class("blocked"), do: "text-warning"
  defp todo_icon_class(_status), do: "text-subtle"

  # Running sessions show the streaming text; settled ones their result.
  defp output(%{"status" => "running", "lastText" => text}) when is_binary(text) and text != "",
    do: {"Latest output", text}

  defp output(%{"result" => text}) when is_binary(text) and text != "", do: {"Result", text}

  defp output(%{"lastText" => text}) when is_binary(text) and text != "",
    do: {"Latest output", text}

  defp output(_session), do: {"Output", nil}

  defp count_text(1, noun), do: "1 #{noun}"
  defp count_text(n, noun) when is_integer(n), do: "#{n} #{noun}s"
  defp count_text(_n, noun), do: "0 #{noun}s"

  defp exit_text(%{"code" => code, "reason" => reason})
       when is_integer(code) and is_binary(reason),
       do: "exit code #{code} · #{exit_text(%{"reason" => reason})}"

  defp exit_text(%{"code" => code}) when is_integer(code), do: "exit code #{code}"
  defp exit_text(%{"reason" => "closed"}), do: "closed on request"
  defp exit_text(%{"reason" => "idle_timeout"}), do: "closed after the idle timeout"
  defp exit_text(%{"reason" => "startup_timeout"}), do: "omp did not become ready in time"
  defp exit_text(%{"reason" => reason}) when is_binary(reason), do: "ended unexpectedly"
  defp exit_text(_exit), do: "ended"

  def detail_error_text(:not_found),
    do: "No omp session with that id. Ended sessions are kept until the runtime restarts."

  def detail_error_text({:error, message}), do: message
  def detail_error_text(_state), do: nil

  defp recent_workspaces(sessions) do
    sessions
    |> Map.values()
    |> Enum.sort_by(&(-recency(&1)))
    |> Enum.map(& &1["cwd"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp basename(path) when is_binary(path) do
    case Path.basename(path) do
      "" -> path
      name -> name
    end
  end

  defp list(value) when is_list(value), do: Enum.filter(value, &is_map/1)
  defp list(_value), do: []

  @doc false
  def now_ms, do: System.system_time(:millisecond)
end
