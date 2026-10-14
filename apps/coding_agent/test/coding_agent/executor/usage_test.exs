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
      CodingAgent.Session.RunTranslator.handle_event(translator, {:message_end, message})

    completed =
      CodingAgent.Session.RunTranslator.handle_event(translator, {:agent_end, [message]})

    replay = CodingAgent.Session.RunTranslator.handle_event(completed, {:agent_end, [message]})
    assert [fields] = replay.emitter_state.completed
    assert [%{usage: %{cost: 0.5, price_known: true}}] = fields.usage.occurrences

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
    assert cost == price.total
    refute inspect(Usage.occurrence(message)) =~ "private"

    free = %{message | usage: %LemonAi.Types.Usage{cost: %Cost{}}}
    assert %{usage: %{cost: 0.0, price_known: true}} = Usage.occurrence(free)
    unknown = %{free | provider: :custom, model: "uncatalogued"}
    assert %{usage: %{cost: nil, price_known: false}} = Usage.occurrence(unknown)
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
end
