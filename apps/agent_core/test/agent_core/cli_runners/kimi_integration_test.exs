defmodule AgentCore.CliRunners.KimiIntegrationTest do
  @moduledoc """
  Integration tests for Kimi CLI runner.

  These tests actually spawn the `kimi` CLI and verify end-to-end functionality.
  They require `kimi` to be installed and configured.

  Run with: mix test apps/agent_core/test/agent_core/cli_runners/kimi_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.KimiSubagent
  alias AgentCore.CliRunners.Types.ResumeToken

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    if System.find_executable("kimi") == nil do
      {:ok, skip_reason: "kimi CLI not installed"}
    else
      tmp_dir = Path.join(System.tmp_dir!(), "kimi_test_#{:rand.uniform(1_000_000)}")
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
        IO.puts("Skipping Kimi integration test: #{ctx[:skip_reason]}")
        assert true
      else
        cwd = ctx[:cwd]

        {:ok, session} =
          KimiSubagent.start(
            prompt: "What is 2 + 2? Reply with just the number, nothing else.",
            cwd: cwd,
            timeout: 60_000
          )

        events = collect_events(session)

        {answer, opts} = get_completed_answer(events)
        assert opts[:error] == nil
        assert String.trim(answer) != ""
        assert %ResumeToken{engine: "kimi"} = opts[:resume]

        assert Enum.any?(events, fn
                 {:completed, answer, opts} ->
                   opts[:error] == nil and String.contains?(answer, "4")

                 _ ->
                   false
               end)

        IO.puts("\n=== Kimi Basic Execution Test ===")
        IO.puts("Events received: #{length(events)}")
        print_events(events)
      end
    end
  end

  describe "session continuation" do
    @tag timeout: 120_000
    test "can continue a session when resume token is available", ctx do
      if ctx[:skip_reason] do
        IO.puts("Skipping Kimi integration test: #{ctx[:skip_reason]}")
        assert true
      else
        cwd = ctx[:cwd]

        {:ok, session1} =
          KimiSubagent.start(
            prompt: "Remember the number 42. Just say 'remembered'.",
            cwd: cwd,
            timeout: 60_000
          )

        events1 = collect_events(session1)

        IO.puts("\n=== Kimi Session Continuation Test - Part 1 ===")
        print_events(events1)

        token = KimiSubagent.resume_token(session1)

        if token == nil do
          IO.puts("No resume token returned by Kimi CLI; skipping continuation check.")
          assert true
        else
          {:ok, session2} =
            KimiSubagent.continue(session1, "What number did I ask you to remember?")

          events2 = collect_events(session2)

          IO.puts("\n=== Kimi Session Continuation Test - Part 2 ===")
          print_events(events2)

          {answer, opts} = get_completed_answer(events2)
          assert opts[:error] == nil
          assert String.contains?(answer, "42")
        end
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp collect_events(session) do
    session
    |> KimiSubagent.events()
    |> Enum.to_list()
  end

  defp print_events(events) do
    Enum.each(events, fn event ->
      case event do
        {:started, token} ->
          IO.puts("  [STARTED] Session: #{token.value}")

        {:action, %{kind: kind, title: title}, phase, opts} ->
          ok_str = if opts[:ok] != nil, do: " (ok=#{opts[:ok]})", else: ""

          IO.puts(
            "  [ACTION:#{phase}] #{kind}: #{String.slice(to_string(title), 0, 60)}#{ok_str}"
          )

        {:completed, answer, opts} ->
          status = if opts[:error], do: "FAILED", else: "SUCCESS"
          answer_preview = answer |> String.slice(0, 100) |> String.replace("\n", " ")
          IO.puts("  [COMPLETED:#{status}] #{answer_preview}...")
          if opts[:error], do: IO.puts("    Error: #{opts[:error]}")
          if opts[:resume], do: IO.puts("    Resume: #{opts[:resume].value}")

        {:error, reason} ->
          IO.puts("  [ERROR] #{inspect(reason)}")

        other ->
          IO.puts("  [OTHER] #{inspect(other)}")
      end
    end)
  end

  defp get_completed_answer(events) do
    case Enum.find(events, &match?({:completed, _, _}, &1)) do
      {:completed, answer, opts} -> {answer, opts}
      _ -> flunk("Expected a completed event")
    end
  end
end
