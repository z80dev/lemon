defmodule LemonCore.Config.Tools.Section do
  @moduledoc """
  Contract for a `[runtime.tools.<id>]` table owned by another application.

  `LemonCore.Config.Tools` resolves the tool settings core owns. A table that
  configures an optional driver (for example the browser driver's
  `[runtime.tools.browser]`) belongs to the application implementing it: that
  app declares the defaults, environment overrides, resolution and validation,
  so the library never names the driver or its vendors:

      config :lemon_core, :tool_sections, [MyApp.Tools.Widget.Config]

  Modules missing from a given build are skipped, so the list is a superset
  rather than a requirement (the same rule as `:gateway_channels` and
  `:env_registries`). With no registration the table is not resolved and
  validation ignores it, which is the correct answer for a host application
  that ships no such driver.

  ## Callbacks

  * `id/0` - the table key, e.g. `:widget` for `[runtime.tools.widget]`.
    Must be a literal atom.
  * `defaults/0` - the string-keyed default table merged into
    `LemonCore.Config.Tools.defaults/0`.
  * `resolve/1` - receives the raw table (string keys as parsed from TOML;
    `%{}` when absent, or the invalid non-map value) and returns the resolved
    value exposed as `Tools.section(tools, id)` and, in the legacy facade map,
    `agent.tools[id]`. Environment overrides declared by the owner apply here.
  * `validate/2` - receives the resolved value and the accumulated errors and
    returns the error list. Prepend `"runtime.tools.<id>.<field>: ..."`
    strings; the scalar helpers on `LemonCore.Config.Validator` are public for
    this purpose.
  """

  @callback id() :: atom()
  @callback defaults() :: map()
  @callback resolve(section :: term()) :: term()
  @callback validate(section :: term(), errors :: [String.t()]) :: [String.t()]

  @doc "Returns the registered tool-section modules that this build can load."
  @spec registered() :: [module()]
  def registered do
    :lemon_core
    |> Application.get_env(:tool_sections, [])
    |> List.wrap()
    |> Enum.filter(&Code.ensure_loaded?/1)
  end
end
