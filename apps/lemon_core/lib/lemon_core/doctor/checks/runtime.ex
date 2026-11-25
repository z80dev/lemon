defmodule LemonCore.Doctor.Checks.Runtime do
  @moduledoc """
  Checks the build identity, control-plane port and `LEMON_PATH`.

  The Lemon application's Elixir toolchain floor is not a lemon_core concern
  (the package supports every Elixir its mix.exs declares); `lemon doctor`
  reports it from `LemonCli.Doctor.Toolchain`.
  """

  alias LemonCore.Doctor.Check
  alias LemonCore.Runtime.{Env, Health}

  @doc """
  Returns a list of Check results covering runtime readiness.

  Option: `:env` (a `LemonCore.Runtime.Env`, default `Env.resolve/0`).
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &Env.resolve/0)

    [Check.pass("runtime.build", LemonCore.BuildInfo.describe())] ++
      check_runtime(env) ++ [check_lemon_root(System.get_env("LEMON_PATH"))]
  end

  # One /healthz probe yields two checks: whether a Lemon control plane answers
  # on the port, and whether that runtime runs every application its profile
  # expects (an application that failed to start or stopped is named).
  defp check_runtime(env) do
    port = env.control_port

    case Health.check(port, timeout_ms: 500) do
      {:ok, :healthy} ->
        [
          Check.pass("runtime.control_port", "Control-plane is listening on port #{port}."),
          Check.pass(
            "runtime.apps",
            "The runtime on port #{port} runs every expected application."
          )
        ]

      {:error, {:unhealthy, missing}} ->
        [
          Check.pass("runtime.control_port", "Control-plane is answering on port #{port}."),
          Check.fail(
            "runtime.apps",
            "The runtime on port #{port} is not running expected applications: " <>
              Enum.join(missing, ", ") <> ".",
            "An application failed to start or stopped. Check the runtime log for the cause, " <>
              "then run `lemon restart`."
          )
        ]

      {:error, _} ->
        [
          check_unanswered_port(port),
          Check.skip("runtime.apps", "No Lemon runtime answered on port #{port}.")
        ]
    end
  end

  defp check_unanswered_port(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        Check.fail(
          "runtime.control_port",
          "Port #{port} is occupied, but no healthy Lemon control-plane answered.",
          "Inspect the process using this port. Stop the unhealthy runtime with `lemon stop` " <>
            "or choose another port with `lemon setup runtime --control-port PORT`; do not start another daemon on this port."
        )

      {:error, _} ->
        Check.skip(
          "runtime.control_port",
          "Control-plane not running on port #{port}. Run `lemon` to start a coding session."
        )
    end
  end

  # Only an explicit LEMON_PATH is checked. Without it, Env.lemon_root/0 falls
  # back to a compile-time path, which in a release names the build machine.
  defp check_lemon_root(root) when root in [nil, ""] do
    Check.skip("runtime.lemon_root", "LEMON_PATH is not set.")
  end

  # Doctor output is shared, so the path is shown as a label (it may contain
  # spaces that text redaction cannot delimit).
  defp check_lemon_root(root) do
    label = LemonCore.Doctor.Redaction.path_label(root)

    if File.dir?(root) do
      Check.pass("runtime.lemon_root", "Lemon root directory exists: #{label}")
    else
      Check.warn(
        "runtime.lemon_root",
        "LEMON_PATH points to a non-existent directory: #{label}",
        "Fix LEMON_PATH or unset it."
      )
    end
  end
end
