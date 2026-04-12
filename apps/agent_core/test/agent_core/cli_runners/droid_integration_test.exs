defmodule AgentCore.CliRunners.DroidIntegrationTest do
  @moduledoc """
  Integration tests for Droid CLI runner.

  These tests actually spawn the `droid` CLI and verify end-to-end functionality.
  They require `droid` to be installed and authenticated (via CLI login or
  environment-based auth).

  Run with: mix test apps/agent_core/test/agent_core/cli_runners/droid_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.DroidSubagent
  alias LemonCore.ResumeToken

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    cond do
      System.find_executable("droid") == nil ->
        {:ok, skip_reason: "droid CLI not installed"}

      true ->
        tmp_dir = Path.join(System.tmp_dir!(), "droid_test_#{:rand.uniform(1_000_000)}")
        File.mkdir_p!(tmp_dir)

        on_exit(fn ->
          File.rm_rf!(tmp_dir)
        end)

        {:ok, cwd: tmp_dir, skip_reason: nil}
    end
  end

  describe "basic execution" do
    @tag timeout: 60_000
    test "starts a session and receives events", ctx do
      if ctx[:skip_reason] do
        IO.puts("Skipping Droid integration test: #{ctx[:skip_reason]}")
        assert true
      else
        {:ok, session} =
          DroidSubagent.start(
            prompt: "What is 2 + 2? Reply with just the number, nothing else.",
            cwd: ctx.cwd,
            timeout: 60_000
          )

        events = collect_events(session)

        {answer, opts} = get_completed_answer(events)
        assert opts[:error] == nil
        assert String.trim(answer) != ""
        assert %ResumeToken{engine: "droid"} = opts[:resume]

        assert Enum.any?(events, fn
                 {:completed, answer, opts} ->
                   opts[:error] == nil and String.contains?(answer, "4")

                 _ ->
                   false
               end)
      end
    end
  end

  describe "session continuation" do
    @tag timeout: 120_000
    test "can continue a session when resume token is available", ctx do
      if ctx[:skip_reason] do
        IO.puts("Skipping Droid integration test: #{ctx[:skip_reason]}")
        assert true
      else
        {:ok, session1} =
          DroidSubagent.start(
            prompt: "Remember the number 42. Just say remembered.",
            cwd: ctx.cwd,
            timeout: 60_000
          )

        _events1 = collect_events(session1)
        token = DroidSubagent.resume_token(session1)

        if token == nil do
          IO.puts("No resume token returned by Droid CLI; skipping continuation check.")
          assert true
        else
          {:ok, session2} =
            DroidSubagent.continue(session1, "What number did I ask you to remember?")

          events2 = collect_events(session2)

          {answer, opts} = get_completed_answer(events2)
          assert opts[:error] == nil
          assert String.contains?(answer, "42")
        end
      end
    end
  end

  defp collect_events(session) do
    session
    |> DroidSubagent.events()
    |> Enum.to_list()
  end

  defp get_completed_answer(events) do
    case Enum.find(events, &match?({:completed, _, _}, &1)) do
      {:completed, answer, opts} -> {answer, opts}
      _ -> flunk("Expected a completed event")
    end
  end
end
