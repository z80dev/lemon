defmodule LemonAgent.AgentRedirectTest do
  @moduledoc """
  Tests for LemonAgent.Agent.redirect/3.

  A redirect on a running agent cancels the in-flight model request and
  retries with the correction appended; on an idle agent it degrades to
  follow-up semantics. It must never flip the abort bookkeeping.
  """
  use ExUnit.Case, async: true

  alias LemonAgent.Agent, as: CoreAgent
  alias LemonAgent.Test.Mocks

  alias LemonAi.Types.{TextContent, UserMessage}

  defp start_agent(opts \\ []) do
    default_opts = [
      initial_state: %{
        system_prompt: Keyword.get(opts, :system_prompt, "You are a test assistant."),
        model: Keyword.get(opts, :model, Mocks.mock_model()),
        thinking_level: :off,
        tools: Keyword.get(opts, :tools, [])
      },
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm())
    ]

    merged_opts = Keyword.merge(default_opts, opts)
    CoreAgent.start_link(merged_opts)
  end

  defp user_message(text) do
    %UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp user_content?(message, text) do
    Map.get(message, :role) == :user and
      (message.content == text or
         (is_list(message.content) and
            Enum.any?(message.content, fn
              %TextContent{text: ^text} -> true
              _ -> false
            end)))
  end

  describe "redirect while running" do
    test "cancels the model call, applies the correction, and the run completes" do
      parent = self()
      counter = :counters.new(1, [:atomics])

      stream_fn = fn model, llm_context, options ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(parent, {:llm_call, n, llm_context.messages})

        case n do
          1 ->
            {:ok, stream} = LemonAi.EventStream.start_link()

            Task.start(fn ->
              response = Mocks.assistant_message("Partial before redirect")
              LemonAi.EventStream.push(stream, {:start, response})

              for i <- 1..20 do
                send(parent, {:streaming_chunk, i})
                Process.sleep(30)
                LemonAi.EventStream.push(stream, {:text_delta, 0, "chunk #{i}", response})
              end

              LemonAi.EventStream.push(stream, {:done, :stop, response})
              LemonAi.EventStream.complete(stream, response)
            end)

            {:ok, stream}

          _ ->
            Mocks.mock_stream_fn_single(Mocks.assistant_message("After redirect")).(
              model,
              llm_context,
              options
            )
        end
      end

      {:ok, agent} = start_agent(stream_fn: stream_fn)

      :ok = CoreAgent.prompt(agent, "Start")

      assert_receive {:streaming_chunk, 2}, 2000

      :ok = CoreAgent.redirect(agent, user_message("Correction: switch approach"))

      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 10_000)

      agent_state = CoreAgent.get_state(agent)

      # The run completed without being treated as an error/abort
      assert agent_state.error == nil
      refute agent_state.is_streaming

      # The correction and the retried final answer are in the history
      assert Enum.any?(agent_state.messages, &user_content?(&1, "Correction: switch approach"))

      assert Enum.any?(agent_state.messages, fn msg ->
               Map.get(msg, :role) == :assistant and Map.get(msg, :stop_reason) == :stop and
                 is_list(msg.content) and
                 Enum.any?(msg.content, fn
                   %TextContent{text: "After redirect"} -> true
                   _ -> false
                 end)
             end)

      # The retried call saw the correction
      assert_receive {:llm_call, 2, retry_messages}, 2000
      assert Enum.any?(retry_messages, &user_content?(&1, "Correction: switch approach"))
    end
  end

  describe "redirect while idle" do
    test "degrades to follow-up semantics" do
      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Second response")

      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn([response1, response2]))

      # Redirect with no run active: should queue as a follow-up
      :ok = CoreAgent.redirect(agent, user_message("Queued while idle"))
      assert length(:sys.get_state(agent).follow_up_queue) == 1

      :ok = CoreAgent.prompt(agent, "Hello")
      assert :ok = CoreAgent.wait_for_idle(agent, timeout: 10_000)

      agent_state = CoreAgent.get_state(agent)

      # Both the prompt turn and the follow-up turn ran
      assert Enum.any?(agent_state.messages, &user_content?(&1, "Queued while idle"))

      assistant_texts =
        for %{role: :assistant, content: content} <- agent_state.messages,
            %TextContent{text: text} <- List.wrap(content),
            do: text

      assert "First response" in assistant_texts
      assert "Second response" in assistant_texts
    end
  end
end
