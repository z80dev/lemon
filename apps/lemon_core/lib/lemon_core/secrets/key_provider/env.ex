defmodule LemonCore.Secrets.KeyProvider.Env do
  @moduledoc """
  Master key provider backed by an environment variable.

  Reads `LEMON_SECRETS_MASTER_KEY` by default; the name is configurable with
  `config :lemon_core, LemonCore.Secrets, env_var: "..."` or the `:env_var`
  option.
  """

  use LemonCore.Secrets.KeyProvider

  alias LemonCore.Secrets.KeyProvider

  @impl true
  def name, do: :env

  @impl true
  def fetch(opts) do
    case KeyProvider.env_getter(opts).(KeyProvider.env_var(opts)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing}
    end
  end
end
