defmodule LemonWeb.UI do
  @moduledoc """
  Lemon Web design-system function components.

  Every LiveView, LiveComponent and HTML module imports this module (see
  `LemonWeb.html_helpers/0`). Components render the classes defined in
  `assets/css/app.css` (`.btn`, `.input`, `.card`, `.badge`, ...) over the
  theme tokens, so they follow light/dark automatically.

  Conventions:

    * Tone values: `"neutral" | "accent" | "success" | "warning" | "danger" | "info" | "plan"`.
    * Mutating controls that must never fire while offline carry
      `data-requires-connection` (applied by `button/1` with `mutation`).
    * Dialogs use `<.modal>`; destructive actions use `<.confirm_dialog>` whose
      confirmation is bound server-side to the exact preview.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ── Icons ────────────────────────────────────────────────────────────────

  attr(:name, :string, required: true)
  attr(:class, :any, default: "h-4 w-4")
  attr(:rest, :global)

  def icon(assigns) do
    assigns = assign(assigns, :body, LemonWeb.Icons.body(assigns.name))

    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
      class={["shrink-0", @class]}
      {@rest}
    >{Phoenix.HTML.raw(@body)}</svg>
    """
  end

  # ── Buttons ──────────────────────────────────────────────────────────────

  @doc """
  Button or link styled as a button.

  Renders `<a>` (via `<.link>`) when `navigate`, `patch` or `href` is given,
  otherwise `<button>`. `mutation` marks controls disabled while the LiveView
  socket is disconnected.
  """
  attr(:type, :string, default: "button")

  attr(:variant, :string,
    default: "secondary",
    values: ~w(primary secondary ghost danger danger-soft)
  )

  attr(:size, :string, default: "md", values: ~w(sm md lg))
  attr(:icon, :string, default: nil)
  attr(:icon_right, :string, default: nil)
  attr(:icon_only, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:loading, :boolean, default: false)
  attr(:mutation, :boolean, default: false)
  attr(:navigate, :string, default: nil)
  attr(:patch, :string, default: nil)
  attr(:href, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global, include: ~w(form name value download target rel phx-disable-with))
  slot(:inner_block)

  def button(assigns) do
    assigns =
      assign(assigns, :classes, [
        "btn",
        "btn-#{assigns.variant}",
        assigns.size == "sm" && "btn-sm",
        assigns.size == "lg" && "btn-lg",
        assigns.icon_only && "btn-icon",
        assigns.class
      ])

    ~H"""
    <.link
      :if={@navigate || @patch || @href}
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={@classes}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
      <.icon :if={@icon_right} name={@icon_right} class={icon_size(@size)} />
    </.link>
    <button
      :if={!(@navigate || @patch || @href)}
      type={@type}
      class={@classes}
      disabled={@disabled || @loading}
      aria-busy={@loading && "true"}
      data-requires-connection={@mutation && ""}
      {@rest}
    >
      <.icon :if={@loading} name="loader" class={["animate-spin", icon_size(@size)]} />
      <.icon :if={@icon && !@loading} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
      <.icon :if={@icon_right} name={@icon_right} class={icon_size(@size)} />
    </button>
    """
  end

  defp icon_size("sm"), do: "h-3.5 w-3.5"
  defp icon_size(_), do: "h-4 w-4"

  # ── Badges, kbd, spinner, dots ───────────────────────────────────────────

  attr(:tone, :string, default: "neutral")
  attr(:icon, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={["badge", "badge-#{@tone}", @class]} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-3 w-3" />{render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Keyboard shortcut, e.g. `keys="mod+k"`. `mod` renders ⌘ on macOS and Ctrl
  elsewhere; `alt` renders ⌥/Alt (chosen by CSS from `html[data-platform]`).
  """
  attr(:keys, :string, required: true)
  attr(:class, :any, default: nil)

  def kbd(assigns) do
    assigns = assign(assigns, :parts, String.split(assigns.keys, "+", trim: true))

    ~H"""
    <span class={["inline-flex items-center gap-0.5", @class]} aria-hidden="true">
      <kbd :for={part <- @parts} class="kbd" data-kbd={part}>
        <%= case part do %>
          <% "mod" -> %>
            <span class="kbd-mac">⌘</span><span class="kbd-other">Ctrl</span>
          <% "alt" -> %>
            <span class="kbd-mac">⌥</span><span class="kbd-other">Alt</span>
          <% other -> %>
            {kbd_label(other)}
        <% end %>
      </kbd>
    </span>
    """
  end

  defp kbd_label("shift"), do: "⇧"
  defp kbd_label("enter"), do: "↵"
  defp kbd_label("esc"), do: "Esc"
  defp kbd_label("up"), do: "↑"
  defp kbd_label("down"), do: "↓"
  defp kbd_label("tab"), do: "Tab"
  defp kbd_label(key), do: String.upcase(key)

  attr(:class, :any, default: "h-4 w-4")
  attr(:label, :string, default: "Loading")

  def spinner(assigns) do
    ~H"""
    <span role="status" class="inline-flex">
      <.icon name="loader" class={["animate-spin text-subtle", @class]} />
      <span class="sr-only">{@label}</span>
    </span>
    """
  end

  @doc "Small status dot. `pulse` animates for live/running states."
  attr(:tone, :string, default: "neutral")
  attr(:pulse, :boolean, default: false)
  attr(:class, :any, default: nil)

  def status_dot(assigns) do
    ~H"""
    <span class={["relative inline-flex h-2 w-2 shrink-0", @class]} aria-hidden="true">
      <span
        :if={@pulse}
        class={["absolute inline-flex h-full w-full animate-ping rounded-full opacity-60", dot_bg(@tone)]}
      >
      </span>
      <span class={["relative inline-flex h-2 w-2 rounded-full", dot_bg(@tone)]}></span>
    </span>
    """
  end

  defp dot_bg("success"), do: "bg-success"
  defp dot_bg("warning"), do: "bg-warning"
  defp dot_bg("danger"), do: "bg-danger"
  defp dot_bg("info"), do: "bg-info"
  defp dot_bg("accent"), do: "bg-accent"
  defp dot_bg("plan"), do: "bg-plan"
  defp dot_bg(_), do: "bg-subtle"

  # ── Layout primitives ────────────────────────────────────────────────────

  @doc "Standard scrollable page body for operator pages."
  attr(:class, :any, default: nil)
  attr(:wide, :boolean, default: false)
  slot(:inner_block, required: true)

  def page(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto scroll-thin">
      <div class={[
        "mx-auto w-full px-4 pb-16 pt-5 sm:px-6 lg:px-8",
        if(@wide, do: "max-w-[96rem]", else: "max-w-6xl"),
        @class
      ]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:icon, :string, default: nil)
  attr(:class, :any, default: nil)
  slot(:actions)
  slot(:meta)

  def page_header(assigns) do
    ~H"""
    <header class={["mb-5 flex flex-wrap items-start justify-between gap-3", @class]}>
      <div class="flex min-w-0 items-start gap-3">
        <div
          :if={@icon}
          class="mt-0.5 hidden h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-line bg-surface text-muted shadow-sm sm:flex"
        >
          <.icon name={@icon} class="h-[18px] w-[18px]" />
        </div>
        <div class="min-w-0">
          <h1 class="truncate text-lg font-semibold tracking-tight text-fg">{@title}</h1>
          <p :if={@subtitle} class="mt-0.5 text-[13px] text-muted">{@subtitle}</p>
          <div :if={@meta != []} class="mt-1.5 flex flex-wrap items-center gap-2">{render_slot(@meta)}</div>
        </div>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr(:id, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:body_class, :any, default: "card-body")
  attr(:rest, :global)
  slot(:header)
  slot(:actions)
  slot(:inner_block, required: true)
  slot(:footer)

  def card(assigns) do
    ~H"""
    <section id={@id} class={["card", @class]} {@rest}>
      <div :if={@header != [] || @actions != []} class="card-header">
        <div class="min-w-0 text-[13px] font-semibold text-fg">{render_slot(@header)}</div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-1.5">{render_slot(@actions)}</div>
      </div>
      <div class={@body_class}>{render_slot(@inner_block)}</div>
      <div :if={@footer != []} class="border-t border-line px-4 py-3">{render_slot(@footer)}</div>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:icon, :string, default: "circle-dot")
  attr(:class, :any, default: nil)
  slot(:inner_block)

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center rounded-lg border border-dashed border-line px-6 py-10 text-center",
      @class
    ]}>
      <div class="mb-3 flex h-10 w-10 items-center justify-center rounded-full bg-surface-2 text-subtle">
        <.icon name={@icon} class="h-5 w-5" />
      </div>
      <p class="text-[13px] font-medium text-fg">{@title}</p>
      <p :if={@description} class="mt-1 max-w-sm text-xs text-muted">{@description}</p>
      <div :if={@inner_block != []} class="mt-4 flex items-center gap-2">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc "Inline callout for unavailable states, warnings and notices."
  attr(:tone, :string, default: "info")
  attr(:title, :string, default: nil)
  attr(:icon, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block)
  slot(:actions)

  def callout(assigns) do
    ~H"""
    <div
      role={if @tone in ["danger", "warning"], do: "alert", else: "status"}
      class={["flex gap-3 rounded-lg border px-3 py-2.5 text-[13px]", callout_tone(@tone), @class]}
      {@rest}
    >
      <.icon name={@icon || callout_icon(@tone)} class="mt-0.5 h-4 w-4" />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-medium">{@title}</p>
        <div :if={@inner_block != []} class={[@title && "mt-0.5", "text-fg/80"]}>
          {render_slot(@inner_block)}
        </div>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-start gap-1.5">{render_slot(@actions)}</div>
    </div>
    """
  end

  defp callout_tone("success"), do: "border-success/30 bg-success/[0.07] text-success"
  defp callout_tone("warning"), do: "border-warning/30 bg-warning/[0.07] text-warning"
  defp callout_tone("danger"), do: "border-danger/30 bg-danger/[0.07] text-danger"
  defp callout_tone("plan"), do: "border-plan/30 bg-plan/[0.07] text-plan"
  defp callout_tone("neutral"), do: "border-line bg-surface-2 text-muted"
  defp callout_tone(_), do: "border-info/30 bg-info/[0.07] text-info"

  defp callout_icon("success"), do: "check-circle"
  defp callout_icon("warning"), do: "alert-triangle"
  defp callout_icon("danger"), do: "alert-circle"
  defp callout_icon("plan"), do: "list-checks"
  defp callout_icon(_), do: "info"

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:hint, :string, default: nil)
  attr(:icon, :string, default: nil)
  attr(:tone, :string, default: "neutral")
  attr(:class, :any, default: nil)

  def stat(assigns) do
    ~H"""
    <div class={["card px-4 py-3", @class]}>
      <div class="flex items-center gap-1.5 text-xs font-medium text-muted">
        <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5" />{@label}
      </div>
      <div class={["mt-1 text-xl font-semibold tabular-nums tracking-tight", stat_tone(@tone)]}>{@value}</div>
      <div :if={@hint} class="mt-0.5 text-xs text-subtle">{@hint}</div>
    </div>
    """
  end

  defp stat_tone("success"), do: "text-success"
  defp stat_tone("warning"), do: "text-warning"
  defp stat_tone("danger"), do: "text-danger"
  defp stat_tone(_), do: "text-fg"

  @doc "Horizontal usage meter. `value`/`max` are numbers; tone auto-escalates at 70%/90% when `auto_tone`."
  attr(:value, :any, required: true)
  attr(:max, :any, required: true)
  attr(:label, :string, default: nil)
  attr(:tone, :string, default: "accent")
  attr(:auto_tone, :boolean, default: false)
  attr(:class, :any, default: nil)

  def meter(assigns) do
    pct = percent(assigns.value, assigns.max)

    tone =
      cond do
        not assigns.auto_tone -> assigns.tone
        pct >= 90 -> "danger"
        pct >= 70 -> "warning"
        true -> assigns.tone
      end

    assigns = assign(assigns, pct: pct, resolved_tone: tone)

    ~H"""
    <div
      class={["h-1.5 w-full overflow-hidden rounded-full bg-surface-2", @class]}
      role="meter"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={round(@pct)}
      aria-label={@label}
    >
      <div class={["h-full rounded-full transition-[width] duration-300", dot_bg(@resolved_tone)]} style={"width: #{@pct}%"}>
      </div>
    </div>
    """
  end

  defp percent(value, max) when is_number(value) and is_number(max) and max > 0,
    do: min(max(value * 100 / max, 0), 100) |> Float.round(1)

  defp percent(_value, _max), do: 0.0

  attr(:class, :any, default: nil)

  slot :item, required: true do
    attr(:label, :string, required: true)
  end

  def key_value(assigns) do
    ~H"""
    <dl class={["grid grid-cols-[minmax(7rem,auto)_1fr] gap-x-4 gap-y-1.5 text-[13px]", @class]}>
      <%= for item <- @item do %>
        <dt class="text-muted">{item.label}</dt>
        <dd class="min-w-0 break-words text-fg">{render_slot(item)}</dd>
      <% end %>
    </dl>
    """
  end

  # ── Forms ────────────────────────────────────────────────────────────────

  @doc """
  Labeled form control. `type` may be any input type, `"textarea"` or
  `"select"` (with `options`). Accepts a `Phoenix.HTML.FormField` via `field`
  or explicit `name`/`value`.
  """
  attr(:id, :any, default: nil)
  attr(:name, :any, default: nil)
  attr(:value, :any, default: nil)
  attr(:field, Phoenix.HTML.FormField, default: nil)
  attr(:type, :string, default: "text")
  attr(:label, :string, default: nil)
  attr(:hint, :string, default: nil)
  attr(:errors, :list, default: [])
  attr(:options, :list, default: [])
  attr(:prompt, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:input_class, :any, default: nil)

  attr(:rest, :global,
    include:
      ~w(autocomplete autofocus disabled form max maxlength min minlength pattern placeholder readonly required rows step spellcheck inputmode)
  )

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil)
    |> assign_new(:id, fn -> field.id end)
    |> assign(:name, field.name)
    |> assign(:value, assigns.value || field.value)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns = assign_new(assigns, :checked, fn -> assigns.value in [true, "true", "on"] end)

    ~H"""
    <label class={["flex items-start gap-2 text-[13px]", @class]}>
      <input type="hidden" name={@name} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        class="mt-0.5 h-4 w-4 rounded border-line-strong bg-surface text-accent focus:ring-ring/40"
        {@rest}
      />
      <span>
        <span class="font-medium text-fg">{@label}</span>
        <span :if={@hint} class="block text-xs text-subtle">{@hint}</span>
      </span>
    </label>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={@class}>
      <label :if={@label} for={@id} class="field-label">{@label}</label>
      <textarea
        :if={@type == "textarea"}
        id={@id}
        name={@name}
        class={["input", @input_class]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <select
        :if={@type == "select"}
        id={@id}
        name={@name}
        class={["input", @input_class]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <input
        :if={@type not in ["textarea", "select"]}
        type={@type}
        id={@id}
        name={@name}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={["input", @input_class]}
        aria-invalid={@errors != [] && "true"}
        {@rest}
      />
      <p :if={@hint && @errors == []} class="field-hint">{@hint}</p>
      <p :for={error <- @errors} class="field-error">{error}</p>
    </div>
    """
  end

  @doc "Accessible switch. Emits `phx-click` with `value` toggled on the server."
  attr(:id, :string, required: true)
  attr(:checked, :boolean, default: false)
  attr(:label, :string, required: true)
  attr(:show_label, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:rest, :global)

  def toggle(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      role="switch"
      aria-checked={to_string(@checked)}
      aria-label={!@show_label && @label}
      disabled={@disabled}
      class="group inline-flex items-center gap-2 text-[13px] disabled:opacity-50"
      data-requires-connection
      {@rest}
    >
      <span class={[
        "relative inline-flex h-[18px] w-8 shrink-0 rounded-full border transition-colors",
        if(@checked, do: "border-transparent bg-accent", else: "border-line-strong bg-surface-2")
      ]}>
        <span class={[
          "absolute top-[1px] h-3.5 w-3.5 rounded-full shadow transition-transform",
          if(@checked, do: "translate-x-[15px] bg-accent-fg", else: "translate-x-[1px] bg-surface")
        ]}>
        </span>
      </span>
      <span :if={@show_label} class="text-fg">{@label}</span>
    </button>
    """
  end

  # ── Tabs ─────────────────────────────────────────────────────────────────

  @doc """
  Tab list. Each `:tab` slot item has `id`, `label` and either `patch`/`navigate`
  (route tabs) or `click` (server event with `phx-value-tab`).
  """
  attr(:active, :string, required: true)
  attr(:label, :string, default: "Sections")
  attr(:class, :any, default: nil)

  slot :tab, required: true do
    attr(:id, :string, required: true)
    attr(:label, :string, required: true)
    attr(:icon, :string)
    attr(:patch, :string)
    attr(:navigate, :string)
    attr(:click, :string)
    attr(:count, :any)
  end

  def tabs(assigns) do
    ~H"""
    <div role="tablist" aria-label={@label} class={["flex items-center gap-4 overflow-x-auto overflow-y-hidden border-b border-line", @class]}>
      <%= for tab <- @tab do %>
        <.link
          :if={tab[:patch] || tab[:navigate]}
          patch={tab[:patch]}
          navigate={tab[:navigate]}
          role="tab"
          aria-selected={to_string(tab.id == @active)}
          class="tab"
        >
          <.icon :if={tab[:icon]} name={tab.icon} class="h-3.5 w-3.5" />{tab.label}
          <span :if={tab[:count] not in [nil, 0]} class="badge badge-neutral h-4 px-1.5">{tab.count}</span>
        </.link>
        <button
          :if={!(tab[:patch] || tab[:navigate])}
          type="button"
          role="tab"
          aria-selected={to_string(tab.id == @active)}
          class="tab"
          phx-click={tab[:click]}
          phx-value-tab={tab.id}
        >
          <.icon :if={tab[:icon]} name={tab.icon} class="h-3.5 w-3.5" />{tab.label}
          <span :if={tab[:count] not in [nil, 0]} class="badge badge-neutral h-4 px-1.5">{tab.count}</span>
        </button>
      <% end %>
    </div>
    """
  end

  # ── Overlays ─────────────────────────────────────────────────────────────

  @doc """
  Modal dialog. Render conditionally (`:if`) with `show` to open it.
  `on_cancel` runs on Esc, backdrop and close.
  """
  attr(:id, :string, required: true)
  attr(:show, :boolean, default: false)
  attr(:on_cancel, JS, default: %JS{})
  attr(:title, :string, default: nil)
  attr(:description, :string, default: nil)
  attr(:size, :string, default: "md", values: ~w(sm md lg xl))
  slot(:inner_block, required: true)
  slot(:footer)

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-bg"} class="fixed inset-0 bg-black/40 backdrop-blur-[2px] animate-fade-in" aria-hidden="true" />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={@title && "#{@id}-title"}
        aria-describedby={@description && "#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-start justify-center p-3 pt-[10vh] sm:p-6 sm:pt-[12vh]">
          <.focus_wrap
            id={"#{@id}-container"}
            phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
            phx-key="escape"
            phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
            class={[
              "relative w-full rounded-xl border border-line bg-elevated shadow-overlay animate-scale-in",
              modal_width(@size)
            ]}
          >
            <div :if={@title} class="flex items-start justify-between gap-4 px-5 pb-1 pt-4">
              <div>
                <h2 id={"#{@id}-title"} class="text-[15px] font-semibold text-fg">{@title}</h2>
                <p :if={@description} id={"#{@id}-description"} class="mt-0.5 text-[13px] text-muted">
                  {@description}
                </p>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-icon btn-sm -mr-2"
                phx-click={JS.exec("data-cancel", to: "##{@id}")}
                aria-label="Close"
              >
                <.icon name="x" />
              </button>
            </div>
            <div class="px-5 py-4">{render_slot(@inner_block)}</div>
            <div :if={@footer != []} class="flex flex-wrap items-center justify-end gap-2 border-t border-line px-5 py-3">
              {render_slot(@footer)}
            </div>
          </.focus_wrap>
        </div>
      </div>
    </div>
    """
  end

  defp modal_width("sm"), do: "max-w-sm"
  defp modal_width("lg"), do: "max-w-2xl"
  defp modal_width("xl"), do: "max-w-4xl"
  defp modal_width(_), do: "max-w-lg"

  defp show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.focus_first(to: "##{id}-container")
  end

  defp hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(to: "##{id}", transition: {"ease-in duration-100", "opacity-100", "opacity-0"})
    |> JS.pop_focus()
  end

  @doc """
  Right-side drawer (sheet) for details. Same lifecycle as `modal/1`: render
  with `:if` + `show`. Full-width below 640px.
  """
  attr(:id, :string, required: true)
  attr(:show, :boolean, default: false)
  attr(:on_cancel, JS, default: %JS{})
  attr(:title, :string, default: nil)
  attr(:description, :string, default: nil)
  attr(:width, :string, default: "sm:max-w-md")
  slot(:inner_block, required: true)
  slot(:footer)

  def drawer(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div class="fixed inset-0 bg-black/30 animate-fade-in" aria-hidden="true" />
      <div
        class="fixed inset-y-0 right-0 flex w-full"
        role="dialog"
        aria-modal="true"
        aria-labelledby={@title && "#{@id}-title"}
        aria-describedby={@description && "#{@id}-description"}
      >
        <.focus_wrap
          id={"#{@id}-container"}
          phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
          phx-key="escape"
          phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
          class={[
            "ml-auto flex h-full w-full flex-col border-l border-line bg-elevated shadow-overlay animate-slide-up",
            @width
          ]}
        >
          <div class="flex items-start justify-between gap-3 border-b border-line px-5 py-3.5">
            <div class="min-w-0">
              <h2 :if={@title} id={"#{@id}-title"} class="truncate text-[15px] font-semibold text-fg">
                {@title}
              </h2>
              <p :if={@description} id={"#{@id}-description"} class="mt-0.5 text-[13px] text-muted">
                {@description}
              </p>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-icon btn-sm -mr-2"
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              aria-label="Close"
            >
              <.icon name="x" />
            </button>
          </div>
          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4 scroll-thin">{render_slot(@inner_block)}</div>
          <div :if={@footer != []} class="flex flex-wrap items-center justify-end gap-2 border-t border-line px-5 py-3">
            {render_slot(@footer)}
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  @doc """
  Preview-then-confirm dialog for destructive operations.

  The caller has already produced a server-side preview (kept in socket
  assigns, bound to exact targets/revisions); this dialog only displays it.
  When `confirm_text` is set the operator must type it exactly before the
  confirm button submits `confirm_event` with the typed value as `confirmation`.
  The server must re-validate the binding; this component never decides.
  """
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:confirm_label, :string, default: "Confirm")
  attr(:confirm_event, :string, required: true)
  attr(:cancel_event, :string, required: true)
  attr(:confirm_text, :string, default: nil)
  attr(:tone, :string, default: "danger")
  attr(:target, :any, default: nil)
  slot(:inner_block)

  def confirm_dialog(assigns) do
    ~H"""
    <.modal id={@id} show title={@title} description={@description} on_cancel={JS.push(@cancel_event, target: @target)}>
      <form id={"#{@id}-form"} phx-submit={@confirm_event} phx-target={@target} class="space-y-4">
        <div :if={@inner_block != []} class="text-[13px] text-fg">{render_slot(@inner_block)}</div>
        <div :if={@confirm_text}>
          <label for={"#{@id}-confirmation"} class="field-label">
            Type <span class="font-mono text-fg">{@confirm_text}</span> to confirm
          </label>
          <input
            id={"#{@id}-confirmation"}
            name="confirmation"
            class="input font-mono"
            autocomplete="off"
            spellcheck="false"
            required
          />
        </div>
        <div class="flex justify-end gap-2">
          <button type="button" class="btn btn-secondary" phx-click={@cancel_event} phx-target={@target}>
            Cancel
          </button>
          <button
            type="submit"
            class={["btn", if(@tone == "danger", do: "btn-danger", else: "btn-primary")]}
            data-requires-connection
            phx-disable-with="Working…"
          >
            {@confirm_label}
          </button>
        </div>
      </form>
    </.modal>
    """
  end

  @doc """
  Dropdown menu anchored to a trigger. Items are arbitrary markup; give
  clickable items the `menu-item` class and `role="menuitem"`.
  """
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:align, :string, default: "end", values: ~w(start end))
  attr(:class, :any, default: nil)
  attr(:menu_class, :any, default: nil)
  slot(:trigger, required: true)
  slot(:inner_block, required: true)

  def dropdown(assigns) do
    ~H"""
    <div class={["relative", @class]} id={@id} phx-hook="Dropdown">
      <button
        type="button"
        id={"#{@id}-trigger"}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-menu"}
        aria-label={@label}
        data-dropdown-trigger
        class="inline-flex max-w-full items-center rounded-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/40"
      >
        {render_slot(@trigger)}
      </button>
      <div
        id={"#{@id}-menu"}
        role="menu"
        aria-labelledby={"#{@id}-trigger"}
        hidden
        data-dropdown-menu
        class={[
          "menu absolute top-full mt-1",
          if(@align == "end", do: "right-0", else: "left-0"),
          @menu_class
        ]}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # ── Tables ───────────────────────────────────────────────────────────────

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil)
  attr(:row_click, :any, default: nil)
  attr(:empty, :string, default: "Nothing here yet.")
  attr(:class, :any, default: nil)

  slot :col, required: true do
    attr(:label, :string)
    attr(:class, :string)
  end

  slot(:action)

  def table(assigns) do
    ~H"""
    <div class={["overflow-x-auto", @class]}>
      <table class="table" id={@id}>
        <thead>
          <tr>
            <th :for={col <- @col} class={col[:class]}>{col[:label]}</th>
            <th :if={@action != []}><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td colspan={length(@col) + if(@action != [], do: 1, else: 0)} class="py-8 text-center text-muted">
              {@empty}
            </td>
          </tr>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={@row_click && "cursor-pointer"}
            phx-click={@row_click && @row_click.(row)}
          >
            <td :for={col <- @col} class={col[:class]}>{render_slot(col, row)}</td>
            <td :if={@action != []} class="w-0 whitespace-nowrap text-right">
              <div class="flex items-center justify-end gap-1">
                <%= for action <- @action do %>
                  {render_slot(action, row)}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ── Code ─────────────────────────────────────────────────────────────────

  @doc """
  Highlighted code block with copy button. Highlighting runs client-side
  (`Highlight` hook, vendored highlight.js) after mount/update.
  """
  attr(:id, :string, required: true)
  attr(:code, :string, required: true)
  attr(:language, :string, default: nil)
  attr(:class, :any, default: nil)
  attr(:max_height, :string, default: "max-h-96")
  attr(:wrap, :boolean, default: false)

  def code_block(assigns) do
    ~H"""
    <div class={["group relative rounded-lg border border-line code-surface", @class]}>
      <button
        type="button"
        class="btn btn-ghost btn-icon btn-sm absolute right-1.5 top-1.5 z-10 opacity-0 transition-opacity focus:opacity-100 group-hover:opacity-100"
        phx-hook="CopyButton"
        id={"#{@id}-copy"}
        data-copy-target={"#{@id}-code"}
        aria-label="Copy code"
      >
        <.icon name="copy" class="h-3.5 w-3.5" />
      </button>
      <pre class={["overflow-auto p-3 font-mono text-xs leading-relaxed scroll-thin", @max_height, @wrap && "whitespace-pre-wrap break-words"]}><code
          id={"#{@id}-code"}
          phx-hook="Highlight"
          data-language={@language}
          class={@language && "language-#{@language}"}
        >{@code}</code></pre>
    </div>
    """
  end

  # ── Flash / toasts ───────────────────────────────────────────────────────

  attr(:flash, :map, default: %{})
  attr(:id, :string, default: "flash-group")

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      class="pointer-events-none fixed bottom-4 right-4 z-[60] flex w-[min(24rem,calc(100vw-2rem))] flex-col gap-2"
      aria-live="polite"
      role="status"
    >
      <.flash :for={{kind, message} <- @flash} kind={kind} message={message} />
    </div>
    """
  end

  attr(:kind, :any, required: true)
  attr(:message, :any, required: true)

  def flash(assigns) do
    ~H"""
    <div
      :if={is_binary(@message) and @message != ""}
      id={"flash-#{@kind}"}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
      phx-hook="AutoDismiss"
      class={[
        "pointer-events-auto flex cursor-pointer items-start gap-2.5 rounded-lg border bg-elevated px-3 py-2.5 text-[13px] shadow-pop animate-slide-up",
        if(to_string(@kind) == "error", do: "border-danger/40", else: "border-line")
      ]}
    >
      <.icon
        name={if to_string(@kind) == "error", do: "alert-circle", else: "check-circle"}
        class={["mt-0.5 h-4 w-4", if(to_string(@kind) == "error", do: "text-danger", else: "text-success")]}
      />
      <p class="flex-1 text-fg">{@message}</p>
      <.icon name="x" class="mt-0.5 h-3.5 w-3.5 text-subtle" />
    </div>
    """
  end

  # ── Formatting helpers ───────────────────────────────────────────────────

  @doc "Compact relative time for a millisecond epoch (\"3m ago\")."
  @spec relative_time(integer() | nil, integer()) :: String.t()
  def relative_time(ms, now_ms \\ System.system_time(:millisecond))

  def relative_time(ms, now_ms) when is_integer(ms) and is_integer(now_ms) do
    diff = div(now_ms - ms, 1000)

    cond do
      diff < 0 -> "just now"
      diff < 45 -> "just now"
      diff < 3600 -> "#{max(div(diff, 60), 1)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)}d ago"
      true -> ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%b %-d, %Y")
    end
  end

  def relative_time(_ms, _now_ms), do: "—"

  @doc "Formats token counts compactly (1.2k, 3.4M)."
  @spec compact_number(number() | nil) :: String.t()
  def compact_number(n) when is_integer(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  def compact_number(n) when is_integer(n) and n >= 10_000, do: "#{round(n / 1000)}k"
  def compact_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1000, 1)}k"
  def compact_number(n) when is_integer(n), do: Integer.to_string(n)
  def compact_number(n) when is_float(n), do: compact_number(round(n))
  def compact_number(_), do: "—"

  @doc "Formats a USD amount."
  @spec usd(number() | nil) :: String.t()
  def usd(n) when is_number(n) and n < 0.01 and n > 0, do: "<$0.01"
  def usd(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n * 1.0, decimals: 2)
  def usd(_), do: "—"

  @doc "Formats a duration in milliseconds (\"1m 12s\")."
  @spec duration(integer() | nil) :: String.t()
  def duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  def duration(ms) when is_integer(ms) and ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

  def duration(ms) when is_integer(ms) do
    s = div(ms, 1000)

    if s < 3600,
      do: "#{div(s, 60)}m #{rem(s, 60)}s",
      else: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
  end

  def duration(_), do: "—"
end
