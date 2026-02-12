defmodule CodingAgent.AgentLoopIntegrationTest do
  @moduledoc """
  Integration tests for the full CodingAgent loop with real API calls.

  These tests verify the complete flow:
  1. User prompt → Session → AgentCore → AI Provider → Real API
  2. Model response with tool calls → Tool execution → Tool results
  3. Multi-turn conversations with context preservation
  4. Session persistence with real messages

  Configuration is done via environment variables - see Ai.Test.IntegrationConfig.

  To run these tests:

      # Run all agent loop integration tests
      source .env.kimi && mix test apps/coding_agent/test/coding_agent/agent_loop_integration_test.exs --include integration

      # Run with specific tag
      source .env.kimi && mix test --include integration --only agent_loop
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :agent_loop

  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias Ai.Types.{AssistantMessage, TextContent}
  alias Ai.Test.IntegrationConfig

  # ============================================================================
  # Test Configuration
  # ============================================================================

  defp default_settings do
    %SettingsManager{
      default_thinking_level: :off,
      compaction_enabled: false,
      reserve_tokens: 16384
    }
  end

  defp start_session(opts) do
    base_opts = [
      cwd: opts[:cwd] || System.tmp_dir!(),
      model: opts[:model] || IntegrationConfig.model(),
      settings_manager: opts[:settings_manager] || default_settings(),
      system_prompt: opts[:system_prompt] || "You are a helpful coding assistant. Be concise."
    ]

    merged_opts = Keyword.merge(base_opts, opts)
    {:ok, session} = Session.start_link(merged_opts)
    session
  end

  defp skip_unless_configured do
    unless IntegrationConfig.configured?() do
      IO.puts(IntegrationConfig.skip_message())
      :skip
    else
      :ok
    end
  end

  defp subscribe_and_collect_events(session, timeout) do
    _ref = Session.subscribe(session)
    collect_events([], timeout)
  end

  defp collect_events(events, timeout) do
    receive do
      {:session_event, _session_id, {:agent_end, _messages}} ->
        Enum.reverse(events)

      {:session_event, _session_id, {:error, reason, _partial}} ->
        Enum.reverse([{:error, reason} | events])

      {:session_event, _session_id, event} ->
        collect_events([event | events], timeout)
    after
      timeout ->
        Enum.reverse([{:timeout, timeout} | events])
    end
  end

  defp wait_for_response(session, timeout \\ 30_000) do
    events = subscribe_and_collect_events(session, timeout)

    # Find the final assistant message (last one, after all tool executions)
    message_end_events =
      Enum.filter(events, fn
        {:message_end, %AssistantMessage{}} -> true
        _ -> false
      end)

    case message_end_events do
      [] ->
        error =
          Enum.find(events, fn
            {:error, _} -> true
            {:timeout, _} -> true
            _ -> false
          end)

        {:error, error || :no_response, events}

      messages ->
        # Get the last message (after tool calls are processed)
        {:message_end, msg} = List.last(messages)
        {:ok, msg, events}
    end
  end

  defp get_text(%AssistantMessage{content: content}) do
    content
    |> Enum.filter(&match?(%TextContent{}, &1))
    |> Enum.map(& &1.text)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup_all do
    # Ensure provider registry is initialized
    Ai.ProviderRegistry.init()
    Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
    IO.puts("\n[Agent Loop Tests] Configuration: #{IntegrationConfig.describe()}")
    :ok
  end

  # ============================================================================
  # Basic Agent Loop Tests
  # ============================================================================

  describe "Basic Agent Loop" do
    @tag :tmp_dir
    test "completes a simple prompt through the full stack", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session = start_session(cwd: tmp_dir)
          :ok = Session.prompt(session, "What is 2 + 2? Reply with just the number.")

          case wait_for_response(session) do
            {:ok, msg, _events} ->
              text = get_text(msg)
              assert String.contains?(text, "4")

            {:error, reason, events} ->
              flunk("Agent loop failed: #{inspect(reason)}, events: #{inspect(events)}")
          end
      end
    end

    @tag :tmp_dir
    test "streams response events correctly", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session = start_session(cwd: tmp_dir)
          :ok = Session.prompt(session, "Say hello.")

          case wait_for_response(session) do
            {:ok, _msg, events} ->
              # Should have agent_start
              assert Enum.any?(events, &match?({:agent_start}, &1))

              # Should have turn_start
              assert Enum.any?(events, &match?({:turn_start}, &1))

              # Should have message_start for user
              assert Enum.any?(events, fn
                       {:message_start, %Ai.Types.UserMessage{}} -> true
                       _ -> false
                     end)

              # Should have message_start for assistant
              assert Enum.any?(events, fn
                       {:message_start, %AssistantMessage{}} -> true
                       _ -> false
                     end)

              # Should have message_update events (streaming)
              assert Enum.any?(events, &match?({:message_update, _, _}, &1))

            {:error, reason, _events} ->
              flunk("Agent loop failed: #{inspect(reason)}")
          end
      end
    end

    @tag :tmp_dir
    test "handles multi-turn conversation", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session = start_session(cwd: tmp_dir)

          # First turn
          :ok = Session.prompt(session, "My favorite color is blue. Remember this.")

          case wait_for_response(session) do
            {:ok, _msg, _events} ->
              # Second turn - should remember context
              :ok = Session.prompt(session, "What is my favorite color?")

              case wait_for_response(session) do
                {:ok, msg, _events} ->
                  text = String.downcase(get_text(msg))
                  assert text =~ "blue"

                {:error, reason, _events} ->
                  flunk("Second turn failed: #{inspect(reason)}")
              end

            {:error, reason, _events} ->
              flunk("First turn failed: #{inspect(reason)}")
          end
      end
    end
  end

  # ============================================================================
  # Tool Execution Tests
  # ============================================================================

  describe "Tool Execution" do
    @tag :tmp_dir
    test "model can call read tool and get file contents", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Create a test file
          test_file = Path.join(tmp_dir, "test_data.txt")
          File.write!(test_file, "The secret number is 42.")

          session = start_session(cwd: tmp_dir)

          prompt = """
          Read the file test_data.txt and tell me what the secret number is.
          Just reply with the number.
          """

          :ok = Session.prompt(session, prompt)

          case wait_for_response(session, 60_000) do
            {:ok, msg, events} ->
              # Should have tool call events (may be nested in message_update)
              tool_events =
                Enum.filter(events, fn
                  {:tool_start, _, _} -> true
                  {:tool_end, _, _} -> true
                  {:message_update, _, {:tool_call_start, _, _}} -> true
                  {:message_update, _, {:tool_call_end, _, _, _}} -> true
                  _ -> false
                end)

              # Model should have called the read tool
              assert length(tool_events) > 0,
                     "Expected tool call events, got: #{inspect(Enum.take(events, 20))}"

              # Final response should contain 42
              text = get_text(msg)
              assert String.contains?(text, "42"), "Expected '42' in response, got: #{text}"

            {:error, reason, events} ->
              flunk(
                "Tool execution failed: #{inspect(reason)}, events: #{inspect(Enum.take(events, 10))}"
              )
          end
      end
    end

    @tag :tmp_dir
    test "model can call write tool to create a file", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session = start_session(cwd: tmp_dir)

          prompt = """
          Create a file called greeting.txt with the content "Hello from the AI!".
          After creating it, confirm the file was created.
          """

          :ok = Session.prompt(session, prompt)

          case wait_for_response(session, 60_000) do
            {:ok, _msg, events} ->
              # Should have tool call events for write (may be nested in message_update)
              tool_events =
                Enum.filter(events, fn
                  {:tool_start, _, _} -> true
                  {:tool_end, _, _} -> true
                  {:message_update, _, {:tool_call_start, _, _}} -> true
                  {:message_update, _, {:tool_call_end, _, _, _}} -> true
                  _ -> false
                end)

              assert length(tool_events) > 0, "Expected tool call events"

              # File should exist
              expected_file = Path.join(tmp_dir, "greeting.txt")
              assert File.exists?(expected_file), "File was not created at #{expected_file}"

              # Content should be correct
              content = File.read!(expected_file)
              assert content =~ "Hello"

            {:error, reason, _events} ->
              flunk("Tool execution failed: #{inspect(reason)}")
          end
      end
    end

    @tag :tmp_dir
    test "model can call find tool to locate files", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          # Create some test files
          File.write!(Path.join(tmp_dir, "file1.ex"), "defmodule One do end")
          File.write!(Path.join(tmp_dir, "file2.ex"), "defmodule Two do end")
          File.write!(Path.join(tmp_dir, "readme.md"), "# README")

          session = start_session(cwd: tmp_dir)

          prompt = """
          Find all .ex files in the current directory using the find tool.
          List their names.
          """

          :ok = Session.prompt(session, prompt)

          case wait_for_response(session, 60_000) do
            {:ok, msg, events} ->
              text = String.downcase(get_text(msg))
              # Should either mention the .ex files or have tool events showing find was used
              has_file_names = text =~ "file1" or text =~ "file2" or text =~ ".ex"

              tool_events =
                Enum.filter(events, fn
                  {:tool_start, _, _} -> true
                  {:tool_end, _, _} -> true
                  {:message_update, _, {:tool_call_start, _, _}} -> true
                  {:message_update, _, {:tool_call_end, _, _, _}} -> true
                  _ -> false
                end)

              assert has_file_names or length(tool_events) > 0,
                     "Expected file names in response or tool events, got text: #{text}"

            {:error, reason, _events} ->
              flunk("Tool execution failed: #{inspect(reason)}")
          end
      end
    end
  end

  # ============================================================================
  # Session Persistence Tests
  # ============================================================================

  describe "Session Persistence" do
    @tag :tmp_dir
    test "messages are persisted to session file", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session_file = Path.join(tmp_dir, "test_session.jsonl")
          session = start_session(cwd: tmp_dir, session_file: session_file)

          :ok = Session.prompt(session, "Say 'hello test'.")

          case wait_for_response(session) do
            {:ok, _msg, _events} ->
              # Save the session
              :ok = Session.save(session)

              # File should exist and have content
              assert File.exists?(session_file)
              content = File.read!(session_file)
              assert content != ""

              # Should contain both user and assistant messages
              assert content =~ "user"
              assert content =~ "assistant"

            {:error, reason, _events} ->
              flunk("Session failed: #{inspect(reason)}")
          end
      end
    end

    @tag :tmp_dir
    test "session can be resumed from file", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session_file = Path.join(tmp_dir, "resume_test.jsonl")

          # First session
          session1 = start_session(cwd: tmp_dir, session_file: session_file)

          :ok = Session.prompt(session1, "My secret word is 'banana'. Remember it.")

          case wait_for_response(session1) do
            {:ok, _msg, _events} ->
              :ok = Session.save(session1)
              GenServer.stop(session1)

              # Resume session
              session2 = start_session(cwd: tmp_dir, session_file: session_file)

              :ok = Session.prompt(session2, "What was my secret word?")

              case wait_for_response(session2) do
                {:ok, msg, _events} ->
                  text = String.downcase(get_text(msg))
                  assert text =~ "banana", "Expected 'banana' in response, got: #{text}"

                {:error, reason, _events} ->
                  flunk("Resumed session failed: #{inspect(reason)}")
              end

            {:error, reason, _events} ->
              flunk("Initial session failed: #{inspect(reason)}")
          end
      end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "Error Handling" do
    @tag :tmp_dir
    test "handles abort gracefully during streaming", %{tmp_dir: tmp_dir} do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          session = start_session(cwd: tmp_dir)

          # Subscribe to events
          _ref = Session.subscribe(session)

          # Start a prompt that might take a while
          :ok = Session.prompt(session, "Count from 1 to 100 slowly.")

          # Wait a bit for streaming to start
          Process.sleep(500)

          # Abort
          :ok = Session.abort(session)

          # Should not crash, and is_streaming should be false eventually
          # Retry a few times as abort may take some time to propagate
          result =
            Enum.find_value(1..10, {:error, :timeout}, fn _ ->
              Process.sleep(200)
              state = Session.get_state(session)
              if state.is_streaming == false, do: {:ok, state}, else: nil
            end)

          case result do
            {:ok, _state} ->
              assert true

            {:error, :timeout} ->
              state = Session.get_state(session)
              assert state.is_streaming == false, "is_streaming should be false after abort"
          end
      end
    end
  end
end
