defmodule LemonWeb.SettingsLive do
  @moduledoc """
  `/settings`: browser preferences, session defaults, shortcuts and operator
  access.

  * Appearance and notification preferences live in the browser
    (`localStorage` keys `lemon-theme` and `lemon-notify`), handled by the
    `ThemeSwitcher` and `NotificationPrefs` hooks; the server never sees them.
  * Session defaults are the `[defaults]` keys in the global `config.toml`
    that new sessions start from. Changes go through
    `ProviderConfiguration` (`defaults.thinking_level`; the default model is
    chosen on `/models`) with a server-held preview revision, so an edit made
    elsewhere after the preview fails closed. Current per-session policy stays
    in `LemonCore.PolicyStore` — this page never writes a second policy plane.
  * The shortcut reference renders `LemonWeb.Shortcuts`.
  """

  use LemonWeb, :live_view

  alias LemonWeb.ProviderConfig

  @thinking_levels ~w(off minimal low medium high xhigh auto)
  @identifier ~r/^[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,127}$/

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(nav: :settings, page_title: "Settings · Lemon", page_heading: "Settings")
     |> assign(pending: nil, notice: nil, error: nil)
     |> load_defaults()
     |> then(&assign(&1, :thinking_draft, current_thinking(&1)))}
  end

  @impl true
  def handle_event("draft-thinking", %{"defaults" => %{"thinking_level" => level}}, socket) do
    {:noreply,
     assign(socket, :thinking_draft, if(level in @thinking_levels, do: level, else: nil))}
  end

  def handle_event("preview-thinking", %{"defaults" => %{"thinking_level" => level}}, socket)
      when level in @thinking_levels do
    socket = assign(socket, thinking_draft: level, pending: nil, notice: nil, error: nil)

    case ProviderConfig.configure(%{
           "action" => "defaults.thinking_level",
           "thinkingLevel" => level
         }) do
      {:ok, result} ->
        pending = %{
          level: level,
          from: current_thinking(socket),
          to: safe_level(get_in(result, ["proposedDefaults", "thinkingLevel"])) || level,
          changed: result["changed"] == true,
          revision: result["configRevision"]
        }

        {:noreply, assign(socket, :pending, pending)}

      {:error, code, _message} ->
        {:noreply, assign(socket, :error, error_text(code))}
    end
  end

  def handle_event("preview-thinking", _params, socket),
    do: {:noreply, assign(socket, pending: nil, error: "Choose a supported thinking level.")}

  def handle_event("cancel-preview", _params, socket),
    do:
      {:noreply, assign(socket, pending: nil, notice: "Preview dismissed. Nothing was written.")}

  def handle_event("apply-preview", _params, %{assigns: %{pending: nil}} = socket),
    do: {:noreply, assign(socket, :error, "Preview the change before applying it.")}

  def handle_event("apply-preview", _params, %{assigns: %{pending: pending}} = socket) do
    case ProviderConfig.configure(%{
           "action" => "defaults.thinking_level",
           "thinkingLevel" => pending.level,
           "apply" => true,
           "expectedRevision" => pending.revision
         }) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(pending: nil, error: nil)
         |> assign(:defaults, sanitize_defaults(result["defaults"]))
         |> assign(
           :notice,
           "Default thinking level saved. New sessions start at #{pending.level}."
         )}

      {:error, :stale_configuration, _message} ->
        {:noreply,
         socket
         |> assign(pending: nil, notice: nil)
         |> assign(
           :error,
           "The config changed after the preview, so nothing was written. Preview again."
         )
         |> load_defaults()}

      {:error, code, _message} ->
        {:noreply, assign(socket, :error, error_text(code))}
    end
  end

  defp load_defaults(socket) do
    case ProviderConfig.snapshot() do
      {:ok, _routing, defaults} ->
        assign(socket, defaults: sanitize_defaults(defaults), defaults_available?: true)

      _ ->
        assign(socket, defaults: sanitize_defaults(nil), defaults_available?: false)
    end
  end

  defp sanitize_defaults(%{} = defaults) do
    %{
      provider: safe_identifier(defaults["provider"]),
      model: safe_identifier(defaults["model"]),
      thinking: safe_level(defaults["thinkingLevel"])
    }
  end

  defp sanitize_defaults(_defaults), do: %{provider: nil, model: nil, thinking: nil}

  defp current_thinking(socket), do: socket.assigns.defaults.thinking

  defp safe_level(level) when level in @thinking_levels, do: level
  defp safe_level(_level), do: nil

  defp safe_identifier(value) when is_binary(value) do
    if Regex.match?(@identifier, value), do: value
  end

  defp safe_identifier(_value), do: nil

  defp error_text(:invalid_config),
    do: "The current Lemon configuration is not valid, so nothing was written."

  defp error_text(code)
       when code in [:invalid_thinking_level, :invalid_action, :missing_parameter],
       do: "That value is not supported."

  defp error_text(_code), do: "Configuration is temporarily unavailable. Nothing was written."

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        thinking_levels: @thinking_levels,
        shortcut_groups: LemonWeb.Shortcuts.groups()
      )

    ~H"""
    <.page>
      <.page_header title="Settings" icon="settings" subtitle="Preferences for this browser, defaults for new sessions, and operator access." />

      <div class="grid gap-6 lg:grid-cols-[11rem_minmax(0,1fr)]">
        <nav aria-label="Settings sections" class="hidden lg:block">
          <ul class="sticky top-2 space-y-px">
            <li :for={{id, label, icon} <- sections()}>
              <a href={"##{id}"} class="nav-item"><.icon name={icon} class="h-4 w-4" />{label}</a>
            </li>
          </ul>
        </nav>

        <div class="min-w-0 space-y-5">
          <.card id="appearance">
            <:header>Appearance</:header>
            <p class="mb-3 text-xs text-muted">
              Stored in this browser. <.kbd keys="mod+shift+l" /> cycles themes anywhere.
            </p>
            <div
              id="settings-theme"
              phx-hook="ThemeSwitcher"
              phx-update="ignore"
              role="group"
              aria-label="Theme"
              class="grid grid-cols-3 gap-2 sm:max-w-md"
            >
              <button
                :for={{choice, label, icon} <- [{"light", "Light", "sun"}, {"dark", "Dark", "moon"}, {"system", "System", "monitor"}]}
                type="button"
                data-theme-choice={choice}
                aria-pressed="false"
                class="group flex flex-col items-center gap-2 rounded-lg border border-line bg-surface p-3 text-[13px] font-medium text-muted transition-colors hover:border-line-strong hover:text-fg aria-pressed:border-accent aria-pressed:text-fg aria-pressed:ring-1 aria-pressed:ring-accent"
              >
                <span class={[
                  "flex h-10 w-full items-center justify-center rounded-md border",
                  theme_swatch(choice)
                ]}>
                  <.icon name={icon} class="h-4 w-4" />
                </span>
                {label}
              </button>
            </div>
          </.card>

          <.card id="notifications">
            <:header>Notifications</:header>
            <div id="notification-prefs" phx-hook="NotificationPrefs" phx-update="ignore" class="space-y-4">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-[13px] font-medium text-fg">Desktop alerts</p>
                  <p data-permission-status class="text-xs text-muted">Checking browser permission…</p>
                </div>
                <button type="button" data-request-permission hidden class="btn btn-secondary btn-sm">
                  <.icon name="bell" class="h-3.5 w-3.5" /> Enable desktop alerts
                </button>
              </div>
              <ul class="divide-y divide-line rounded-lg border border-line">
                <li
                  :for={{pref, label, hint} <- [
                    {"runs", "Run finished", "When a run completes, fails or is cancelled."},
                    {"approvals", "Approval needed", "When an agent asks to run a gated tool."}
                  ]}
                  class="flex items-center justify-between gap-3 px-3 py-2.5"
                >
                  <div class="min-w-0">
                    <p id={"notify-#{pref}-label"} class="text-[13px] font-medium text-fg">{label}</p>
                    <p class="text-xs text-muted">{hint}</p>
                  </div>
                  <button
                    type="button"
                    role="switch"
                    aria-checked="true"
                    aria-labelledby={"notify-#{pref}-label"}
                    data-pref={pref}
                    id={"notify-#{pref}"}
                    class="group relative inline-flex h-[18px] w-8 shrink-0 rounded-full border border-line-strong bg-surface-2 transition-colors aria-checked:border-transparent aria-checked:bg-accent"
                  >
                    <span class="absolute top-[1px] h-3.5 w-3.5 translate-x-[1px] rounded-full bg-surface shadow transition-transform group-aria-checked:translate-x-[15px] group-aria-checked:bg-accent-fg">
                    </span>
                  </button>
                </li>
              </ul>
              <p class="text-xs text-subtle">
                Stored in this browser. In-app toasts follow the same switches; desktop alerts appear only while Lemon is in a background tab.
              </p>
            </div>
          </.card>

          <.card id="session-defaults">
            <:header>Session defaults</:header>
            <p class="mb-4 text-xs text-muted">
              New sessions start from the <code class="font-mono text-fg">[defaults]</code> in your global config.
              Changing them never affects running sessions. Each change is previewed first.
            </p>

            <.callout :if={not @defaults_available?} tone="warning" class="mb-3" id="defaults-unavailable">
              Session defaults could not be read from the configuration.
            </.callout>
            <div id="defaults-feedback" aria-live="polite">
              <.callout :if={@notice} tone="success" class="mb-3">{@notice}</.callout>
              <.callout :if={@error} tone="danger" class="mb-3">{@error}</.callout>
            </div>

            <div class="divide-y divide-line rounded-lg border border-line">
              <div class="flex flex-wrap items-center justify-between gap-3 px-3 py-3">
                <div class="min-w-0">
                  <p class="text-[13px] font-medium text-fg">Default model</p>
                  <p class="truncate font-mono text-xs text-muted" id="default-model">{model_label(@defaults)}</p>
                </div>
                <.button size="sm" navigate={~p"/models"} icon_right="arrow-right">Choose in Models</.button>
              </div>

              <.form
                for={to_form(%{"thinking_level" => @thinking_draft}, as: :defaults)}
                id="thinking-form"
                phx-change="draft-thinking"
                phx-submit="preview-thinking"
                class="flex flex-wrap items-end justify-between gap-3 px-3 py-3"
              >
                <div class="min-w-0">
                  <label for="defaults_thinking_level" class="text-[13px] font-medium text-fg">Default thinking level</label>
                  <p class="text-xs text-muted">Currently <span class="font-medium text-fg">{@defaults.thinking || "not set"}</span></p>
                </div>
                <div class="flex items-center gap-2">
                  <select id="defaults_thinking_level" name="defaults[thinking_level]" class="input h-8 w-36">
                    <option :for={level <- @thinking_levels} value={level} selected={level == @thinking_draft}>{level}</option>
                  </select>
                  <.button type="submit" size="sm" icon="eye" disabled={@thinking_draft == @defaults.thinking}>
                    Preview
                  </.button>
                </div>
              </.form>
            </div>

            <section
              :if={@pending}
              id="defaults-preview"
              aria-labelledby="defaults-preview-title"
              class="mt-4 rounded-lg border border-warning/40 bg-warning/[0.05] p-3"
            >
              <div class="flex items-center gap-2">
                <.badge tone="warning" icon="eye">Preview</.badge>
                <h3 id="defaults-preview-title" class="text-[13px] font-semibold text-fg">Default thinking level</h3>
              </div>
              <p class="mt-2 font-mono text-[13px]">
                <span class="text-muted line-through decoration-danger/60">{@pending.from || "not set"}</span>
                <span class="mx-1.5 text-subtle">→</span>
                <span class="text-fg">{@pending.to}</span>
              </p>
              <p :if={not @pending.changed} class="mt-1 text-xs text-muted">This is already the configured value.</p>
              <p class="mt-1 text-xs text-muted">Writes <code class="font-mono">defaults.thinking_level</code> in the global config. Nothing has been written yet.</p>
              <div class="mt-3 flex flex-wrap gap-2">
                <.button variant="primary" size="sm" icon="check" phx-click="apply-preview" mutation disabled={not @pending.changed} id="apply-defaults">
                  Apply
                </.button>
                <.button variant="ghost" size="sm" phx-click="cancel-preview">Cancel</.button>
              </div>
            </section>
          </.card>

          <.card id="keyboard">
            <:header>Keyboard shortcuts</:header>
            <p class="mb-4 text-xs text-muted">
              <.kbd keys="mod" /> is ⌘ on macOS and Ctrl elsewhere. Press <.kbd keys="?" /> anywhere for this list.
            </p>
            <div class="grid gap-x-8 gap-y-5 md:grid-cols-2">
              <section :for={{group, shortcuts} <- @shortcut_groups} aria-labelledby={"keys-#{slug(group)}"}>
                <h3 id={"keys-#{slug(group)}"} class="mb-1.5 text-2xs font-semibold uppercase tracking-wider text-subtle">{group}</h3>
                <dl class="divide-y divide-line">
                  <div :for={shortcut <- shortcuts} class="flex items-center justify-between gap-3 py-1.5 text-[13px]">
                    <dt class="text-fg">{shortcut.description}</dt>
                    <dd class="flex shrink-0 items-center gap-1">
                      <span class="sr-only">{shortcut.keys}</span>
                      <%= for {part, index} <- Enum.with_index(String.split(shortcut.keys, " ")) do %>
                        <span :if={index > 0} class="text-2xs text-subtle" aria-hidden="true">then</span>
                        <.kbd keys={part} />
                      <% end %>
                    </dd>
                  </div>
                </dl>
              </section>
            </div>
          </.card>

          <.card id="operator">
            <:header>Operator access</:header>
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div class="min-w-0 space-y-1">
                <p class="flex items-center gap-2 text-[13px] font-medium text-fg">
                  <.icon name={if @operator_access == :token, do: "key", else: "shield-alert"} class="h-4 w-4 text-muted" />
                  {access_label(@operator_access)}
                  <.badge tone={if @operator_access == :token, do: "success", else: "warning"}>
                    {if @operator_access == :token, do: "Token", else: "Loopback"}
                  </.badge>
                </p>
                <p class="max-w-prose text-xs text-muted">{access_hint(@operator_access)}</p>
              </div>
              <.link
                :if={@operator_access == :token}
                href={~p"/logout"}
                method="delete"
                class="btn btn-secondary"
                id="sign-out"
              >
                <.icon name="log-out" /> Sign out
              </.link>
            </div>
          </.card>
        </div>
      </div>
    </.page>
    """
  end

  defp sections do
    [
      {"appearance", "Appearance", "sun"},
      {"notifications", "Notifications", "bell"},
      {"session-defaults", "Session defaults", "sparkles"},
      {"keyboard", "Shortcuts", "keyboard"},
      {"operator", "Operator", "shield-check"}
    ]
  end

  defp theme_swatch("light"), do: "border-[#e2e2de] bg-[#f8f8f6] text-[#17171a]"
  defp theme_swatch("dark"), do: "border-[#2c2c32] bg-[#0b0b0d] text-[#ececef]"
  defp theme_swatch(_), do: "border-line bg-gradient-to-r from-[#f8f8f6] to-[#0b0b0d] text-subtle"

  defp model_label(%{model: nil}), do: "Not set"

  defp model_label(%{model: model, provider: provider}) do
    if String.contains?(model, ":") or is_nil(provider), do: model, else: "#{provider}:#{model}"
  end

  defp access_label(:token), do: "Signed in with the operator token"
  defp access_label(_access), do: "Tokenless loopback access"

  defp access_hint(:token),
    do:
      "The browser holds only a session marker derived from the control-plane operator token. " <>
        "Rotating LEMON_CONTROL_PLANE_OPERATOR_TOKEN signs every browser out."

  defp access_hint(_access),
    do:
      "No operator token is configured and unauthenticated loopback access is enabled, so any local process can use this UI. " <>
        "Set LEMON_CONTROL_PLANE_OPERATOR_TOKEN to require sign-in."

  defp slug(group), do: group |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
end
