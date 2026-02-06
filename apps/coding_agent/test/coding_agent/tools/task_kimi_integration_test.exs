defmodule CodingAgent.Tools.TaskKimiIntegrationTest do
  @moduledoc """
  Integration test for Task tool using the Kimi CLI engine.

  This exercises the lane queue path and ensures the Kimi runner is wired end-to-end.

  Run with:
    mix test apps/coding_agent/test/coding_agent/tools/task_kimi_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Task, as: TaskTool
  alias Ai.Test.IntegrationConfig
  alias Ai.Types.TextContent

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    case System.find_executable("kimi") do
      nil ->
        {:ok, skip_reason: "kimi CLI not installed"}

      _ ->
        Application.ensure_all_started(:coding_agent)
        tmp_dir = Path.join(System.tmp_dir!(), "kimi_task_test_#{:rand.uniform(1_000_000)}")
        File.mkdir_p!(tmp_dir)

        on_exit(fn ->
          File.rm_rf!(tmp_dir)
        end)

        skip_reason = kimi_healthcheck_reason(tmp_dir)
        {:ok, cwd: tmp_dir, skip_reason: skip_reason}
    end
  end

  test "task tool can run via kimi engine (lane queue)", %{cwd: cwd, skip_reason: skip_reason} do
    if skip_reason do
      IO.puts("Skipping Kimi Task integration test: #{skip_reason}")
      assert true
    else
      result =
        TaskTool.execute(
          "test_kimi_task",
          %{
            "description" => "Kimi README summary",
            "prompt" => "Say 'hello from kimi' and nothing else.",
            "engine" => "kimi"
          },
          nil,
          nil,
          cwd,
          model: IntegrationConfig.model()
        )

      case result do
        %AgentCore.Types.AgentToolResult{content: content, details: details} ->
          text =
            content
            |> Enum.filter(&match?(%TextContent{}, &1))
            |> Enum.map(& &1.text)
            |> Enum.join(" ")

          assert text =~ "hello" or text =~ "Hello"
          assert details[:engine] == "kimi"
          assert details[:status] == "completed"

        {:error, %{message: message} = reason} ->
          if String.contains?(message, "Invalid Authentication") or
               String.contains?(message, "LLM not set") do
            IO.puts("Skipping Kimi Task integration test: #{message}")
            assert true
          else
            flunk("Task tool (kimi engine) failed: #{inspect(reason)}")
          end

        {:error, reason} ->
          flunk("Task tool (kimi engine) failed: #{inspect(reason)}")
      end
    end
  end

  defp kimi_healthcheck_reason(cwd) do
    config = Path.expand("~/.kimi/config.toml")
    args = ["--print", "--output-format", "stream-json", "-p", "ping", "--work-dir", cwd]
    args = if File.exists?(config), do: args ++ ["--config-file", config], else: args

    env = [{"HOME", System.user_home!()}]

    case System.cmd("kimi", args, stderr_to_stdout: true, env: env) do
      {output, 0} ->
        cond do
          String.contains?(output, "Invalid Authentication") ->
            "kimi CLI authentication failed"

          String.contains?(output, "LLM not set") ->
            "kimi CLI missing model configuration"

          String.trim(output) == "" ->
            "kimi CLI produced no output"

          true ->
            nil
        end

      {output, _} ->
        cond do
          String.contains?(output, "Invalid Authentication") ->
            "kimi CLI authentication failed"

          String.contains?(output, "LLM not set") ->
            "kimi CLI missing model configuration"

          true ->
            "kimi CLI failed: #{String.slice(output, 0, 200)}"
        end
    end
  end
end
