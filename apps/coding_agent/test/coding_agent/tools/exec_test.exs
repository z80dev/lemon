defmodule CodingAgent.Tools.ExecTest do
  use ExUnit.Case, async: false

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
end
