defmodule LemonCli.LauncherLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @root Path.expand("../../../..", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    release = Path.join(tmp_dir, "release")
    tools = Path.join(tmp_dir, "tools")
    home = Path.join(tmp_dir, "home")

    for dir <- [Path.join(source, "bin"), Path.join(release, "bin"), tools, home] do
      File.mkdir_p!(dir)
    end

    File.cp!(Path.join(@root, "bin/lemon"), Path.join(source, "bin/lemon"))
    registry = "apps/lemon_cli/lib/lemon_cli/command_registry.ex"
    File.mkdir_p!(Path.dirname(Path.join(source, registry)))
    File.cp!(Path.join(@root, registry), Path.join(source, registry))
    File.cp!(Path.join(@root, "rel/overlays/bin/lemon"), Path.join(release, "bin/lemon"))

    executable(Path.join(tools, "mix"), "echo 'unexpected Mix invocation' >&2; exit 99")
    executable(Path.join(tools, "curl"), "printf '%s' \"${TEST_HEALTH:-}\"")
    executable(Path.join(tools, "sleep"), "exit 0")

    executable(Path.join(release, "bin/lemon_runtime_min"), """
    case "$1" in
      daemon) exit 0 ;;
      pid) printf '%s\\n' "$TEST_RUNTIME_PID" ;;
      *) echo 'unexpected release invocation' >&2; exit 99 ;;
    esac
    """)

    overrides =
      ~w(LEMON_CONTROL_PLANE_OPERATOR_TOKEN LEMON_RUNTIME_PID_FILE LEMON_RUNTIME_LOG_FILE
      LEMON_CONTROL_PLANE_PORT LEMON_WEB_PORT LEMON_SIM_UI_PORT RELEASE_TMP RELEASE_COOKIE)

    env =
      Enum.map(overrides, &{&1, nil}) ++
        [
          {"HOME", home},
          {"PATH", tools <> ":" <> System.get_env("PATH")},
          {"LEMON_CONTROL_PLANE_PORT", Integer.to_string(free_port())},
          {"LEMON_WEB_PORT", "49180"},
          {"LEMON_SIM_UI_PORT", "49190"},
          {"LEMON_SECRETS_MASTER_KEY", String.duplicate("a", 64)},
          {"RELEASE_COOKIE", "isolated-launcher-test"},
          {"LEMON_WEB_SECRET_KEY_BASE", String.duplicate("b", 64)},
          {"ERL_FLAGS", "+S 2:2"}
        ]

    {:ok, source: source, release: release, tools: tools, home: home, env: env}
  end

  test "source help reads the registry without Mix or HOME mutation", ctx do
    for args <- [
          ["--help"],
          ["-h"],
          ["help", "start"],
          ["start", "--help"],
          ["setup", "--help"],
          ["gateway", "setup", "--help"],
          ["-p", "--help"]
        ] do
      assert {output, 0} = launch(ctx.source, args, ctx.env)
      assert output =~ "Usage: lemon"
      refute output =~ "unexpected Mix"
      refute File.exists?(Path.join(ctx.home, ".lemon"))
      refute File.exists?(Path.join(ctx.source, "_build"))
    end
  end

  test "source help preserves invalid and release-only command exit codes", ctx do
    for command <- ~w(not-a-command remote eval rpc) do
      assert {output, 2} = launch(ctx.source, ["help", command], ctx.env)
      assert output =~ if(command == "not-a-command", do: "Unknown command", else: "packaged release")
      refute output =~ "unexpected Mix"
      refute File.exists?(Path.join(ctx.home, ".lemon"))
    end
  end

  test "source explains missing Elixir and Mix", ctx do
    bare = Path.join(ctx.tools, "bare")
    File.mkdir_p!(bare)
    File.ln_s!(System.find_executable("dirname"), Path.join(bare, "dirname"))
    assert {output, 1} = launch(ctx.source, ["--help"], put(ctx.env, "PATH", bare))
    assert output =~ "Elixir and Mix are required for a source checkout"
    assert output =~ "docs/install.md"
  end

  test "both launchers explain missing curl instead of reporting stopped", ctx do
    bare = Path.join(ctx.tools, "bare")
    File.mkdir_p!(bare)
    File.ln_s!(System.find_executable("dirname"), Path.join(bare, "dirname"))

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], put(ctx.env, "PATH", bare))
      assert output =~ "curl is required for health checks; install it and retry"
      refute output =~ "not running"
    end
  end

  test "source validates every lifecycle port flag before probes or mutation", ctx do
    for command <- ~w(start daemon status stop restart),
        flag <- ~w(--port --web-port --sim-port),
        value <- ~w(abc 0 65536 999999 12345678901234567890 -1) do
      assert {output, 2} = launch(ctx.source, [command, flag, value], ctx.env)
      assert output =~ "invalid port value: #{value} (expected 1-65535)"
      refute File.exists?(Path.join(ctx.home, ".lemon"))
    end
  end

  test "both launchers reject invalid environment ports", ctx do
    for root <- [ctx.source, ctx.release],
        name <- ~w(LEMON_CONTROL_PLANE_PORT LEMON_WEB_PORT LEMON_SIM_UI_PORT),
        value <- ~w(abc 0 65536 999999) do
      assert {output, 2} = launch(root, ["status"], put(ctx.env, name, value))
      assert output =~ "invalid port value: #{value} (expected 1-65535)"
    end
  end

  test "both statuses show selected home, web, sim, logs and fail when stopped", ctx do
    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], ctx.env)
      assert output =~ "no Lemon runtime answers on port"
      assert output =~ "home: #{ctx.home}/.lemon"
      assert output =~ "web: port 49180"
      assert output =~ "sim: port 49190"
      assert output =~ "log: "
      refute output =~ "pid record"
    end
  end

  test "both statuses recognize a healthy foreground or externally managed runtime", ctx do
    env = put(ctx.env, "TEST_HEALTH", ~s({"ok":true}))

    for root <- [ctx.source, ctx.release] do
      assert {output, 0} = launch(root, ["status"], env)
      assert output =~ "running, healthy on port"
      assert output =~ "not managed by this HOME"
      assert output =~ "(launcher)"
    end
  end

  test "packaged status fails for a live pid with unreachable control plane", ctx do
    state = Path.join(ctx.home, ".lemon/run")
    File.mkdir_p!(state)
    port = env_value(ctx.env, "LEMON_CONTROL_PLANE_PORT")
    File.write!(Path.join(state, "lemon-#{port}.pid"), System.pid() <> "\n")
    assert {output, 1} = launch(ctx.release, ["status"], ctx.env)
    assert output =~ "running (pid #{System.pid()})"
    assert output =~ "control-plane not reachable"
  end

  test "stop and restart refuse foreign listeners without invoking Mix", ctx do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, port} = :inet.port(socket)
    env = put(ctx.env, "LEMON_CONTROL_PLANE_PORT", Integer.to_string(port))

    for root <- [ctx.source, ctx.release], command <- ~w(stop restart) do
      assert {output, 1} = launch(root, [command], env)
      assert output =~ "port #{port} answers but is not managed by this HOME"
      assert output =~ "stop it where it runs"
      refute output =~ "unexpected Mix"
      refute output =~ "reusing it"
    end
  end

  test "source restart from stopped skips the stop error and reaches compilation", ctx do
    assert {output, 99} = launch(ctx.source, ["restart", "--no-distribution"], ctx.env)
    assert output =~ "unexpected Mix invocation"
    refute output =~ "no process was signalled"
    refute output =~ "not running"
  end

  test "packaged start and daemon reject an occupied non-Lemon port before boot", ctx do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, port} = :inet.port(socket)
    env = put(ctx.env, "LEMON_CONTROL_PLANE_PORT", Integer.to_string(port))

    for command <- ~w(start daemon) do
      assert {output, 1} = launch(ctx.release, [command], env)
      assert output =~ "port #{port} is occupied but does not answer Lemon health checks"
      assert output =~ "LEMON_CONTROL_PLANE_PORT"
      refute output =~ "unexpected release"
    end
  end

  test "packaged health timeout terminates its launch and removes both records", ctx do
    sleeper =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["120"]])

    {:os_pid, pid} = Port.info(sleeper, :os_pid)
    on_exit(fn -> if Port.info(sleeper), do: Port.close(sleeper) end)
    env = put(ctx.env, "TEST_RUNTIME_PID", Integer.to_string(pid))

    assert {output, 1} = launch(ctx.release, ["daemon"], env)
    assert output =~ "runtime did not become healthy"
    assert output =~ "see #{ctx.release}/tmp/log"
    port = env_value(ctx.env, "LEMON_CONTROL_PLANE_PORT")
    refute File.exists?(Path.join(ctx.home, ".lemon/run/lemon-#{port}.pid"))
    refute File.exists?(Path.join(ctx.home, ".lemon/run/lemon-#{port}.root"))

    assert {_, status} =
             System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    assert status != 0
  end

  defp launch(root, args, env) do
    System.cmd("/bin/bash", [Path.join(root, "bin/lemon") | args],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp executable(path, body) do
    File.write!(path, "#!/bin/bash\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  defp put(env, key, value), do: [{key, value} | Enum.reject(env, &(elem(&1, 0) == key))]

  defp env_value(env, key),
    do: env |> Enum.reverse() |> Enum.find_value(fn {k, v} -> if k == key, do: v end)

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
