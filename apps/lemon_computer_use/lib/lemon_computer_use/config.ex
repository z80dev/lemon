defmodule LemonComputerUse.Config do
  @moduledoc """
  Runtime settings for native computer use.

  Precedence for each value is the environment variable declared in
  `LemonComputerUse.Env`, then the `[runtime.tools.computer_use]` section of
  Lemon's config (`enabled`, `chrome`, `lcu_root`, `node`, `declined_origins`),
  then `config :lemon_computer_use`, then the built-in default. Nothing here
  raises: an unusable value falls back to the next source.

    * `:enabled` / `LEMON_COMPUTER_USE_ENABLED` — the opt-in switch (default
      `false`). Disabled, the app registers no tools and no prompt section and
      never starts LCU.
    * `:lcu_root` / `LEMON_COMPUTER_USE_LCU_ROOT` — the installed LCU release
      (default `~/.local/share/lcu/current`, or `/opt/lcu/current` when only that
      exists). Lemon runs `<root>/bin/lcu` as the computer-use MCP server and
      imports LCU's shared harness client from `<root>/adapters/client.mjs`.
    * `:node` / `LEMON_COMPUTER_USE_NODE` — Node runtime for the bridge (default
      `<root>/agent-tools/node/bin/node`, the runtime LCU selected at setup).
    * `:chrome` / `LEMON_COMPUTER_USE_CHROME` — also enable the runtime's
      browser surface (`lcu --chrome`): Chrome tabs through the official
      ChatGPT extension (default `false`). Requires `lcu browser install`.
    * `:connect_timeout_ms` — how long tool construction waits for the first
      connection (default 30 seconds).

  `:command` and `:bridge_script` are test seams: the LCU server argv and the
  bridge script path.
  """

  @app :lemon_computer_use
  @default_connect_timeout_ms 30_000

  @spec enabled?() :: boolean()
  def enabled? do
    case parse_bool(env("LEMON_COMPUTER_USE_ENABLED")) do
      value when is_boolean(value) -> value
      nil -> boolean(toml(:enabled), Application.get_env(@app, :enabled, false))
    end
  end

  @spec chrome?() :: boolean()
  def chrome? do
    case parse_bool(env("LEMON_COMPUTER_USE_CHROME")) do
      value when is_boolean(value) -> value
      nil -> boolean(toml(:chrome), Application.get_env(@app, :chrome, false))
    end
  end

  @spec lcu_root() :: String.t()
  def lcu_root do
    case env("LEMON_COMPUTER_USE_LCU_ROOT") || string(toml(:lcu_root)) ||
           Application.get_env(@app, :lcu_root) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> default_root()
    end
  end

  defp default_root do
    candidates = [Path.join(System.user_home!(), ".local/share/lcu/current"), "/opt/lcu/current"]
    Enum.find(candidates, hd(candidates), &File.dir?/1)
  end

  @spec node() :: String.t()
  def node do
    case env("LEMON_COMPUTER_USE_NODE") || string(toml(:node)) ||
           Application.get_env(@app, :node) do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.join(lcu_root(), "agent-tools/node/bin/node")
    end
  end

  @doc "argv of the original computer-use MCP server."
  @spec command() :: [String.t()]
  def command do
    case Application.get_env(@app, :command) do
      [_ | _] = argv -> argv
      _ -> [Path.join(lcu_root(), "bin/lcu") | if(chrome?(), do: ["--chrome"], else: [])]
    end
  end

  @spec bridge_script() :: String.t()
  def bridge_script do
    case Application.get_env(@app, :bridge_script) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Path.join(:code.priv_dir(@app), "lcu_bridge.mjs")
    end
  end

  @spec connect_timeout_ms() :: pos_integer()
  def connect_timeout_ms do
    case Application.get_env(@app, :connect_timeout_ms, @default_connect_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_connect_timeout_ms
    end
  end

  @doc """
  Website origins computer use always declines, besides Lemon's local ports:
  the Lemon Bot web client's origin (`LEMON_BOT_PUBLIC_URL`, which serves its
  approvals surface) and any origins listed in
  `LEMON_COMPUTER_USE_DECLINED_ORIGINS` (comma-separated), the config file's
  `declined_origins` list, or `config :lemon_computer_use, declined_origins: [...]`. Each entry is reduced
  to its `scheme://host[:port]` origin; unparseable entries are ignored.
  """
  @spec declined_origins() :: [String.t()]
  def declined_origins do
    listed =
      case env("LEMON_COMPUTER_USE_DECLINED_ORIGINS") do
        nil -> []
        value -> String.split(value, ",", trim: true)
      end

    configured =
      case Application.get_env(@app, :declined_origins, []) do
        list when is_list(list) -> list
        _ -> []
      end

    file =
      case toml(:declined_origins) do
        list when is_list(list) -> list
        _ -> []
      end

    [env("LEMON_BOT_PUBLIC_URL") | listed ++ file ++ configured]
    |> Enum.flat_map(&origin_of/1)
    |> Enum.uniq()
  end

  @doc false
  @spec origin_of(term()) :: [String.t()]
  def origin_of(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        bracketed = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
        default = if scheme == "https", do: 443, else: 80
        suffix = if port in [nil, default], do: "", else: ":" <> Integer.to_string(port)
        [scheme <> "://" <> String.downcase(bracketed) <> suffix]

      _ ->
        []
    end
  end

  def origin_of(_value), do: []

  # The config file's `[runtime.tools.computer_use]`, through the platform's
  # cached config. A missing or unreadable config is simply "not set".
  defp toml(key) do
    case LemonCore.Config.cached() do
      %{agent: %{tools: %{computer_use: %{} = section}}} -> Map.get(section, key)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp boolean(value, _fallback) when is_boolean(value), do: value
  defp boolean(_value, fallback), do: fallback == true

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp parse_bool(nil), do: nil

  defp parse_bool(value) do
    case String.downcase(value) do
      v when v in ~w(1 true yes on) -> true
      v when v in ~w(0 false no off) -> false
      _ -> nil
    end
  end
end
