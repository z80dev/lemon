defmodule LemonSim.LLM.UsageTest do
  use ExUnit.Case, async: true

  alias Ai.Types.{Model, ModelCost, Usage}
  alias LemonSim.LLM.Usage, as: SimUsage

  test "aggregates tokens, decisions, actors, and priced cost" do
    {:ok, collector} = SimUsage.start_link("usage_math")

    model_a = fake_model("openai", "a", %ModelCost{input: 2.0, output: 8.0, cache_read: 1.0})
    model_b = fake_model("anthropic", "b", %ModelCost{input: 3.0, output: 15.0})

    SimUsage.record_response(collector, "operator", model_a, %Usage{
      input: 1_000,
      output: 200,
      cache_read: 500,
      total_tokens: 1_700
    })

    SimUsage.record_response(collector, "operator", model_a, %Usage{
      input: 2_000,
      output: 100,
      cache_write: 50,
      total_tokens: 2_150
    })

    SimUsage.record_decision(collector, "operator", model_a)

    SimUsage.record_response(collector, "worker", model_b, %Usage{
      input: 3_000,
      output: 400,
      total_tokens: 3_400
    })

    SimUsage.record_decision(collector, "worker", model_b)

    artifact = SimUsage.artifact(collector, "usage_math")

    assert artifact.totals.decisions == 2
    assert artifact.totals.input_tokens == 6_000
    assert artifact.totals.output_tokens == 700
    assert artifact.totals.cache_read_tokens == 500
    assert artifact.totals.cache_write_tokens == 50
    assert artifact.totals.cost_usd == 0.0239

    assert artifact.actors["operator"].model_id == "openai:a"
    assert artifact.actors["operator"].decisions == 1
    assert artifact.actors["operator"].input_tokens == 3_000
    assert artifact.actors["operator"].output_tokens == 300
    assert artifact.actors["operator"].cache_read_tokens == 500
    assert artifact.actors["operator"].cache_write_tokens == 50
    assert artifact.actors["operator"].cost_usd == 0.0089

    assert artifact.actors["worker"].model_id == "anthropic:b"
    assert artifact.actors["worker"].decisions == 1
    assert artifact.actors["worker"].cost_usd == 0.015
  end

  test "emits null cost for unknown all-zero model pricing" do
    {:ok, collector} = SimUsage.start_link("usage_unknown")
    model = fake_model("local", "freeish", %ModelCost{})

    SimUsage.record_response(collector, "operator", model, %Usage{
      input: 100,
      output: 20,
      total_tokens: 120
    })

    SimUsage.record_decision(collector, "operator", model)

    artifact = SimUsage.artifact(collector, "usage_unknown")

    assert artifact.totals.cost_usd == nil
    assert artifact.actors["operator"].cost_usd == nil
    assert SimUsage.encode_artifact(artifact) =~ ~s("cost_usd": null)
  end

  defp fake_model(provider, id, cost) do
    %Model{
      id: id,
      name: id,
      api: provider,
      provider: provider,
      cost: cost
    }
  end
end
