defmodule LemonAi.Models do
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
      model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")

      # List all models for a provider
      models = LemonAi.Models.get_models(:openai)

      # Check capabilities
      LemonAi.Models.supports_vision?(model)
      LemonAi.Models.supports_reasoning?(model)

  Model data is loaded from JSON under `priv/models/` at compile time by
  `LemonAi.Models.Catalog` into per-provider submodules under
  `LemonAi.Models.*`, then merged into a single registry here. Most providers
  map to one resource; Google Antigravity is assembled from tagged Google
  entries plus an extras file, and OpenAI Codex derives from OpenAI plus
  OAuth-only model IDs.

  OpenAI-compatible provider presets (`LemonAi.Models.Presets`: Ollama,
  LM Studio, llama.cpp, vLLM, LiteLLM and hosted open-model APIs) have no
  static catalog. `get_model/2` answers any model ID for them, preferring
  metadata from the latest `LemonAi.Models.Discovery` listing, and
  `discover_preset/2` lists what an endpoint serves. `list_models/0` and
  `find_by_id/1` cover the static catalogs only and never touch the network.
  """

  alias LemonAi.Models.{Discovery, Presets}
  alias LemonAi.Types.Model

  @default_openai_base_url "https://api.openai.com/v1"
  @default_openai_discovery_timeout_ms 4_000

  # ============================================================================
  # Provider Submodule Imports
  # ============================================================================

  @openai_codex_models LemonAi.Models.OpenAI.codex_models()

  # ============================================================================
  # Combined Registry
  # ============================================================================

  @models %{
    :anthropic => LemonAi.Models.Anthropic.models(),
    :openai => LemonAi.Models.OpenAI.models(),
    :"openai-codex" => @openai_codex_models,
    :amazon_bedrock => LemonAi.Models.AmazonBedrock.models(),
    :google => LemonAi.Models.Google.models(),
    :google_antigravity => LemonAi.Models.Google.antigravity_models(),
    :kimi => LemonAi.Models.Kimi.models(),
    :kimi_coding => LemonAi.Models.KimiCoding.models(),
    :opencode => LemonAi.Models.OpenCode.models(),
    :opencode_go => LemonAi.Models.OpenCodeGo.models(),
    :xai => LemonAi.Models.XAI.models(),
    :mistral => LemonAi.Models.Mistral.models(),
    :cerebras => LemonAi.Models.Cerebras.models(),
    :deepseek => LemonAi.Models.DeepSeek.models(),
    :qwen => LemonAi.Models.Qwen.models(),
    :minimax => LemonAi.Models.MiniMax.models(),
    :zai => LemonAi.Models.ZAI.models(),
    :azure_openai_responses => LemonAi.Models.AzureOpenAI.models(),
    :github_copilot => LemonAi.Models.GitHubCopilot.models(),
    :google_gemini_cli => LemonAi.Models.GoogleGeminiCLI.models(),
    :google_vertex => LemonAi.Models.GoogleVertex.models(),
    :groq => LemonAi.Models.Groq.models(),
    :huggingface => LemonAi.Models.HuggingFace.models(),
    :minimax_cn => LemonAi.Models.MiniMaxCN.models(),
    :fireworks => LemonAi.Models.Fireworks.models(),
    :openrouter => LemonAi.Models.OpenRouter.models(),
    :vercel_ai_gateway => LemonAi.Models.VercelAIGateway.models()
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
    :opencode_go,
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
    :fireworks,
    :openrouter,
    :vercel_ai_gateway
  ]

  @preset_providers Presets.ids()

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get a specific model by provider and model ID.

  Static catalog providers return `nil` for unknown IDs. Preset providers
  (`LemonAi.Models.Presets`) return the latest discovered entry for the ID, or
  a synthesized model with the preset's API, base URL and conservative limits.

  ## Examples

      iex> model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")
      iex> model.name
      "Claude Sonnet 5"

      iex> LemonAi.Models.get_model(:anthropic, "nonexistent")
      nil

      iex> model = LemonAi.Models.get_model(:ollama, "qwen3:32b")
      iex> {model.provider, model.api, model.base_url}
      {:ollama, :openai_completions, "http://127.0.0.1:11434/v1"}

  """
  @spec get_model(atom(), String.t()) :: Model.t() | nil
  def get_model(provider, model_id) when is_atom(provider) and is_binary(model_id) do
    case Map.get(@models, provider) do
      nil when provider in @preset_providers and model_id != "" ->
        Presets.cached_model(provider, model_id) || Presets.model(provider, model_id)

      nil ->
        nil

      provider_models ->
        Map.get(provider_models, model_id)
    end
  end

  @doc """
  Like `get_model/2`, but returns only catalog or discovered models: preset
  providers never synthesize an entry for an unknown ID.
  """
  @spec known_model(atom(), String.t()) :: Model.t() | nil
  def known_model(provider, model_id) when is_atom(provider) and is_binary(model_id) do
    case Map.get(@models, provider) do
      nil when provider in @preset_providers -> Presets.cached_model(provider, model_id)
      nil -> nil
      provider_models -> Map.get(provider_models, model_id)
    end
  end

  @doc """
  Get all models for a provider.

  For preset providers this is the cached listing for the current default
  endpoint and environment credential (no network access); use `discover_preset/2`
  to refresh it. Explicitly configured endpoints remain scoped to their caller.

  ## Examples

      iex> models = LemonAi.Models.get_models(:anthropic)
      iex> length(models) > 0
      true

      iex> LemonAi.Models.get_models(:unknown_provider)
      []

  """
  @spec get_models(atom()) :: [Model.t()]
  def get_models(provider) when is_atom(provider) do
    case Map.get(@models, provider) do
      nil when provider in @preset_providers -> Presets.cached_models(provider)
      nil -> []
      provider_models -> Map.values(provider_models)
    end
  end

  @doc """
  List all known providers: static catalog providers, then presets.

  ## Examples

      iex> providers = LemonAi.Models.get_providers()
      iex> :anthropic in providers and :ollama in providers
      true

  """
  @spec get_providers() :: [atom()]
  def get_providers do
    @providers ++ @preset_providers
  end

  @doc """
  List all static catalog models across all providers. Offline: preset
  providers contribute nothing here.

  ## Examples

      iex> models = LemonAi.Models.list_models()
      iex> length(models) > 0
      true

  """
  @spec list_models() :: [Model.t()]
  def list_models do
    Enum.flat_map(@providers, &(@models |> Map.fetch!(&1) |> Map.values()))
  end

  @type discover_preset_opt ::
          {:base_url, String.t()}
          | {:api_key, String.t()}
          | {:headers, map()}
          | {:timeout_ms, pos_integer()}
          | {:ttl_ms, non_neg_integer()}
          | {:force_refresh, boolean()}
          | {:req_options, keyword()}

  @doc """
  Discover the models a preset endpoint serves via `LemonAi.Models.Discovery`.

  The base URL defaults to `LemonAi.Models.Presets.base_url/1` (preset default
  or its base-URL environment variable). Results carry the preset's API,
  compatibility flags and limits. Never raises.
  """
  @spec discover_preset(atom(), [discover_preset_opt()]) ::
          {:ok, [Model.t()]} | {:error, term()}
  def discover_preset(provider, opts \\ []) when is_atom(provider) and is_list(opts) do
    case Presets.get(provider) do
      nil ->
        {:error, {:unknown_preset, provider}}

      preset ->
        base_url =
          case Keyword.get(opts, :base_url) do
            url when is_binary(url) and url != "" -> url
            _ -> Presets.base_url(provider)
          end

        discovery_opts =
          opts
          |> Keyword.take([
            :api_key,
            :headers,
            :timeout_ms,
            :ttl_ms,
            :force_refresh,
            :req_options
          ])
          |> Keyword.put_new(:api_key, Presets.env_api_key(provider))
          |> Keyword.merge(
            provider: provider,
            api: preset.api,
            model_defaults: Presets.model_defaults(provider)
          )

        Discovery.discover(preset.discovery, base_url, discovery_opts)
    end
  end

  @type list_models_opt ::
          {:discover_openai, boolean()}
          | {:openai_api_key, String.t()}
          | {:openai_base_url, String.t()}
          | {:openai_timeout_ms, pos_integer()}
          | {:discover_codex, boolean()}
          | {:codex_access_token, String.t()}
          | {:codex_base_url, String.t()}
          | {:codex_timeout_ms, pos_integer()}
          | {:codex_force_refresh, boolean()}
          | {:codex_req_options, keyword()}

  @doc """
  List all known models with optional runtime discovery.

  ## Options

  - `:discover_openai` - When true, query OpenAI `/v1/models` and filter the
    OpenAI model list to IDs reported as available for the configured key.
    If discovery fails, returns the static model registry.
  - `:openai_api_key` - Optional API key override for discovery.
  - `:openai_base_url` - Optional OpenAI-compatible base URL override.
  - `:openai_timeout_ms` - Optional request timeout in milliseconds.
  - `:discover_codex` - Query the account-scoped ChatGPT Codex registry. A failed
    lookup never falls back to unverified Codex models. Successful results are
    cached by account and endpoint for five minutes.
  - `:codex_access_token` - Concrete ChatGPT JWT (no credential-file lookup or refresh).
  - `:codex_base_url`, `:codex_timeout_ms`, `:codex_force_refresh` - Discovery controls.
  """
  @spec list_models([list_models_opt()]) :: [Model.t()]
  def list_models(opts) when is_list(opts) do
    static_models = list_models()

    models =
      if Keyword.get(opts, :discover_openai, false) do
        case discover_openai_model_ids(opts) do
          {:ok, available_ids} -> filter_openai_models(static_models, available_ids)
          {:error, _reason} -> static_models
        end
      else
        static_models
      end

    if Keyword.get(opts, :discover_codex, false) do
      discovery_opts = [
        access_token: Keyword.get(opts, :codex_access_token),
        base_url: Keyword.get(opts, :codex_base_url),
        timeout_ms: Keyword.get(opts, :codex_timeout_ms, 5_000),
        force_refresh: Keyword.get(opts, :codex_force_refresh, false),
        req_options: Keyword.get(opts, :codex_req_options, [])
      ]

      discovered =
        case LemonAi.Models.OpenAICodexDiscovery.discover(discovery_opts) do
          {:ok, available} -> Map.new(available, &{&1.id, &1})
          {:error, _} -> %{}
        end

      Enum.flat_map(models, fn
        %Model{provider: :"openai-codex", id: id} ->
          case Map.get(discovered, id) do
            nil -> []
            model -> [model]
          end

        model ->
          [model]
      end)
    else
      models
    end
  end

  @doc """
  Check if a model supports vision (image input).

  ## Examples

      iex> model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")
      iex> LemonAi.Models.supports_vision?(model)
      true

      iex> model = LemonAi.Models.get_model(:openai, "o3-mini")
      iex> LemonAi.Models.supports_vision?(model)
      false

  """
  @spec supports_vision?(Model.t()) :: boolean()
  def supports_vision?(%Model{input: input}) do
    :image in input
  end

  @doc """
  Check if a model supports reasoning/thinking.

  ## Examples

      iex> model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")
      iex> LemonAi.Models.supports_reasoning?(model)
      true

      iex> model = LemonAi.Models.get_model(:openai, "gpt-4o")
      iex> LemonAi.Models.supports_reasoning?(model)
      false

  """
  @spec supports_reasoning?(Model.t()) :: boolean()
  def supports_reasoning?(%Model{reasoning: reasoning}) do
    reasoning
  end

  @doc """
  Check if a model supports the xhigh reasoning level.

  Driven by the model's `reasoning_efforts` capability flag (see
  `LemonAi.Types.Model`). On Anthropic adaptive-thinking models `:xhigh` maps
  to effort `"max"`.

  ## Examples

      iex> model = LemonAi.Models.get_model(:openai, "gpt-5.5")
      iex> LemonAi.Models.supports_xhigh(model)
      true

      iex> model = LemonAi.Models.get_model(:anthropic, "claude-opus-5-5")
      iex> LemonAi.Models.supports_xhigh(model)
      true

      iex> model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-4-5")
      iex> LemonAi.Models.supports_xhigh(model)
      false
  """
  @spec supports_xhigh(Model.t()) :: boolean()
  def supports_xhigh(%Model{reasoning_efforts: efforts}), do: :xhigh in efforts

  @doc false
  @spec supports_xhigh?(Model.t()) :: boolean()
  def supports_xhigh?(model), do: supports_xhigh(model)

  @reasoning_levels [:minimal, :low, :medium, :high, :xhigh]

  @doc """
  Resolve the reasoning level to send for `model`.

  Models that declare `reasoning_efforts` get the requested level when it is
  declared, otherwise the highest declared level below it, otherwise their
  lowest declared level. Models with no declaration (and unknown levels) pass
  the requested level through unchanged.

  ## Examples

      iex> model = LemonAi.Models.get_model(:openai, "gpt-5.1")
      iex> LemonAi.Models.reasoning_effort_for(model, :xhigh)
      :high

      iex> model = LemonAi.Models.get_model(:openai, "gpt-5.2")
      iex> LemonAi.Models.reasoning_effort_for(model, :minimal)
      :low

      iex> model = LemonAi.Models.get_model(:openai, "gpt-5.5")
      iex> LemonAi.Models.reasoning_effort_for(model, :xhigh)
      :xhigh
  """
  @spec reasoning_effort_for(Model.t(), atom() | nil) :: atom() | nil
  def reasoning_effort_for(%Model{}, nil), do: nil
  def reasoning_effort_for(%Model{reasoning_efforts: []}, level), do: level

  def reasoning_effort_for(%Model{reasoning_efforts: efforts}, level)
      when level in @reasoning_levels do
    if level in efforts do
      level
    else
      below =
        Enum.take_while(@reasoning_levels, &(&1 != level))
        |> Enum.filter(&(&1 in efforts))

      case below do
        [] -> Enum.find(@reasoning_levels, &(&1 in efforts))
        levels -> List.last(levels)
      end
    end
  end

  def reasoning_effort_for(%Model{}, level), do: level

  @default_thinking_budgets %{
    minimal: 1024,
    low: 2048,
    medium: 8192,
    high: 16_384
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

      iex> LemonAi.Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)
      {24576, 16384}

      iex> LemonAi.Models.adjust_max_tokens_for_thinking(8192, 200_000, :medium, %{medium: 4096})
      {12288, 4096}
  """
  @spec adjust_max_tokens_for_thinking(
          non_neg_integer(),
          non_neg_integer(),
          atom(),
          map()
        ) :: {non_neg_integer(), non_neg_integer()}
  def adjust_max_tokens_for_thinking(
        base_max_tokens,
        model_max_tokens,
        reasoning_level,
        custom_budgets \\ %{}
      ) do
    min_output_tokens = 1024
    level = clamp_reasoning(reasoning_level)
    budgets = Map.merge(@default_thinking_budgets, custom_budgets)
    thinking_budget = Map.get(budgets, level, 0)
    max_tokens = min(base_max_tokens + thinking_budget, model_max_tokens)

    thinking_budget =
      if max_tokens <= thinking_budget do
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

      iex> LemonAi.Models.clamp_reasoning(:xhigh)
      :high

      iex> LemonAi.Models.clamp_reasoning(:medium)
      :medium

      iex> LemonAi.Models.clamp_reasoning(nil)
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

      iex> model = LemonAi.Models.find_by_id("gpt-4o")
      iex> model.provider
      :openai

      iex> LemonAi.Models.find_by_id("nonexistent")
      nil

  """
  @spec find_by_id(String.t()) :: Model.t() | nil
  def find_by_id(model_id) when is_binary(model_id) do
    Enum.find_value(@providers, fn provider ->
      get_model(provider, model_id)
    end)
  end

  @doc """
  Check if two models are equal by comparing both their id and provider.
  Returns false if either model is nil.

  Ported from Pi's modelsAreEqual.

  ## Examples

      iex> model1 = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")
      iex> model2 = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")
      iex> LemonAi.Models.models_equal?(model1, model2)
      true

      iex> model1 = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")
      iex> model2 = LemonAi.Models.get_model(:openai, "gpt-4o")
      iex> LemonAi.Models.models_equal?(model1, model2)
      false

      iex> LemonAi.Models.models_equal?(nil, model1)
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

      iex> ids = LemonAi.Models.get_model_ids(:anthropic)
      iex> "claude-sonnet-5" in ids
      true

  """
  @spec get_model_ids(atom()) :: [String.t()]
  def get_model_ids(provider) when is_atom(provider) do
    case Map.get(@models, provider) do
      nil -> provider |> get_models() |> Enum.map(& &1.id)
      provider_models -> Map.keys(provider_models)
    end
  end

  # Always fetched fresh for this account, independent of cached picker listings.
  defp discover_openai_model_ids(opts) do
    with {:ok, api_key} <- resolve_openai_api_key(opts),
         {:ok, models} <-
           Discovery.discover(:openai_models, openai_base_url(opts),
             api_key: api_key,
             timeout_ms: openai_timeout_ms(opts),
             force_refresh: true
           ) do
      ids = MapSet.new(models, & &1.id)
      if MapSet.size(ids) > 0, do: {:ok, ids}, else: {:error, :no_models_returned}
    end
  end

  defp resolve_openai_api_key(opts) do
    case Keyword.get(opts, :openai_api_key) || System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp openai_base_url(opts) do
    base_url =
      Keyword.get(opts, :openai_base_url) ||
        System.get_env("OPENAI_BASE_URL") ||
        @default_openai_base_url

    normalize_openai_base_url(base_url)
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
