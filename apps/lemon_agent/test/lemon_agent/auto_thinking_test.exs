defmodule LemonAgent.AutoThinkingTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{AbortSignal, AutoThinking, Loop}
  alias LemonAgent.Agent, as: RuntimeAgent
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAi.Models

  alias LemonAi.Types.{
    AssistantMessage,
    ImageContent,
    Model,
    StreamOptions,
    TextContent,
    ThinkingContent
  }

  defp active_model(efforts \\ [:low, :medium, :high, :xhigh]) do
    %{Mocks.mock_model(reasoning: true) | reasoning_efforts: efforts}
  end

  defp classifier_model do
    Mocks.mock_model(id: "classifier", provider: :classifier_provider, max_tokens: 8_192)
  end

  defp classification(label), do: {:ok, Mocks.assistant_message(label)}

  defp classifier_opts(complete_fn, extra \\ []) do
    Keyword.merge(
      [
        resolve_classifier: fn ->
          {classifier_model(), %StreamOptions{api_key: "synthetic-classifier-key"}}
        end,
        complete_fn: complete_fn
      ],
      extra
    )
  end

  test "model labels are concrete and respect sparse and provider-specific effort capabilities" do
    cases =
      Enum.map([:low, :medium, :high, :xhigh], &{active_model(), Atom.to_string(&1), &1}) ++
        [
          {active_model([:low, :high]), "medium", :low},
          {active_model([:high]), "low", :high},
          {active_model([:minimal]), "high", :minimal},
          {Models.get_model(:openai, "gpt-5.1"), "xhigh", :high},
          {Models.get_model(:openai, "gpt-5.5"), "xhigh", :xhigh},
          {Models.get_model(:anthropic, "claude-sonnet-4-6"), "xhigh", :high},
          {Models.get_model(:anthropic, "claude-opus-4-6"), "xhigh", :xhigh}
        ]

    for {model, label, expected} <- cases do
      assert %Model{} = model
      opts = classifier_opts(fn _, _, _ -> classification(label) end)

      assert AutoThinking.resolve(model, Mocks.user_message("request"), nil, opts) ==
               {:ok, expected}
    end

    parent = self()
    opts = classifier_opts(fn _, _, _ -> send(parent, :unexpected_classifier) end)

    assert AutoThinking.resolve(
             %Model{reasoning: false},
             Mocks.user_message("request"),
             nil,
             opts
           ) == {:ok, nil}

    refute_receive :unexpected_classifier, 0
  end

  test "missing classifiers, exceptions and invalid output fall back without a primary-model classification" do
    parent = self()
    model = active_model([:low, :high])
    prompt = Mocks.user_message("request")

    assert AutoThinking.resolve(model, prompt, nil,
             resolve_classifier: fn -> nil end,
             complete_fn: fn _, _, _ -> send(parent, :unexpected_completion) end
           ) == {:ok, :low}

    refute_receive :unexpected_completion, 0

    for complete_fn <- [
          fn _, _, _ -> {:error, "synthetic-sensitive-error"} end,
          fn _, _, _ -> raise "synthetic-sensitive-exception" end,
          fn _, _, _ -> exit(:classifier_failed) end,
          fn _, _, _ -> classification("high because the request is hard") end,
          fn _, _, _ -> classification("auto") end,
          fn _, _, _ ->
            {:ok, %AssistantMessage{content: [%TextContent{text: "high"}], stop_reason: :error}}
          end,
          fn _, _, _ -> {:ok, %AssistantMessage{content: [], stop_reason: :stop}} end
        ] do
      assert AutoThinking.resolve(model, prompt, nil, classifier_opts(complete_fn)) == {:ok, :low}
    end
  end

  test "explicit ultrathink selects maximum supported effort without a classifier call" do
    parent = self()
    opts = classifier_opts(fn _, _, _ -> send(parent, :unexpected_classifier) end)

    for prompt <- ["Please ULTRATHINK about this", [%TextContent{text: "ultrathink"}]],
        {efforts, expected} <- [{[:low, :medium, :high], :high}, {[:low, :xhigh], :xhigh}] do
      assert AutoThinking.resolve(active_model(efforts), Mocks.user_message(prompt), nil, opts) ==
               {:ok, expected}
    end

    assert AutoThinking.resolve(
             %Model{reasoning: false},
             Mocks.user_message("ultrathink"),
             nil,
             opts
           ) == {:ok, nil}

    refute_receive :unexpected_classifier, 0

    opts = classifier_opts(fn _, _, _ -> classification("low") end)

    assert AutoThinking.resolve(
             active_model(),
             Mocks.user_message("ultrathinking is not the keyword"),
             nil,
             opts
           ) == {:ok, :low}
  end

  test "classifier inputs and output budgets are bounded and cannot inherit tools or observers" do
    parent = self()

    prompt =
      Mocks.user_message([
        %ImageContent{data: "do-not-send-image"},
        %TextContent{text: "a" <> String.duplicate("€", 5_000)},
        %TextContent{text: "tail"}
      ])

    for {max_tokens, expected_tokens} <- [{8_192, 4_096}, {512, 512}] do
      opts =
        classifier_opts(
          fn _, context, options ->
            send(parent, {:classifier_request, context, options})

            {:ok,
             %AssistantMessage{
               content: [
                 %ThinkingContent{thinking: "private classifier reasoning"},
                 %TextContent{text: " HIGH\n"}
               ],
               stop_reason: :stop
             }}
          end,
          resolve_classifier: fn ->
            options = %StreamOptions{
              api_key: "synthetic-classifier-key",
              reasoning: :xhigh,
              session_id: "primary-session",
              tool_choice: :required,
              on_payload: fn _, _ -> send(parent, :unexpected_observer) end,
              on_usage: fn _, _ -> send(parent, :unexpected_observer) end
            }

            {%{classifier_model() | max_tokens: max_tokens}, options}
          end
        )

      assert AutoThinking.resolve(active_model(), prompt, nil, opts) == {:ok, :high}
      assert_receive {:classifier_request, context, options}
      assert context.tools == []
      assert [message] = context.messages
      assert String.valid?(message.content)
      assert byte_size(message.content) <= 12_000
      assert String.starts_with?(message.content, "a€")
      refute message.content =~ "do-not-send-image"
      assert options.max_tokens == expected_tokens
      assert options.stream_timeout == 5_000
      assert options.reasoning == nil
      assert options.tool_choice == nil
      assert options.session_id == nil
      assert options.on_payload == nil
      assert options.on_usage == nil
      refute_receive :unexpected_observer, 0
    end
  end

  test "credential/completion deadlines terminate workers while user abort remains cancellation" do
    parent = self()
    signal = AbortSignal.new()
    on_exit(fn -> AbortSignal.clear(signal) end)

    for stage <- [:resolver_timeout, :completion_timeout, :abort] do
      blocked = fn ->
        send(parent, {:blocked_classifier, stage, self()})

        receive do
          :release -> nil
        end
      end

      opts =
        if stage == :resolver_timeout do
          classifier_opts(fn _, _, _ -> classification("high") end,
            resolve_classifier: blocked,
            timeout_ms: 50
          )
        else
          classifier_opts(fn _, _, _ -> blocked.() end,
            timeout_ms: if(stage == :abort, do: 5_000, else: 50)
          )
        end

      task =
        Task.async(fn ->
          AutoThinking.resolve(active_model(), Mocks.user_message("request"), signal, opts)
        end)

      assert_receive {:blocked_classifier, ^stage, worker}
      monitor = Process.monitor(worker)
      if stage == :abort, do: AbortSignal.abort(signal)
      expected = if stage == :abort, do: {:error, :aborted}, else: {:ok, :medium}
      assert Task.await(task, 1_000) == expected
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    end

    assert AutoThinking.resolve(active_model(), Mocks.user_message("ultrathink"), signal) ==
             {:error, :aborted}
  end

  test "latest-user classifications survive retries/tools, change for followups, and respect exhausted budgets" do
    parent = self()
    calls = :counters.new(1, [:atomics])
    followups = :counters.new(1, [:atomics])

    tool_response =
      Mocks.assistant_message_with_tool_calls([
        Mocks.tool_call("echo", %{"text" => "echo"}, id: "echo-1")
      ])

    complete_fn = fn _, context, _ ->
      prompt = hd(context.messages).content
      send(parent, {:classified_prompt, prompt})
      classification(if(prompt == "latest request", do: "high", else: "low"))
    end

    resolver = fn model, message, signal ->
      AutoThinking.resolve(model, message, signal, classifier_opts(complete_fn))
    end

    stream_fn = fn _, _, options ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)
      send(parent, {:primary_effort, call, options.reasoning})

      case call do
        1 ->
          {:error, {:http_error, 503, %{}}}

        2 ->
          Mocks.mock_stream_fn_single(tool_response).(nil, nil, nil)

        _ ->
          Mocks.mock_stream_fn_single(Mocks.assistant_message("primary answer")).(nil, nil, nil)
      end
    end

    config = %AgentLoopConfig{
      model: active_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      resolve_thinking: resolver,
      max_retries: 1,
      retry_base_delay_ms: 0,
      retry_max_delay_ms: 0,
      stream_fn: stream_fn,
      get_follow_up_messages: fn ->
        :counters.add(followups, 1, 1)
        if :counters.get(followups, 1) == 1, do: [Mocks.user_message("followup")], else: []
      end
    }

    context =
      AgentContext.new(
        messages: [Mocks.user_message("old ultrathink"), Mocks.assistant_message("old answer")],
        tools: [Mocks.echo_tool()]
      )

    events =
      Loop.stream([Mocks.user_message("latest request")], context, config) |> Enum.to_list()

    assert_receive {:classified_prompt, "latest request"}
    assert_receive {:classified_prompt, "followup"}
    refute_receive {:classified_prompt, _}, 0
    for call <- 1..3, do: assert_receive({:primary_effort, ^call, :high})
    assert_receive {:primary_effort, 4, :low}
    assert Enum.any?(events, &match?({:agent_end, _}, &1))
    refute inspect(events) =~ "synthetic-classifier-key"
    refute inspect(events) =~ "classifier_provider"

    assistant_texts =
      for {:message_end, %{role: :assistant, content: content}} <- events,
          %TextContent{text: text} <- content,
          do: text

    assert assistant_texts == ["primary answer", "primary answer"]

    blocked = %{config | budget_limits: %{max_run_tokens: 0}}
    Loop.stream([Mocks.user_message("forbidden by budget")], context, blocked) |> Enum.to_list()
    refute_receive {:classified_prompt, _}, 0
    refute_receive {:primary_effort, _, _}, 0
  end

  test "Agent preserves auto and concrete effort across continuation and model switches, but reclassifies new prompts" do
    parent = self()
    prompt = Mocks.user_message("same user turn", timestamp: 1)

    resolver = fn _, message, _ ->
      send(parent, {:agent_classified, message.content})
      {:ok, if(message.content == "same user turn", do: :high, else: :low)}
    end

    stream_fn = fn model, _, options ->
      send(parent, {:agent_wire, model.id, options.reasoning})
      Mocks.mock_stream_fn_single(Mocks.assistant_message("answer")).(nil, nil, nil)
    end

    model = %{active_model([:low, :high]) | id: "original"}

    agent =
      start_supervised!(
        {RuntimeAgent,
         initial_state: %{
           model: model,
           thinking_level: :auto,
           messages: [
             Mocks.user_message("prior turn", timestamp: 0),
             Mocks.assistant_message("prior answer")
           ]
         },
         resolve_thinking: resolver,
         stream_fn: stream_fn}
      )

    assert :ok = RuntimeAgent.prompt(agent, prompt)
    assert :ok = RuntimeAgent.wait_for_idle(agent, 2_000)
    assert_receive {:agent_classified, "same user turn"}
    assert_receive {:agent_wire, "original", :high}
    assert RuntimeAgent.get_state(agent).thinking_level == :auto

    continuation = [
      prompt,
      Mocks.assistant_message_with_tool_calls([
        Mocks.tool_call("echo", %{"text" => "done"}, id: "done")
      ]),
      Mocks.tool_result_message("done", "echo", "done")
    ]

    assert :ok = RuntimeAgent.replace_messages(agent, continuation)
    assert :ok = RuntimeAgent.set_model(agent, %{active_model([:low]) | id: "narrow"})
    assert :ok = RuntimeAgent.continue(agent)
    assert :ok = RuntimeAgent.wait_for_idle(agent, 2_000)
    assert_receive {:agent_wire, "narrow", :low}
    refute_receive {:agent_classified, _}, 0

    assert :ok = RuntimeAgent.replace_messages(agent, continuation)
    assert :ok = RuntimeAgent.set_model(agent, model)
    assert :ok = RuntimeAgent.continue(agent)
    assert :ok = RuntimeAgent.wait_for_idle(agent, 2_000)
    assert_receive {:agent_wire, "original", :high}
    refute_receive {:agent_classified, _}, 0

    assert :ok = RuntimeAgent.prompt(agent, "a new user prompt")
    assert :ok = RuntimeAgent.wait_for_idle(agent, 2_000)
    assert_receive {:agent_classified, "a new user prompt"}
    assert_receive {:agent_wire, "original", :low}
    assert RuntimeAgent.get_state(agent).thinking_level == :auto
  end
end
