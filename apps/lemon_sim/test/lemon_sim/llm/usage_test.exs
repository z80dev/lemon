defmodule LemonSim.LLM.UsageTest do
  use ExUnit.Case, async: true

  alias LemonAi.Types.{Model, ModelCost, Usage}
  alias LemonSim.LLM.Usage, as: SimUsage

  test "aggregates tokens, decisions, actors, and priced cost" do
    {:ok, collector} = SimUsage.start_link("usage_math")

    model_a = fake_model("openai", "a", %ModelCost{input: 2.0, output: 8.0, cache_read: 1.0})
    model_b = fake_model("anthropic", "b", %ModelCost{input: 3.0, output: 15.0})

    SimUsage.record_response(
      collector,
      "operator",
      model_a,
      %Usage{
        input: 1_000,
        output: 200,
        cache_read: 500,
        total_tokens: 1_700
      },
      125
    )

    SimUsage.record_response(collector, "operator", model_a, %Usage{
      input: 2_000,
      output: 100,
      cache_write: 50,
      total_tokens: 2_150
    })

    SimUsage.record_decision(collector, "operator", model_a)

    SimUsage.record_response(
      collector,
      "worker",
      model_b,
      %Usage{
        input: 3_000,
        output: 400,
        total_tokens: 3_400
      },
      275
    )

    SimUsage.record_decision(collector, "worker", model_b)

    artifact = SimUsage.artifact(collector, "usage_math")

    assert artifact.totals.decisions == 2
    assert artifact.totals.input_tokens == 6_000
    assert artifact.totals.output_tokens == 700
    assert artifact.totals.cache_read_tokens == 500
    assert artifact.totals.cache_write_tokens == 50
    assert artifact.totals.latency_ms == 400
    assert artifact.totals.cost_usd == 0.0239

    assert artifact.actors["operator"].model_id == "openai:a"
    assert artifact.actors["operator"].decisions == 1
    assert artifact.actors["operator"].input_tokens == 3_000
    assert artifact.actors["operator"].output_tokens == 300
    assert artifact.actors["operator"].cache_read_tokens == 500
    assert artifact.actors["operator"].cache_write_tokens == 50
    assert artifact.actors["operator"].latency_ms == 125
    assert artifact.actors["operator"].cost_usd == 0.0089

    assert artifact.actors["worker"].model_id == "anthropic:b"
    assert artifact.actors["worker"].decisions == 1
    assert artifact.actors["worker"].latency_ms == 275
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

  test "restores a persisted artifact and keeps accumulating" do
    {:ok, first_collector} = SimUsage.start_link("usage_resumed")
    model = fake_model("openai", "resume", %ModelCost{input: 1.0, output: 2.0})

    SimUsage.record_response(first_collector, "operator", model, %Usage{input: 100, output: 20})
    SimUsage.record_decision(first_collector, "operator", model)
    persisted = SimUsage.artifact(first_collector, "usage_resumed")
    Agent.stop(first_collector)

    {:ok, resumed_collector} = SimUsage.start_link("usage_resumed", persisted)
    SimUsage.record_response(resumed_collector, "operator", model, %Usage{input: 50, output: 10})
    SimUsage.record_decision(resumed_collector, "operator", model)

    artifact = SimUsage.artifact(resumed_collector, "usage_resumed")
    assert artifact.totals.input_tokens == 150
    assert artifact.totals.output_tokens == 30
    assert artifact.totals.decisions == 2
  end

  test "partial responses propagate unknown counters and cost through later known responses" do
    {:ok, collector} = SimUsage.start_link("usage_partial")
    model = fake_model("zai", "partial", %ModelCost{input: 1.0, output: 2.0})

    SimUsage.record_response(collector, "operator", model, %Usage{
      input: nil,
      output: 7,
      cache_read: nil,
      cache_write: nil,
      cache_write_long: nil,
      total_tokens: nil,
      cost: nil
    })

    known = %Usage{input: 100, output: 20, cache_read: 0, cache_write: 0}
    SimUsage.record_response(collector, "operator", model, known, 10)
    SimUsage.record_response(collector, "worker", model, known, 15)
    SimUsage.record_decision(collector, "operator", model)
    artifact = SimUsage.artifact(collector, "usage_partial")

    assert Process.alive?(collector)
    refute artifact.cost_known?
    assert artifact.totals.input_tokens == nil
    assert artifact.totals.output_tokens == 47
    assert artifact.totals.cache_read_tokens == nil
    assert artifact.totals.cache_write_tokens == nil
    assert artifact.totals.cost_usd == nil
    assert artifact.totals.decisions == 1
    assert artifact.totals.latency_ms == 25
    assert artifact.actors["operator"].input_tokens == nil
    assert artifact.actors["operator"].output_tokens == 27
    assert artifact.actors["operator"].cost_usd == nil
    assert artifact.actors["worker"].input_tokens == 100
    assert artifact.actors["worker"].cost_usd == 0.00014
  end

  test "every nullable usage counter keeps the collector alive" do
    model = fake_model("openai", "nullable", %ModelCost{input: 1.0, output: 2.0})

    for field <- [:input, :output, :cache_read, :cache_write, :cache_write_long] do
      {:ok, collector} = SimUsage.start_link("usage_nil_#{field}")
      usage = Map.put(%Usage{input: 10, output: 2}, field, nil)
      SimUsage.record_response(collector, "operator", model, usage)
      artifact = SimUsage.artifact(collector, "usage_nil_#{field}")

      assert Process.alive?(collector)
      refute artifact.cost_known?
      assert artifact.totals.cost_usd == nil
      assert artifact.actors["operator"].cost_usd == nil
    end
  end

  test "missing response usage is unknown rather than an unrecorded zero" do
    {:ok, collector} = SimUsage.start_link("usage_missing")
    model = fake_model("openai", "missing", %ModelCost{input: 1.0, output: 2.0})
    SimUsage.record_response(collector, "operator", model, nil, 5)
    artifact = SimUsage.artifact(collector, "usage_missing")

    assert Process.alive?(collector)
    refute artifact.cost_known?
    assert artifact.totals.input_tokens == nil
    assert artifact.totals.output_tokens == nil
    assert artifact.totals.cache_read_tokens == nil
    assert artifact.totals.cache_write_tokens == nil
    assert artifact.totals.cost_usd == nil
    assert artifact.totals.latency_ms == 5
  end

  test "a priced catalog model with an unknown cost component has unknown cost" do
    {:ok, collector} = SimUsage.start_link("usage_partial_price")
    model = fake_model("openai", "partial-price", %ModelCost{input: 1.0, output: nil})
    SimUsage.record_response(collector, "operator", model, %Usage{input: 100, output: 20})
    artifact = SimUsage.artifact(collector, "usage_partial_price")

    assert Process.alive?(collector)
    refute artifact.cost_known?
    assert artifact.totals.input_tokens == 100
    assert artifact.totals.output_tokens == 20
    assert artifact.totals.cost_usd == nil
    assert artifact.actors["operator"].cost_usd == nil
  end

  test "JSON round trips and resumed accumulation retain unknown measurements" do
    model = fake_model("zai", "resume-partial", %ModelCost{input: 1.0, output: 2.0})
    {:ok, collector} = SimUsage.start_link("usage_partial_resume")

    SimUsage.record_response(collector, "operator", model, %Usage{
      input: nil,
      output: 7,
      cache_read: 0,
      cache_write: nil
    })

    persisted =
      collector |> SimUsage.artifact("usage_partial_resume") |> SimUsage.encode_artifact()

    decoded = Jason.decode!(persisted)
    assert decoded["totals"]["input_tokens"] == nil
    assert decoded["totals"]["cache_read_tokens"] == 0
    assert decoded["actors"]["operator"]["cache_write_tokens"] == nil

    assert SimUsage.summary_line(decoded) ==
             "usage: unknown in / 7 out, unknown cost (1 actors)"

    {:ok, resumed} = SimUsage.start_link("usage_partial_resume", decoded)
    SimUsage.record_response(resumed, "operator", model, %Usage{input: 50, output: 3})
    artifact = SimUsage.artifact(resumed, "usage_partial_resume")

    refute artifact.cost_known?
    assert artifact.totals.input_tokens == nil
    assert artifact.totals.output_tokens == 10
    assert artifact.totals.cache_read_tokens == 0
    assert artifact.totals.cache_write_tokens == nil
    assert artifact.actors["operator"].input_tokens == nil
    assert artifact.actors["operator"].cost_usd == nil
    assert SimUsage.encode_artifact(decoded) == persisted
  end

  test "normalization never replaces absent token measurements with zeros" do
    persisted = %{
      "schema" => "lemon_sim.usage.v1",
      "sim_id" => "usage_absent",
      "cost_known?" => true,
      "totals" => %{"output_tokens" => nil, "cost_usd" => nil},
      "actors" => %{"operator" => %{"model_id" => "zai:partial"}}
    }

    artifact = SimUsage.artifact(persisted, "usage_absent")
    refute artifact.cost_known?
    assert artifact.totals.input_tokens == nil
    assert artifact.totals.output_tokens == nil
    assert artifact.actors["operator"].cache_read_tokens == nil
    assert artifact.actors["operator"].cache_write_tokens == nil

    assert SimUsage.summary_line(persisted) ==
             "usage: unknown in / unknown out, unknown cost (1 actors)"
  end

  test "normalization honors an explicit unknown-cost flag with numeric stored totals" do
    artifact = %{SimUsage.new("usage_unknown_flag") | cost_known?: false}
    normalized = SimUsage.artifact(artifact, "usage_unknown_flag")
    refute normalized.cost_known?
    assert normalized.totals.cost_usd == nil

    persisted = artifact |> Jason.encode!() |> Jason.decode!()
    normalized = SimUsage.artifact(persisted, "usage_unknown_flag")
    refute normalized.cost_known?
    assert normalized.totals.cost_usd == nil
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
