defmodule LemonCore.Config.Gateway.Channel do
  @moduledoc """
  Contract for a chat-platform section of the `[gateway]` config table.

  `LemonCore.Config.Gateway` resolves the platform-independent gateway
  settings: concurrency, engine binding, bindings, queueing. Everything named
  after a specific chat platform — the `[gateway.<id>]` sub-table, the
  `enable_<id>` flag, the platform's `LEMON_*` variables and its validation
  rules — belongs to the application that implements that platform, so the
  library asks instead of knowing:

      config :lemon_core, :gateway_channels, [MyApp.Channels.Foo.Config]

  Each module owns exactly one section id and everything named after it. The
  umbrella's own registrations live in `config/config.exs`.

  Modules missing from a given build are skipped, so the list is a superset
  rather than a requirement — the same rule `LemonCore.Env` applies to
  `:env_registries`. With no registrations the gateway config simply carries no
  platform sections, which is the correct answer for a host application that
  ships no chat platforms.

  ## Callbacks

  * `id/0` — the section key, e.g. `:foo` for `[gateway.foo]` and
    `enable_foo`. Must be a literal atom, not derived at runtime.
  * `resolve/1` — receives the raw `[gateway.<id>]` sub-table (string keys, as
    parsed from TOML; `%{}` when absent) and returns the resolved section that
    `config.gateway[<id>]` exposes. This is where secret indirection,
    `${VAR}` expansion and the platform's own `LEMON_*` defaults are applied.
  * `enabled?/1` — receives the `enable_<id>` value from the config file
    (already coerced to a boolean, `false` when absent) and returns the
    effective flag. Implementations that honour an environment override read it
    here, because the reader owns the declaration (see `LemonCore.Env`).
  * `validate/2` — receives the *resolved* section and the accumulated error
    list, and returns the error list. Prepend `"gateway.<id>.<field>: ..."`
    strings, matching `LemonCore.Config.Validator`'s other messages; the
    generic scalar checks on that module are public for this purpose.
  """

  @callback id() :: atom()
  @callback resolve(section :: map()) :: map()
  @callback enabled?(configured :: boolean()) :: boolean()
  @callback validate(section :: map(), errors :: [String.t()]) :: [String.t()]

  @doc """
  Returns the registered channel-config modules that this build can load.
  """
  @spec registered() :: [module()]
  def registered do
    :lemon_core
    |> Application.get_env(:gateway_channels, [])
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  @doc """
  Returns the section ids of the registered channel-config modules.
  """
  @spec ids() :: [atom()]
  def ids, do: Enum.map(registered(), & &1.id())
end
