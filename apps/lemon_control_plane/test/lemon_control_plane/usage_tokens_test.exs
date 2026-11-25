defmodule LemonControlPlane.UsageTokensTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.UsageTokens
  alias LemonCore.Events.Usage

  describe "normalize/1" do
    test "preserves native cache, context, and benchmark counters" do
      usage = %{
        input: 100,
        output: 20,
        cache_read: 800,
        cache_write: 50,
        total_tokens: 970,
        context_tokens: 920,
        turns: 3,
        tool_errors: 1
      }

      expected = %{
        "cacheReadTokens" => 800,
        "cacheWriteTokens" => 50,
        "contextTokens" => 920,
        "totalTokens" => 970,
        "turns" => 3,
        "tool_errors" => 1
      }

      assert ^expected = Map.take(UsageTokens.normalize(usage), Map.keys(expected))
      assert ^expected = Map.take(UsageTokens.normalize(Usage.new(usage)), Map.keys(expected))
    end

    test "returns nil for anything without numbers in it" do
      assert UsageTokens.normalize(nil) == nil
      assert UsageTokens.normalize(%{}) == nil
      assert UsageTokens.normalize("usage") == nil
      assert UsageTokens.normalize(%{"model" => "gpt-5.4"}) == nil
    end

    test "reads only canonical field names" do
      for usage <- [
            %{
              input_tokens: 1_200,
              output_tokens: 340,
              cache_read_input_tokens: 8_000,
              cache_creation_input_tokens: 500
            },
            %{
              "prompt_tokens" => 5_000,
              "completion_tokens" => 20,
              "cached_input_tokens" => 4_000
            },
            %{"inputTokens" => 7, "outputTokens" => 2, "contextTokens" => 9}
          ] do
        assert UsageTokens.normalize(usage) == nil
      end
    end

    test "keeps latest context separate from cumulative cache-inclusive totals" do
      usage = %{
        input: 1_200,
        output: 340,
        cache_read: 8_000,
        cache_write: 500,
        context_tokens: 3_200
      }

      assert %{"contextTokens" => 3_200, "totalTokens" => 10_040} =
               UsageTokens.normalize(usage)
    end

    test "context falls back to the last call, never the cumulative input" do
      cumulative = %{input: 1_200, output: 340, cache_read: 8_000, cache_write: 500}

      assert %{"contextTokens" => nil, "totalTokens" => 10_040} =
               UsageTokens.normalize(cumulative)

      calls = [
        %{usage: %{input: 1_000, cache_read: 7_000, cache_write: 500}},
        %{usage: %{input: 200, cache_read: 1_000, cache_write: 0}}
      ]

      assert %{"contextTokens" => 1_200, "totalTokens" => 10_040} =
               UsageTokens.normalize(Map.put(cumulative, :occurrences, calls))
    end

    test "reads the session.detail spelling (:input/:output/:total_tokens/:cost)" do
      usage = %{input: 90, output: 10, total_tokens: 100, cost: %{total: 0.0042}}

      assert %{
               "inputTokens" => 90,
               "outputTokens" => 10,
               "totalTokens" => 100,
               "contextTokens" => nil,
               "costUsd" => 0.0042
             } = UsageTokens.normalize(usage)
    end

    test "cache reads alone do not attest the missing input or output counters" do
      assert %{"contextTokens" => nil, "totalTokens" => nil, "cacheReadTokens" => 2_048} =
               UsageTokens.normalize(%{cache_read: 2_048})
    end

    test "accepts string keys" do
      assert %{"inputTokens" => 7, "outputTokens" => 3, "totalTokens" => nil} =
               UsageTokens.normalize(%{"input" => 7, "output" => 3})
    end

    test "keeps a reported total over the computed one" do
      assert %{"totalTokens" => 999} =
               UsageTokens.normalize(%{input: 1, output: 1, total_tokens: 999})
    end

    test "missing components remain null even with turns and nominal zero cost" do
      normalized =
        UsageTokens.normalize(%{
          input: nil,
          output: 30,
          cache_read: 20,
          cache_write: nil,
          total_tokens: 130,
          cost: %{total: nil},
          turns: 4
        })

      assert normalized["inputTokens"] == nil
      assert normalized["cacheWriteTokens"] == nil
      assert normalized["outputTokens"] == 30
      assert normalized["totalTokens"] == 130
      assert normalized["costUsd"] == nil
      assert normalized["turns"] == 4
    end

    test "zero cache counts permit complete sums while missing counts stay unknown" do
      assert %{"totalTokens" => 3} =
               UsageTokens.normalize(%{input: 1, output: 2, cache_read: 0, cache_write: 0})

      assert %{"totalTokens" => nil} =
               UsageTokens.normalize(%{input: 1, output: 2, cache_read: nil, cache_write: 0})
    end

    test "positive reported cost remains known when token counters are unavailable" do
      for usage <- [%{cost: 0.25}, %{"cost" => %{"total" => 0.25}}] do
        normalized = UsageTokens.normalize(usage)

        assert normalized["costUsd"] == 0.25
        assert normalized["inputTokens"] == nil
        assert normalized["outputTokens"] == nil
        assert normalized["totalTokens"] == nil
        assert normalized["contextTokens"] == nil
      end
    end

    test "partial tokens do not erase a positive cost or attest a nominal zero" do
      usage = %{input: 12, output: 3, cache_read: 20, cache_write: nil, cost: 0.25}
      normalized = UsageTokens.normalize(usage)

      assert normalized["inputTokens"] == 12
      assert normalized["outputTokens"] == 3
      assert normalized["cacheWriteTokens"] == nil
      assert normalized["contextTokens"] == nil
      assert normalized["totalTokens"] == nil
      assert normalized["costUsd"] == 0.25

      assert UsageTokens.normalize(Map.put(usage, :price_known, false))["costUsd"] == nil
      assert UsageTokens.normalize(Map.put(usage, :cost, 0.0))["costUsd"] == nil
    end
  end
end
