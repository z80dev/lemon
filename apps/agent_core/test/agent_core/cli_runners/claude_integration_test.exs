defmodule AgentCore.CliRunners.ClaudeIntegrationTest do
  @moduledoc """
  Integration tests for Claude CLI runner.

  These tests actually spawn the `claude` CLI and verify end-to-end functionality.
  They require `claude` (Claude Code) to be installed and configured.

  Run with: mix test apps/agent_core/test/agent_core/cli_runners/claude_integration_test.exs --include integration
  """

  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.ClaudeSubagent
  alias AgentCore.CliRunners.Types.ResumeToken

  @moduletag :integration
  @moduletag timeout: 120_000

  # Skip if claude isn't installed
  setup do
    case System.find_executable("claude") do
      nil ->
        {:skip, "claude CLI not installed"}

      _path ->
        # Create a temp directory for tests
        tmp_dir = Path.join(System.tmp_dir!(), "claude_test_#{:rand.uniform(1_000_000)}")
        File.mkdir_p!(tmp_dir)

        on_exit(fn ->
          File.rm_rf!(tmp_dir)
        end)

        {:ok, cwd: tmp_dir}
    end
  end

  describe "basic execution" do
    @tag timeout: 60_000
    test "starts a session and receives events", %{cwd: cwd} do
      {:ok, session} =
        ClaudeSubagent.start(
          prompt: "What is 2 + 2? Reply with just the number, nothing else.",
          cwd: cwd,
          timeout: 60_000
        )

      events = collect_events(session)

      assert_started_and_output(events, "claude")

      assert Enum.any?(events, fn
               {:completed, answer, opts} -> opts[:ok] == true and String.contains?(answer, "4")
               _ -> false
             end)

      IO.puts("\n=== Claude Basic Execution Test ===")
      IO.puts("Events received: #{length(events)}")
      print_events(events)
    end
  end

  describe "session continuation" do
    @tag timeout: 120_000
    test "can continue a session with follow-up prompt", %{cwd: cwd} do
      # First prompt
      {:ok, session1} =
        ClaudeSubagent.start(
          prompt: "Remember the number 42. Just say 'remembered'.",
          cwd: cwd,
          timeout: 60_000
        )

      events1 = collect_events(session1)

      IO.puts("\n=== Claude Session Continuation Test - Part 1 ===")
      print_events(events1)

      # Get the resume token
      token = ClaudeSubagent.resume_token(session1)
      assert token != nil, "Should have a resume token after first session"
      IO.puts("Resume token: #{token.value}")

      # Continue the session
      {:ok, session2} =
        ClaudeSubagent.continue(session1, "What number did I ask you to remember?")

      events2 = collect_events(session2)

      IO.puts("\n=== Claude Session Continuation Test - Part 2 ===")
      print_events(events2)

      # Should complete and mention 42
      {answer, opts} = get_completed_answer(events2)
      assert opts[:ok] == true

      IO.puts("Answer from continued session: #{String.slice(answer, 0, 200)}")

      assert String.contains?(answer, "42"),
             "Expected answer to contain '42' but got: #{String.slice(answer, 0, 200)}"
    end

    @tag timeout: 120_000
    test "can resume session using saved token", %{cwd: cwd} do
      # First session
      {:ok, session1} =
        ClaudeSubagent.start(
          prompt: "My favorite color is green and my lucky number is 888. Remember these.",
          cwd: cwd,
          timeout: 60_000
        )

      events1 = collect_events(session1)
      token = ClaudeSubagent.resume_token(session1)

      IO.puts("\n=== Claude Resume Test - Part 1 ===")
      IO.puts("Token: #{inspect(token)}")
      print_events(events1)

      assert token != nil

      # Resume with the token directly
      {:ok, session2} =
        ClaudeSubagent.resume(token,
          prompt: "What was my lucky number?",
          cwd: cwd,
          timeout: 60_000
        )

      events2 = collect_events(session2)

      IO.puts("\n=== Claude Resume Test - Part 2 ===")
      print_events(events2)

      {answer, opts} = get_completed_answer(events2)
      assert opts[:ok] == true

      IO.puts("Answer: #{String.slice(answer, 0, 300)}")

      assert String.contains?(answer, "888"),
             "Expected answer to contain '888' but got: #{String.slice(answer, 0, 200)}"
    end
  end

  describe "tool execution" do
    @tag timeout: 60_000
    test "receives action events for tool calls", %{cwd: cwd} do
      {:ok, session} =
        ClaudeSubagent.start(
          prompt: "Run the command: echo 'hello from claude'",
          cwd: cwd,
          timeout: 60_000
        )

      events = collect_events(session)

      IO.puts("\n=== Claude Tool Execution Test ===")
      print_events(events)

      # Should have tool/command action events
      action_events =
        Enum.filter(events, fn
          {:action, _, _, _} -> true
          _ -> false
        end)

      IO.puts("Action events: #{length(action_events)}")

      # We should see at least one command or tool action
      assert length(action_events) > 0, "Expected at least one action event"
      assert_started_and_output(events, "claude")
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp collect_events(session) do
    session
    |> ClaudeSubagent.events()
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
          status = if opts[:ok], do: "SUCCESS", else: "FAILED"
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

  defp assert_started_and_output(events, engine) do
    assert Enum.any?(events, fn
             {:started, %ResumeToken{engine: ^engine}} -> true
             _ -> false
           end),
           "Expected started event for #{engine}"

    {answer, opts} = get_completed_answer(events)
    assert opts[:ok] == true
    assert String.trim(answer) != ""
  end

  defp get_completed_answer(events) do
    case Enum.find(events, &match?({:completed, _, _}, &1)) do
      {:completed, answer, opts} -> {answer, opts}
      _ -> flunk("Expected a completed event")
    end
  end
end
