defmodule LemonCore.UsageLedgerTest do
  use ExUnit.Case, async: true

  alias LemonCore.UsageLedger

  test "entry extracts provider, model, tokens and cost without prompts or answers" do
    entry =
      UsageLedger.entry("run-1", "agent:s", %{
        completed: %LemonCore.Events.Completion{
          ok: true,
          answer: "secret answer",
          usage: %{"prompt_tokens" => 40, "completion_tokens" => 8, "cost" => 0.01}
        },
        meta: %{model: "openai:gpt-5"},
        prompt: "secret prompt"
      })

    assert %{
             run_id: "run-1",
             session_key: "agent:s",
             provider: "openai",
             model: "gpt-5",
             input: 40,
             output: 8,
             cost: 0.01
           } = entry
  end

  test "an unprefixed model uses the provider from meta, else unknown" do
    usage = %{completed: %{usage: %{input: 1, output: 1}}}

    assert %{provider: "zai", model: "glm"} =
             UsageLedger.entry("r", nil, Map.put(usage, :meta, %{model: "glm", provider: "zai"}))

    assert %{provider: "unknown", model: "glm", session_key: nil} =
             UsageLedger.entry("r", nil, Map.put(usage, :meta, %{model: "glm"}))
  end

  test "sessions per day are bounded and the rest counted as omitted" do
    record =
      Enum.reduce(1..105, %{}, fn i, record ->
        UsageLedger.add_to_record(
          record,
          %{session_key: "s#{i}", provider: "p", model: "m", input: 1, output: 1, cost: 0.0},
          "2026-01-01",
          i
        )
      end)

    assert map_size(record.sessions) == 100
    assert record.sessions_omitted == 5
    assert record.requests == %{"p" => 105}
    assert record.models["p:m"].requests == 105
  end

  test "the finalize hook ignores malformed payloads without raising" do
    assert UsageLedger.handle_finalize_run(:no_such_server, %{run_id: "r", summary: %{}}) == :ok
    assert UsageLedger.handle_finalize_run(%{}) == :ok
  end

  test "parent run owns every occurrence and nil counters survive JSON and ledger projection" do
    occurrences = [
      %{
        run_id: "untrusted-child-run",
        model: "glm-5.3",
        provider: "zai",
        at_ms: 1000,
        usage: %{
          input: 70,
          output: 30,
          cache_read: 20,
          cache_write: 10,
          total_tokens: 130,
          cost: 0.2,
          price_known: true
        }
      },
      %{
        model: "glm-5.3",
        provider: "zai",
        at_ms: 1001,
        usage: %{input: nil, output: 30, total_tokens: 130, cache_read: 20, cache_write: nil}
      },
      %{model: "glm-5.3", provider: "zai", at_ms: 1002, usage: nil}
    ]

    summary =
      %{completed: %{usage: %{occurrences: occurrences}}, meta: %{agent_id: "bot"}}
      |> Jason.encode!()
      |> Jason.decode!()

    assert [complete, partial, missing] =
             UsageLedger.entries("parent-run", "agent:bot:main", summary)

    assert Enum.all?([complete, partial, missing], &(&1.run_id == "parent-run"))
    assert Enum.map([complete, partial, missing], & &1.occurrence) == [0, 1, 2]
    assert complete.input == 100
    assert complete.output == 30
    assert complete.total_tokens == 130
    assert complete.uncached_input == 70
    assert complete.cache_read == 20
    assert complete.cache_write == 10

    assert partial.input == 100
    assert partial.uncached_input == nil
    assert partial.cache_write == nil
    assert partial.cost == nil
    assert missing.input == nil
    assert missing.output == nil
    assert missing.total_tokens == nil
    refute missing.price_known

    record = UsageLedger.occurrence_record(missing)
    assert record.input_tokens == nil
    assert record.output_tokens == nil
    assert record.total_tokens == nil
    assert record.cost_usd == nil
  end

  test "reported positive cost survives missing token counters and unknown attribution" do
    for usage <- [
          %{cost: 0.25},
          %{cost: %{total: 0.25}},
          %{"cost" => %{"total" => 0.25}, "price_known" => true}
        ] do
      entry = UsageLedger.entry("cost-only", nil, %{completed: %{usage: usage}})

      assert %{provider: "unknown", model: "unknown", cost: 0.25, price_known: true} = entry
      assert entry.input == nil
      assert entry.output == nil
      assert entry.total_tokens == nil

      record = UsageLedger.occurrence_record(entry)
      assert record.cost_usd == 0.25
      assert record.price_known
      assert record.input_tokens == nil
      assert record.output_tokens == nil
      assert record.total_tokens == nil
    end
  end

  test "explicit unknown price overrides positive cost without dropping reported tokens" do
    entry =
      UsageLedger.entry("unknown-price", nil, %{
        completed: %{usage: %{"input" => 12, "cost" => 0.25, "price_known" => false}}
      })

    assert entry.uncached_input == 12
    assert entry.input == nil
    assert entry.output == nil
    assert entry.total_tokens == nil
    assert entry.cost == nil
    refute entry.price_known
  end

  test "known zero needs explicit provenance and complete counters" do
    usage = %{input: 12, output: 3, cache_read: 0, cache_write: 0, cost: 0.0}
    summary = %{completed: %{usage: usage}}

    assert %{input: 12, output: 3, total_tokens: 15, cost: nil, price_known: false} =
             UsageLedger.entry("unpriced", nil, summary)

    assert %{input: 12, output: 3, total_tokens: 15, cost: 0.0, price_known: true} =
             UsageLedger.entry("free", nil, %{
               completed: %{usage: Map.put(usage, :price_known, true)}
             })
  end

  test "historical missing usage is absent but an explicit missing occurrence is retained" do
    assert UsageLedger.entry("absent", nil, %{completed: %{usage: nil}}) == nil
    assert UsageLedger.entries("absent", nil, %{completed: %{usage: nil}}) == []

    assert [entry] =
             UsageLedger.entries("observed", nil, %{
               completed: %{usage: %{occurrences: [%{usage: nil}]}}
             })

    assert entry.run_id == "observed"
    assert entry.occurrence == 0
    assert entry.input == nil
    assert entry.output == nil
    assert entry.total_tokens == nil
    assert entry.cost == nil
    refute entry.price_known
  end

  test "a partial request cannot attest a known zero price or a complete total" do
    entry =
      UsageLedger.entry("partial", "agent:bot:main", %{
        completed: %{usage: %{input: 12, cost: 0.0, price_known: true}}
      })

    assert entry.uncached_input == 12
    assert entry.input == nil
    assert entry.output == nil
    assert entry.total_tokens == nil
    assert entry.cost == nil
    refute entry.price_known
  end
end
