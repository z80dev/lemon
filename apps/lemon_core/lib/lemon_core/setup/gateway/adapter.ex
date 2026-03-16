defmodule LemonCore.Setup.Gateway.Adapter do
  @moduledoc """
  Behaviour for gateway transport setup adapters.

  Each transport (Telegram, Discord, …) implements this behaviour to
  participate in `mix lemon.setup gateway`.

  An adapter is responsible for:
  - validating that required secrets exist in the keychain
  - verifying that the config has a minimal `[gateway.<transport>]` section
  - optionally running a connectivity smoke test against the transport API
  - printing a config snippet the user can paste into config.toml
  """

  @doc "Machine-readable transport name, e.g. `\"telegram\"`."
  @callback name() :: String.t()

  @doc "Short human-readable description shown in the transport picker."
  @callback description() :: String.t()

  @doc """
  Run the interactive (or non-interactive) setup flow for this transport.

  `args` are the remaining CLI arguments after the transport name has been
  consumed.  `io` is the injected IO callbacks map with `:info`, `:error`,
  `:prompt`, and `:secret` keys.
  """
  @callback run([String.t()], map()) :: :ok | {:error, term()}
end
