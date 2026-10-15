defmodule LemonWeb.Chat.Inspector do
  @moduledoc """
  Chat inspector panel tabs (Context, Plan, Changes, Subagents, Details).

  ## Adding a tab

  Append `{id, label, icon}` to `tabs/0` and add a `tab/1` clause matching
  that id. The pane passes its whole assigns map, so a tab can read the
  session key (`@session_key`) and workspace (`@cwd`).
  """

  use Phoenix.Component

  import LemonWeb.UI

  @tabs [
    {"context", "Context", "gauge"},
    {"plan", "Plan", "list-checks"},
    {"changes", "Changes", "file-diff"},
    {"subagents", "Subagents", "network"},
    {"details", "Details", "info"}
  ]

  @doc "Ordered `{id, label, icon}` tab list."
  def tabs, do: @tabs

  def tab_ids, do: Enum.map(@tabs, &elem(&1, 0))

  # ── Changes ─────────────────────────────────────────────────────────────

  def tab(%{tab: "changes"} = assigns) do
    ~H"""
    <.live_component
      module={LemonWeb.WorkspaceChangesComponent}
      id={"changes-" <> @dom_key}
      session_key={@session_key}
      cwd={@cwd}
    />
    """
  end

  # ── Context ─────────────────────────────────────────────────────────────

  def tab(%{tab: "context"} = assigns) do
    ~H"""
    <div id={"context-panel-#{@dom_key}"} class="space-y-4">
      <div :if={@context.status == :loading && !@context.data} class="flex items-center gap-2 text-xs text-muted">
        <.spinner class="h-3.5 w-3.5" /> Measuring context…
      </div>
      <.callout :if={@context.status == :unavailable} id={"context-unavailable-#{@dom_key}"} tone="warning" title="Context usage unavailable">
        {@context.error || "Lemon could not measure this session's context window."}
        <:actions>
          <.button size="sm" variant="ghost" icon="refresh" phx-click="refresh-context">Retry</.button>
        </:actions>
      </.callout>
      <%= if data = @context.data do %>
        <div>
          <div class="flex items-baseline justify-between gap-2">
            <p class="text-2xl font-semibold tabular-nums tracking-tight text-fg">
              {format_percent(data["percentUsed"])}
            </p>
            <p class="text-xs tabular-nums text-muted">
              {compact_number(data["usedTokens"])} / {compact_number(data["window"])} tokens
            </p>
          </div>
          <.meter
            value={data["usedTokens"] || 0}
            max={data["window"] || 0}
            auto_tone
            label="Context window used"
            class="mt-2 h-2"
          />
          <div class="mt-2 flex flex-wrap items-center gap-1.5 text-2xs text-subtle">
            <.badge tone={if data["live"], do: "success", else: "neutral"}>
              {if data["live"], do: "live session", else: "stored session"}
            </.badge>
            <.badge tone="neutral">{source_label(data["source"])}</.badge>
            <span :if={is_map(data["model"])} class="font-mono">{data["model"]["id"]}</span>
          </div>
        </div>

        <div :if={threshold(data)} class="rounded-md border border-line bg-surface-2/50 px-3 py-2 text-xs text-muted">
          <.icon name="layers" class="mr-1 inline h-3.5 w-3.5" />
          Auto-compaction at {compact_number(threshold(data))} tokens
          <span :if={headroom(data)}>· {compact_number(headroom(data))} to go</span>
        </div>
        <p :if={data["autoCompaction"] && data["autoCompaction"]["enabled"] == false} class="text-xs text-warning">
          Auto-compaction is disabled for this session.
        </p>

        <section aria-label="Usage by category">
          <h3 class="mb-2 text-2xs font-semibold uppercase tracking-wide text-subtle">Breakdown</h3>
          <ul class="space-y-2">
            <li :for={cat <- categories(data)} class="text-xs" data-category={cat["id"]}>
              <div class="mb-0.5 flex items-center justify-between gap-2">
                <span class="truncate text-fg">{cat["label"]}</span>
                <span class="shrink-0 tabular-nums text-muted">
                  {compact_number(cat["tokens"])}
                  <span :if={cat["percent"]} class="text-subtle">· {format_percent(cat["percent"])}</span>
                </span>
              </div>
              <.meter value={cat["tokens"]} max={data["usedTokens"]} tone="info" label={cat["label"]} />
            </li>
          </ul>
        </section>

        <section :if={(data["top"] || []) != []} aria-label="Largest items">
          <h3 class="mb-2 text-2xs font-semibold uppercase tracking-wide text-subtle">Largest items</h3>
          <ul class="divide-y divide-line rounded-md border border-line">
            <li :for={item <- data["top"]} class="flex items-center justify-between gap-2 px-2.5 py-1.5 text-xs">
              <span class="min-w-0 truncate text-fg" title={item["label"]}>{item["label"]}</span>
              <span class="shrink-0 tabular-nums text-muted">{compact_number(item["tokens"])}</span>
            </li>
          </ul>
        </section>

        <p class="text-2xs text-subtle">
          {data["messageCount"]} messages
          <span :if={data["measuredAt"] not in [nil, 0]}>· measured {relative_time(data["measuredAt"])}</span>
        </p>
      <% end %>

      <div class="flex flex-wrap gap-2 border-t border-line pt-3">
        <.button size="sm" icon="refresh" phx-click="refresh-context" loading={@context.status == :loading}>
          Refresh
        </.button>
        <.button
          size="sm"
          icon="layers"
          mutation
          phx-click="compact"
          loading={@compacting}
          disabled={@run.status in [:running, :stopping]}
        >
          Compact now
        </.button>
      </div>
      <p :if={@run.status in [:running, :stopping]} class="text-2xs text-subtle">Compaction is available when the run finishes.</p>
    </div>
    """
  end

  # ── Plan ────────────────────────────────────────────────────────────────

  def tab(%{tab: "plan"} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center gap-2">
        <.badge :if={@plan.mode == "plan"} tone="plan" icon="list-checks">Plan mode on</.badge>
        <.badge :if={@plan.mode == "code"} tone="neutral">Plan mode off</.badge>
        <.badge :if={@plan.mode == nil} tone="warning">Unknown</.badge>
        <span :if={@plan.path} class="min-w-0 truncate font-mono text-2xs text-subtle" title="Plan file">
          {Path.basename(@plan.path)}
        </span>
      </div>
      <p :if={@plan.error} class="text-xs text-warning">{@plan.error}</p>
      <div :if={@plan.content} id={"plan-content-#{@dom_key}"} class="md rounded-md border border-line bg-bg/40 p-3 text-[13px]" phx-hook="ChatMarkdown">
        {LemonWeb.Markdown.to_html(@plan.content)}
      </div>
      <p :if={!@plan.content} class="text-xs text-muted">
        {if @plan.mode == "plan",
          do: "The agent has not written a plan yet. It drafts one read-only, then asks you to approve it.",
          else: "Turn on plan mode to have the agent research read-only and propose a plan for approval."}
      </p>
      <section :if={is_map(@todos)} id={"todo-recovery-#{@dom_key}"} aria-label="Current branch todos" class="space-y-2">
        <h3 class="text-2xs font-semibold uppercase tracking-wide text-subtle">Current branch todos</h3>
        <p :if={@todos["status"] != "ok"} class="text-xs text-warning">Todo status is unavailable.</p>
        <p :if={@todos["truncated"] == true} class="text-xs text-warning">Todo snapshot truncated; some owned state is omitted.</p>
        <ul :if={@todos["status"] == "ok"} class="space-y-1 text-xs">
          <li :for={todo <- @todos["items"] || []} data-todo-id={todo["id"]}>
            <span class="font-mono text-subtle">{todo["status"]}</span>
            {todo["content"] || todo["title"]}
          </li>
        </ul>
      </section>
      <div class="flex gap-2">
        <.button size="sm" icon={if @plan.mode == "plan", do: "x", else: "list-checks"} mutation phx-click="toggle-plan">
          {if @plan.mode == "plan", do: "Exit plan mode", else: "Enter plan mode"}
        </.button>
        <.button size="sm" variant="ghost" icon="refresh" phx-click="refresh-plan">Refresh</.button>
      </div>
    </div>
    """
  end

  # ── Subagents ───────────────────────────────────────────────────────────

  def tab(%{tab: "subagents"} = assigns) do
    ~H"""
    <div id={"subagent-tree-#{@dom_key}"} class="subagent-tree space-y-2">
      <.callout :if={@subagents.status == :unavailable} id={"subagent-tree-unavailable-#{@dom_key}"} tone="warning">
        Subagent status is unavailable right now.
      </.callout>
      <p
        :if={@subagents.status == :available and @subagents.nodes == []}
        id={"subagent-tree-empty-#{@dom_key}"}
        class="text-xs text-muted"
      >
        No subagents for the current run.
      </p>
      <ul :if={@subagents.nodes != []} class="space-y-1" aria-label="Subagents">
        <li
          :for={node <- @subagents.nodes}
          id={node.dom_id}
          data-depth={node.depth}
          data-parent-id={node.parent_id}
          data-status={node.status}
          class="rounded-md border border-line bg-surface px-2.5 py-1.5 text-xs"
          style={"margin-left: #{node.depth * 12}px"}
        >
          <div class="flex items-center gap-2">
            <.status_dot tone={node_tone(node.status)} pulse={node.status == "running"} />
            <span class="font-medium text-fg">{node.label}</span>
            <span class="min-w-0 flex-1 truncate font-mono text-2xs text-subtle">{node.id}</span>
            <.badge tone={node_tone(node.status)}>{node.status}</.badge>
          </div>
          <div :if={node.tools != [] or node.session_path} class="mt-1 flex flex-wrap items-center gap-1.5 text-2xs text-muted">
            <span :for={tool <- node.tools} class="rounded bg-surface-2 px-1 font-mono">{tool}</span>
            <.link :if={node.session_path} navigate={node.session_path} class="ml-auto inline-flex items-center gap-1 text-info hover:underline">
              Open child session <.icon name="arrow-right" class="h-3 w-3" />
            </.link>
          </div>
        </li>
      </ul>
      <p :if={@subagents.truncated?} id={"subagent-tree-truncated-#{@dom_key}"} class="text-2xs text-subtle">
        Showing the first {length(@subagents.nodes)} subagents.
      </p>
    </div>
    """
  end

  # ── Details ─────────────────────────────────────────────────────────────

  def tab(%{tab: "details"} = assigns) do
    ~H"""
    <div class="space-y-3 text-xs">
      <.detail_row id={"detail-key-#{@dom_key}"} label="Session key" value={@session_key} />
      <.detail_row :if={@cwd} id={"detail-cwd-#{@dom_key}"} label="Workspace" value={@cwd} />
      <.detail_row id={"detail-agent-#{@dom_key}"} label="Agent" value={@agent_id} />
      <.detail_row :if={@meta.model} id={"detail-model-#{@dom_key}"} label="Model" value={@meta.model} />
      <.detail_row :if={@meta.thinking_level} id={"detail-thinking-#{@dom_key}"} label="Thinking" value={@meta.thinking_level} />
      <.detail_row :if={@run.run_id} id={"detail-run-#{@dom_key}"} label="Active run" value={@run.run_id} />
      <.detail_row :if={@last_run_id} id={"detail-last-run-#{@dom_key}"} label="Last run" value={@last_run_id} />
      <section :if={is_map(@processes)} id={"process-recovery-#{@dom_key}"} aria-label="Owned background processes" class="space-y-2 border-t border-line pt-3">
        <h3 class="text-2xs font-semibold uppercase tracking-wide text-subtle">Owned background processes</h3>
        <p :if={@processes["status"] != "ok"} class="text-xs text-warning">Process status is unavailable.</p>
        <p :if={@processes["truncated"] == true} class="text-xs text-warning">Process snapshot truncated; some owned state is omitted.</p>
        <ul :if={@processes["status"] == "ok"} class="space-y-1">
          <li :for={process <- @processes["items"] || []} class="break-all">
            <code>{process["identity"]}</code>
            <span class="badge badge-neutral">{process["status"] || process["classification"]}</span>
            <span :if={process["reason"]} class="text-subtle">{process["reason"]}</span>
          </li>
        </ul>
      </section>
      <div class="flex flex-wrap gap-2 border-t border-line pt-3">
        <.button size="sm" icon="download" href={"/sessions/#{URI.encode_www_form(@session_key)}/export/markdown"}>
          Markdown
        </.button>
        <.button size="sm" icon="download" href={"/sessions/#{URI.encode_www_form(@session_key)}/export/json"}>
          JSON
        </.button>
        <.button size="sm" variant="ghost" icon="external-link" navigate={"/sessions/#{URI.encode_www_form(@session_key)}"}>
          Session manager
        </.button>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp detail_row(assigns) do
    ~H"""
    <div>
      <p class="mb-0.5 text-2xs font-semibold uppercase tracking-wide text-subtle">{@label}</p>
      <div class="group flex items-start gap-1">
        <code id={@id} class="min-w-0 flex-1 break-all rounded bg-surface-2 px-1.5 py-1 font-mono text-2xs text-fg">{@value}</code>
        <button
          type="button"
          id={"#{@id}-copy"}
          class="btn btn-ghost btn-icon btn-sm h-6 w-6 shrink-0"
          phx-hook="CopyButton"
          data-copy-target={@id}
          aria-label={"Copy #{@label}"}
        >
          <.icon name="copy" class="h-3 w-3" />
        </button>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp categories(data) do
    (data["categories"] || [])
    |> Enum.filter(&(is_map(&1) and is_integer(&1["tokens"]) and &1["tokens"] > 0))
    |> Enum.sort_by(& &1["tokens"], :desc)
  end

  defp threshold(%{"autoCompaction" => %{"enabled" => true, "thresholdTokens" => t}})
       when is_integer(t) and t > 0,
       do: t

  defp threshold(_), do: nil

  defp headroom(%{"autoCompaction" => %{"headroomTokens" => h}}) when is_integer(h) and h > 0,
    do: h

  defp headroom(_), do: nil

  defp source_label("usage"), do: "measured"
  defp source_label("usage+estimate"), do: "measured + estimate"
  defp source_label(_), do: "estimate"

  @doc "Formats a percentage (`12.3%`)."
  def format_percent(value) when is_number(value),
    do: "#{:erlang.float_to_binary(value * 1.0, decimals: 1)}%"

  def format_percent(_), do: "—"

  defp node_tone("running"), do: "info"
  defp node_tone("queued"), do: "neutral"
  defp node_tone("completed"), do: "success"
  defp node_tone(status) when status in ["error", "killed", "lost", "tracking_lost"], do: "danger"
  defp node_tone(_), do: "neutral"
end
