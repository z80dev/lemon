defmodule Ai.Models do
  @moduledoc """
  Registry of known AI models with their capabilities and pricing.

  This module provides access to model metadata including:
  - Model identification (id, name, provider)
  - API configuration (api type, base_url)
  - Capabilities (reasoning support, input types)
  - Pricing (cost per million tokens)
  - Limits (context window, max tokens)

  ## Usage

      # Get a specific model
      model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")

      # List all models for a provider
      models = Ai.Models.get_models(:openai)

      # Check capabilities
      Ai.Models.supports_vision?(model)
      Ai.Models.supports_reasoning?(model)

  Model data is defined in per-provider submodules under `Ai.Models.*` and
  merged into a single compile-time registry here.
  """

  alias Ai.Types.{Model, ModelCost}

  @default_openai_base_url "https://api.openai.com/v1"
  @default_openai_discovery_timeout_ms 4_000

  # ============================================================================
  # Provider Submodule Imports
  # ============================================================================

  # OpenAI Codex (ChatGPT OAuth) uses the Codex Responses endpoint.
  # Models are mostly the same IDs as OpenAI's Responses API, but usage is billed
  # via ChatGPT subscription, not per-token API pricing, so we set costs to 0.
  @openai_codex_models Enum.into(Ai.Models.OpenAI.models(), %{}, fn {id, model} ->
                         {id,
                          %Model{
                            model
                            | api: :openai_codex_responses,
                              provider: :"openai-codex",
                              base_url: "https://chatgpt.com",
                              cost: %ModelCost{
                                input: 0.0,
                                output: 0.0,
                                cache_read: 0.0,
                                cache_write: 0.0
                              }
                          }}
                       end)

  # ============================================================================
  # Combined Registry
  # ============================================================================

  @models %{
    :anthropic => Ai.Models.Anthropic.models(),
    :openai => Ai.Models.OpenAI.models(),
    :"openai-codex" => @openai_codex_models,
    :amazon_bedrock => Ai.Models.AmazonBedrock.models(),
    :google => Ai.Models.Google.models(),
    :google_antigravity => Ai.Models.Google.antigravity_models(),
    :kimi => Ai.Models.Kimi.models(),
    :kimi_coding => Ai.Models.KimiCoding.models(),
    :opencode => Ai.Models.OpenCode.models(),
    :xai => Ai.Models.XAI.models(),
    :mistral => Ai.Models.Mistral.models(),
    :cerebras => Ai.Models.Cerebras.models(),
    :deepseek => Ai.Models.DeepSeek.models(),
    :qwen => Ai.Models.Qwen.models(),
    :minimax => Ai.Models.MiniMax.models(),
    :zai => Ai.Models.ZAI.models(),
    :azure_openai_responses => Ai.Models.AzureOpenAI.models(),
    :github_copilot => Ai.Models.GitHubCopilot.models(),
    :google_gemini_cli => Ai.Models.GoogleGeminiCLI.models(),
    :google_vertex => Ai.Models.GoogleVertex.models(),
    :groq => Ai.Models.Groq.models(),
    :huggingface => Ai.Models.HuggingFace.models(),
    :minimax_cn => Ai.Models.MiniMaxCN.models(),
    :openrouter => Ai.Models.OpenRouter.models(),
    :vercel_ai_gateway => Ai.Models.VercelAIGateway.models()
  }

  # Keep provider iteration deterministic for lookups like find_by_id/1 where
  # duplicate model IDs can exist across providers (e.g. OpenAI vs Azure/OpenAI,
  # Google vs Vertex). Canonical providers should be checked first.
  @providers [
    :anthropic,
    :openai,
    :"openai-codex",
    :amazon_bedrock,
    :google,
    :google_antigravity,
    :kimi,
    :kimi_coding,
    :opencode,
    :xai,
    :mistral,
    :cerebras,
    :deepseek,
    :qwen,
    :minimax,
    :zai,
    :azure_openai_responses,
    :github_copilot,
    :google_gemini_cli,
    :google_vertex,
    :groq,
    :huggingface,
    :minimax_cn,
    :openrouter,
    :vercel_ai_gateway
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get a specific model by provider and model ID.

  ## Examples

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> model.name
      "Claude Sonnet 4"

      iex> Ai.Models.get_model(:anthropic, "nonexistent")
      nil

  """
  @spec get_model(atom(), String.t()) :: Model.t() | nil
  def get_model(provider, model_id) when is_atom(provider) and is_binary(model_id) do
    case Map.get(@models, provider) do
      nil -> nil
      provider_models -> Map.get(provider_models, model_id)
    end
  end

  @doc """
  Get all models for a provider.

  ## Examples

      iex> models = Ai.Models.get_models(:anthropic)
      iex> length(models) > 0
      true

      iex> Ai.Models.get_models(:unknown_provider)
      []

  """
  @spec get_models(atom()) :: [Model.t()]
  def get_models(provider) when is_atom(provider) do
    case Map.get(@models, provider) do
      nil -> []
      provider_models -> Map.values(provider_models)
    end
  end

  @doc """
  List all known providers.

  ## Examples

      iex> providers = Ai.Models.get_providers()
      iex> :anthropic in providers
      true

  """
  @spec get_providers() :: [atom()]
  def get_providers do
    @providers
  end

  @doc """
  List all known models across all providers.

  ## Examples

      iex> models = Ai.Models.list_models()
      iex> length(models) > 0
      true

  """
  @spec list_models() :: [Model.t()]
  def list_models do
    get_providers()
    |> Enum.flat_map(&get_models/1)
  end

  @type list_models_opt ::
          {:discover_openai, boolean()}
          | {:openai_api_key, String.t()}
          | {:openai_base_url, String.t()}
          | {:openai_timeout_ms, pos_integer()}

  @doc """
  List all known models with optional runtime discovery.

  ## Options

  - `:discover_openai` - When true, query OpenAI `/v1/models` and filter the
    OpenAI model list to IDs reported as available for the configured key.
    If discovery fails, returns the static model registry.
  - `:openai_api_key` - Optional API key override for discovery.
  - `:openai_base_url` - Optional OpenAI-compatible base URL override.
  - `:openai_timeout_ms` - Optional request timeout in milliseconds.
  """
  @spec list_models([list_models_opt()]) :: [Model.t()]
  def list_models(opts) when is_list(opts) do
    static_models = list_models()

    if Keyword.get(opts, :discover_openai, false) do
      case discover_openai_model_ids(opts) do
        {:ok, available_ids} ->
          filter_openai_models(static_models, available_ids)

        {:error, _reason} ->
          static_models
      end
    else
      static_models
    end
  end

  @doc """
  Backwards-compatible alias for `list_models/0`.
  """
  @deprecated "Use list_models/0"
  @spec all() :: [Model.t()]
  def all, do: list_models()

  @doc """
  Check if a model supports vision (image input).

  ## Examples

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.supports_vision?(model)
      true

      iex> model = Ai.Models.get_model(:openai, "o3-mini")
      iex> Ai.Models.supports_vision?(model)
      false

  """
  @spec supports_vision?(Model.t()) :: boolean()
  def supports_vision?(%Model{input: input}) do
    :image in input
  end

  @doc """
  Check if a model supports reasoning/thinking.

  ## Examples

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.supports_reasoning?(model)
      true

      iex> model = Ai.Models.get_model(:openai, "gpt-4o")
      iex> Ai.Models.supports_reasoning?(model)
      false

  """
  @spec supports_reasoning?(Model.t()) :: boolean()
  def supports_reasoning?(%Model{reasoning: reasoning}) do
    reasoning
  end

  @doc """
  Check if a model supports the xhigh thinking level.

  Supported models:
  - GPT-5.2 / GPT-5.3 model families
  - Anthropic Opus 4.6 models (xhigh maps to adaptive effort "max")

  Ported from Pi's model-resolver.

  ## Examples

      iex> model = Ai.Models.get_model(:openai, "gpt-5.2")
      iex> Ai.Models.supports_xhigh(model)
      true

      iex> model = Ai.Models.get_model(:anthropic, "claude-opus-4-6")
      iex> Ai.Models.supports_xhigh(model)
      true

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.supports_xhigh(model)
      false
  """
  @spec supports_xhigh(Model.t()) :: boolean()
  def supports_xhigh(%Model{id: id, api: api}) do
    cond do
      String.contains?(id, "gpt-5.2") or String.contains?(id, "gpt-5.3") ->
        true
      api == :anthropic_messages and
          (String.contains?(id, "opus-4-6") or String.contains?(id, "opus-4.6")) ->
        true
      true ->
        false
    end
  end

  @doc false
  @spec supports_xhigh?(Model.t()) :: boolean()
  def supports_xhigh?(model), do: supports_xhigh(model)

  @default_thinking_budgets %{
    minimal: 1024,
    low: 2048,
    medium: 8192,
    high: 16384
  }

  @doc """
  Adjust max tokens to accommodate a thinking budget for a given reasoning level.

  Computes the thinking token budget for the requested level (clamping xhigh
  to high), then increases `base_max_tokens` by that amount without exceeding
  `model_max_tokens`. If the resulting max is smaller than the budget, the
  budget is reduced to leave at least 1024 output tokens.

  Ported from Pi's adjustMaxTokensForThinking.

  ## Parameters

    - `base_max_tokens` - The base output token limit before thinking
    - `model_max_tokens` - The model's hard maximum token limit
    - `reasoning_level` - One of `:minimal`, `:low`, `:medium`, `:high`, `:xhigh`
    - `custom_budgets` - Optional map overriding default budgets per level

  ## Returns

  A tuple `{max_tokens, thinking_budget}`.

  ## Examples

      iex> Ai.Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)
      {24576, 16384}

      iex> Ai.Models.adjust_max_tokens_for_thinking(8192, 200_000, :medium, %{medium: 4096})
      {12288, 4096}
  """
  @spec adjust_max_tokens_for_thinking(
          non_neg_integer(),
          non_neg_integer(),
          atom(),
          map()
        ) :: {non_neg_integer(), non_neg_integer()}
  def adjust_max_tokens_for_thinking(base_max_tokens, model_max_tokens, reasoning_level, custom_budgets \\ %{}) do
    min_output_tokens = 1024
    level = clamp_reasoning(reasoning_level)
    budgets = Map.merge(@default_thinking_budgets, custom_budgets)
    thinking_budget = Map.get(budgets, level, 0)
    max_tokens = min(base_max_tokens + thinking_budget, model_max_tokens)

    thinking_budget = if max_tokens <= thinking_budget do
      max(0, max_tokens - min_output_tokens)
    else
      thinking_budget
    end

    {max_tokens, thinking_budget}
  end

  @doc """
  Clamp a reasoning level, mapping `:xhigh` to `:high` for providers that
  don't support it.

  ## Examples

      iex> Ai.Models.clamp_reasoning(:xhigh)
      :high

      iex> Ai.Models.clamp_reasoning(:medium)
      :medium

      iex> Ai.Models.clamp_reasoning(nil)
      nil
  """
  @spec clamp_reasoning(atom() | nil) :: atom() | nil
  def clamp_reasoning(nil), do: nil
  def clamp_reasoning(:xhigh), do: :high
  def clamp_reasoning(level) when level in [:minimal, :low, :medium, :high], do: level
  def clamp_reasoning(_), do: nil

  @doc """
  Find a model by ID across all providers.

  Returns the first matching model found, or nil if no match.

  ## Examples

      iex> model = Ai.Models.find_by_id("gpt-4o")
      iex> model.provider
      :openai

      iex> Ai.Models.find_by_id("nonexistent")
      nil

  """
  @spec find_by_id(String.t()) :: Model.t() | nil
  def find_by_id(model_id) when is_binary(model_id) do
    Enum.find_value(get_providers(), fn provider ->
      get_model(provider, model_id)
    end)
  end

  @doc """
  Check if two models are equal by comparing both their id and provider.
  Returns false if either model is nil.

  Ported from Pi's modelsAreEqual.

  ## Examples

      iex> model1 = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> model2 = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.models_equal?(model1, model2)
      true

      iex> model1 = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> model2 = Ai.Models.get_model(:openai, "gpt-4o")
      iex> Ai.Models.models_equal?(model1, model2)
      false

      iex> Ai.Models.models_equal?(nil, model1)
      false

  """
  @spec models_equal?(Model.t() | nil, Model.t() | nil) :: boolean()
  def models_equal?(nil, _b), do: false
  def models_equal?(_a, nil), do: false
  def models_equal?(%Model{id: id_a, provider: provider_a}, %Model{id: id_b, provider: provider_b}) do
    id_a == id_b and provider_a == provider_b
  end

  @doc """
  Get model IDs for a provider.

  ## Examples

      iex> ids = Ai.Models.get_model_ids(:anthropic)
      iex> "claude-sonnet-4-20250514" in ids
      true

  """
  @spec get_model_ids(atom()) :: [String.t()]
  def get_model_ids(provider) when is_atom(provider) do
    case Map.get(@models, provider) do
      nil -> []
      provider_models -> Map.keys(provider_models)
    end
  end

  defp discover_openai_model_ids(opts) do
    with {:ok, api_key} <- resolve_openai_api_key(opts),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           Req.get(openai_models_url(opts),
             headers: %{
               "Authorization" => "Bearer #{api_key}",
               "Accept" => "application/json"
             },
             connect_options: [timeout: openai_timeout_ms(opts)],
             receive_timeout: openai_timeout_ms(opts),
             retry: false
           ),
         %{"data" => data} when is_list(data) <- body do
      ids =
        data
        |> Enum.flat_map(fn
          %{"id" => id} when is_binary(id) and id != "" -> [id]
          _ -> []
        end)
        |> MapSet.new()

      if MapSet.size(ids) > 0 do
        {:ok, ids}
      else
        {:error, :no_models_returned}
      end
    else
      {:ok, _response} ->
        {:error, :http_error}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :invalid_response}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp resolve_openai_api_key(opts) do
    case Keyword.get(opts, :openai_api_key) || System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp openai_models_url(opts) do
    base_url =
      Keyword.get(opts, :openai_base_url) ||
        System.get_env("OPENAI_BASE_URL") ||
        @default_openai_base_url

    "#{normalize_openai_base_url(base_url)}/models"
  end

  defp normalize_openai_base_url(base_url) when is_binary(base_url) do
    trimmed =
      base_url
      |> String.trim()
      |> String.trim_trailing("/")

    cond do
      trimmed == "" ->
        @default_openai_base_url

      String.ends_with?(trimmed, "/v1") ->
        trimmed

      true ->
        "#{trimmed}/v1"
    end
  end

  defp openai_timeout_ms(opts) do
    case Keyword.get(opts, :openai_timeout_ms, @default_openai_discovery_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_openai_discovery_timeout_ms
    end
  end

  defp filter_openai_models(models, available_ids) do
    Enum.filter(models, fn
      %Model{provider: :openai, id: id} -> MapSet.member?(available_ids, id)
      %Model{} -> true
    end)
  end
end
