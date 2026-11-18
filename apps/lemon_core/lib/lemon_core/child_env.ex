defmodule LemonCore.ChildEnv do
  @moduledoc """
  Environment for child processes that run model-directed or user code.

  Erlang ports and `System.cmd/3` inherit the BEAM's OS environment.
  `port_env/1` (port `{:env, _}` form) and `cmd_env/1` (`System.cmd/3` `:env`
  form) return the caller's extra variables plus an explicit unset for every
  controller credential currently present, so a shell, process, PTY, eval
  kernel, Git filter or MCP server cannot read Lemon's own credentials:

    * `LEMON_NODE_*TOKEN*` — execution-node pairing/session tokens
    * `LEMON_SECRETS_*` — secret-store master keys and settings
    * `LEMON_*_API_KEY` — provider/API keys

  Caller-supplied entries with a credential name are dropped as well. Ordinary
  variables such as `OPENAI_API_KEY` are inherited unchanged.
  """

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
  def credential?("LEMON_NODE_" <> rest), do: String.contains?(rest, "TOKEN")
  def credential?("LEMON_SECRETS_" <> _), do: true
  def credential?("LEMON_" <> rest), do: String.ends_with?(rest, "_API_KEY")
  def credential?(_name), do: false
end
