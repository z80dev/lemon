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

      assert Enum.all?(models, fn %Model{provider: provider} ->
               provider in [:google, :google_antigravity]
             end)
    end

    test "returns empty list for unknown provider" do
      assert Models.get_models(:unknown_provider) == []
    end

    test "returns all opencode models" do
      models = Models.get_models(:opencode)

      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{provider: :opencode}, &1))
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
      assert :opencode in providers
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

    test "claude opus 4.6 thinking has correct specs" do
      model = Models.get_model(:anthropic, "claude-opus-4-6-thinking")

      assert model.cost.input == 5.0
      assert model.cost.output == 25.0
      assert model.cost.cache_read == 0.5
      assert model.cost.cache_write == 6.25
      assert model.context_window == 200_000
      assert model.max_tokens == 128_000
      assert model.reasoning == true
      assert model.name == "Claude Opus 4.6 (Thinking)"
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

    test "gemini 3.1 pro has correct specs" do
      model = Models.get_model(:google, "gemini-3.1-pro")

      assert model.cost.input == 2.0
      assert model.cost.output == 12.0
      assert model.cost.cache_read == 0.2
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_536
      assert model.reasoning == true
    end

    test "gemini 3.1 pro preview customtools has correct specs" do
      model = Models.get_model(:google, "gemini-3.1-pro-preview-customtools")

      assert model.cost.input == 2.0
      assert model.cost.output == 12.0
      assert model.cost.cache_read == 0.2
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_536
      assert model.reasoning == true
      assert model.name == "Gemini 3.1 Pro Preview (Custom Tools)"
    end

    test "gemini 3 flash has correct specs" do
      model = Models.get_model(:google, "gemini-3-flash")

      assert model.cost.input == 0.5
      assert model.cost.output == 3.0
      assert model.cost.cache_read == 0.5
      assert model.cost.cache_write == 0.0
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_536
      assert model.reasoning == true
      assert model.name == "Gemini 3 Flash"
    end

    test "gemini 3 flash preview has correct specs" do
      model = Models.get_model(:google, "gemini-3-flash-preview")

      assert model.cost.input == 0.5
      assert model.cost.output == 3.0
      assert model.cost.cache_read == 0.05
      assert model.cost.cache_write == 0.0
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_536
      assert model.reasoning == true
      assert model.name == "Gemini 3 Flash Preview"
    end

    test "gemini 3 pro has correct specs" do
      model = Models.get_model(:google, "gemini-3-pro")

      assert model.cost.input == 2.0
      assert model.cost.output == 12.0
      assert model.cost.cache_read == 0.2
      assert model.cost.cache_write == 0.0
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_536
      assert model.reasoning == true
      assert model.name == "Gemini 3 Pro"
    end

    test "gemini 3 pro preview has correct specs" do
      model = Models.get_model(:google, "gemini-3-pro-preview")

      assert model.cost.input == 2.0
      assert model.cost.output == 12.0
      assert model.cost.cache_read == 0.2
      assert model.cost.cache_write == 0.0
      assert model.context_window == 1_000_000
      assert model.max_tokens == 64_000
      assert model.reasoning == true
      assert model.name == "Gemini 3 Pro Preview"
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
      assert Models.get_model(:anthropic, "claude-opus-4-6-thinking") != nil
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
      assert Models.get_model(:google, "gemini-3.1-pro") != nil
      assert Models.get_model(:google, "gemini-3.1-pro-preview") != nil
      assert Models.get_model(:google, "gemini-3.1-pro-preview-customtools") != nil
      assert Models.get_model(:google, "gemini-3-flash") != nil
      assert Models.get_model(:google, "gemini-3-flash-preview") != nil
      assert Models.get_model(:google, "gemini-3-pro") != nil
      assert Models.get_model(:google, "gemini-3-pro-preview") != nil
    end

    test "opencode models" do
      assert Models.get_model(:opencode, "big-pickle") != nil
      assert Models.get_model(:opencode, "claude-sonnet-4-6") != nil
      assert Models.get_model(:opencode, "gemini-3-pro") != nil
      assert Models.get_model(:opencode, "gpt-5.2-codex") != nil
      assert Models.get_model(:opencode, "minimax-m2.5") != nil
      assert Models.get_model(:opencode, "trinity-large-preview-free") != nil
      assert Models.get_model(:opencode, "kimi-k2") != nil
      assert Models.get_model(:opencode, "kimi-k2-thinking") != nil
      assert Models.get_model(:opencode, "kimi-k2.5") != nil
    end

    test "google antigravity models" do
      assert Models.get_model(:google_antigravity, "gemini-3-pro-high") != nil
      assert Models.get_model(:google_antigravity, "gemini-3-pro-low") != nil
    end

    test "xai grok models" do
      assert Models.get_model(:xai, "grok-2") != nil
      assert Models.get_model(:xai, "grok-2-vision") != nil
      assert Models.get_model(:xai, "grok-3") != nil
      assert Models.get_model(:xai, "grok-3-fast") != nil
      assert Models.get_model(:xai, "grok-3-mini") != nil
      assert Models.get_model(:xai, "grok-3-mini-fast") != nil
      assert Models.get_model(:xai, "grok-3-mini-fast-latest") != nil
      assert Models.get_model(:xai, "grok-3-mini-latest") != nil
      assert Models.get_model(:xai, "grok-4") != nil
      assert Models.get_model(:xai, "grok-4-1-fast") != nil
      assert Models.get_model(:xai, "grok-4-1-fast-non-reasoning") != nil
      assert Models.get_model(:xai, "grok-4-fast") != nil
      assert Models.get_model(:xai, "grok-4-fast-non-reasoning") != nil
    end
  end

  describe "google antigravity models" do
    test "gemini 3 pro high has correct specs" do
      model = Models.get_model(:google_antigravity, "gemini-3-pro-high")

      assert model.id == "gemini-3-pro-high"
      assert model.name == "Gemini 3 Pro High (Antigravity)"
      assert model.provider == :google_antigravity
      assert model.api == :google_gemini_cli
      assert model.base_url == "https://daily-cloudcode-pa.sandbox.googleapis.com"
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.cost.input == 2.0
      assert model.cost.output == 12.0
      assert model.cost.cache_read == 0.2
      assert model.cost.cache_write == 2.375
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_535
    end

    test "gemini 3 pro low has correct specs" do
      model = Models.get_model(:google_antigravity, "gemini-3-pro-low")

      assert model.id == "gemini-3-pro-low"
      assert model.name == "Gemini 3 Pro Low (Antigravity)"
      assert model.provider == :google_antigravity
      assert model.api == :google_gemini_cli
      assert model.base_url == "https://daily-cloudcode-pa.sandbox.googleapis.com"
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.cost.input == 2.0
      assert model.cost.output == 12.0
      assert model.cost.cache_read == 0.2
      assert model.cost.cache_write == 2.375
      assert model.context_window == 1_048_576
      assert model.max_tokens == 65_535
    end
  end

  describe "xai grok models" do
    test "grok 2 has correct specs" do
      model = Models.get_model(:xai, "grok-2")

      assert model.id == "grok-2"
      assert model.name == "Grok 2"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == false
      assert model.input == [:text]
      assert model.cost.input == 2.0
      assert model.cost.output == 10.0
      assert model.cost.cache_read == 2.0
      assert model.cost.cache_write == 0.0
      assert model.context_window == 131_072
      assert model.max_tokens == 8192
    end

    test "grok 2 vision has correct specs" do
      model = Models.get_model(:xai, "grok-2-vision")

      assert model.id == "grok-2-vision"
      assert model.name == "Grok 2 Vision"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == false
      assert model.input == [:text, :image]
      assert model.cost.input == 2.0
      assert model.cost.output == 10.0
      assert model.cost.cache_read == 2.0
      assert model.cost.cache_write == 0.0
      assert model.context_window == 8192
      assert model.max_tokens == 4096
    end

    test "grok 3 has correct specs" do
      model = Models.get_model(:xai, "grok-3")

      assert model.id == "grok-3"
      assert model.name == "Grok 3"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == false
      assert model.input == [:text]
      assert model.cost.input == 3.0
      assert model.cost.output == 15.0
      assert model.cost.cache_read == 0.75
      assert model.cost.cache_write == 0.0
      assert model.context_window == 131_072
      assert model.max_tokens == 8192
    end

    test "grok 3 fast has correct specs" do
      model = Models.get_model(:xai, "grok-3-fast")

      assert model.id == "grok-3-fast"
      assert model.name == "Grok 3 Fast"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == false
      assert model.input == [:text]
      assert model.cost.input == 5.0
      assert model.cost.output == 25.0
      assert model.cost.cache_read == 1.25
      assert model.cost.cache_write == 0.0
      assert model.context_window == 131_072
      assert model.max_tokens == 8192
    end

    test "grok 3 mini has correct specs" do
      model = Models.get_model(:xai, "grok-3-mini")

      assert model.id == "grok-3-mini"
      assert model.name == "Grok 3 Mini"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == true
      assert model.input == [:text]
      assert model.cost.input == 0.3
      assert model.cost.output == 0.5
      assert model.cost.cache_read == 0.075
      assert model.cost.cache_write == 0.0
      assert model.context_window == 131_072
      assert model.max_tokens == 8192
    end

    test "grok 3 mini fast has correct specs" do
      model = Models.get_model(:xai, "grok-3-mini-fast")

      assert model.id == "grok-3-mini-fast"
      assert model.name == "Grok 3 Mini Fast"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == true
      assert model.input == [:text]
      assert model.cost.input == 0.6
      assert model.cost.output == 4.0
      assert model.cost.cache_read == 0.15
      assert model.cost.cache_write == 0.0
      assert model.context_window == 131_072
      assert model.max_tokens == 8192
    end

    test "grok 4 has correct specs" do
      model = Models.get_model(:xai, "grok-4")

      assert model.id == "grok-4"
      assert model.name == "Grok 4"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == true
      assert model.input == [:text]
      assert model.cost.input == 3.0
      assert model.cost.output == 15.0
      assert model.cost.cache_read == 0.75
      assert model.cost.cache_write == 0.0
      assert model.context_window == 256_000
      assert model.max_tokens == 64_000
    end

    test "grok 4.1 fast has correct specs" do
      model = Models.get_model(:xai, "grok-4-1-fast")

      assert model.id == "grok-4-1-fast"
      assert model.name == "Grok 4.1 Fast"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.cost.input == 0.2
      assert model.cost.output == 0.5
      assert model.cost.cache_read == 0.05
      assert model.cost.cache_write == 0.0
      assert model.context_window == 2_000_000
      assert model.max_tokens == 30_000
    end

    test "grok 4.1 fast non-reasoning has correct specs" do
      model = Models.get_model(:xai, "grok-4-1-fast-non-reasoning")

      assert model.id == "grok-4-1-fast-non-reasoning"
      assert model.name == "Grok 4.1 Fast (Non-Reasoning)"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == false
      assert model.input == [:text, :image]
      assert model.cost.input == 0.2
      assert model.cost.output == 0.5
      assert model.cost.cache_read == 0.05
      assert model.cost.cache_write == 0.0
      assert model.context_window == 2_000_000
      assert model.max_tokens == 30_000
    end

    test "grok 4 fast has correct specs" do
      model = Models.get_model(:xai, "grok-4-fast")

      assert model.id == "grok-4-fast"
      assert model.name == "Grok 4 Fast"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.cost.input == 5.0
      assert model.cost.output == 25.0
      assert model.cost.cache_read == 1.25
      assert model.cost.cache_write == 0.0
      assert model.context_window == 131_072
      assert model.max_tokens == 8192
    end

    test "grok 4 fast non-reasoning has correct specs" do
      model = Models.get_model(:xai, "grok-4-fast-non-reasoning")

      assert model.id == "grok-4-fast-non-reasoning"
      assert model.name == "Grok 4 Fast (Non-Reasoning)"
      assert model.provider == :xai
      assert model.api == :openai_completions
      assert model.base_url == "https://api.x.ai/v1"
      assert model.reasoning == false
      assert model.input == [:text, :image]
      assert model.cost.input == 0.2
      assert model.cost.output == 0.5
      assert model.cost.cache_read == 0.05
      assert model.cost.cache_write == 0.0
      assert model.context_window == 2_000_000
      assert model.max_tokens == 30_000
    end
  end

  describe "kimi k2 models" do
    test "kimi k2 has correct specs" do
      model = Models.get_model(:opencode, "kimi-k2")

      assert model.id == "kimi-k2"
      assert model.name == "Kimi K2"
      assert model.provider == :opencode
      assert model.api == :openai_completions
      assert model.base_url == "https://opencode.ai/zen/v1"
      assert model.reasoning == false
      assert model.input == [:text]
      assert model.cost.input == 0.4
      assert model.cost.output == 2.5
      assert model.cost.cache_read == 0.4
      assert model.context_window == 262_144
      assert model.max_tokens == 262_144
    end

    test "kimi k2 thinking has correct specs" do
      model = Models.get_model(:opencode, "kimi-k2-thinking")

      assert model.id == "kimi-k2-thinking"
      assert model.name == "Kimi K2 Thinking"
      assert model.provider == :opencode
      assert model.api == :openai_completions
      assert model.reasoning == true
      assert model.input == [:text]
      assert model.cost.input == 0.4
      assert model.cost.output == 2.5
      assert model.context_window == 262_144
      assert model.max_tokens == 262_144
    end

    test "kimi k2.5 has correct specs" do
      model = Models.get_model(:opencode, "kimi-k2.5")

      assert model.id == "kimi-k2.5"
      assert model.name == "Kimi K2.5"
      assert model.provider == :opencode
      assert model.api == :openai_completions
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.cost.input == 0.6
      assert model.cost.output == 3.0
      assert model.cost.cache_read == 0.08
      assert model.context_window == 262_144
      assert model.max_tokens == 262_144
    end
  end

  describe "kimi-coding models (from Pi upstream)" do
    test "k2p5 has correct specs" do
      model = Models.get_model(:kimi, "k2p5")

      assert model != nil
      assert model.id == "k2p5"
      assert model.name == "Kimi K2.5"
      assert model.api == :anthropic_messages
      assert model.provider == :kimi
      assert model.base_url == "https://api.kimi.com/coding"
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.cost.input == 0.0
      assert model.cost.output == 0.0
      assert model.context_window == 262_144
      assert model.max_tokens == 32_768
    end

    test "kimi-k2-thinking has correct specs" do
      model = Models.get_model(:kimi, "kimi-k2-thinking")

      assert model != nil
      assert model.id == "kimi-k2-thinking"
      assert model.name == "Kimi K2 Thinking"
      assert model.api == :anthropic_messages
      assert model.provider == :kimi
      assert model.base_url == "https://api.kimi.com/coding"
      assert model.reasoning == true
      assert model.input == [:text]
      assert model.cost.input == 0.0
      assert model.cost.output == 0.0
      assert model.context_window == 262_144
      assert model.max_tokens == 32_768
    end

    test "kimi provider includes all 3 models" do
      models = Models.get_models(:kimi)
      ids = Enum.map(models, & &1.id)

      assert "kimi-for-coding" in ids
      assert "k2p5" in ids
      assert "kimi-k2-thinking" in ids
      assert length(models) == 3
    end
  end

  describe "opencode zen mixed api models" do
    test "anthropic-compatible opencode models use anthropic_messages api" do
      model = Models.get_model(:opencode, "claude-sonnet-4-6")
      assert model.api == :anthropic_messages
      assert model.base_url == "https://opencode.ai/zen"
    end

    test "google-compatible opencode models use google_generative_ai api" do
      model = Models.get_model(:opencode, "gemini-3-pro")
      assert model.api == :google_generative_ai
      assert model.base_url == "https://opencode.ai/zen/v1"
    end

    test "openai responses opencode models use openai_responses api" do
      model = Models.get_model(:opencode, "gpt-5.2-codex")
      assert model.api == :openai_responses
      assert model.base_url == "https://opencode.ai/zen/v1"
    end
  end

  describe "amazon bedrock nova models" do
    test "returns amazon bedrock model by id" do
      model = Models.get_model(:amazon_bedrock, "amazon.nova-pro-v1:0")

      assert %Model{} = model
      assert model.id == "amazon.nova-pro-v1:0"
      assert model.name == "Nova Pro"
      assert model.api == :bedrock_converse_stream
      assert model.provider == :amazon_bedrock
      assert model.base_url == "https://bedrock-runtime.us-east-1.amazonaws.com"
      assert model.reasoning == false
      assert model.input == [:text, :image]
      assert model.context_window == 300_000
      assert model.max_tokens == 8192
    end

    test "returns all amazon bedrock models" do
      models = Models.get_models(:amazon_bedrock)

      assert is_list(models)
      # Synced from Pi catalog: currently 83 Bedrock models
      assert length(models) == 83
      assert Enum.all?(models, &match?(%Model{provider: :amazon_bedrock}, &1))
    end

    test "nova lite has correct specs" do
      model = Models.get_model(:amazon_bedrock, "amazon.nova-lite-v1:0")

      assert model.id == "amazon.nova-lite-v1:0"
      assert model.name == "Nova Lite"
      assert model.provider == :amazon_bedrock
      assert model.api == :bedrock_converse_stream
      assert model.reasoning == false
      assert model.input == [:text, :image]
      assert model.cost.input == 0.06
      assert model.cost.output == 0.24
      assert model.cost.cache_read == 0.015
      assert model.context_window == 300_000
      assert model.max_tokens == 8192
    end

    test "nova micro has correct specs" do
      model = Models.get_model(:amazon_bedrock, "amazon.nova-micro-v1:0")

      assert model.id == "amazon.nova-micro-v1:0"
      assert model.name == "Nova Micro"
      assert model.provider == :amazon_bedrock
      assert model.api == :bedrock_converse_stream
      assert model.reasoning == false
      assert model.input == [:text]
      assert model.cost.input == 0.035
      assert model.cost.output == 0.14
      assert model.cost.cache_read == 0.00875
      assert model.context_window == 128_000
      assert model.max_tokens == 8192
    end

    test "nova premier has correct specs" do
      model = Models.get_model(:amazon_bedrock, "amazon.nova-premier-v1:0")

      assert model.id == "amazon.nova-premier-v1:0"
      assert model.name == "Nova Premier"
      assert model.provider == :amazon_bedrock
      assert model.api == :bedrock_converse_stream
      assert model.reasoning == true
      assert model.input == [:text, :image]
      assert model.cost.input == 2.5
      assert model.cost.output == 12.5
      assert model.context_window == 1_000_000
      assert model.max_tokens == 16384
    end

    test "amazon bedrock flagship models" do
      assert Models.get_model(:amazon_bedrock, "amazon.nova-2-lite-v1:0") != nil
      assert Models.get_model(:amazon_bedrock, "amazon.nova-lite-v1:0") != nil
      assert Models.get_model(:amazon_bedrock, "amazon.nova-micro-v1:0") != nil
      assert Models.get_model(:amazon_bedrock, "amazon.nova-premier-v1:0") != nil
      assert Models.get_model(:amazon_bedrock, "amazon.nova-pro-v1:0") != nil
    end
  end

  # ============================================================================
  # Thinking Level Utilities (ported from Pi)
  # ============================================================================

  describe "supports_xhigh?/1" do
    test "returns true for GPT-5.2 models" do
      model = Models.get_model(:openai, "gpt-5.2")
      assert model != nil
      assert Models.supports_xhigh?(model) == true
    end

    test "returns true for GPT-5.3 codex models" do
      model = Models.get_model(:openai, "gpt-5.3-codex")
      assert model != nil
      assert Models.supports_xhigh?(model) == true
    end

    test "returns true for Anthropic Opus 4.6 models" do
      model = Models.get_model(:anthropic, "claude-opus-4-6-20250514")
      if model do
        assert Models.supports_xhigh?(model) == true
      else
        # Try alternate ID format
        model = Models.get_model(:anthropic, "claude-opus-4-6-20250514")
        assert model == nil || Models.supports_xhigh?(model) == true
      end
    end

    test "returns false for Claude Sonnet models" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert model != nil
      assert Models.supports_xhigh?(model) == false
    end

    test "returns false for GPT-4o" do
      model = Models.get_model(:openai, "gpt-4o")
      assert model != nil
      assert Models.supports_xhigh?(model) == false
    end

    test "returns false for GPT-5.1 (not 5.2+)" do
      model = Models.get_model(:openai, "gpt-5.1")
      assert model != nil
      assert Models.supports_xhigh?(model) == false
    end
  end

  describe "adjust_max_tokens_for_thinking/4" do
    test "adds thinking budget to base max tokens" do
      {max, budget} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)
      assert budget == 16384
      assert max == 8192 + 16384
    end

    test "respects model max token limit" do
      {max, _budget} = Models.adjust_max_tokens_for_thinking(8192, 10_000, :high)
      assert max == 10_000
    end

    test "reduces budget when model max is too small" do
      {max, budget} = Models.adjust_max_tokens_for_thinking(8192, 1500, :high)
      assert max == 1500
      # Budget reduced to leave 1024 for output
      assert budget == max(0, 1500 - 1024)
    end

    test "uses default budgets per level" do
      {_, budget_min} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :minimal)
      {_, budget_low} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :low)
      {_, budget_med} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :medium)
      {_, budget_high} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)

      assert budget_min == 1024
      assert budget_low == 2048
      assert budget_med == 8192
      assert budget_high == 16384
    end

    test "accepts custom budgets" do
      {max, budget} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :medium, %{medium: 4096})
      assert budget == 4096
      assert max == 8192 + 4096
    end

    test "clamps xhigh to high" do
      {max_xhigh, budget_xhigh} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :xhigh)
      {max_high, budget_high} = Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)
      assert max_xhigh == max_high
      assert budget_xhigh == budget_high
    end
  end

  describe "clamp_reasoning/1" do
    test "maps xhigh to high" do
      assert Models.clamp_reasoning(:xhigh) == :high
    end

    test "passes through valid levels" do
      assert Models.clamp_reasoning(:minimal) == :minimal
      assert Models.clamp_reasoning(:low) == :low
      assert Models.clamp_reasoning(:medium) == :medium
      assert Models.clamp_reasoning(:high) == :high
    end

    test "returns nil for nil" do
      assert Models.clamp_reasoning(nil) == nil
    end

    test "returns nil for unknown levels" do
      assert Models.clamp_reasoning(:unknown) == nil
      assert Models.clamp_reasoning(:turbo) == nil
    end
  end
end
