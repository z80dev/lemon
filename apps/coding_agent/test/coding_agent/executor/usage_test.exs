defmodule CodingAgent.Executor.UsageTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Executor.{Usage, RemoteRequestCodec}
  alias LemonAi.Types.{AssistantMessage, Cost}

  defmodule Emitter do
    @behaviour CodingAgent.Session.RunTranslator.Emitter
    def emit_started(state, _), do: state
    def emit_action_event(state, _), do: state
    def emit_delta(state, _, _), do: state
    def emit_completed(state, fields), do: Map.update!(state, :completed, &[fields | &1])
  end

  test "actual local completion emits usage occurrences once, including failure completion" do
    message = %AssistantMessage{
      provider: :custom,
      model: "actual-model",
      timestamp: 1500,
      content: [%LemonAi.Types.TextContent{text: "private answer"}],
      usage: %LemonAi.Types.Usage{input: 2, output: 1, total_tokens: 3, cost: %Cost{total: 0.5}}
    }

    translator =
      CodingAgent.Session.RunTranslator.new(
        emitter: Emitter,
        emitter_state: %{completed: []},
        engine: "lemon",
        label: "test",
        cwd: "/private/path",
        run_id: "local-run"
      )

    translator =
      CodingAgent.Session.RunTranslator.handle_event(translator, {:provider_usage, message})

    completed =
      CodingAgent.Session.RunTranslator.handle_event(translator, {:agent_end, [message]})

    replay = CodingAgent.Session.RunTranslator.handle_event(completed, {:agent_end, [message]})
    assert [fields] = replay.emitter_state.completed
    assert [%{usage: %{cost: %{total: 0.5}, price_known: true}}] = fields.usage.occurrences

    assert [entry] =
             LemonCore.UsageLedger.entries("local-run", "agent:bot:main", %{
               completed: fields,
               meta: %{agent_id: "bot"}
             })

    assert entry.run_id == "local-run"
    assert entry.cost == 0.5
    refute inspect(fields.usage.occurrences) =~ "private"

    failed = CodingAgent.Session.RunTranslator.handle_event(translator, {:error, :failed, %{}})
    assert [failure] = failed.emitter_state.completed
    assert failure.ok == false
    assert failure.usage.occurrences == fields.usage.occurrences
  end

  test "records actual catalog pricing, known zero, and unknown default zero distinctly" do
    model = LemonAi.Models.get_models(:anthropic) |> hd()
    tokens = %LemonAi.Types.Usage{input: 1000, output: 100, total_tokens: 1100}
    price = LemonAi.calculate_cost(model, tokens)

    message = %AssistantMessage{
      provider: model.provider,
      model: model.id,
      timestamp: 1234,
      usage: %{tokens | cost: price},
      content: [%{text: "private prompt/response"}]
    }

    assert %{at_ms: 1234, usage: %{cost: cost, price_known: true}} = Usage.occurrence(message)
    assert cost.total == price.total
    refute inspect(Usage.occurrence(message)) =~ "private"

    free = %{message | usage: %LemonAi.Types.Usage{cost: %Cost{}}}
    assert %{usage: %{cost: %{total: 0.0}, price_known: true}} = Usage.occurrence(free)
    unknown = %{free | provider: :custom, model: "uncatalogued"}
    assert %{usage: %{cost: %{total: nil}, price_known: false}} = Usage.occurrence(unknown)
  end

  test "named-node completion retains actual occurrence prices and run owner identity" do
    occurrence =
      Usage.occurrence(%AssistantMessage{
        provider: :custom,
        model: "private-model",
        timestamp: 2000,
        usage: %LemonAi.Types.Usage{
          input: 7,
          output: 3,
          total_tokens: 10,
          cost: %Cost{total: 0.25}
        }
      })

    payload = Jason.encode!(%{ok: true, usage: %{occurrences: [occurrence]}}) |> Jason.decode!()
    assert {:ok, completed} = RemoteRequestCodec.decode_result(payload)

    assert [entry] =
             LemonCore.UsageLedger.entries("native-run", "agent:bot:main", %{
               completed: completed,
               meta: %{agent_id: "bot"}
             })

    assert entry.run_id == "native-run"
    assert entry.agent_id == "bot"
    assert entry.cost == 0.25
    assert entry.at_ms == 2000
    assert entry.input == 7
    assert entry.output == 3
    assert entry.model == "private-model"
  end

  test "missing and partial provider usage are not free measured-zero requests" do
    for usage <- [nil, %{}, %{input: 12, output: nil, total_tokens: nil, cost: %Cost{}}] do
      occurrence =
        Usage.occurrence(%AssistantMessage{
          provider: :zai,
          model: "glm-5.3",
          usage: usage
        })

      assert occurrence.usage.output == nil
      assert occurrence.usage.total_tokens == nil
      assert occurrence.usage.cost == nil or occurrence.usage.cost.total == nil
      refute occurrence.usage.price_known
    end
  end

  test "string-keyed transported counters are not shadowed by null defaults" do
    occurrence =
      Usage.occurrence(%{
        "role" => "assistant",
        "provider" => "zai",
        "model" => "glm-5.3",
        "usage" => %{
          "input" => 70,
          "output" => 30,
          "cache_read" => 20,
          "cache_write" => 10,
          "total_tokens" => 130,
          "cost" => 0.2
        }
      })

    assert occurrence.usage.input == 70
    assert occurrence.usage.output == 30
    assert occurrence.usage.cache_read == 20
    assert occurrence.usage.cache_write == 10
    assert occurrence.usage.total_tokens == 130
    assert occurrence.usage.cost.total == 0.2
    refute Enum.any?(Map.keys(occurrence.usage), &is_binary/1)

    totals = CodingAgent.Session.Presentation.build_usage([occurrence, occurrence])
    json = totals |> Jason.encode!() |> Jason.decode!()
    assert json["input"] == 140
    assert json["cache_read"] == 40
    assert json["cache_write"] == 20
    assert json["total_tokens"] == 260
  end

  test "observed occurrences retain long-cache subsets and known component costs" do
    usage = %LemonAi.Types.Usage{
      input: 10,
      output: 5,
      cache_read: 0,
      cache_write: 4,
      cache_write_long: 2,
      total_tokens: 19,
      cost: %Cost{input: 0.1, output: 0.2, cache_read: 0.0, cache_write: 0.1, total: 0.4}
    }

    message = %AssistantMessage{provider: :anthropic, model: "offline-fixture", usage: usage}

    translator =
      CodingAgent.Session.RunTranslator.new(
        emitter: Emitter,
        emitter_state: %{completed: []},
        engine: "lemon",
        label: "offline fixture",
        cwd: "/fixture",
        run_id: "parent-run"
      )

    translator =
      translator
      |> CodingAgent.Session.RunTranslator.handle_event({:provider_usage, message})
      |> CodingAgent.Session.RunTranslator.handle_event({:provider_usage, message})
      |> CodingAgent.Session.RunTranslator.handle_event({:agent_end, [message]})

    assert [completed] = translator.emitter_state.completed
    assert completed.usage.cache_write == 8
    assert completed.usage.cache_write_long == 4
    assert completed.usage.total_tokens == 38

    assert completed.usage.cost == %{
             input: 0.2,
             output: 0.4,
             cache_read: 0.0,
             cache_write: 0.2,
             cache_write_long: nil,
             total: 0.8
           }

    assert Enum.all?(completed.usage.occurrences, &(&1.usage.cache_write_long == 2))
  end

  test "four successful turns with missing usage stay unknown despite budget subtotals" do
    message = %AssistantMessage{provider: :zai, model: "glm-5.3", usage: nil}

    translator =
      CodingAgent.Session.RunTranslator.new(
        emitter: Emitter,
        emitter_state: %{completed: []},
        engine: "lemon",
        label: "offline fixture",
        cwd: "/fixture",
        run_id: "parent-run"
      )

    translator =
      Enum.reduce(1..4, translator, fn _, translator ->
        translator
        |> CodingAgent.Session.RunTranslator.handle_event({:provider_usage, message})
        |> CodingAgent.Session.RunTranslator.handle_event({:turn_end, message, []})
      end)
      |> CodingAgent.Session.RunTranslator.handle_event(
        {:usage_budget_updated, %{run_usage: %{tokens: 0, cost_usd: 0.0}}}
      )
      |> CodingAgent.Session.RunTranslator.handle_event({:agent_end, List.duplicate(message, 4)})

    assert [completed] = translator.emitter_state.completed
    assert completed.ok
    assert completed.usage.turns == 4
    assert completed.usage.total_tokens == nil
    assert completed.usage.cost_usd == nil
    assert length(completed.usage.occurrences) == 4

    entries =
      LemonCore.UsageLedger.entries("parent-run", "agent:bot:main", %{completed: completed})

    assert length(entries) == 4
    assert Enum.all?(entries, &(&1.run_id == "parent-run"))
    assert Enum.all?(entries, &(is_nil(&1.input) and is_nil(&1.output) and is_nil(&1.cost)))
  end

  test "multiple complete fixture requests sum disjoint cache and output exactly" do
    alias CodingAgent.Session.Presentation

    # Synthetic offline usage, not a real provider response. Output already
    # includes reasoning; there is no second reasoning charge to add here.
    usage = %LemonAi.Types.Usage{
      input: 70,
      output: 30,
      cache_read: 20,
      cache_write: 10,
      total_tokens: 130,
      cost: %Cost{input: 0.1, output: 0.1, total: 0.2}
    }

    messages = List.duplicate(%AssistantMessage{usage: usage}, 2)
    totals = Presentation.build_usage(messages)
    assert totals.input == 140
    assert totals.output == 60
    assert totals.cache_read == 40
    assert totals.cache_write == 20
    assert totals.total_tokens == 260
    assert totals.cost.total == 0.4
    assert totals.context_tokens == 130

    translator =
      CodingAgent.Session.RunTranslator.new(
        emitter: Emitter,
        emitter_state: %{completed: []},
        engine: "lemon",
        label: "offline fixture",
        cwd: "/fixture",
        run_id: "parent-run"
      )

    message = %AssistantMessage{usage: usage, provider: :zai, model: "glm-5.3"}

    translator =
      translator
      |> CodingAgent.Session.RunTranslator.handle_event({:provider_usage, message})
      |> CodingAgent.Session.RunTranslator.handle_event({:provider_usage, message})
      # Terminal messages may omit an earlier interrupted/retried response.
      |> CodingAgent.Session.RunTranslator.handle_event({:agent_end, [message]})

    assert [completed] = translator.emitter_state.completed
    assert completed.usage.total_tokens == 260
    assert completed.usage.input == 140
    assert completed.usage.cost.total == 0.4
    assert length(completed.usage.occurrences) == 2

    for messages <- [
          messages ++ [%AssistantMessage{usage: nil}],
          [%AssistantMessage{usage: nil} | messages]
        ] do
      partial = Presentation.build_usage(messages)
      assert partial.input == nil
      assert partial.output == nil
      assert partial.total_tokens == nil
      assert partial.cost.total == nil
    end
  end

  test "trace options retain map callbacks and native parent identity" do
    observer = fn _, _ -> :ok end
    usage_observer = fn _, _ -> :ok end

    opts =
      CodingAgent.Session.Presentation.build_session_opts(
        [
          stream_options: %{
            on_payload: observer,
            on_usage: usage_observer,
            headers: %{"derived-header" => "provider"},
            caller_headers: %{"caller-header" => "caller"}
          }
        ],
        "/fixture",
        "parent-run",
        "agent:bot:main",
        "bot"
      )

    stream_options = Keyword.fetch!(opts, :stream_options)
    assert stream_options.on_payload == observer
    assert stream_options.on_usage == usage_observer
    assert stream_options.headers["x-lemon-run-id"] == "parent-run"
    assert stream_options.caller_headers["x-lemon-run-id"] == "parent-run"
    assert stream_options.caller_headers["caller-header"] == "caller"
    refute Map.has_key?(stream_options.caller_headers, "derived-header")

    switched = LemonAgent.ModelRuntime.StreamOptions.sanitize_for_provider_switch(stream_options)
    assert switched.on_payload == observer
    assert switched.on_usage == usage_observer
  end
end
