defmodule LemonCore.Runtime.Env do
  @moduledoc """
  Environment resolution for Lemon runtime startup.

  Centralises all the environment-variable defaults and path normalization that
  previously lived in `bin/lemon` and `bin/lemon-dev` shell scripts.

  ## Port defaults

  | Port       | Env var                    | Default |
  |------------|---------------------------|---------|
  | control    | `LEMON_CONTROL_PLANE_PORT` | 4040    |
  | web        | `LEMON_WEB_PORT`           | 4080    |
  | sim        | `LEMON_SIM_UI_PORT`        | 4090    |

  ## Usage

      env = LemonCore.Runtime.Env.resolve()
      env.control_port   #=> 4040
      env.web_port       #=> 4080
      env.lemon_root     #=> "/path/to/lemon"
  """

  @default_control_port 4040
  @default_web_port 4080
  @default_sim_port 4090
  @lemon_web_endpoint :"Elixir.LemonWeb.Endpoint"
  @lemon_sim_ui_endpoint :"Elixir.LemonSimUi.Endpoint"

  defstruct control_port: @default_control_port,
            web_port: @default_web_port,
            sim_port: @default_sim_port,
            lemon_root: nil,
            dotenv_dir: nil,
            debug: false,
            node_name: "lemon",
            node_cookie: nil

  @type t :: %__MODULE__{
          control_port: pos_integer(),
          web_port: pos_integer(),
          sim_port: pos_integer(),
          lemon_root: String.t() | nil,
          dotenv_dir: String.t() | nil,
          debug: boolean(),
          node_name: String.t(),
          node_cookie: String.t() | nil
        }

  @doc """
  Resolves the runtime environment from system environment variables and defaults.
  """
  @spec resolve() :: t()
  def resolve do
    %__MODULE__{
      control_port: resolve_port("LEMON_CONTROL_PLANE_PORT", @default_control_port),
      web_port: resolve_port("LEMON_WEB_PORT", @default_web_port),
      sim_port: resolve_port("LEMON_SIM_UI_PORT", @default_sim_port),
      lemon_root: lemon_root(),
      dotenv_dir: System.get_env("LEMON_DOTENV_DIR"),
      debug: debug?(),
      node_name: node_name(),
      node_cookie: node_cookie()
    }
  end

  @doc """
  Returns the Lemon project root directory.

  Reads `LEMON_PATH` if set; falls back to the directory two levels above
  this file's location (i.e. the umbrella root when running from source).
  """
  @spec lemon_root() :: String.t()
  def lemon_root do
    case System.get_env("LEMON_PATH") do
      nil -> Path.expand("../../../../..", __DIR__)
      "" -> Path.expand("../../../../..", __DIR__)
      path -> path
    end
  end

  @doc """
  Returns the effective control-plane port.
  """
  @spec control_port() :: pos_integer()
  def control_port, do: resolve_port("LEMON_CONTROL_PLANE_PORT", @default_control_port)

  @doc """
  Returns the effective web port.
  """
  @spec web_port() :: pos_integer()
  def web_port, do: resolve_port("LEMON_WEB_PORT", @default_web_port)

  @doc """
  Returns the effective sim-ui port.
  """
  @spec sim_port() :: pos_integer()
  def sim_port, do: resolve_port("LEMON_SIM_UI_PORT", @default_sim_port)

  @doc """
  Returns `true` when debug mode is enabled via `LEMON_DEBUG` or `LEMON_LOG_LEVEL=debug`.
  """
  @spec debug?() :: boolean()
  def debug? do
    System.get_env("LEMON_DEBUG") in ["1", "true"] or
      System.get_env("LEMON_LOG_LEVEL") == "debug"
  end

  @doc """
  Returns the Erlang node name to use (defaults to `"lemon"`).
  """
  @spec node_name() :: String.t()
  def node_name do
    System.get_env("LEMON_GATEWAY_NODE_NAME") || "lemon"
  end

  @doc """
  Returns the Erlang distribution cookie.
  """
  @spec node_cookie() :: String.t() | nil
  def node_cookie do
    case System.get_env("LEMON_GATEWAY_NODE_COOKIE") || System.get_env("LEMON_GATEWAY_COOKIE") do
      nil -> nil
      "" -> nil
      cookie -> cookie
    end
  end

  @dev_cookie "lemon_gateway_dev_cookie"

  @doc """
  Validates that a production-grade cookie has been configured.

  Raises `RuntimeError` if the cookie is the hardcoded dev default.  Call this
  from the boot sequence when running in a production context (e.g. when
  `RELEASE_NODE` is set or `MIX_ENV=prod`).
  """
  @spec require_prod_cookie!() :: :ok
  def require_prod_cookie! do
    case node_cookie() do
      nil ->
        raise RuntimeError,
          message:
            "Production boot requires an explicit Erlang distribution cookie. " <>
              "Set LEMON_GATEWAY_NODE_COOKIE or LEMON_GATEWAY_COOKIE to a " <>
              "strong random secret."

      @dev_cookie ->
        raise RuntimeError,
          message:
            "Production boot requires an explicit Erlang distribution cookie. " <>
              "Set LEMON_GATEWAY_NODE_COOKIE or LEMON_GATEWAY_COOKIE to a " <>
              "strong random secret (not the default dev cookie)."

      _cookie ->
        :ok
    end
  end

  @doc """
  Applies resolved port values to the OTP application environment so running
  apps pick up the right port without restarts.

  Safe to call multiple times (idempotent).
  """
  @spec apply_ports(t()) :: :ok
  def apply_ports(%__MODULE__{} = env) do
    apply_control_port(env.control_port)
    apply_web_port(env.web_port)
    apply_sim_port(env.sim_port)
    :ok
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp resolve_port(env_var, default) do
    case System.get_env(env_var) do
      nil ->
        default

      "" ->
        default

      raw ->
        case Integer.parse(raw) do
          {port, ""} when port > 0 and port <= 65535 -> port
          _ -> default
        end
    end
  end

  defp apply_control_port(port) do
    Application.put_env(:lemon_control_plane, :port, port)
  end

  defp apply_web_port(port) do
    existing = Application.get_env(:lemon_web, @lemon_web_endpoint, [])
    existing_http = Keyword.get(existing, :http, [])
    merged_http = Keyword.merge(existing_http, ip: {127, 0, 0, 1}, port: port)

    Application.put_env(
      :lemon_web,
      @lemon_web_endpoint,
      Keyword.put(existing, :http, merged_http)
    )
  end

  defp apply_sim_port(port) do
    existing = Application.get_env(:lemon_sim_ui, @lemon_sim_ui_endpoint, [])

    Application.put_env(
      :lemon_sim_ui,
      @lemon_sim_ui_endpoint,
      Keyword.merge(existing, server: true, http: [ip: {127, 0, 0, 1}, port: port])
    )
  end
end
