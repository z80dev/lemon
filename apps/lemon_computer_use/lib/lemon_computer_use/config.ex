defmodule LemonComputerUse.Config do
  @moduledoc """
  Runtime settings for native computer use.

  Precedence for each value is the environment variable declared in
  `LemonComputerUse.Env`, then the `[runtime.tools.computer_use]` section of
  Lemon's config (`enabled`, `lcu_root`, `node`, `declined_origins`),
  then `config :lemon_computer_use`, then the built-in default. Nothing here
  raises: an unusable value falls back to the next source.

    * `:enabled` / `LEMON_COMPUTER_USE_ENABLED` — the opt-in switch (default
      `false`) and the only thing that enables computer use. The browser
      provider never enables it: a resolved `lcu` provider only adds the Chrome
      surface to a bridge this switch already started.
    * `:lcu_root` / `LEMON_COMPUTER_USE_LCU_ROOT` — the installed LCU release
      (default `~/.local/share/lcu/current`, or `/opt/lcu/current` when only that
      exists). Lemon runs `<root>/bin/lcu` as the computer-use MCP server and
      imports LCU's shared harness client from `<root>/adapters/client.mjs`.
    * `:node` / `LEMON_COMPUTER_USE_NODE` — Node runtime for the bridge (default
      `<root>/agent-tools/node/bin/node`, the runtime LCU selected at setup).
    * Chrome is controlled exclusively by `[runtime.tools.browser] provider` /
      `LEMON_BROWSER_PROVIDER`. The LCU Chrome surface is included only when
      the read-only provider resolver confirms a connected LCU extension.
    * `:connect_timeout_ms` — the shared RPC handshake deadline and how long
      tool construction waits for the first connection (default 30 seconds).

  `:command` and `:bridge_script` are test seams: the LCU server argv and the
  bridge script path.
  """

  @app :lemon_computer_use
  @default_connect_timeout_ms 30_000

  @doc """
  Resolve the opt-in switch. `LemonComputerUse.Application` calls this once at
  boot; everything else reads that boot decision via `LemonComputerUse.enabled?/0`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case parse_bool(env("LEMON_COMPUTER_USE_ENABLED")) do
      value when is_boolean(value) -> value
      nil -> boolean(toml(:enabled), Application.get_env(@app, :enabled, false))
    end
  end

  @spec chrome?(keyword()) :: boolean()
  def chrome?(opts \\ []), do: LemonCore.BrowserProvider.resolve(opts).provider == "lcu"

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
  @spec command(keyword()) :: [String.t()]
  def command(opts \\ []) do
    case Application.get_env(@app, :command) do
      [_ | _] = argv -> argv
      _ -> [Path.join(lcu_root(), "bin/lcu") | if(chrome?(opts), do: ["--chrome"], else: [])]
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
  Apps (bundle ids, case-insensitive) whose computer-use approvals may keep a
  lasting grant: the config file's `lasting_grant_apps` list, or
  `config :lemon_computer_use, lasting_grant_apps: [...]`. Empty by default,
  so every app is once-only. Returned trimmed and downcased.
  """
  @spec lasting_grant_apps() :: [String.t()]
  def lasting_grant_apps do
    case toml(:lasting_grant_apps) || Application.get_env(@app, :lasting_grant_apps, []) do
      list when is_list(list) ->
        for app <- list,
            is_binary(app),
            app = String.downcase(String.trim(app)),
            app != "",
            do: app

      _ ->
        []
    end
  end

  @doc """
  Website origins computer use always declines, besides every local origin
  (see `LemonComputerUse.Approval`): the Lemon Bot web client's origin, which
  serves its approvals surface — `LEMON_BOT_PUBLIC_URL` from this process and
  from every installed Lemon Bot backend service unit (the backend owns that
  value; the controller usually lacks it), plus that unit's
  `LEMON_BOT_HOST`/`LEMON_BOT_PORT` address — and any origins listed in
  `LEMON_COMPUTER_USE_DECLINED_ORIGINS` (comma-separated), the config file's
  `declined_origins` list, or `config :lemon_computer_use, declined_origins: [...]`.
  Each entry is reduced to its `scheme://host[:port]` origin; unparseable
  entries are ignored. `opts` (`:home`, `:os`) locate service units in tests.
  """
  @spec declined_origins(keyword()) :: [String.t()]
  def declined_origins(opts \\ []) do
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

    [env("LEMON_BOT_PUBLIC_URL") | installed_bot_urls(opts) ++ listed ++ file ++ configured]
    |> Enum.flat_map(&origin_of/1)
    |> Enum.uniq()
  end

  # The Lemon Bot addresses saved in installed backend service units.
  defp installed_bot_urls(opts) do
    alias LemonCore.Service.{Role, Unit}

    managers =
      case Keyword.get(opts, :os, :os.type()) do
        {:unix, :darwin} -> ["launchd", "none"]
        {:unix, :linux} -> ["systemd", "none"]
        _ -> ["none"]
      end

    for manager <- managers,
        {"backend", unit_opts} <- LemonCore.Service.discover(manager, opts),
        unit_opts = Keyword.merge(opts, unit_opts),
        port = Role.port("backend", unit_opts),
        path = Role.unit_path(Role.label("backend", manager, nil, port), manager, unit_opts),
        {:ok, %{env: unit_env}} <- [Unit.read(path, manager)],
        url <- [
          unit_env["LEMON_BOT_PUBLIC_URL"],
          bot_address(unit_env["LEMON_BOT_HOST"], unit_env["LEMON_BOT_PORT"] || port)
        ],
        is_binary(url),
        do: url
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp bot_address(host, port) when is_binary(host) and host != "" do
    host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
    "http://" <> host <> ":" <> to_string(port)
  end

  defp bot_address(_host, _port), do: nil

  @doc false
  @spec origin_of(term()) :: [String.t()]
  def origin_of(value) when is_binary(value) do
    uri = URI.parse(String.trim(value))
    host = if is_binary(uri.host), do: String.downcase(uri.host), else: uri.host
    origin_of(%{uri | host: host})
  end

  def origin_of(%URI{} = uri) do
    case uri do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        bracketed = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
        default = if scheme == "https", do: 443, else: 80
        suffix = if port in [nil, default], do: "", else: ":" <> Integer.to_string(port)
        [scheme <> "://" <> bracketed <> suffix]

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
