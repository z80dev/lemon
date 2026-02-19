defmodule Ai.ModelsTest do
  use ExUnit.Case

  alias Ai.Models
  alias Ai.Types.{Model, ModelCost}

  describe "get_model/2" do
    test "returns anthropic model by id" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")

      assert %Model{} = model
      assert model.id == "claude-sonnet-4-20250514"
      assert model.name == "Claude Sonnet 4"
      assert model.api == :anthropic_messages
      assert model.provider == :anthropic
      assert model.base_url == "https://api.anthropic.com"
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.context_window == 200_000
      assert model.max_tokens == 64_000
    end

    test "returns openai model by id" do
      model = Models.get_model(:openai, "gpt-4o")

      assert %Model{} = model
      assert model.id == "gpt-4o"
      assert model.name == "GPT-4o"
      assert model.api == :openai_responses
      assert model.provider == :openai
      assert model.reasoning == false
      assert model.input == [:text, :image]
    end

    test "returns openai-codex model by id (Codex subscription provider)" do
      model = Models.get_model(:"openai-codex", "gpt-5.2")

      assert %Model{} = model
      assert model.id == "gpt-5.2"
      assert model.api == :openai_codex_responses
      assert model.provider == :"openai-codex"
      assert model.base_url == "https://chatgpt.com"
      assert %ModelCost{} = model.cost
      assert model.cost.input == 0.0
    end

    test "returns google model by id" do
      model = Models.get_model(:google, "gemini-2.5-pro")

      assert %Model{} = model
      assert model.id == "gemini-2.5-pro"
      assert model.name == "Gemini 2.5 Pro"
      assert model.api == :google_generative_ai
      assert model.provider == :google
      assert model.reasoning == true
    end

    test "returns nil for unknown model" do
      assert Models.get_model(:anthropic, "nonexistent") == nil
    end

    test "returns nil for unknown provider" do
      assert Models.get_model(:unknown_provider, "some-model") == nil
    end
  end

  describe "get_models/1" do
    test "returns all anthropic models" do
      models = Models.get_models(:anthropic)

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{provider: :anthropic}, &1))
    end

    test "returns all openai models" do
      models = Models.get_models(:openai)

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{provider: :openai}, &1))
    end

    test "returns all openai-codex models" do
      models = Models.get_models(:"openai-codex")

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{provider: :"openai-codex"}, &1))
    end

    test "returns all google models" do
      models = Models.get_models(:google)

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{provider: :google}, &1))
    end

    test "returns empty list for unknown provider" do
      assert Models.get_models(:unknown_provider) == []
    end
  end

  describe "get_providers/0" do
    test "returns all known providers" do
      providers = Models.get_providers()

      assert is_list(providers)
      assert :anthropic in providers
      assert :openai in providers
      assert :"openai-codex" in providers
      assert :google in providers
    end
  end

  describe "list_models/0" do
    test "returns all models from all providers" do
      models = Models.list_models()

      assert is_list(models)
      assert length(models) > 0

      # Should have models from multiple providers
      providers = models |> Enum.map(& &1.provider) |> Enum.uniq()
      assert :anthropic in providers
      assert :openai in providers
      assert :"openai-codex" in providers
      assert :google in providers
    end
  end

  describe "list_models/1 with OpenAI discovery" do
    setup do
      previous_defaults = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared(%{})

      on_exit(fn ->
        Req.default_options(previous_defaults)
        Req.Test.set_req_test_to_private(%{})
      end)

      :ok
    end

    test "filters OpenAI models to those returned by /v1/models" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/models"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-openai-key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "gpt-4o"},
              %{"id" => "gpt-5"}
            ]
          })
        )
      end)

      models =
        Models.list_models(
          discover_openai: true,
          openai_api_key: "test-openai-key",
          openai_base_url: "https://api.openai.com/v1"
        )

      openai_ids =
        models
        |> Enum.filter(&(&1.provider == :openai))
        |> Enum.map(& &1.id)

      assert "gpt-4o" in openai_ids
      assert "gpt-5" in openai_ids
      refute "gpt-4-turbo" in openai_ids
      assert Enum.any?(models, &(&1.provider == :anthropic))
    end

    test "falls back to static models when discovery fails" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "bad gateway"}))
      end)

      static_models = Models.list_models()

      discovered_models =
        Models.list_models(
          discover_openai: true,
          openai_api_key: "test-openai-key",
          openai_base_url: "https://api.openai.com/v1"
        )

      assert Enum.sort_by(discovered_models, &{&1.provider, &1.id}) ==
               Enum.sort_by(static_models, &{&1.provider, &1.id})
    end
  end

  describe "supports_vision?/1" do
    test "returns true for models that support images" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.supports_vision?(model) == true
    end

    test "returns false for text-only models" do
      model = Models.get_model(:openai, "o3-mini")
      assert Models.supports_vision?(model) == false
    end
  end

  describe "supports_reasoning?/1" do
    test "returns true for reasoning models" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.supports_reasoning?(model) == true

      model = Models.get_model(:openai, "o3")
      assert Models.supports_reasoning?(model) == true
    end

    test "returns false for non-reasoning models" do
      model = Models.get_model(:openai, "gpt-4o")
      assert Models.supports_reasoning?(model) == false

      model = Models.get_model(:google, "gemini-2.0-flash")
      assert Models.supports_reasoning?(model) == false
    end
  end

  describe "find_by_id/1" do
    test "finds model across all providers" do
      model = Models.find_by_id("gpt-4o")
      assert model.provider == :openai

      model = Models.find_by_id("claude-sonnet-4-20250514")
      assert model.provider == :anthropic

      model = Models.find_by_id("gemini-2.5-pro")
      assert model.provider == :google
    end

    test "returns nil for unknown model" do
      assert Models.find_by_id("nonexistent-model") == nil
    end
  end

  describe "get_model_ids/1" do
    test "returns model ids for provider" do
      ids = Models.get_model_ids(:anthropic)

      assert is_list(ids)
      assert "claude-sonnet-4-20250514" in ids
      assert "claude-opus-4-5-20251101" in ids
    end

    test "returns empty list for unknown provider" do
      assert Models.get_model_ids(:unknown_provider) == []
    end
  end

  describe "model pricing" do
    test "anthropic models have correct pricing" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")

      assert %ModelCost{} = model.cost
      assert model.cost.input == 3.0
      assert model.cost.output == 15.0
      assert model.cost.cache_read == 0.3
      assert model.cost.cache_write == 3.75
    end

    test "openai models have correct pricing" do
      model = Models.get_model(:openai, "gpt-4o")

      assert %ModelCost{} = model.cost
      assert model.cost.input == 2.5
      assert model.cost.output == 10.0
      assert model.cost.cache_read == 1.25
      assert model.cost.cache_write == 0.0
    end

    test "google models have correct pricing" do
      model = Models.get_model(:google, "gemini-2.5-pro")

      assert %ModelCost{} = model.cost
      assert model.cost.input == 1.25
      assert model.cost.output == 10.0
      assert model.cost.cache_read == 0.31
      assert model.cost.cache_write == 0.0
    end

    test "claude opus 4.5 has correct pricing" do
      model = Models.get_model(:anthropic, "claude-opus-4-5-20251101")

      assert model.cost.input == 5.0
      assert model.cost.output == 25.0
      assert model.cost.cache_read == 0.5
      assert model.cost.cache_write == 6.25
    end

    test "gpt-5 has correct pricing" do
      model = Models.get_model(:openai, "gpt-5")

      assert model.cost.input == 1.25
      assert model.cost.output == 10.0
      assert model.cost.cache_read == 0.125
    end

    test "o1 has correct pricing" do
      model = Models.get_model(:openai, "o1")

      assert model.cost.input == 15.0
      assert model.cost.output == 60.0
      assert model.cost.cache_read == 7.5
    end

    test "claude sonnet 4.6 has correct pricing" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-6")

      assert model.cost.input == 3.0
      assert model.cost.output == 15.0
      assert model.cost.cache_read == 0.3
      assert model.cost.cache_write == 3.75
      assert model.context_window == 200_000
      assert model.max_tokens == 64_000
      assert model.reasoning == true
    end

    test "claude opus 4.6 has correct pricing" do
      model = Models.get_model(:anthropic, "claude-opus-4-6")

      assert model.cost.input == 5.0
      assert model.cost.output == 25.0
      assert model.cost.cache_read == 0.5
      assert model.cost.cache_write == 6.25
      assert model.context_window == 200_000
      assert model.max_tokens == 128_000
      assert model.reasoning == true
    end

    test "gemini 3.1 pro preview has correct specs" do
      model = Models.get_model(:google, "gemini-3.1-pro-preview")

      assert model.cost.input == 2.0
      assert model.cost.output == 12.0
      assert model.cost.cache_read == 0.2
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_536
      assert model.reasoning == true
    end

    test "gpt 5.3 codex spark has correct specs" do
      model = Models.get_model(:openai, "gpt-5.3-codex-spark")

      assert model.cost.input == 1.75
      assert model.cost.output == 14.0
      assert model.cost.cache_read == 0.175
      assert model.cost.cache_write == 0.0
      assert model.context_window == 128_000
      assert model.max_tokens == 32_000
      assert model.reasoning == true
    end
  end

  describe "model context windows" do
    test "claude models have 200k context" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert model.context_window == 200_000
    end

    test "gemini models have large context" do
      model = Models.get_model(:google, "gemini-2.5-pro")
      assert model.context_window == 1_048_576
    end

    test "gpt-5 has 400k context" do
      model = Models.get_model(:openai, "gpt-5")
      assert model.context_window == 400_000
    end
  end

  describe "commonly used models exist" do
    test "anthropic flagship models" do
      assert Models.get_model(:anthropic, "claude-sonnet-4-20250514") != nil
      assert Models.get_model(:anthropic, "claude-opus-4-20250514") != nil
      assert Models.get_model(:anthropic, "claude-opus-4-5-20251101") != nil
      assert Models.get_model(:anthropic, "claude-3-5-haiku-20241022") != nil
      assert Models.get_model(:anthropic, "claude-haiku-4-5-20251001") != nil
      assert Models.get_model(:anthropic, "claude-sonnet-4-6") != nil
      assert Models.get_model(:anthropic, "claude-opus-4-6") != nil
    end

    test "openai flagship models" do
      assert Models.get_model(:openai, "gpt-4o") != nil
      assert Models.get_model(:openai, "gpt-4o-mini") != nil
      assert Models.get_model(:openai, "gpt-5") != nil
      assert Models.get_model(:openai, "o1") != nil
      assert Models.get_model(:openai, "o3") != nil
      assert Models.get_model(:openai, "o3-mini") != nil
      assert Models.get_model(:openai, "gpt-5.2-codex") != nil
      assert Models.get_model(:openai, "gpt-5.3-codex") != nil
      assert Models.get_model(:openai, "gpt-5.3-codex-spark") != nil
    end

    test "google flagship models" do
      assert Models.get_model(:google, "gemini-2.5-pro") != nil
      assert Models.get_model(:google, "gemini-2.5-flash") != nil
      assert Models.get_model(:google, "gemini-2.0-flash") != nil
      assert Models.get_model(:google, "gemini-1.5-pro") != nil
      assert Models.get_model(:google, "gemini-3.1-pro-preview") != nil
    end
  end
end
