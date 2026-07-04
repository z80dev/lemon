defmodule LemonSim.LLM.Deciders.ExternalDeciderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.Context
  alias LemonSim.Bench.Artifacts.Verifier
  alias LemonSim.LLM.Deciders.ExternalDecider

  test "loops through support tools and returns the terminal decision" do
    script =
      """
      #!/bin/sh
      read hello
      read request
      printf '%s\\n' '{"type":"tool_call","turn":1,"name":"check_balance","arguments":{}}'
      read result
      printf '%s\\n' '{"type":"tool_call","turn":1,"name":"wait_for_next_day","arguments":{}}'
      read game_over
      """

    {:ok, session} = start_session(script)

    assert {:ok, decision} =
             ExternalDecider.decide(context(), [check_balance_tool(), wait_tool()],
               external_decider: session,
               support_tool_matcher: &(&1.name == "check_balance"),
               live_step_timeout_ms: 500
             )

    assert decision["tool_name"] == "wait_for_next_day"

    assert Enum.map(decision["executed_calls"], & &1.tool_name) == [
             "check_balance",
             "wait_for_next_day"
           ]
  end

  test "malformed lines return malformed turn errors" do
    script =
      """
      #!/bin/sh
      read hello
      read request
      printf '%s\\n' 'not-json'
      """

    {:ok, session} = start_session(script)

    assert {:error, {:malformed_turn, details}} =
             ExternalDecider.decide(context(), [wait_tool()],
               external_decider: session,
               live_step_timeout_ms: 500
             )

    assert details.reason =~ "Invalid JSON"
  end

  test "process exit maps to an empty response error" do
    script =
      """
      #!/bin/sh
      read hello
      read request
      exit 0
      """

    {:ok, session} = start_session(script)

    assert {:error, {:tool_call_required, details}} =
             ExternalDecider.decide(context(), [wait_tool()],
               external_decider: session,
               live_step_timeout_ms: 500
             )

    assert details.assistant_text == ""
    assert details.executed_calls == []
  end

  test "reassembles long no-eol port fragments into one tool call" do
    script =
      """
      #!/bin/sh
      read hello
      read request
      printf '%s' '{"type":"tool_call","turn":1,"name":"wait_for_next_day","arguments":{"thought":"'
      i=0
      while [ "$i" -lt 70000 ]; do
        printf x
        i=$((i + 1))
      done
      printf '%s\\n' '"}}'
      read game_over
      """

    {:ok, session} = start_session(script)

    assert {:ok, decision} =
             ExternalDecider.decide(context(), [wait_tool()],
               external_decider: session,
               live_step_timeout_ms: 1_000
             )

    assert decision["tool_name"] == "wait_for_next_day"
    assert [%{arguments: %{"thought" => thought}}] = decision["executed_calls"]
    assert byte_size(thought) == 70_000
  end

  test "discards stale tool calls for the wrong turn before reading the matching turn" do
    script =
      """
      #!/bin/sh
      read hello
      read request
      printf '%s\\n' '{"type":"tool_call","turn":999,"name":"wait_for_next_day","arguments":{"stale":true}}'
      printf '%s\\n' '{"type":"tool_call","turn":1,"name":"wait_for_next_day","arguments":{"stale":false}}'
      read game_over
      """

    {:ok, session} = start_session(script)

    assert {:ok, decision} =
             ExternalDecider.decide(context(), [wait_tool()],
               external_decider: session,
               live_step_timeout_ms: 500
             )

    assert decision["tool_name"] == "wait_for_next_day"
    assert [%{arguments: %{"stale" => false}}] = decision["executed_calls"]
  end

  test "no line before the decision timeout maps to live step timeout" do
    script =
      """
      #!/bin/sh
      read hello
      read request
      sleep 1
      """

    {:ok, session} = start_session(script)

    assert {:error, {:live_step_timeout, 50}} =
             ExternalDecider.decide(context(), [wait_tool()],
               external_decider: session,
               live_step_timeout_ms: 50
             )
  end

  test "stop terminates an external process that ignores stdin eof" do
    script =
      """
      #!/bin/sh
      trap '' TERM
      while true; do
        sleep 60
      done
      """

    {:ok, session} = start_session(script)
    %{os_pid: os_pid} = :sys.get_state(session)

    assert is_integer(os_pid)
    assert os_pid_alive?(os_pid)

    assert :ok = ExternalDecider.stop(session, "test_done")
    refute os_pid_alive?(os_pid)
  end

  @tag timeout: 90_000
  test "baseline agent completes a ci preset VendingBench run and verifies artifacts" do
    case System.find_executable("python3") do
      nil ->
        IO.puts("Skipping external baseline integration: python3 not found")
        assert true

      python ->
        artifact_dir = tmp_dir("vb_external_baseline")
        sim_id = "vb_external_baseline_#{System.unique_integer([:positive])}"

        agent_path =
          Path.expand("../../../../../examples/external_agents/baseline_agent.py", __DIR__)

        cmd = "#{shell_quote(python)} #{shell_quote(agent_path)}"

        capture_io(fn ->
          Mix.Tasks.Lemon.Sim.VendingBench.run([
            "--preset",
            "ci",
            "--sim-id",
            sim_id,
            "--external-cmd",
            cmd,
            "--artifact-dir",
            artifact_dir,
            "--deterministic-artifacts",
            "--live-step-timeout-ms",
            "5000"
          ])
        end)

        assert {:ok, _verified} = Verifier.verify_run(artifact_dir)

        final_world =
          artifact_dir
          |> Path.join("final_world.json")
          |> File.read!()
          |> Jason.decode!()

        assert final_world["status"] == "complete"
        refute final_world["status"] == "bankrupt"

        usage =
          artifact_dir
          |> Path.join("usage.json")
          |> File.read!()
          |> Jason.decode!()

        assert usage["totals"]["input_tokens"] == 0
        assert usage["totals"]["output_tokens"] == 0
        assert is_nil(usage["totals"]["cost_usd"])
    end
  end

  defp start_session(script) do
    path = Path.join(tmp_dir("external_agent"), "agent.sh")
    File.write!(path, script)
    File.chmod!(path, 0o755)

    {:ok, session} =
      ExternalDecider.start_link(
        cmd: "sh #{path}",
        sim_id: "external_decider_test",
        preset: "test",
        max_days: 1,
        driver_max_turns: 3
      )

    on_exit(fn -> ExternalDecider.stop(session, "test_done") end)
    {:ok, session}
  end

  defp context do
    Context.new(system_prompt: "Use tools only")
    |> Context.add_user_message("""
    SIM_PROMPT_V1

    ## World State
    ```json
    {"day_number":1,"status":"in_progress"}
    ```

    ## Decision Contract
    Pick one action.
    """)
  end

  defp check_balance_tool do
    %AgentTool{
      name: "check_balance",
      description: "Check balance",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Check Balance",
      execute: fn _id, _params, _signal, _on_update ->
        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("Balance: $500.00")],
           details: %{"ok" => true},
           trust: :trusted
         }}
      end
    }
  end

  defp wait_tool do
    %AgentTool{
      name: "wait_for_next_day",
      description: "Wait",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Wait",
      execute: fn _id, _params, _signal, _on_update ->
        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("Waiting")],
           details: %{"event" => %{"kind" => "next_day_waited", "payload" => %{}}},
           trust: :trusted
         }}
      end
    }
  end

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp os_pid_alive?(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
