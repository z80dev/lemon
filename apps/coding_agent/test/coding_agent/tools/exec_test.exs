defmodule CodingAgent.Tools.ExecTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.Exec
  alias CodingAgent.ProcessStore

  setup do
    # Clear all processes before each test
    try do
      ProcessStore.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "tool/2" do
    test "returns tool definition" do
      tool = Exec.tool("/tmp")

      assert tool.name == "exec"
      assert tool.label == "Execute Background Process"
      assert is_map(tool.parameters)
      assert is_function(tool.execute, 4)

      assert tool.parameters["properties"]["backend"]["enum"] == [
               "local",
               "local_pty",
               "docker",
               "ssh"
             ]
    end
  end

  describe "execute/4 sync mode" do
    test "executes command synchronously" do
      tool = Exec.tool("/tmp")

      result = tool.execute.("call_1", %{"command" => "echo hello"}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "hello"
      assert result.details.status == "completed"
      assert result.details.exit_code == 0
      assert result.details.backend == :local
    end

    test "accepts the local backend explicitly" do
      tool = Exec.tool("/tmp")

      result =
        tool.execute.("call_1", %{"command" => "echo hello", "backend" => "local"}, nil, nil)

      assert result.details.status == "completed"
      assert result.details.backend == :local
    end

    test "rejects unknown backends" do
      tool = Exec.tool("/tmp")

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"command" => "echo hello", "backend" => "unknown-docker"},
                 nil,
                 nil
               )

      assert reason =~ "Unknown terminal backend"
    end

    test "rejects backends blocked by policy" do
      previous = System.get_env("LEMON_TERMINAL_BACKENDS_DENY")
      System.put_env("LEMON_TERMINAL_BACKENDS_DENY", "local")

      on_exit(fn ->
        if previous do
          System.put_env("LEMON_TERMINAL_BACKENDS_DENY", previous)
        else
          System.delete_env("LEMON_TERMINAL_BACKENDS_DENY")
        end
      end)

      tool = Exec.tool("/tmp")

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"command" => "echo hello", "backend" => "local"},
                 nil,
                 nil
               )

      assert reason =~ "blocked by policy"
    end

    test "requests approval for approval-required backend before execution" do
      previous = System.get_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL")
      System.put_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL", "local")

      on_exit(fn ->
        if previous do
          System.put_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL", previous)
        else
          System.delete_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL")
        end
      end)

      parent = self()

      tool =
        Exec.tool("/tmp",
          approval_context: %{
            run_id: "run-exec-approval",
            session_key: "agent:test:main",
            approval_request_fun: fn request ->
              send(parent, {:approval_request, request})
              {:ok, :approved, :once}
            end
          }
        )

      result =
        tool.execute.(
          "call_1",
          %{"command" => "echo approved", "env" => %{"SECRET_VALUE" => "not-visible"}},
          nil,
          nil
        )

      assert_receive {:approval_request, request}
      assert request.tool == "exec"
      assert request.action["backend"] == "local"
      assert request.action["envKeys"] == ["SECRET_VALUE"]
      refute inspect(request.action) =~ "not-visible"

      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "approved"
      assert result.details.status == "completed"
    end

    test "blocks approval-required backend when no approval context exists" do
      previous = System.get_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL")
      System.put_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL", "local")

      on_exit(fn ->
        if previous do
          System.put_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL", previous)
        else
          System.delete_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL")
        end
      end)

      tool = Exec.tool("/tmp")

      assert {:error, reason} =
               tool.execute.("call_1", %{"command" => "echo blocked"}, nil, nil)

      assert reason =~ "requires approval"
    end

    test "runs with docker backend when Docker is usable" do
      if docker_ready?() do
        tool = Exec.tool(File.cwd!())

        result =
          tool.execute.(
            "call_1",
            %{
              "command" => """
              echo docker-backend
              test -d /workspace
              touch /tmp/lemon-docker-smoke
              if touch /lemon-root-write-probe 2>/dev/null; then exit 41; fi
              test "$(awk '/NoNewPrivs:/ {print $2}' /proc/self/status)" = "1"
              test "$(awk '/CapEff:/ {print $2}' /proc/self/status)" = "0000000000000000"
              printf '#!/bin/sh\\nexit 13\\n' > /tmp/lemon-noexec-probe
              chmod +x /tmp/lemon-noexec-probe
              if /tmp/lemon-noexec-probe >/dev/null 2>&1; then exit 44; fi
              grep -E ' /tmp .*noexec' /proc/mounts >/dev/null
              if [ -r /sys/fs/cgroup/memory.max ]; then test "$(cat /sys/fs/cgroup/memory.max)" = "1073741824"; fi
              if [ -r /sys/fs/cgroup/cpu.max ]; then test "$(cat /sys/fs/cgroup/cpu.max)" = "200000 100000"; fi
              if [ -r /sys/fs/cgroup/pids.max ]; then test "$(cat /sys/fs/cgroup/pids.max)" = "256"; fi
              echo docker-hardening-ok
              """,
              "backend" => "docker"
            },
            nil,
            nil
          )

        text = result.content |> hd() |> Map.get(:text)
        assert text =~ "docker-backend"
        assert text =~ "docker-hardening-ok"
        assert result.details.status == "completed"
        assert result.details.backend == :docker
      end
    end

    test "runs with local PTY backend when script is available" do
      if System.find_executable("script") do
        tool = Exec.tool("/tmp")

        result =
          tool.execute.(
            "call_1",
            %{
              "command" =>
                "if test -t 0; then echo stdin-tty; fi; if test -t 1; then echo stdout-tty; fi",
              "backend" => "local_pty"
            },
            nil,
            nil
          )

        text = result.content |> hd() |> Map.get(:text)
        assert text =~ "stdin-tty"
        assert text =~ "stdout-tty"
        assert result.details.status == "completed"
        assert result.details.backend == :local_pty
      end
    end

    test "captures non-zero exit code" do
      tool = Exec.tool("/tmp")

      result = tool.execute.("call_1", %{"command" => "exit 42"}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "42"
      assert result.details.status == "error"
      assert result.details.exit_code == 42
    end

    test "respects cwd parameter" do
      tool = Exec.tool("/default")

      result = tool.execute.("call_1", %{"command" => "pwd", "cwd" => "/tmp"}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "/tmp"
    end

    test "uses default cwd when not specified" do
      tool = Exec.tool("/default/path")

      result = tool.execute.("call_1", %{"command" => "pwd"}, nil, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "/default/path"
    end

    test "validates empty command" do
      tool = Exec.tool("/tmp")

      assert {:error, reason} = tool.execute.("call_1", %{"command" => ""}, nil, nil)
      assert reason =~ "empty"
    end

    test "validates command type" do
      tool = Exec.tool("/tmp")

      assert {:error, reason} = tool.execute.("call_1", %{"command" => 123}, nil, nil)
      assert reason =~ "string"
    end

    test "validates yield_ms range" do
      tool = Exec.tool("/tmp")

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"command" => "echo test", "yield_ms" => 4_000_000},
                 nil,
                 nil
               )

      assert reason =~ "1 hour"
    end

    test "validates env payload shape" do
      tool = Exec.tool("/tmp")

      assert {:error, reason} =
               tool.execute.("call_1", %{"command" => "echo hi", "env" => []}, nil, nil)

      assert reason =~ "env must be an object"

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"command" => "echo hi", "env" => %{"1BAD" => "value"}},
                 nil,
                 nil
               )

      assert reason =~ "valid environment variable names"

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"command" => "echo hi", "env" => %{"GOOD" => 123}},
                 nil,
                 nil
               )

      assert reason =~ "keys and values must be strings"
    end

    @tag :tmp_dir
    test "creates a restorable checkpoint before risky shell commands with configured paths", %{
      tmp_dir: tmp_dir
    } do
      session_id = "exec-risky-shell-#{System.unique_integer([:positive])}"
      path = Path.join(tmp_dir, "target.txt")
      File.write!(path, "before\n")

      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      tool = Exec.tool(tmp_dir, session_id: session_id)

      result =
        tool.execute.(
          "call_1",
          %{"command" => "rm target.txt", "checkpoint_paths" => ["target.txt"]},
          nil,
          nil
        )

      assert result.details.status == "completed"
      assert result.details.checkpoint_kind == "filesystem"
      assert result.details.checkpoint_trigger == "risky_shell"
      refute File.exists?(path)

      {:ok, _restored} = Checkpoint.restore_filesystem(result.details.checkpoint_id)
      assert File.read!(path) == "before\n"
    end

    test "validates checkpoint_paths payload shape" do
      tool = Exec.tool("/tmp")

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"command" => "echo hi", "checkpoint_paths" => "target.txt"},
                 nil,
                 nil
               )

      assert reason =~ "checkpoint_paths must be a list of strings"

      assert {:error, reason} =
               tool.execute.(
                 "call_1",
                 %{"command" => "echo hi", "checkpoint_paths" => [""]},
                 nil,
                 nil
               )

      assert reason =~ "checkpoint_paths entries must be non-empty strings"
    end
  end

  describe "execute/4 background mode" do
    test "starts process in background when background=true" do
      tool = Exec.tool("/tmp")

      result =
        tool.execute.(
          "call_1",
          %{"command" => "sleep 60", "background" => true},
          nil,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "background"
      assert result.details.background == true
      assert is_binary(result.details.process_id)
      assert result.details.status == "running"
      assert result.details.backend == :local

      # Clean up
      CodingAgent.ProcessManager.kill(result.details.process_id, :sigkill)
    end

    test "starts process in background when yield_ms is set" do
      tool = Exec.tool("/tmp")

      result =
        tool.execute.(
          "call_1",
          %{"command" => "sleep 60", "yield_ms" => 100},
          nil,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "background"
      assert result.details.background == true
      assert is_binary(result.details.process_id)

      # Clean up
      CodingAgent.ProcessManager.kill(result.details.process_id, :sigkill)
    end
  end

  describe "execute/4 with abort signal" do
    test "returns cancelled when aborted" do
      tool = Exec.tool("/tmp")
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      result = tool.execute.("call_1", %{"command" => "echo hello"}, signal, nil)

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "cancelled"
    end
  end

  describe "execute/4 with environment variables" do
    test "sets environment variables" do
      tool = Exec.tool("/tmp")

      result =
        tool.execute.(
          "call_1",
          %{"command" => "echo $TEST_VAR", "env" => %{"TEST_VAR" => "hello"}},
          nil,
          nil
        )

      assert result.content != nil
      text = result.content |> hd() |> Map.get(:text)
      assert text =~ "hello"
    end
  end

  defp docker_ready? do
    docker = System.find_executable("docker")
    timeout = System.find_executable("timeout")

    docker != nil and timeout != nil and
      docker_command_ok?(timeout, docker, ["version", "--format", "{{.Server.Version}}"]) and
      docker_command_ok?(timeout, docker, [
        "image",
        "inspect",
        LemonCore.TerminalBackends.Docker.image()
      ])
  rescue
    _ -> false
  end

  defp docker_command_ok?(timeout, docker, args) do
    case System.cmd(timeout, ["5", docker | args], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
