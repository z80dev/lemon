defmodule LemonControlPlane.Lifecycle.Driver do
  @moduledoc """
  Runtime side effects, replaceable with `:lemon_control_plane, :lifecycle_driver`
  in tests. Never log the command: source distribution arguments include a cookie.
  """

  @callback restart(map()) :: :ok | {:error, term()}
  @callback stop() :: :ok | {:error, term()}

  def restart(command) do
    File.mkdir_p!(Path.dirname(command.log_file))
    nohup = System.find_executable("nohup") || raise "nohup is unavailable"

    # All dynamic values are positional argv, never interpolated shell code.
    # The short-lived shell exits after spawning nohup; the orphaned launcher
    # ignores HUP and inherits no VM-owned stdin/stdout/stderr pipe.
    script = ~s(log=$1; shift; "$@" >>"$log" 2>&1 </dev/null &)

    args = [
      "-c",
      script,
      "lemon-lifecycle",
      command.log_file,
      nohup,
      command.launcher | command.args
    ]

    case System.cmd("/bin/sh", args, env: command.env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> {:error, :spawn_failed}
    end
  end

  def stop, do: System.stop(0)

  @doc false
  def restart_command(env \\ System.get_env(), distribution \\ distribution_args()) do
    port = Map.get(env, "LEMON_CONTROL_PLANE_PORT", "4040")
    home = Map.get(env, "HOME", LemonCore.Paths.home_dir())

    log =
      Map.get(
        env,
        "LEMON_RUNTIME_LOG_FILE",
        Path.join([home, ".lemon", "run", "lemon-#{port}.log"])
      )

    source? = env["LEMON_CLI_LAUNCHER"] == "source"

    %{
      launcher: env["LEMON_LAUNCHER"],
      args: ["restart" | if(source?, do: distribution, else: [])],
      log_file: log,
      # Other environment (including release node/cookie/distribution selection)
      # is inherited by System.cmd and by nohup, not rebuilt or exposed in RPC.
      env:
        Map.to_list(
          Map.take(
            env,
            ~w(HOME LEMON_CONTROL_PLANE_PORT LEMON_WEB_PORT LEMON_SIM_UI_PORT LEMON_RUNTIME_PID_FILE LEMON_RUNTIME_LOG_FILE)
          )
        )
    }
  end

  defp distribution_args do
    if Node.alive?() do
      {mode, name} =
        case :init.get_argument(:name) do
          {:ok, [[name] | _]} ->
            {"--name", List.to_string(name)}

          _ ->
            case :init.get_argument(:sname) do
              {:ok, [[name] | _]} -> {"--sname", List.to_string(name)}
              _ -> {"--name", Atom.to_string(Node.self())}
            end
        end

      [mode, name, "--cookie", Atom.to_string(Node.get_cookie())]
    else
      ["--no-distribution"]
    end
  end
end
