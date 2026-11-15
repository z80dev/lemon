defmodule CodingAgent.Tools.Task.RunnerContinuationTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias CodingAgent.Session
  alias CodingAgent.Tools.Task.Runner
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{AssistantMessage, TextContent}

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf!(CodingAgent.SessionManager.get_session_dir(tmp_dir)) end)
    :ok
  end

  for continuation <- [:steps, :validation] do
    @continuation continuation
    test "#{continuation} waits for terminal state without retrying admission", %{
      tmp_dir: tmp_dir
    } do
      observer = self()
      counter = start_supervised!({Agent, fn -> 0 end})

      stream_fn = fn model, context, options ->
        count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        text = if count == 1, do: "first answer", else: "final answer"
        send(observer, {:provider_called, count, context})

        Mocks.blocking_stream_fn(Mocks.assistant_message(text), observer, chunks: 1).(
          model,
          context,
          options
        )
      end

      opts =
        case @continuation do
          :steps ->
            [steps: ["Continue from the first answer."]]

          :validation ->
            [
              validate_output: fn
                "final answer" -> :ok
                _ -> {:error, "expected final answer"}
              end
            ]
        end

      runner =
        Task.async(fn ->
          Runner.start_session_with_prompt(
            [
              cwd: tmp_dir,
              workspace_dir: tmp_dir,
              session_mode: :chat,
              register: true,
              tools: [],
              mcp_tools: [],
              extension_inventory: {[], []},
              project_memory_capture: false,
              model: Mocks.mock_model(),
              stream_fn: stream_fn
            ],
            "Give the first answer.",
            "Continuation ordering",
            nil,
            fn result -> send(observer, {:child_session, result.details.session_id}) end,
            nil,
            opts
          )
        end)

      assert_receive {:provider_called, 1, _context}, 5_000
      assert_receive {:stream_blocked, first_producer}, 5_000
      on_exit(fn -> send(first_producer, :release_stream) end)
      assert_receive {:child_session, session_id}, 5_000
      assert {:ok, session} = CodingAgent.lookup_session(session_id)
      on_exit(fn -> send(session, :release_terminal) end)

      # Session publishes agent_end before running its completion hooks. Hold
      # that exact window open so the runner must synchronize with the owner,
      # rather than betting on a delay before its next prompt.
      :sys.replace_state(session, fn state ->
        hook = fn _messages ->
          unless Process.get({__MODULE__, :terminal_released}) do
            Process.put({__MODULE__, :terminal_released}, true)
            send(observer, {:terminal_handler_blocked, self()})

            receive do
              :release_terminal -> :ok
            end
          end
        end

        %{state | hooks: Keyword.put(state.hooks, :on_agent_end, [hook])}
      end)

      runner_pid = runner.pid
      assert 1 = :erlang.trace(runner_pid, true, [:send, {:tracer, observer}])
      send(first_producer, :release_stream)
      assert_receive {:terminal_handler_blocked, ^session}, 5_000

      assert_receive {:trace, ^runner_pid, :send, {:"$gen_call", _from, :streaming?}, ^session},
                     5_000

      :erlang.trace(runner_pid, false, [:send])
      refute_receive {:provider_called, 2, _}, 0
      send(session, :release_terminal)

      assert_receive {:provider_called, 2, context}, 5_000

      assert Enum.any?(context.messages, fn
               %AssistantMessage{} = message -> LemonAi.get_text(message) == "first answer"
               _ -> false
             end)

      assert_receive {:stream_blocked, second_producer}, 5_000
      on_exit(fn -> send(second_producer, :release_stream) end)
      send(second_producer, :release_stream)

      assert %AgentToolResult{content: [%TextContent{text: "final answer"}]} =
               Task.await(runner, 5_000)

      assert Agent.get(counter, & &1) == 2
    end
  end
end
