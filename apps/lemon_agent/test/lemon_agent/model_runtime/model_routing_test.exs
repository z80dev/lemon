defmodule LemonAgent.ModelRuntime.ModelRoutingTest do
  use ExUnit.Case, async: true

  alias LemonAgent.ModelRuntime.ModelRouting
  alias LemonAi.Types.{Context, Model, ModelCost, StreamOptions, TextContent, Tool, UserMessage}

  @cap_error {:error, :model_routing_cost_cap}

  describe "prepare/2" do
    test "disabled configuration ignores inactive values and never resolves" do
      resolver = fn _ -> flunk("disabled routing must not resolve models") end

      for raw <- [nil, %{}, %{rules: :invalid}, %{"enabled" => false, "unknown" => :invalid}] do
        assert ModelRouting.prepare(raw, resolver) == nil
      end

      model = model("default")
      assert ModelRouting.select(nil, model, %{}, %{}) == {:ok, model}
      assert ModelRouting.check_cap(nil, %{model | cost: nil}, %{}, %{}) == :ok
    end

    test "resolves rules in order and normalizes string keys" do
      resolver = fn selector ->
        send(self(), {:resolved, selector})
        model(selector)
      end

      policy =
        ModelRouting.prepare(
          %{
            "enabled" => true,
            "max_cost_usd" => 1,
            "rules" => [
              %{"model" => "first", "contains" => "HELLO", "min_chars" => 0, "max_chars" => 9},
              %{"model" => "second"}
            ]
          },
          resolver
        )

      assert policy.max_cost_usd == 1

      assert [
               %{model: %Model{id: "first"}, contains: "hello", min_chars: 0, max_chars: 9},
               %{model: %Model{id: "second"}}
             ] = policy.rules

      assert_received {:resolved, "first"}
      assert_received {:resolved, "second"}
    end

    test "rejects invalid enabled policies without exposing raw values" do
      invalid = [
        :not_a_table,
        %{enabled: "true"},
        %{enabled: true},
        %{enabled: true, max_cost_usd: nil},
        %{enabled: true, max_cost_usd: -1},
        %{enabled: true, max_cost_usd: "secret-cap"},
        %{enabled: true, max_cost_usd: 1, unknown_secret: "secret-value"},
        %{enabled: true, max_cost_usd: 1, rules: %{}},
        %{enabled: true, max_cost_usd: 1, rules: false},
        %{enabled: true, max_cost_usd: 1, rules: nil},
        %{"enabled" => true, enabled: true, max_cost_usd: 1}
      ]

      for raw <- invalid do
        error = assert_raise ArgumentError, fn -> ModelRouting.prepare(raw, &model/1) end
        assert error.message =~ "model_routing"
        refute error.message =~ "secret"
      end

      assert %{max_cost_usd: 0, rules: []} =
               ModelRouting.prepare(%{enabled: true, max_cost_usd: 0}, &model/1)

      assert_raise ArgumentError, fn ->
        ModelRouting.prepare(%{enabled: true, max_cost_usd: 1}, nil)
      end
    end

    test "rejects unknown rule keys, missing selectors, and invalid matcher bounds" do
      for rule <- [
            nil,
            %{},
            %{model: ""},
            %{model: "  "},
            %{model: 1},
            %{model: "first", unknown: true},
            %{model: "first", contains: nil},
            %{model: "first", contains: 12},
            %{model: "first", min_chars: -1},
            %{model: "first", min_chars: 1.0},
            %{model: "first", max_chars: -1},
            %{model: "first", max_chars: nil},
            %{model: "first", min_chars: 2, max_chars: 1}
          ] do
        assert_raise ArgumentError, fn -> prepare([rule]) end
      end
    end

    test "resolver failures and non-model results are safe configuration errors" do
      for resolver <- [
            fn _ -> raise "private-selector-and-credentials" end,
            fn _ -> throw("private-selector-and-credentials") end,
            fn _ -> {:error, "private-selector-and-credentials"} end,
            fn _ -> %Model{} end
          ] do
        error =
          assert_raise ArgumentError, fn ->
            ModelRouting.prepare(
              %{enabled: true, max_cost_usd: 1, rules: [%{model: "private-selector"}]},
              resolver
            )
          end

        assert error.message == "model_routing rule model could not be resolved"
      end
    end
  end

  describe "select/4" do
    test "first matching rule wins and every supplied matcher is required, inclusively" do
      policy =
        prepare([
          %{model: "first", contains: "HELLO", min_chars: 5, max_chars: 5},
          %{model: "second", contains: "hello"},
          %{model: "fallback"}
        ])

      assert selected(policy, "hElLo") == "first"
      assert selected(policy, "hello!") == "second"
      assert selected(policy, "other") == "fallback"

      lower = prepare([%{model: "short", min_chars: 0, max_chars: 0}])
      assert selected(lower, "") == "short"
      assert selected(lower, "x") == "default"
    end

    test "length is Unicode characters, not binary bytes" do
      policy = prepare([%{model: "unicode", contains: "É", min_chars: 1, max_chars: 1}])
      assert selected(policy, "é") == "unicode"
    end

    test "matches only latest user text and ignores system, assistant, tool and image text" do
      policy = prepare([%{model: "matched", contains: "needle"}])

      context = %Context{
        system_prompt: "needle",
        messages: [
          %UserMessage{content: "needle"},
          %UserMessage{
            content: [
              %TextContent{text: "latest "},
              %{"type" => "text", "text" => "ordinary"},
              %{type: :image, text: "needle", data: "needle"}
            ]
          },
          %{role: :assistant, content: "needle"},
          %{role: :tool_result, content: "needle"}
        ]
      }

      assert {:ok, %Model{id: "default"}} =
               ModelRouting.select(policy, model("default"), context, %{max_tokens: 1})

      context = %{
        context
        | messages: context.messages ++ [%{"role" => "user", "content" => "NEEDLE"}]
      }

      assert {:ok, %Model{id: "matched"}} =
               ModelRouting.select(policy, model("default"), context, %{max_tokens: 1})

      assert {:ok, %Model{id: "default"}} =
               ModelRouting.select(policy, model("default"), %Context{}, %{max_tokens: 1})
    end

    test "no matching rule uses default but still enforces the cap" do
      policy = prepare([%{model: "other", contains: "not-present"}], 0)

      assert ModelRouting.select(policy, model("default"), context("hello"), %{max_tokens: 1}) ==
               @cap_error
    end

    test "over-cap first match does not fall through to a cheaper rule or default" do
      expensive = %{model("expensive") | cost: prices(100, 100, 0, 0)}
      cheap = %{model("cheap") | cost: prices(1, 1, 0, 0)}

      resolver = fn
        "expensive" -> expensive
        "cheap" -> cheap
      end

      policy =
        ModelRouting.prepare(
          %{
            enabled: true,
            max_cost_usd: 0.00001,
            rules: [%{model: "expensive"}, %{model: "cheap"}]
          },
          resolver
        )

      assert ModelRouting.select(policy, cheap, context("x"), %{max_tokens: 1}) == @cap_error
    end
  end

  describe "catalog projection" do
    test "known inclusive cost boundary uses binary bytes for prompt and tool schemas" do
      model = %{model("priced") | cost: prices(1, 2, 0, 0)}

      context = %Context{
        system_prompt: "é",
        messages: [%UserMessage{content: "abc"}],
        tools: [%Tool{name: "t", description: "d", parameters: %{"type" => "string"}}]
      }

      # 2 + 3 + 1 + 1 + 4 + 6 = 17 input bytes; ten output tokens at $2/M.
      assert cap(model, context, %{max_tokens: 10}, 37 / 1_000_000) == :ok
      assert cap(model, context, %{max_tokens: 10}, 36 / 1_000_000) == @cap_error
    end

    test "cache read and long-retention cache write variants use the highest input rate" do
      read = %{model("read") | cost: prices(1, 1, 10, 1)}
      write = %{model("write") | cost: prices(1, 1, 1, 10)}
      assert cap(read, context("x"), %{max_tokens: 1}, 11 / 1_000_000) == :ok
      assert cap(read, context("x"), %{max_tokens: 1}, 10 / 1_000_000) == @cap_error
      assert cap(write, context("x"), %{max_tokens: 1}, 17 / 1_000_000) == :ok
      assert cap(write, context("x"), %{max_tokens: 1}, 16 / 1_000_000) == @cap_error
    end

    test "long context and tier variants cannot bypass the cap" do
      cost = %{
        prices(1, 1, 0, 0)
        | long_context: %{
            input_threshold: 0,
            input: 3,
            output: 5,
            cache_read: 0,
            cache_write: 0
          }
      }

      model = %{model("long") | cost: cost, service_tier_cost: %{"priority" => 2}}
      assert cap(model, context("x"), %{max_tokens: 1}, 16 / 1_000_000) == :ok
      assert cap(model, context("x"), %{max_tokens: 1}, 15 / 1_000_000) == @cap_error
    end

    test "unknown, nil, all-zero, negative and partial catalog pricing fail closed" do
      for cost <- [
            nil,
            :unknown,
            %{},
            %ModelCost{},
            %{input: 1, output: 1},
            %{input: 1, output: 1, cache_read: nil, cache_write: 0},
            %{input: 1, output: nil, cache_read: 0, cache_write: 0},
            prices(-1, 1, 0, 0),
            %{prices(1, 1, 0, 0) | long_context: %{input: 2}},
            %{prices(1, 1, 0, 0) | long_context: :unknown}
          ] do
        assert cap(%{model("unknown") | cost: cost}, context("x"), %{max_tokens: 1}, 100) ==
                 @cap_error
      end

      # Declared zero cache rates are valid, unlike missing rates or all-zero pricing.
      assert cap(%{model("known") | cost: prices(1, 0, 0, 0)}, context("x"), %{max_tokens: 1}, 1) ==
               :ok
    end

    test "missing output override uses known catalog maximum and explicit bounds cannot exceed it" do
      model = %{model("bounded") | cost: prices(1, 1, 0, 0), max_tokens: 10}
      assert cap(model, context("x"), %StreamOptions{}, 11 / 1_000_000) == :ok
      assert cap(model, context("x"), [], 10 / 1_000_000) == @cap_error
      assert cap(model, context("x"), [max_tokens: 10], 1) == :ok
      assert cap(model, context("x"), %{"max_tokens" => 10}, 1) == :ok

      for output <- [0, -1, 11, 1.5, "10", false] do
        assert cap(model, context("x"), %{max_tokens: output}, 100) == @cap_error
      end

      for maximum <- [nil, 0, -1, "10", 1.5] do
        invalid = %{model | max_tokens: maximum}
        assert cap(invalid, context("x"), %{}, 100) == @cap_error
        assert cap(invalid, context("x"), %{max_tokens: 1}, 100) == @cap_error
      end
    end

    test "concrete fallback candidates are capped without reapplying routing rules" do
      policy = prepare([%{model: "first"}], 0.00001)
      fallback = %{model("fallback") | cost: prices(100, 100, 0, 0)}

      assert ModelRouting.check_cap(policy, fallback, context("x"), %{max_tokens: 1}) ==
               @cap_error
    end

    test "configured noncatalog additions require explicit prices for selection and fallback" do
      for entry <- [
            %{id: "new-private-model"},
            %{id: "new-private-model", cost: %{input: 1, output: 2}}
          ] do
        providers = %{"anthropic" => %{models: [entry]}}
        model = LemonAgent.ModelRuntime.CustomProviders.lookup(providers, :anthropic, entry.id)
        assert model.cost.input > 0
        resolver = fn _ -> model end

        policy =
          ModelRouting.prepare(
            %{enabled: true, max_cost_usd: 100, rules: [%{model: "anthropic:#{entry.id}"}]},
            resolver,
            providers
          )

        assert ModelRouting.select(policy, model("default"), context("x"), %{max_tokens: 1}) ==
                 @cap_error

        assert ModelRouting.check_cap(policy, model, context("x"), %{max_tokens: 1}) ==
                 @cap_error
      end
    end

    test "exact catalog identities may inherit prices but additions need complete pricing" do
      catalog = LemonAi.Models.get_model(:anthropic, "claude-3-7-sonnet-20250219")

      for entry <- [
            %{id: catalog.id},
            %{id: "new-private-model", cost: prices(1, 2, 0, 0)}
          ] do
        providers = %{"anthropic" => %{models: [entry]}}

        candidate =
          LemonAgent.ModelRuntime.CustomProviders.lookup(providers, :anthropic, entry.id)

        policy =
          ModelRouting.prepare(
            %{enabled: true, max_cost_usd: 100},
            &model/1,
            providers
          )

        assert ModelRouting.select(policy, candidate, context("x"), %{max_tokens: 1}) ==
                 {:ok, candidate}

        assert ModelRouting.check_cap(policy, candidate, context("x"), %{max_tokens: 1}) == :ok
      end
    end
  end

  defp prepare(rules, max_cost_usd \\ 1) do
    ModelRouting.prepare(%{enabled: true, max_cost_usd: max_cost_usd, rules: rules}, &model/1)
  end

  defp model(id) do
    %Model{id: id, provider: :test, api: :test, cost: prices(1, 1, 0, 0), max_tokens: 100}
  end

  defp prices(input, output, cache_read, cache_write) do
    %ModelCost{input: input, output: output, cache_read: cache_read, cache_write: cache_write}
  end

  defp context(text), do: %Context{messages: [%UserMessage{content: text}]}

  defp selected(policy, text) do
    assert {:ok, model} =
             ModelRouting.select(policy, model("default"), context(text), %{max_tokens: 1})

    model.id
  end

  defp cap(model, context, options, maximum) do
    ModelRouting.check_cap(%{max_cost_usd: maximum, rules: []}, model, context, options)
  end
end
