defmodule LemonControlPlane.Methods.SystemLifecycleTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.{Lifecycle, WS.Connection}
  alias LemonControlPlane.Lifecycle.Driver
  alias LemonControlPlane.Methods.{Registry, SystemRestart, SystemStop}

  @moduletag :tmp_dir

  defmodule FakeDriver do
    @behaviour Driver
    def restart(command) do
      send(
        Application.fetch_env!(:lemon_control_plane, :lifecycle_test_pid),
        {:acted, :restart, command}
      )

      :ok
    end

    def stop do
      send(Application.fetch_env!(:lemon_control_plane, :lifecycle_test_pid), {:acted, :stop})
      :ok
    end
  end

  setup do
    keys =
      ~w(LEMON_LAUNCHER LEMON_CLI_LAUNCHER LEMON_CONTROL_PLANE_PORT LEMON_WEB_PORT LEMON_SIM_UI_PORT)

    previous = Map.new(keys, &{&1, System.get_env(&1)})
    old_driver = Application.get_env(:lemon_control_plane, :lifecycle_driver)
    old_pid = Application.get_env(:lemon_control_plane, :lifecycle_test_pid)
    System.delete_env("LEMON_LAUNCHER")
    Application.put_env(:lemon_control_plane, :lifecycle_driver, FakeDriver)
    Application.put_env(:lemon_control_plane, :lifecycle_test_pid, self())
    restart_coordinator()

    on_exit(fn ->
      restart_coordinator()
      restore_app(:lifecycle_driver, old_driver)
      restore_app(:lifecycle_test_pid, old_pid)

      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "registered methods require admin; read, write and node callers are forbidden" do
    for method <- ["system.restart", "system.stop"] do
      assert method in Registry.list_methods()
      assert LemonControlPlane.Auth.Authorize.required_scopes(method) == [:admin]

      for auth <- [
            %{role: :operator, scopes: [:read]},
            %{role: :operator, scopes: [:write]},
            %{role: :node, scopes: [:invoke, :event]}
          ] do
        assert {:error, {:forbidden, _}} =
                 Registry.dispatch(method, %{}, %{auth: auth, conn_pid: self()})
      end
    end

    assert SystemRestart.scopes() == [:admin]
    assert SystemStop.scopes() == [:admin]
    refute_receive {:acted, _}, 20
  end

  test "restart is unavailable without a launcher, matching status" do
    assert {:error, {:unavailable, reason}} = SystemRestart.handle(%{}, context())
    assert reason == Lifecycle.availability()["reason"]
    assert Lifecycle.availability()["restart"] == false
    refute_receive {:lifecycle_after_reply, _}, 20
  end

  test "stop returns acceptance first and acts only after the socket post-reply turn" do
    state = state()
    request = Jason.encode!(%{type: "req", id: "stop-1", method: "system.stop", params: %{}})
    before = System.system_time(:millisecond)

    assert {:push, {:text, wire}, ^state} =
             Connection.handle_in({request, [opcode: :text]}, state)

    assert %{"id" => "stop-1", "ok" => true, "payload" => payload} = Jason.decode!(wire)
    assert payload["accepted"] == true
    assert payload["action"] == "stop"
    assert payload["acceptedAtMs"] >= before
    assert_receive {:lifecycle_after_reply, ref}
    refute_receive {:acted, :stop}, 300
    assert {:ok, ^state} = Connection.handle_info({:lifecycle_after_reply, ref}, state)
    refute_receive {:acted, :stop}, 100
    assert_receive {:acted, :stop}, 1000
  end

  test "restart is single-flight across both methods and preserves source flags and ports" do
    System.put_env("LEMON_LAUNCHER", "/test/launcher with spaces")
    System.put_env("LEMON_CLI_LAUNCHER", "source")
    System.put_env("LEMON_CONTROL_PLANE_PORT", "49040")
    System.put_env("LEMON_WEB_PORT", "49080")
    System.put_env("LEMON_SIM_UI_PORT", "49090")

    assert {:ok, %{"accepted" => true, "action" => "restart", "acceptedAtMs" => at}} =
             Registry.dispatch("system.restart", %{}, context())

    assert is_integer(at)
    assert_receive {:lifecycle_after_reply, ref}
    assert {:error, {:conflict, _}} = Registry.dispatch("system.stop", %{}, context())
    assert {:error, {:conflict, _}} = Registry.dispatch("system.restart", %{}, context())
    Connection.handle_info({:lifecycle_after_reply, ref}, state())
    assert_receive {:acted, :restart, command}, 1000
    assert command.launcher == "/test/launcher with spaces"
    assert command.args == ["restart", "--no-distribution"]
    assert Map.new(command.env)["LEMON_CONTROL_PLANE_PORT"] == "49040"
    assert Map.new(command.env)["LEMON_WEB_PORT"] == "49080"
    assert Map.new(command.env)["LEMON_SIM_UI_PORT"] == "49090"
    assert command.log_file =~ "lemon-49040.log"
    assert {:error, {:conflict, _}} = SystemStop.handle(%{}, context())
  end

  test "source distributed argv is preserved and packaged launchers receive only restart" do
    env = %{
      "HOME" => "/isolated/home",
      "LEMON_LAUNCHER" => "/release/bin/lemon",
      "LEMON_CLI_LAUNCHER" => "source",
      "LEMON_CONTROL_PLANE_PORT" => "49140"
    }

    for flags <- [
          ["--name", "lemon@host.example", "--cookie", "private-cookie"],
          ["--sname", "lemon", "--cookie", "private-cookie"],
          ["--no-distribution"]
        ] do
      assert Driver.restart_command(env, flags).args == ["restart" | flags]
    end

    assert Driver.restart_command(Map.put(env, "LEMON_CLI_LAUNCHER", "release"), [
             "--no-distribution"
           ]).args == ["restart"]

    assert Driver.restart_command(
             Map.put(env, "LEMON_RUNTIME_LOG_FILE", "/isolated/logs/runtime.log"),
             []
           ).log_file ==
             "/isolated/logs/runtime.log"
  end

  test "nonempty params are rejected without accepting an action" do
    assert {:error, {:invalid_request, _}} = SystemRestart.handle(%{"force" => true}, context())
    assert {:error, {:invalid_request, _}} = SystemStop.handle(%{"anything" => true}, context())
    refute_receive {:lifecycle_after_reply, _}, 20
  end

  test "detached launcher survives the parent VM exiting and receives literal argv/environment",
       %{tmp_dir: tmp_dir} do
    launcher = Path.join(tmp_dir, "launcher with spaces;literal")
    release = Path.join(tmp_dir, "release-child")
    output = Path.join(tmp_dir, "argv-and-env")
    log = Path.join(tmp_dir, "runtime.log")

    File.write!(launcher, """
    #!/bin/sh
    attempt=0
    while [ ! -f "$LB_RELEASE_FILE" ] && [ "$attempt" -lt 200 ]; do
      sleep 0.05
      attempt=$((attempt + 1))
    done
    # Publish atomically: a plain `>` redirect creates the file before printf writes it,
    # so the test could observe an existing-but-empty output file.
    printf '%s\\n' "$@" "$LEMON_CONTROL_PLANE_PORT" "$LEMON_WEB_PORT" "$LEMON_SIM_UI_PORT" > "$LB_OUTPUT_FILE.tmp"
    mv "$LB_OUTPUT_FILE.tmp" "$LB_OUTPUT_FILE"
    echo launcher-output
    """)

    File.chmod!(launcher, 0o700)

    on_exit(fn ->
      File.write(release, "release")
      File.rm_rf(tmp_dir)
    end)

    command = %{
      launcher: launcher,
      args: ["restart", "--no-distribution"],
      log_file: log,
      env: [
        {"LB_RELEASE_FILE", release},
        {"LB_OUTPUT_FILE", output},
        {"LEMON_CONTROL_PLANE_PORT", "49240"},
        {"LEMON_WEB_PORT", "49280"},
        {"LEMON_SIM_UI_PORT", "49290"}
      ]
    }

    beam_path = Driver |> :code.which() |> List.to_string() |> Path.dirname()

    code =
      " :ok = LemonControlPlane.Lifecycle.Driver.restart(#{inspect(command)}); System.stop(0)"

    assert {_, 0} =
             System.cmd(System.find_executable("elixir"), ["-pa", beam_path, "-e", code],
               stderr_to_stdout: true
             )

    refute File.exists?(output)
    File.write!(release, "parent exited")
    assert eventually(fn -> File.exists?(output) end)
    assert File.read!(output) == "restart\n--no-distribution\n49240\n49280\n49290\n"

    assert eventually(fn ->
             File.exists?(log) and String.contains?(File.read!(log), "launcher-output")
           end)
  end

  defp context,
    do: %{auth: %{role: :operator, scopes: [:admin]}, conn_pid: self(), conn_id: "lifecycle-test"}

  defp state,
    do: %Connection{
      conn_id: "lifecycle-test",
      connected: true,
      auth: context().auth,
      event_seq: 0,
      state_version: %{}
    }

  defp restart_coordinator do
    :ok = Supervisor.terminate_child(LemonControlPlane.Supervisor, Lifecycle)
    {:ok, _} = Supervisor.restart_child(LemonControlPlane.Supervisor, Lifecycle)
  end

  defp restore_app(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore_app(key, value), do: Application.put_env(:lemon_control_plane, key, value)
  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end
end
