defmodule LemonGateway.LemonIntegrationTest do
  use ExUnit.Case

  alias CodingAgent.CliRunners.LemonRunner
  alias AgentCore.CliRunners.Types.{CompletedEvent, StartedEvent}

  @moduletag :integration

  @doc """
  Integration test for the native Lemon engine.

  Enable with: LEMON_INTEGRATION=1 mix test --only integration

  Requires:
  - Valid AI provider API key configured in settings
  """
  test "lemon runner completes" do
    if not enabled?("LEMON_INTEGRATION") do
      :ok
    else
      {:ok, pid} =
        LemonRunner.start_link(
          prompt: "Reply with exactly: OK",
          cwd: File.cwd!(),
          timeout: 180_000
        )

      stream = LemonRunner.stream(pid)

      task =
        Task.async(fn ->
          AgentCore.EventStream.events(stream) |> Enum.to_list()
        end)

      events = Task.await(task, 200_000)

      # Verify we got a started event
      assert Enum.any?(events, fn
               {:cli_event, %StartedEvent{engine: "lemon"}} -> true
               _ -> false
             end)

      # Verify we got a completed event
      assert Enum.any?(events, fn
               {:cli_event, %CompletedEvent{ok: true, engine: "lemon"}} -> true
               _ -> false
             end)
    end
  end

  test "lemon runner provides resume token" do
    if not enabled?("LEMON_INTEGRATION") do
      :ok
    else
      {:ok, pid} =
        LemonRunner.start_link(
          prompt: "Reply with: DONE",
          cwd: File.cwd!(),
          timeout: 180_000
        )

      stream = LemonRunner.stream(pid)

      task =
        Task.async(fn ->
          AgentCore.EventStream.events(stream) |> Enum.to_list()
        end)

      events = Task.await(task, 200_000)

      # Find the started event and verify it has a resume token
      started =
        Enum.find(events, fn
          {:cli_event, %StartedEvent{engine: "lemon"}} -> true
          _ -> false
        end)

      assert started != nil
      {:cli_event, %StartedEvent{resume: resume}} = started
      assert resume != nil
      assert resume.engine == "lemon"
      assert is_binary(resume.value) and resume.value != ""
    end
  end

  defp enabled?(env) do
    System.get_env(env) in ["1", "true", "TRUE", "yes", "YES"]
  end
end
