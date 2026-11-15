defmodule LemonCore.TerminalSandbox606Test do
  use ExUnit.Case, async: false

  alias LemonCore.TerminalBackends.Docker
  alias LemonCore.TerminalBackends.Docker.Sandbox
  alias LemonCore.ToolPolicy

  test "sandbox authority forces Docker even when a child requests another backend" do
    parent = ToolPolicy.parse!(%{sandbox: true})
    assert {:ok, child} = ToolPolicy.restrict(parent, %{sandbox: false})

    for requested <- [:local, :local_pty, :ssh, :docker, "unknown"] do
      assert {:ok, :docker} = Sandbox.backend(backend: requested, tool_policy: child)
    end

    assert {:ok, :local} = Sandbox.backend([])
    assert {:error, _} = Sandbox.backend(tool_policy: %{sandbox: "false"})
  end

  test "Docker argv enforces no network independently of operator network and client proxy env" do
    names = ["LEMON_DOCKER_TERMINAL_NETWORK", "LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS"]
    original = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env("LEMON_DOCKER_TERMINAL_NETWORK", "host")
    System.put_env("LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS", "false")

    descriptor = %{directory: "/private/broker-public", uid: 1000, gid: 1000}

    args =
      Docker.args(
        "printf safe",
        "/workspace/project",
        %{
          "HTTPS_PROXY" => "http://attacker:8080",
          "NO_PROXY" => "*",
          "VISIBLE" => "ok"
        },
        descriptor
      )

    pairs = Enum.chunk_every(args, 2, 1, :discard)
    assert ["--network", "none"] in pairs
    refute ["--network", "host"] in pairs
    assert "--read-only" in args
    assert ["--cap-drop", "ALL"] in pairs
    assert ["--security-opt", "no-new-privileges"] in pairs
    assert ["--user", "1000:1000"] in pairs
    assert ["--volume", "/private/broker-public:/run/lemon-egress:ro"] in pairs
    assert ["--env", "HTTPS_PROXY=http://127.0.0.1:18080"] in pairs
    assert ["--env", "NO_PROXY="] in pairs
    refute Enum.any?(args, &String.contains?(&1, "attacker"))
    assert ["--entrypoint", "python3"] in pairs
    assert Enum.take(args, -3) == ["-I", "/run/lemon-egress/adapter.py", "printf safe"]
    refute Enum.any?(args, &String.contains?(&1, "docker.sock"))
  end

  test "ordinary Docker still uses the configured non-sandbox backend" do
    args = Docker.args("echo ok", "/work", %{"EXPLICIT" => "value"})
    assert ["--env", "EXPLICIT=value"] in Enum.chunk_every(args, 2, 1, :discard)
    assert Enum.take(args, -3) == ["/bin/sh", "-lc", "echo ok"]
    refute Enum.any?(args, &String.contains?(&1, "/run/lemon-egress"))
  end
end
