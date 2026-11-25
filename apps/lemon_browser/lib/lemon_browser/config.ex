defmodule LemonBrowser.Config do
  @moduledoc """
  Owner of the `[runtime.tools.browser]` table.

  Registered under `config :lemon_core, :tool_sections` (see
  `LemonCore.Config.Tools.Section`), so `LemonCore.Config` resolves and
  validates the table without naming the browser driver:

      [runtime.tools.browser]
      provider = "auto"   # LEMON_BROWSER_PROVIDER
      tern = true         # LEMON_BROWSER_TERN

  Selection is passive and explicit providers never fall back; see
  `LemonBrowser.Provider`. An explicit `LEMON_BROWSER_BACKEND` and non-default
  `:lemon_browser, :backend` application settings still seed `provider` when the
  table does not set it.
  """

  @behaviour LemonCore.Config.Tools.Section

  alias LemonCore.Config.Validator
  alias LemonCore.Env

  @impl true
  def id, do: :browser

  @impl true
  def defaults, do: %{"provider" => "auto", "tern" => true}

  @impl true
  def resolve(section) when is_map(section) do
    provider =
      Env.get(:lemon_browser_provider,
        default: Map.get(section, "provider", legacy_backend() || "auto")
      )

    section
    |> Map.drop(["provider", "tern"])
    |> Map.put(:provider, provider)
    |> Map.put(:tern, Env.get(:lemon_browser_tern, default: Map.get(section, "tern", true)))
  end

  def resolve(invalid), do: invalid

  @impl true
  def validate(%{} = browser, errors) do
    errors = Validator.validate_boolean(errors, browser[:tern], "runtime.tools.browser.tern")

    if browser[:provider] in LemonBrowser.Provider.providers() do
      errors
    else
      [
        "runtime.tools.browser.provider: must be one of #{Enum.join(LemonBrowser.Provider.providers(), ", ")}"
        | errors
      ]
    end
  end

  def validate(_invalid, errors), do: ["runtime.tools.browser: must be a table" | errors]

  # The old default :local is not an explicit choice. Preserve explicit backend
  # environment selections and non-default application settings without making
  # the historical default defeat auto detection.
  defp legacy_backend do
    case Env.string("LEMON_BROWSER_BACKEND") do
      nil ->
        case Application.get_env(:lemon_browser, :backend) do
          backend when backend in [nil, :local, "local"] -> nil
          backend when is_atom(backend) -> Atom.to_string(backend)
          backend -> backend
        end

      backend ->
        backend
    end
  end
end
