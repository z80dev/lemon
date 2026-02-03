defmodule LemonGateway.CodexIntegrationTest do
  use ExUnit.Case

  alias AgentCore.CliRunners.CodexRunner
  alias AgentCore.CliRunners.Types.CompletedEvent

  @tag :integration
  test "codex runner completes" do
    cond do
      not enabled?("LEMON_CODEX_INTEGRATION") ->
        :ok

      System.find_executable("codex") == nil ->
        :ok

      true ->
        {:ok, pid} =
          CodexRunner.start_link(
            prompt: "Reply with OK.",
            cwd: File.cwd!(),
            timeout: 180_000
          )

        stream = CodexRunner.stream(pid)

        task = Task.async(fn ->
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
