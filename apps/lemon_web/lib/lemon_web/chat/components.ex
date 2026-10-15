defmodule LemonWeb.Chat.Components do
  @moduledoc """
  Transcript and approval components for the chat workspace.

  Assistant text is rendered by `LemonWeb.Markdown` (allow-listed HTML) inside
  a `.md` container whose `ChatMarkdown` hook highlights code and adds copy
  buttons. Tool cards are `<details class="tool-card">` elements whose open
  state belongs to the browser (`JS.ignore_attributes("open")`), so streamed
  updates never collapse a card the user expanded.
  """

  use Phoenix.Component

  import LemonWeb.UI

  alias LemonWeb.Chat.Tool
  alias Phoenix.LiveView.JS

  # ── Transcript items ────────────────────────────────────────────────────

  attr(:item, :map, required: true)
  attr(:dom_id, :string, required: true)

  def item(%{item: %{kind: :user}} = assigns) do
    ~H"""
    <div id={@dom_id} data-kind="user" class="group flex justify-end">
      <div class="max-w-[88%] rounded-xl border border-line bg-surface-2 px-3.5 py-2.5 sm:max-w-[80%]">
        <div :if={@item.mode} class="mb-1">
          <.badge tone={mode_tone(@item.mode)} icon={mode_icon(@item.mode)}>{mode_label(@item.mode)}</.badge>
        </div>
        <p class="whitespace-pre-wrap break-words text-[13.5px] leading-relaxed text-fg">{@item.text}</p>
        <ul :if={@item.files != []} class="mt-2 flex flex-wrap gap-1.5" aria-label="Attachments">
          <li :for={name <- @item.files} class="inline-flex max-w-full items-center gap-1 rounded-md border border-line bg-surface px-1.5 py-0.5 text-xs text-muted">
            <.icon name="paperclip" class="h-3 w-3" /><span class="truncate">{name}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  def item(%{item: %{kind: :assistant}} = assigns) do
    ~H"""
    <div
      id={@dom_id}
      data-kind="assistant"
      data-streaming={to_string(@item.streaming)}
      class="group flex gap-3"
    >
      <div class="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-accent text-accent-fg">
        <.icon name="lemon" class="h-3.5 w-3.5" />
      </div>
      <div class="min-w-0 flex-1">
        <div id={"#{@dom_id}-md"} class="md" phx-hook="ChatMarkdown">{LemonWeb.Markdown.to_html(@item.text)}</div>
        <span
          :if={@item.streaming}
          class="ml-0.5 inline-block h-3.5 w-1.5 translate-y-0.5 animate-blink rounded-sm bg-accent"
          aria-hidden="true"
        >
        </span>
        <span :if={@item.streaming} class="sr-only">streaming</span>
        <div class="mt-1 flex h-6 items-center gap-1 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100">
          <button
            :if={!@item.streaming}
            type="button"
            id={"#{@dom_id}-copy"}
            class="btn btn-ghost btn-sm h-6 px-1.5 text-subtle"
            phx-hook="CopyButton"
            data-copy-target={"#{@dom_id}-md"}
            aria-label="Copy response"
          >
            <.icon name="copy" class="h-3 w-3" /> Copy
          </button>
        </div>
      </div>
    </div>
    """
  end

  def item(%{item: %{kind: :thinking}} = assigns) do
    ~H"""
    <details
      id={@dom_id}
      data-kind="thinking"
      class="thinking-block group/think ml-9 rounded-lg border border-line/70 bg-surface/50"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-1.5 text-xs text-muted hover:text-fg">
        <.icon name="brain" class="h-3.5 w-3.5 text-plan" />
        <span class="font-medium">{if @item.streaming, do: "Thinking…", else: "Thought"}</span>
        <span class="min-w-0 flex-1 truncate text-subtle">{first_line(@item.text)}</span>
        <.icon name="chevron-right" class="h-3.5 w-3.5 transition-transform group-open/think:rotate-90" />
      </summary>
      <div class="border-t border-line/70 px-3 py-2">
        <p class="max-h-80 overflow-y-auto whitespace-pre-wrap break-words text-xs italic leading-relaxed text-muted scroll-thin">{@item.text}</p>
      </div>
    </details>
    """
  end

  def item(%{item: %{kind: :tool}} = assigns) do
    ~H"""
    <.tool_card id={@dom_id} tool={@item} />
    """
  end

  def item(%{item: %{kind: :notice}} = assigns) do
    ~H"""
    <div id={@dom_id} data-kind="notice" class="flex justify-center">
      <p class={[
        "inline-flex max-w-full items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs",
        notice_tone(@item.tone)
      ]}>
        <.icon name={notice_icon(@item.tone)} class="h-3 w-3" />
        <span>{@item.text}</span>
      </p>
    </div>
    """
  end

  def item(%{item: %{kind: :run}} = assigns) do
    ~H"""
    <div id={@dom_id} data-kind="run" class="ml-9 flex flex-wrap items-center gap-x-2 gap-y-1 text-2xs text-subtle">
      <.icon
        name={if @item.ok, do: "check", else: "x"}
        class={["h-3 w-3", if(@item.ok, do: "text-success", else: "text-danger")]}
      />
      <span :if={@item[:model]} class="font-mono">{@item.model}</span>
      <span :if={@item[:duration_ms]}>· {duration(@item.duration_ms)}</span>
      <span :if={tokens(@item[:usage])}>· {compact_number(tokens(@item[:usage]))} tokens</span>
      <span :if={cost(@item[:usage])}>· {usd(cost(@item[:usage]))}</span>
    </div>
    """
  end

  defp tokens(%{"totalTokens" => n}) when is_integer(n), do: n
  defp tokens(%{"total_tokens" => n}) when is_integer(n), do: n
  defp tokens(%{"total" => n}) when is_integer(n), do: n

  defp tokens(%{"inputTokens" => i, "outputTokens" => o}) when is_integer(i) and is_integer(o),
    do: i + o

  defp tokens(_), do: nil

  defp cost(%{"costUsd" => n}) when is_number(n) and n > 0, do: n
  defp cost(%{"cost_usd" => n}) when is_number(n) and n > 0, do: n
  defp cost(_), do: nil

  defp mode_label(:followup), do: "Follow-up"
  defp mode_label(:steer), do: "Steer"
  defp mode_label(:redirect), do: "Redirect"
  defp mode_label(_), do: "Message"

  defp mode_icon(:followup), do: "corner-down-left"
  defp mode_icon(:steer), do: "target"
  defp mode_icon(_), do: "arrow-right"

  defp mode_tone(:redirect), do: "warning"
  defp mode_tone(:steer), do: "info"
  defp mode_tone(_), do: "neutral"

  defp notice_tone("success"), do: "border-success/30 bg-success/10 text-success"
  defp notice_tone("warning"), do: "border-warning/30 bg-warning/10 text-warning"
  defp notice_tone("danger"), do: "border-danger/30 bg-danger/10 text-danger"
  defp notice_tone(_), do: "border-line bg-surface text-muted"

  defp notice_icon("success"), do: "check-circle"
  defp notice_icon("warning"), do: "alert-triangle"
  defp notice_icon("danger"), do: "alert-circle"
  defp notice_icon(_), do: "info"

  # ── Tool cards ──────────────────────────────────────────────────────────

  attr(:id, :string, required: true)
  attr(:tool, :map, required: true)

  def tool_card(assigns) do
    tool = assigns.tool
    diff = if tool.type == :edit, do: Tool.diff_lines(tool)

    assigns =
      assign(assigns,
        subject: Tool.subject(tool),
        output: Tool.output(tool),
        diff: diff,
        open: tool.type in [:edit, :todo] or (tool.type == :bash and tool.status == :running)
      )

    ~H"""
    <details
      id={@id}
      class="tool-card group/tool ml-9 overflow-hidden rounded-lg border border-line bg-surface shadow-sm"
      data-kind="tool"
      data-status={@tool.status}
      data-phase={@tool.phase}
      data-tool={@tool.type}
      open={@open}
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2 text-[13px] hover:bg-surface-2/60">
        <.status_icon status={@tool.status} />
        <.icon name={Tool.icon(@tool.type)} class="h-3.5 w-3.5 text-subtle" />
        <span class="shrink-0 font-mono text-xs font-semibold text-fg">{@tool.name}</span>
        <span :if={@subject} class="min-w-0 flex-1 truncate font-mono text-xs text-muted" title={@subject}>{@subject}</span>
        <span :if={!@subject} class="flex-1"></span>
        <.tool_meta tool={@tool} diff={@diff} />
        <span class="badge badge-neutral shrink-0" data-status-label>{status_label(@tool.status)}</span>
        <.icon name="chevron-right" class="h-3.5 w-3.5 shrink-0 text-subtle transition-transform group-open/tool:rotate-90" />
      </summary>
      <div class="space-y-2 border-t border-line px-3 py-2.5">
        <.tool_body tool={@tool} output={@output} diff={@diff} id={@id} />
        <p :if={@tool.message && @tool.status in [:failed, :cancelled]} class="text-xs text-muted">{@tool.message}</p>
        <p :if={@tool.notice} class="flex items-center gap-1.5 text-xs text-warning">
          <.icon name="alert-triangle" class="h-3.5 w-3.5" />{@tool.notice}
        </p>
      </div>
    </details>
    """
  end

  attr(:status, :atom, required: true)

  defp status_icon(%{status: :running} = assigns) do
    ~H"""
    <span class="relative flex h-3.5 w-3.5 shrink-0 items-center justify-center" aria-hidden="true">
      <.icon name="loader" class="h-3.5 w-3.5 animate-spin text-accent-text" />
    </span>
    """
  end

  defp status_icon(assigns) do
    ~H"""
    <.icon
      name={
        case @status do
          :done -> "check-circle"
          :failed -> "x-circle"
          :cancelled -> "alert-circle"
          _ -> "circle-dot"
        end
      }
      class={[
        "h-3.5 w-3.5 shrink-0",
        case @status do
          :done -> "text-success"
          :failed -> "text-danger"
          :cancelled -> "text-warning"
          _ -> "text-subtle"
        end
      ]}
    />
    """
  end

  defp status_label(:running), do: "running"
  defp status_label(:done), do: "done"
  defp status_label(:failed), do: "failed"
  defp status_label(:cancelled), do: "cancelled"
  defp status_label(:completed), do: "completed"
  defp status_label(:unknown), do: "outcome unknown"

  attr(:tool, :map, required: true)
  attr(:diff, :any, default: nil)

  defp tool_meta(assigns) do
    {added, removed} = Tool.diff_stats(assigns.diff)

    assigns =
      assign(assigns,
        added: added,
        removed: removed,
        exit_code: if(assigns.tool.type == :bash, do: Tool.exit_code(assigns.tool)),
        count:
          if(assigns.tool.type == :search and assigns.tool.status != :running,
            do: Tool.search_count(assigns.tool)
          ),
        todos: if(assigns.tool.type == :todo, do: Tool.todos(assigns.tool), else: [])
      )

    ~H"""
    <span class="hidden shrink-0 items-center gap-2 font-mono text-2xs text-subtle sm:flex">
      <span :if={@added + @removed > 0}>
        <span class="text-success">+{@added}</span> <span class="text-danger">−{@removed}</span>
      </span>
      <span :if={is_integer(@exit_code)} class={if @exit_code == 0, do: "text-success", else: "text-danger"}>
        exit {@exit_code}
      </span>
      <span :if={is_integer(@count)}>{@count} {if @count == 1, do: "result", else: "results"}</span>
      <span :if={@todos != []}>
        {Enum.count(@todos, &(&1.status == "completed"))}/{length(@todos)}
      </span>
      <span :if={@tool.duration_ms}>{duration(@tool.duration_ms)}</span>
    </span>
    """
  end

  attr(:tool, :map, required: true)
  attr(:output, :string, default: nil)
  attr(:diff, :any, default: nil)
  attr(:id, :string, required: true)

  defp tool_body(%{tool: %{type: :bash}} = assigns) do
    ~H"""
    <div class="overflow-hidden rounded-md border border-line code-surface">
      <div class="flex items-start gap-2 border-b border-line/60 px-2.5 py-1.5 font-mono text-xs">
        <span class="select-none text-subtle">$</span>
        <code class="min-w-0 flex-1 whitespace-pre-wrap break-words">{Tool.arg(@tool, :command) || @tool.title}</code>
        <.badge :if={Tool.f(@tool.args, :run_in_background) == true} tone="info">background</.badge>
      </div>
      <pre
        :if={@output}
        class="tool-output max-h-80 overflow-auto whitespace-pre-wrap break-words px-2.5 py-2 font-mono text-xs leading-relaxed scroll-thin"
        data-autoscroll={@tool.status == :running && "true"}
      >{@output}</pre>
      <p :if={!@output} class="px-2.5 py-2 text-xs text-subtle">
        {if @tool.status == :running, do: "Waiting for output…", else: "No output."}
      </p>
    </div>
    """
  end

  defp tool_body(%{tool: %{type: :read}} = assigns) do
    path = Tool.arg(assigns.tool, :path) || Tool.arg(assigns.tool, :file_path)

    assigns =
      assign(assigns,
        path: path,
        language: Tool.language(path),
        range: Tool.line_range(assigns.tool)
      )

    ~H"""
    <p :if={@range} class="text-2xs text-subtle">{@range}</p>
    <div :if={@output} class="relative overflow-hidden rounded-md border border-line code-surface">
      <pre class="max-h-96 overflow-auto p-2.5 font-mono text-xs leading-relaxed scroll-thin"><code
          id={"#{@id}-code"}
          phx-hook="Highlight"
          data-language={@language}
        >{@output}</code></pre>
    </div>
    <p :if={!@output} class="text-xs text-subtle">{empty_output(@tool)}</p>
    """
  end

  defp tool_body(%{tool: %{type: :edit}} = assigns) do
    ~H"""
    <div :if={@diff} class="diff-view overflow-hidden rounded-md border border-line code-surface">
      <div class="max-h-96 overflow-auto py-1 font-mono text-xs leading-5 scroll-thin">
        <div
          :for={{type, line} <- @diff}
          class={["whitespace-pre px-2.5", diff_class(type)]}
          data-diff={type}
        >{if line == "", do: " ", else: line}</div>
      </div>
    </div>
    <pre
      :if={@output && (!@diff || @tool.status == :failed)}
      class="max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md bg-surface-2 p-2 font-mono text-xs scroll-thin"
    >{@output}</pre>
    <p :if={!@diff && !@output} class="text-xs text-subtle">{empty_output(@tool)}</p>
    """
  end

  defp tool_body(%{tool: %{type: :search}} = assigns) do
    rows = Tool.search_rows(assigns.tool)

    assigns =
      assign(assigns,
        rows: Enum.take(rows, 200),
        total: Tool.search_count(assigns.tool),
        truncated: Tool.search_truncated?(assigns.tool) or length(rows) > 200
      )

    ~H"""
    <ul :if={@rows != []} class="max-h-80 overflow-auto rounded-md border border-line code-surface py-1 font-mono text-xs scroll-thin">
      <li :for={row <- @rows} class="truncate px-2.5 leading-5" title={row}>{row}</li>
    </ul>
    <p :if={@rows != [] and (@truncated or @total > length(@rows))} class="text-2xs text-subtle">
      Showing {length(@rows)} of {@total}{if @truncated, do: " (truncated)"}
    </p>
    <p :if={@rows == []} class="text-xs text-subtle">
      {if @tool.status == :running, do: "Searching…", else: "No matches."}
    </p>
    """
  end

  defp tool_body(%{tool: %{type: :todo}} = assigns) do
    todos = Tool.todos(assigns.tool)
    done = Enum.count(todos, &(&1.status == "completed"))
    assigns = assign(assigns, todos: todos, done: done)

    ~H"""
    <div :if={@todos != []} class="space-y-2">
      <div class="flex items-center gap-2">
        <.meter value={@done} max={length(@todos)} tone="success" label="Todo progress" class="flex-1" />
        <span class="text-2xs tabular-nums text-subtle">{@done}/{length(@todos)}</span>
      </div>
      <ul class="space-y-1" aria-label="Todo list">
        <li :for={todo <- @todos} class="flex items-start gap-2 text-[13px]" data-todo-status={todo.status}>
          <.icon name={todo_icon(todo.status)} class={["mt-0.5 h-3.5 w-3.5 shrink-0", todo_color(todo.status)]} />
          <span class={[
            "min-w-0 break-words",
            todo.status == "completed" && "text-subtle line-through",
            todo.status == "in_progress" && "font-medium text-fg"
          ]}>{todo.content}</span>
        </li>
      </ul>
    </div>
    <pre :if={@todos == [] && @output} class="max-h-60 overflow-auto whitespace-pre-wrap break-words font-mono text-xs scroll-thin">{@output}</pre>
    """
  end

  defp tool_body(%{tool: %{type: :task}} = assigns) do
    assigns = assign(assigns, info: Tool.task_info(assigns.tool))

    ~H"""
    <div class="flex flex-wrap items-center gap-1.5 text-xs">
      <.badge :if={@info.agent} tone="plan" icon="user">{@info.agent}</.badge>
      <.badge :if={@info.status} tone={task_tone(@info.status)}>{@info.status}</.badge>
      <span :if={@info.current} class="min-w-0 truncate text-muted">↳ {@info.current}</span>
      <button
        type="button"
        class="btn btn-ghost btn-sm ml-auto"
        phx-click="inspector-tab"
        phx-value-tab="subagents"
      >
        <.icon name="network" class="h-3.5 w-3.5" /> Subagents
      </button>
    </div>
    <p :if={Tool.arg(@tool, :prompt)} class="line-clamp-3 whitespace-pre-wrap break-words text-xs text-muted">
      {Tool.arg(@tool, :prompt)}
    </p>
    <div :if={@output} id={"#{@id}-md"} class="md max-h-96 overflow-y-auto rounded-md border border-line bg-bg/40 p-2.5 text-[13px] scroll-thin" phx-hook="ChatMarkdown">
      {LemonWeb.Markdown.to_html(@output)}
    </div>
    """
  end

  defp tool_body(%{tool: %{type: type}} = assigns) when type in [:web, :browser] do
    assigns = assign(assigns, :url, Tool.arg(assigns.tool, :url))

    ~H"""
    <a
      :if={@url && safe_url(@url)}
      href={safe_url(@url)}
      target="_blank"
      rel="noopener noreferrer nofollow"
      class="inline-flex max-w-full items-center gap-1 truncate text-xs text-info underline decoration-info/40 underline-offset-2"
    >
      <.icon name="external-link" class="h-3 w-3" /><span class="truncate">{@url}</span>
    </a>
    <pre
      :if={@output}
      class="max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-md border border-line code-surface p-2.5 font-mono text-xs scroll-thin"
    >{@output}</pre>
    <p :if={!@output} class="text-xs text-subtle">{empty_output(@tool)}</p>
    """
  end

  defp tool_body(assigns) do
    assigns = assign(assigns, :args, Tool.args_text(assigns.tool))

    ~H"""
    <div :if={@args}>
      <p class="mb-1 text-2xs font-semibold uppercase tracking-wide text-subtle">Arguments</p>
      <pre class="max-h-60 overflow-auto whitespace-pre-wrap break-words rounded-md border border-line code-surface p-2.5 font-mono text-xs scroll-thin">{@args}</pre>
    </div>
    <div :if={@output}>
      <p class="mb-1 text-2xs font-semibold uppercase tracking-wide text-subtle">
        {if @tool.status == :running, do: "Live output", else: "Result"}
      </p>
      <pre class="tool-progress max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-md border border-line code-surface p-2.5 font-mono text-xs scroll-thin">{@output}</pre>
    </div>
    <p :if={!@args && !@output && !@tool.notice} class="text-xs text-subtle">{empty_output(@tool)}</p>
    """
  end

  defp empty_output(%{status: :running}), do: "Running…"
  defp empty_output(_), do: "No output reported."

  defp diff_class(:add), do: "diff-line-add"
  defp diff_class(:del), do: "diff-line-del"
  defp diff_class(:hunk), do: "diff-line-hunk"
  defp diff_class(:meta), do: "text-subtle"
  defp diff_class(_), do: nil

  defp todo_icon("completed"), do: "check-circle"
  defp todo_icon("in_progress"), do: "circle-dot"
  defp todo_icon(status) when status in ["blocked", "cancelled", "failed"], do: "x-circle"
  defp todo_icon(_), do: "circle"

  defp todo_color("completed"), do: "text-success"
  defp todo_color("in_progress"), do: "text-accent-text"
  defp todo_color(status) when status in ["blocked", "cancelled", "failed"], do: "text-danger"
  defp todo_color(_), do: "text-subtle"

  defp task_tone(status) when status in ["completed", "done"], do: "success"
  defp task_tone(status) when status in ["error", "failed", "killed", "lost"], do: "danger"
  defp task_tone(status) when status in ["running", "queued"], do: "info"
  defp task_tone(_), do: "neutral"

  defp safe_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> url
      _ -> nil
    end
  end

  # ── Approvals ───────────────────────────────────────────────────────────

  @doc "Display record for a pending approval (wire map from events or `exec.approvals.get`)."
  def approval_view(wire) do
    action = if is_map(wire["action"]), do: wire["action"], else: %{}
    tool = wire["tool"] || "tool"
    id = wire["approvalId"] || wire["id"]

    %{
      id: id,
      dom_id: "approval-" <> dom_digest(id),
      tool: tool,
      plan?: tool == "propose_plan",
      plan_title: action["title"],
      plan: if(is_binary(action["plan"]), do: action["plan"]),
      command: Enum.find_value(["command", "cmd"], &if(is_binary(action[&1]), do: action[&1])),
      path: Enum.find_value(["path", "file_path"], &if(is_binary(action[&1]), do: action[&1])),
      action_text: action |> Map.drop(["plan"]) |> Tool.format(),
      rationale: if(is_binary(wire["rationale"]), do: wire["rationale"]),
      requested_at_ms: wire["requestedAtMs"] || 0,
      expires_at_ms: if(is_integer(wire["expiresAtMs"]), do: wire["expiresAtMs"])
    }
  end

  defp dom_digest(value),
    do:
      :crypto.hash(:sha256, to_string(value))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

  attr(:approval, :map, required: true)

  def approval_card(%{approval: %{plan?: true}} = assigns) do
    ~H"""
    <section
      id={@approval.dom_id}
      data-approval-id={@approval.id}
      class="plan-proposal ml-9 overflow-hidden rounded-xl border border-plan/40 bg-surface shadow-pop"
      aria-labelledby={"#{@approval.dom_id}-title"}
    >
      <header class="flex items-center gap-2 border-b border-plan/20 bg-plan/[0.06] px-4 py-2.5">
        <.icon name="list-checks" class="h-4 w-4 text-plan" />
        <h3 id={"#{@approval.dom_id}-title"} class="min-w-0 flex-1 truncate text-[13px] font-semibold text-fg">
          Plan ready for review{if @approval.plan_title, do: ": #{@approval.plan_title}"}
        </h3>
        <.badge tone="plan">Plan</.badge>
      </header>
      <div
        :if={@approval.plan}
        id={"#{@approval.dom_id}-plan"}
        class="md max-h-[28rem] overflow-y-auto px-4 py-3 scroll-thin"
        phx-hook="ChatMarkdown"
      >
        {LemonWeb.Markdown.to_html(@approval.plan)}
      </div>
      <footer class="flex flex-wrap items-center gap-2 border-t border-line bg-surface-2/50 px-4 py-2.5">
        <p class="mr-auto text-xs text-muted">Approving ends plan mode and starts implementation.</p>
        <.button
          size="sm"
          icon="pencil"
          mutation
          phx-click="refine-plan"
          phx-value-id={@approval.id}
        >
          Refine
        </.button>
        <.button
          size="sm"
          variant="primary"
          icon="play"
          mutation
          phx-click="resolve-approval"
          phx-value-id={@approval.id}
          phx-value-decision="approve_once"
        >
          Approve &amp; execute
        </.button>
      </footer>
    </section>
    """
  end

  def approval_card(assigns) do
    ~H"""
    <section
      id={@approval.dom_id}
      data-approval-id={@approval.id}
      class="approval-card ml-9 overflow-hidden rounded-xl border border-warning/40 bg-surface shadow-pop"
      aria-labelledby={"#{@approval.dom_id}-title"}
    >
      <header class="flex items-center gap-2 border-b border-warning/20 bg-warning/[0.07] px-4 py-2.5">
        <.icon name="shield-alert" class="h-4 w-4 text-warning" />
        <h3 id={"#{@approval.dom_id}-title"} class="flex-1 text-[13px] font-semibold text-fg">
          Allow <code class="rounded bg-surface-2 px-1 font-mono text-xs">{@approval.tool}</code> to run
        </h3>
        <span
          :if={@approval.expires_at_ms}
          id={"#{@approval.dom_id}-expiry"}
          class="text-2xs tabular-nums text-subtle"
          phx-hook="Countdown"
          data-deadline={@approval.expires_at_ms}
          data-prefix="expires in "
        >
        </span>
      </header>
      <div class="space-y-2 px-4 py-3">
        <pre
          :if={@approval.command}
          class="max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md border border-line code-surface p-2.5 font-mono text-xs scroll-thin"
        ><span class="select-none text-subtle">$ </span>{@approval.command}</pre>
        <p :if={!@approval.command && @approval.path} class="font-mono text-xs text-fg">{@approval.path}</p>
        <details :if={!@approval.command && @approval.action_text} class="text-xs" open={!@approval.path}>
          <summary class="cursor-pointer text-muted">Details</summary>
          <pre class="mt-1 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md border border-line code-surface p-2.5 font-mono text-xs scroll-thin">{@approval.action_text}</pre>
        </details>
        <p :if={@approval.rationale} class="text-xs text-muted">
          <span class="font-medium text-fg">Why:</span> {@approval.rationale}
        </p>
      </div>
      <footer class="flex flex-wrap items-center gap-2 border-t border-line bg-surface-2/50 px-4 py-2.5">
        <.button
          size="sm"
          variant="primary"
          icon="check"
          mutation
          phx-click="resolve-approval"
          phx-value-id={@approval.id}
          phx-value-decision="approve_once"
        >
          Approve once
        </.button>
        <.button
          size="sm"
          mutation
          phx-click="resolve-approval"
          phx-value-id={@approval.id}
          phx-value-decision="approve_session"
        >
          Approve for session
        </.button>
        <.button
          size="sm"
          variant="ghost"
          mutation
          phx-click="resolve-approval"
          phx-value-id={@approval.id}
          phx-value-decision="approve_global"
        >
          Always
        </.button>
        <.button
          size="sm"
          variant="danger-soft"
          icon="x"
          class="ml-auto"
          mutation
          phx-click="resolve-approval"
          phx-value-id={@approval.id}
          phx-value-decision="deny"
        >
          Deny
        </.button>
      </footer>
    </section>
    """
  end

  defp first_line(text) when is_binary(text),
    do: text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 160)

  defp first_line(_), do: ""
end
