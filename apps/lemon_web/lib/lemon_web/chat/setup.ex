defmodule LemonWeb.Chat.Setup do
  @moduledoc """
  First-run readiness gate shared by the workspace home and chat panes.

  Readiness is read with `LemonCore.Setup.Readiness` (read-only). Chat fails
  closed while any step is pending: no upload is consumed, no message is
  appended and no control-plane call is made. Setup itself is done with
  `lemon setup`; the UI only explains the pending steps.
  """

  use Phoenix.Component

  import LemonWeb.UI

  alias LemonCore.Setup.Readiness

  @doc "Current readiness state (`:setup_readiness_fun` overrides it in tests)."
  def status do
    case Application.get_env(:lemon_web, :setup_readiness_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Readiness.status()
    end
  rescue
    _ -> unavailable()
  end

  def ready?(state) do
    Readiness.ready?(state)
  rescue
    _ -> false
  end

  def message,
    do: "Finish setup before chatting: run `lemon setup` in a terminal, then check again."

  defp unavailable, do: %{unavailable: true}

  attr(:state, :map, required: true)
  attr(:target, :any, default: nil)

  @doc "Setup checklist callout with a re-check button (`refresh-setup`)."
  def gate(assigns) do
    assigns =
      assigns
      |> assign(:unavailable, Map.get(assigns.state, :unavailable, false))
      |> assign(:steps, steps(assigns.state))

    ~H"""
    <.callout id="setup-readiness" tone="warning" title={if @unavailable, do: "Setup status could not be checked", else: "Finish setup before chatting"}>
      <p :if={@unavailable}>
        Check <.link navigate="/diagnostics" class="underline">diagnostics</.link>, then try again.
        Nothing is sent until setup status is known.
      </p>
      <p :if={!@unavailable}>
        Run <code class="rounded bg-surface-2 px-1 font-mono text-xs">lemon setup</code>
        in a terminal, then check again. Nothing is sent until setup is complete.
      </p>
      <ul :if={!@unavailable} class="mt-2 space-y-1">
        <li :for={{step, complete, help} <- @steps} class="flex items-center gap-2 text-[13px]">
          <.icon
            name={if complete, do: "check-circle", else: "circle"}
            class={["h-3.5 w-3.5", if(complete, do: "text-success", else: "text-warning")]}
          />
          <span class="font-medium text-fg">{step_title(step)}</span>
          <span :if={!complete} class="text-muted">— {help}</span>
        </li>
      </ul>
      <:actions>
        <.button size="sm" icon="refresh" phx-click="refresh-setup" phx-target={@target}>
          Check again
        </.button>
      </:actions>
    </.callout>
    """
  end

  defp steps(state) do
    Enum.map([:config, :secrets, :provider], fn step ->
      complete = get_in(state, [step, :complete]) == true
      {step, complete, step_help(step, state)}
    end)
  end

  defp step_title(:config), do: "Configuration"
  defp step_title(:secrets), do: "Secure secret storage"
  defp step_title(:provider), do: "Provider and model"

  defp step_help(:config, _state), do: "create the local Lemon config"
  defp step_help(:secrets, _state), do: "initialize the encrypted credential store"

  defp step_help(:provider, state) do
    case get_in(state, [:provider, :reason]) do
      :missing_default_provider -> "choose an AI provider"
      :missing_default_model -> "choose a default model"
      :credential_not_usable -> "store a usable provider credential"
      :model_provider_mismatch -> "choose a model that matches the provider"
      _ -> "configure a usable provider, model, and credential"
    end
  end
end
