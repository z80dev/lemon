defmodule LemonCore.Doctor.Checks.Runtime do
  @moduledoc "Checks the supported Elixir toolchain, port availability and running apps."

  alias LemonCore.Doctor.Check
  alias LemonCore.Runtime.{Env, Health}

  @doc """
  Returns a list of Check results covering runtime readiness.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    env = Env.resolve()

    [
      Check.pass("runtime.build", LemonCore.Update.Version.describe()),
      check_elixir(Keyword.get(opts, :elixir_version, System.version())),
      check_control_port(env),
      check_lemon_root(System.get_env("LEMON_PATH"))
    ]
  end

  defp check_elixir(version) do
    supported? =
      case Version.parse(version) do
        {:ok, parsed} -> Version.compare(parsed, "1.20.5") != :lt
        :error -> false
      end

    if supported? do
      Check.pass("runtime.elixir", "Elixir #{version} meets the minimum version 1.20.5.")
    else
      Check.fail(
        "runtime.elixir",
        "Elixir #{version} is unsupported; Lemon requires Elixir 1.20.5 or newer.",
        "Upgrade Elixir to 1.20.5+ (with OTP 29.1.2+), then rerun `lemon doctor`."
      )
    end
  end

  defp check_control_port(env) do
    port = env.control_port

    if Health.running?(port, timeout_ms: 500) do
      Check.pass(
        "runtime.control_port",
        "Control-plane is listening on port #{port}."
      )
    else
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
  end

  # Only an explicit LEMON_PATH is checked. Without it, Env.lemon_root/0 falls
  # back to a compile-time path, which in a release names the build machine.
  defp check_lemon_root(root) when root in [nil, ""] do
    Check.skip("runtime.lemon_root", "LEMON_PATH is not set.")
  end

  defp check_lemon_root(root) do
    if File.dir?(root) do
      Check.pass("runtime.lemon_root", "Lemon root directory exists: #{root}")
    else
      Check.warn(
        "runtime.lemon_root",
        "LEMON_PATH points to a non-existent directory: #{root}",
        "Fix LEMON_PATH or unset it."
      )
    end
  end
end
