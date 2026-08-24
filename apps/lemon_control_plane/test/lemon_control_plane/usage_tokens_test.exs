defmodule LemonControlPlane.UsageTokensTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.UsageTokens

  describe "normalize/1" do
    test "returns nil for anything without numbers in it" do
      assert UsageTokens.normalize(nil) == nil
      assert UsageTokens.normalize(%{}) == nil
      assert UsageTokens.normalize("usage") == nil
      assert UsageTokens.normalize(%{"model" => "gpt-5.4"}) == nil
    end

    test "reads the anthropic spelling and folds cache reads into the context size" do
      usage = %{
        input_tokens: 1_200,
        output_tokens: 340,
        cache_read_input_tokens: 8_000,
        cache_creation_input_tokens: 500
      }

      assert %{
               "inputTokens" => 1_200,
               "outputTokens" => 340,
               "cacheReadTokens" => 8_000,
               "cacheWriteTokens" => 500,
               "contextTokens" => 9_700,
               "totalTokens" => 1_540
             } = UsageTokens.normalize(usage)
    end

    test "reads the session.detail spelling (:input/:output/:total_tokens/:cost)" do
      usage = %{input: 90, output: 10, total_tokens: 100, cost: %{total: 0.0042}}

      assert %{
               "inputTokens" => 90,
               "outputTokens" => 10,
               "totalTokens" => 100,
               "contextTokens" => 90,
               "costUsd" => 0.0042
             } = UsageTokens.normalize(usage)
    end

    test "treats prompt_tokens as already cache-inclusive" do
      usage = %{"prompt_tokens" => 5_000, "completion_tokens" => 20, "cached_input_tokens" => 4_000}

      normalized = UsageTokens.normalize(usage)

      assert normalized["inputTokens"] == 5_000
      assert normalized["outputTokens"] == 20
      # Not 9_000: adding the cache on top would double-count what prompt_tokens already has.
      assert normalized["contextTokens"] == 5_000
    end

    test "falls back to cache reads alone when no input count was reported" do
      assert %{"contextTokens" => 2_048} =
               UsageTokens.normalize(%{cache_read_input_tokens: 2_048})
    end

    test "accepts string keys and numeric strings" do
      assert %{"inputTokens" => 7, "outputTokens" => 3, "totalTokens" => 10} =
               UsageTokens.normalize(%{"input_tokens" => "7", "output_tokens" => "3"})
    end

    test "keeps a reported total over the computed one" do
      assert %{"totalTokens" => 999} =
               UsageTokens.normalize(%{input: 1, output: 1, total_tokens: 999})
    end
  end
end
