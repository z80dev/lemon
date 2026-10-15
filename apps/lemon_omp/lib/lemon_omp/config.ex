defmodule LemonOmp.Config do
  @moduledoc """
  Runtime settings for the omp delegate.

  Every value is advisory: an unparseable environment value falls back to the
  application default rather than failing boot. Precedence is environment
  variable (declared in `LemonOmp.Env`), then `config :lemon_omp`, then the
  built-in default.

    * `:executable` / `LEMON_OMP_BIN` — the `omp` binary. Defaults to the first
      `omp` on `PATH`.
    * `:max_sessions` / `LEMON_OMP_MAX_SESSIONS` — live omp processes Lemon may
      own at once (default 4).
    * `:idle_timeout_ms` / `LEMON_OMP_IDLE_TIMEOUT_MS` — an idle process (no turn
      in flight) is closed after this long; its session file stays resumable
      (default 30 minutes, `0` disables).
    * `:approvals` / `LEMON_OMP_APPROVALS` — `bridge` (default) routes omp tool
      approval selects to Lemon's shared approval prompts; `decline` cancels them.
    * `:approval_timeout_ms` / `LEMON_OMP_APPROVAL_TIMEOUT_MS` — maximum time to
      wait for approval (default 600000 ms), capped by omp's dialog timeout.
    * `:session_dir` / `LEMON_OMP_SESSION_DIR` — Lemon's flat omp history
      directory (default `<LemonCore.Paths.home_state_dir()>/omp/sessions`).
      `"omp"` opts out and uses omp's own per-workspace default.
    * `:agent_dir` / `PI_CODING_AGENT_DIR` — omp's agent directory, used only for
      read-only session discovery (default `~/<PI_CONFIG_DIR or .omp>/agent`).
  """

  @default_max_sessions 4
  @default_idle_timeout_ms 30 * 60 * 1000
  @default_ready_timeout_ms 30_000
  @default_command_timeout_ms 15_000
  @default_approval_timeout_ms 600_000

  @spec executable() :: String.t() | nil
  def executable do
    configured = env("LEMON_OMP_BIN") || Application.get_env(:lemon_omp, :executable)

    case configured do
      value when is_binary(value) and value != "" -> resolve_executable(value)
      _ -> System.find_executable("omp")
    end
  end

  defp resolve_executable(value) do
    cond do
      String.contains?(value, "/") ->
        expanded = Path.expand(value)
        if File.regular?(expanded), do: expanded

      true ->
        System.find_executable(value)
    end
  end

  @spec max_sessions() :: pos_integer()
  def max_sessions do
    positive_int(env("LEMON_OMP_MAX_SESSIONS"), :max_sessions, @default_max_sessions)
  end

  @spec idle_timeout_ms() :: non_neg_integer()
  def idle_timeout_ms do
    case parse_int(env("LEMON_OMP_IDLE_TIMEOUT_MS")) do
      value when is_integer(value) and value >= 0 ->
        value

      _ ->
        case Application.get_env(:lemon_omp, :idle_timeout_ms, @default_idle_timeout_ms) do
          value when is_integer(value) and value >= 0 -> value
          _ -> @default_idle_timeout_ms
        end
    end
  end

  @spec ready_timeout_ms() :: pos_integer()
  def ready_timeout_ms,
    do: app_positive_int(:ready_timeout_ms, @default_ready_timeout_ms)

  @spec command_timeout_ms() :: pos_integer()
  def command_timeout_ms,
    do: app_positive_int(:command_timeout_ms, @default_command_timeout_ms)

  @spec approvals() :: :bridge | :decline
  def approvals do
    case env("LEMON_OMP_APPROVALS") do
      "bridge" ->
        :bridge

      "decline" ->
        :decline

      _ ->
        if Application.get_env(:lemon_omp, :approvals) in [:decline, "decline"],
          do: :decline,
          else: :bridge
    end
  end

  @spec approval_timeout_ms() :: pos_integer()
  def approval_timeout_ms,
    do:
      positive_int(
        env("LEMON_OMP_APPROVAL_TIMEOUT_MS"),
        :approval_timeout_ms,
        @default_approval_timeout_ms
      )

  @doc "omp's agent directory (session discovery root is `<agent_dir>/sessions`)."
  @spec agent_dir() :: String.t()
  def agent_dir do
    case Application.get_env(:lemon_omp, :agent_dir) || env("PI_CODING_AGENT_DIR") do
      value when is_binary(value) and value != "" ->
        Path.expand(value)

      _ ->
        config_dir =
          case env("PI_CONFIG_DIR") do
            value when is_binary(value) and value != "" -> value
            _ -> ".omp"
          end

        Path.join([System.user_home!(), config_dir, "agent"])
    end
  end

  @doc "Lemon's flat session directory, or nil to use omp's own default."
  @spec session_dir() :: String.t() | nil
  def session_dir do
    case parse_session_dir(env("LEMON_OMP_SESSION_DIR")) do
      {:ok, path} ->
        path

      :error ->
        case parse_session_dir(Application.get_env(:lemon_omp, :session_dir)) do
          {:ok, path} -> path
          :error -> Path.expand(Path.join(LemonCore.Paths.home_state_dir(), "omp/sessions"))
        end
    end
  end

  @doc "Effective history directory (flat for Lemon, per-workspace buckets for omp)."
  @spec sessions_dir() :: String.t()
  def sessions_dir, do: session_dir() || omp_sessions_dir()

  @doc "omp's own history root, read alongside Lemon's history without migration."
  @spec omp_sessions_dir() :: String.t()
  def omp_sessions_dir, do: Path.join(agent_dir(), "sessions")

  defp parse_session_dir(value) when is_binary(value) do
    if String.valid?(value) do
      case String.trim(value) do
        "omp" ->
          {:ok, nil}

        "" ->
          :error

        path ->
          if String.match?(path, ~r/[\x00-\x1f\x7f]/),
            do: :error,
            else: {:ok, Path.expand(path)}
      end
    else
      :error
    end
  end

  defp parse_session_dir(_value), do: :error

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp positive_int(env_value, key, default) do
    case parse_int(env_value) do
      value when is_integer(value) and value > 0 -> value
      _ -> app_positive_int(key, default)
    end
  end

  defp app_positive_int(key, default) do
    case Application.get_env(:lemon_omp, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
