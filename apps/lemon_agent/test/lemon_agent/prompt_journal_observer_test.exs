defmodule LemonAgent.PromptJournalObserverTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Agent, as: Runtime
  alias LemonAgent.Test.Mocks
  alias LemonAi.SystemPrompt

  defp blocks(footer) do
    [
      %{text: "shared", directory_derived: false},
      %{text: "\n\n" <> footer, directory_derived: true}
    ]
  end

  test "a queued prompt cannot relabel an in-flight response and private snapshots stay private" do
    owner = self()
    first = blocks("first directory")
    second = blocks("second directory")

    stream = fn model, context, options ->
      send(owner, {:provider_request, self(), context.system_prompt})

      receive do
        :finish ->
          Mocks.mock_stream_fn_single(Mocks.assistant_message("answer")).(model, context, options)
      after
        5_000 -> raise "test did not release provider request"
      end
    end

    agent =
      start_supervised!(
        {Runtime,
         initial_state: %{system_prompt: first, model: Mocks.mock_model()},
         stream_fn: stream,
         system_prompt_observer: owner}
      )

    Runtime.subscribe(agent, self())
    assert :ok = Runtime.prompt(agent, "first")
    assert_receive {:provider_request, producer, ^first}, 5_000
    assert :ok = Runtime.set_system_prompt(agent, second)

    assert :ok =
             Runtime.follow_up(
               agent,
               %LemonAi.Types.UserMessage{
                 content: "second",
                 timestamp: System.system_time(:millisecond)
               },
               system_prompt: second
             )

    send(producer, :finish)

    assert_receive {:agent_system_prompt, ^agent, ^first}, 5_000
    assert_receive {:agent_event, {:message_end, %{role: :assistant}}}, 5_000
    assert_receive {:provider_request, producer, ^second}, 5_000
    send(producer, :finish)
    assert_receive {:agent_system_prompt, ^agent, ^second}, 5_000
    assert_receive {:agent_event, {:agent_end, _}}, 5_000
    refute_receive {:agent_event, {:system_prompt, _}}, 0
  end

  test "empty-reply continuations retain the static blocks and journal the actual nudge" do
    owner = self()
    initial = blocks("directory")
    calls = :counters.new(1, [:atomics])

    stream = fn model, context, options ->
      :counters.add(calls, 1, 1)
      send(owner, {:provider_prompt, context.system_prompt})
      text = if :counters.get(calls, 1) == 1, do: "", else: "answer"
      Mocks.mock_stream_fn_single(Mocks.assistant_message(text)).(model, context, options)
    end

    agent =
      start_supervised!(
        {Runtime,
         initial_state: %{system_prompt: initial, model: Mocks.mock_model()},
         stream_fn: stream,
         system_prompt_observer: owner}
      )

    Runtime.subscribe(agent, self())
    assert :ok = Runtime.prompt(agent, "answer")
    assert_receive {:provider_prompt, ^initial}, 5_000
    assert_receive {:provider_prompt, continued}, 5_000
    assert Enum.take(continued, length(initial)) == initial
    assert List.last(continued).directory_derived
    assert SystemPrompt.text(continued) =~ "[Internal continuation]"
    assert_receive {:agent_system_prompt, ^agent, ^continued}, 5_000
    assert_receive {:agent_event, {:agent_end, _}}, 5_000
    refute_receive {:agent_event, {:system_prompt, _}}, 0
  end

  test "synthetic tool-budget replies carry the request prompt without a public snapshot" do
    owner = self()
    prompt = blocks("directory")

    agent =
      start_supervised!(
        {Runtime,
         initial_state: %{
           system_prompt: prompt,
           model: Mocks.mock_model(),
           tools: [Mocks.echo_tool()]
         },
         stream_fn:
           Mocks.mock_stream_fn_single(
             Mocks.assistant_message_with_tool_calls([
               Mocks.tool_call("echo", %{"text" => "again"}, id: "again")
             ])
           ),
         system_prompt_observer: owner,
         max_tool_turns: 1,
         max_retries: 0}
      )

    Runtime.subscribe(agent, self())
    assert :ok = Runtime.prompt(agent, "fail")
    assert_receive {:agent_system_prompt, ^agent, ^prompt}, 5_000

    assert_receive {:agent_event, {:message_end, %{role: :assistant, stop_reason: :tool_use}}},
                   5_000

    assert_receive {:agent_system_prompt, ^agent, ^prompt}, 5_000
    assert_receive {:agent_event, {:message_end, %{role: :assistant, stop_reason: :error}}}, 5_000
    refute_receive {:agent_event, {:system_prompt, _}}, 0
  end
end
