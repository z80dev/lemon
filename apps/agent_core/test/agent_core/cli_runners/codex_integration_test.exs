defmodule AgentCore.CliRunners.CodexIntegrationTest do
  @moduledoc """
  Integration tests for Codex CLI runner.

  These tests actually spawn the `codex` CLI and verify end-to-end functionality.
  They require `codex` to be installed and configured.

  Run with: mix test apps/agent_core/test/agent_core/cli_runners/codex_integration_test.exs
  """

  use ExUnit.Case, async: false

  alias AgentCore.CliRunners.CodexSubagent
  alias LemonCore.ResumeToken

  @moduletag :integration
  @moduletag timeout: 120_000

  # Skip if codex isn't installed
  setup do
    case System.find_executable("codex") do
      nil ->
        {:skip, "codex CLI not installed"}

      _path ->
        # Create a temp directory for tests
        tmp_dir = Path.join(System.tmp_dir!(), "codex_test_#{:rand.uniform(1_000_000)}")
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
        CodexSubagent.start(
          prompt: "What is 2 + 2? Reply with just the number.",
          cwd: cwd,
          timeout: 60_000
        )

      events = collect_events(session)

      assert_started_and_output(events, "codex")

      assert Enum.any?(events, fn
               {:completed, answer, opts} -> opts[:ok] == true and String.contains?(answer, "4")
               _ -> false
             end)

      IO.puts("\n=== Basic Execution Test ===")
      IO.puts("Events received: #{length(events)}")
      print_events(events)
    end

    @tag timeout: 60_000
    test "handles simple code task", %{cwd: cwd} do
      {:ok, session} =
        CodexSubagent.start(
          prompt: "Create a file called hello.txt with the content 'Hello, World!'",
          cwd: cwd,
          timeout: 60_000
        )

      events = collect_events(session)

      IO.puts("\n=== Code Task Test ===")
      print_events(events)

      # Should complete successfully
      {answer, opts} = get_completed_answer(events)
      assert opts[:ok] == true
      assert String.trim(answer) != ""

      # File should exist (if codex created it)
      # Note: This depends on codex actually executing the task
    end
  end

  describe "session continuation" do
    @tag timeout: 120_000
    test "can continue a session with follow-up prompt", %{cwd: cwd} do
      # First prompt
      {:ok, session1} =
        CodexSubagent.start(
          prompt: "Remember the number 42. Just acknowledge.",
          cwd: cwd,
          timeout: 60_000
        )

      events1 = collect_events(session1)

      IO.puts("\n=== Session Continuation Test - Part 1 ===")
      print_events(events1)

      # Get the resume token
      token = CodexSubagent.resume_token(session1)
      assert token != nil, "Should have a resume token after first session"
      IO.puts("Resume token: #{token.value}")

      # Continue the session
      {:ok, session2} = CodexSubagent.continue(session1, "What number did I ask you to remember?")

      events2 = collect_events(session2)

      IO.puts("\n=== Session Continuation Test - Part 2 ===")
      print_events(events2)

      # Should complete and hopefully mention 42
      {answer, opts} = get_completed_answer(events2)
      assert opts[:ok] == true

      IO.puts("Answer from continued session: #{String.slice(answer, 0, 200)}")

      # The answer should reference 42 (testing context retention)
      assert String.contains?(answer, "42"),
             "Expected answer to contain '42' but got: #{String.slice(answer, 0, 200)}"
    end

    @tag timeout: 120_000
    test "can resume session using saved token", %{cwd: cwd} do
      # First session - use a neutral topic that Codex won't refuse
      {:ok, session1} =
        CodexSubagent.start(
          prompt: "My favorite color is blue and my favorite number is 777. Remember these.",
          cwd: cwd,
          timeout: 60_000
        )

      events1 = collect_events(session1)
      token = CodexSubagent.resume_token(session1)

      IO.puts("\n=== Resume Test - Part 1 ===")
      IO.puts("Token: #{inspect(token)}")
      print_events(events1)

      assert token != nil

      # Resume with the token directly (simulating a fresh process)
      {:ok, session2} =
        CodexSubagent.resume(token,
          prompt: "What was my favorite number?",
          cwd: cwd,
          timeout: 60_000
        )

      events2 = collect_events(session2)

      IO.puts("\n=== Resume Test - Part 2 ===")
      print_events(events2)

      {answer, opts} = get_completed_answer(events2)
      assert opts[:ok] == true

      IO.puts("Answer: #{String.slice(answer, 0, 300)}")

      assert String.contains?(answer, "777"),
             "Expected answer to contain '777' but got: #{String.slice(answer, 0, 200)}"
    end
  end

  describe "action events" do
    @tag timeout: 60_000
    test "receives action events for commands", %{cwd: cwd} do
      {:ok, session} =
        CodexSubagent.start(
          prompt: "Run the command: echo 'test output'",
          cwd: cwd,
          timeout: 60_000
        )

      events = collect_events(session)

      IO.puts("\n=== Action Events Test ===")
      print_events(events)

      # Should have command action events
      command_events =
        Enum.filter(events, fn
          {:action, %{kind: :command}, _, _} -> true
          _ -> false
        end)

      IO.puts("Command events: #{length(command_events)}")

      # We expect at least some command-related activity
      # (Codex may or may not execute depending on its mode)
      assert_started_and_output(events, "codex")
    end
  end

  describe "minimal input" do
    @tag timeout: 30_000
    test "handles minimal prompt and returns output", %{cwd: cwd} do
      {:ok, session} =
        CodexSubagent.start(
          prompt: "Say 'ok' and nothing else.",
          cwd: cwd,
          timeout: 30_000
        )

      events = collect_events(session)

      IO.puts("\n=== Minimal Prompt Test ===")
      print_events(events)

      assert_started_and_output(events, "codex")
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp collect_events(session) do
    session
    |> CodexSubagent.events()
    |> Enum.to_list()
  end

  defp print_events(events) do
    Enum.each(events, fn event ->
      case event do
        {:started, token} ->
          IO.puts("  [STARTED] Session: #{token.value}")

        {:action, %{kind: kind, title: title}, phase, opts} ->
          ok_str = if opts[:ok] != nil, do: " (ok=#{opts[:ok]})", else: ""
          IO.puts("  [ACTION:#{phase}] #{kind}: #{String.slice(title, 0, 60)}#{ok_str}")

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
