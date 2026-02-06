defmodule LemonGateway.ClaudeIntegrationTest do
  use ExUnit.Case

  alias AgentCore.CliRunners.ClaudeRunner
  alias AgentCore.CliRunners.Types.CompletedEvent

  @tag :integration
  test "claude runner completes" do
    cond do
      not enabled?("LEMON_CLAUDE_INTEGRATION") ->
        :ok

      System.find_executable("claude") == nil ->
        :ok

      true ->
        {:ok, pid} =
          ClaudeRunner.start_link(
            prompt: "Reply with OK.",
            cwd: File.cwd!(),
            timeout: 180_000
          )

        stream = ClaudeRunner.stream(pid)

        task =
          Task.async(fn ->
            AgentCore.EventStream.events(stream) |> Enum.to_list()
          end)

        events = Task.await(task, 200_000)

        assert Enum.any?(events, fn
                 {:cli_event, %CompletedEvent{ok: true}} -> true
                 _ -> false
               end)
    end
  end

  defp enabled?(env) do
    System.get_env(env) in ["1", "true", "TRUE", "yes", "YES"]
  end
end
