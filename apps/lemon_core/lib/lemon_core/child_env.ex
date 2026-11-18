defmodule LemonCore.ChildEnv do
  @moduledoc """
  Environment for child processes that run model-directed or user code.

  Erlang ports and `System.cmd/3` inherit the BEAM's OS environment.
  `port_env/1` (port `{:env, _}` form) and `cmd_env/1` (`System.cmd/3` `:env`
  form) return the caller's extra variables plus an explicit unset for every
  Lemon credential currently present, so a shell, process, PTY, eval kernel,
  Git filter, MCP server or browser command cannot read Lemon's own secrets:

    * every `LEMON_*` variable with a `_`-separated word naming a secret
      (`TOKEN`, `SECRET`, `SECRETS`, `KEY`, `COOKIE`, `PASSWORD`, `PASSPHRASE`,
      `PASS`, `AUTH`, `CREDENTIAL`, `CREDENTIALS`), e.g. node pairing/session
      tokens, operator and WebSocket tokens, secret-store master keys, web
      signing keys, bot tokens and `LEMON_*_API_KEY` provider keys
    * `LEMON_NODE_*` variables containing `TOKEN` anywhere
    * `RELEASE_COOKIE`, the Erlang distribution cookie

  Caller-supplied entries with a credential name are dropped as well. Ordinary
  variables such as `OPENAI_API_KEY` are inherited unchanged.

  This scrubs inheritance only. A child running as the same OS user can still
  read the parent's initial environment (`/proc/<pid>/environ`, `ps -E`), which
  is why the launchers never put node tokens there.
  """

  @secret_words ~w(TOKEN SECRET SECRETS KEY COOKIE PASSWORD PASSPHRASE PASS AUTH CREDENTIAL CREDENTIALS)

  @spec cmd_env(Enumerable.t()) :: [{String.t(), String.t() | nil}]
  def cmd_env(extra \\ []) do
    kept =
      for {name, value} <- extra, name = to_string(name), not credential?(name) do
        {name, if(value in [nil, false], do: nil, else: to_string(value))}
      end

    unset = for {name, _} <- System.get_env(), credential?(name), do: {name, nil}
    kept ++ unset
  end

  @spec port_env(Enumerable.t()) :: [{charlist(), charlist() | false}]
  def port_env(extra \\ []) do
    for {name, value} <- cmd_env(extra) do
      {String.to_charlist(name), if(is_nil(value), do: false, else: String.to_charlist(value))}
    end
  end

  @spec credential?(String.t()) :: boolean()
  def credential?("RELEASE_COOKIE"), do: true

  def credential?("LEMON_" <> rest = name) do
    (String.starts_with?(name, "LEMON_NODE_") and String.contains?(rest, "TOKEN")) or
      rest |> String.upcase() |> String.split("_") |> Enum.any?(&(&1 in @secret_words))
  end

  def credential?(_name), do: false
end
