defmodule LemonAgent.ModelRuntime.ProviderNames do
  @moduledoc """
  Canonical provider naming helpers for the Lemon AI runtime boundary.

  This module owns Lemon-side provider alias normalization so callers do not
  duplicate provider/env/default-secret knowledge when resolving credentials or
  runtime stream options.
  """

  @providers %{
    "anthropic" => %{
      config_name: "anthropic",
      atom_name: :anthropic,
      env_vars: ["ANTHROPIC_API_KEY"],
      default_secret_name: "llm_anthropic_api_key_raw",
      oauth_default_secret_name: "llm_anthropic_api_key",
      aliases: ["claude"]
    },
    "openai" => %{
      config_name: "openai",
      atom_name: :openai,
      env_vars: ["OPENAI_API_KEY"],
      default_secret_name: "llm_openai_api_key",
      aliases: []
    },
    "openai_codex" => %{
      config_name: "openai-codex",
      atom_name: :"openai-codex",
      env_vars: ["OPENAI_CODEX_API_KEY", "CHATGPT_TOKEN"],
      default_secret_name: "llm_openai_codex_api_key",
      aliases: ["codex", "openai_codex"]
    },
    "opencode" => %{
      config_name: "opencode",
      atom_name: :opencode,
      env_vars: ["OPENCODE_API_KEY"],
      default_secret_name: "llm_opencode_api_key",
      aliases: []
    },
    "opencode_go" => %{
      config_name: "opencode_go",
      atom_name: :opencode_go,
      env_vars: ["OPENCODE_API_KEY"],
      default_secret_name: "llm_opencode_go_api_key",
      aliases: ["opencode-go", "open-code-go"]
    },
    "google" => %{
      config_name: "google",
      atom_name: :google,
      env_vars: ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"],
      default_secret_name: "llm_google_api_key",
      aliases: []
    },
    "google_antigravity" => %{
      config_name: "google_antigravity",
      atom_name: :google_antigravity,
      env_vars: [],
      default_secret_name: "llm_google_antigravity_api_key",
      aliases: ["google-antigravity", "antigravity"]
    },
    "google_gemini_cli" => %{
      config_name: "google_gemini_cli",
      atom_name: :google_gemini_cli,
      env_vars: ["GOOGLE_GEMINI_CLI_API_KEY"],
      default_secret_name: "llm_google_gemini_cli_api_key",
      aliases: ["google-gemini-cli", "gemini", "gemini_cli", "gemini-cli"]
    },
    "google_vertex" => %{
      config_name: "google_vertex",
      atom_name: :google_vertex,
      env_vars: [],
      default_secret_name: "llm_google_vertex_api_key",
      aliases: ["google-vertex"]
    },
    "github_copilot" => %{
      config_name: "github_copilot",
      atom_name: :github_copilot,
      env_vars: ["GITHUB_COPILOT_API_KEY"],
      default_secret_name: "llm_github_copilot_api_key",
      aliases: ["github-copilot", "copilot"]
    },
    "azure_openai_responses" => %{
      config_name: "azure_openai_responses",
      atom_name: :azure_openai_responses,
      env_vars: ["AZURE_OPENAI_API_KEY"],
      default_secret_name: "llm_azure_openai_responses_api_key",
      aliases: ["azure-openai-responses", "azure-openai"]
    },
    "amazon_bedrock" => %{
      config_name: "amazon_bedrock",
      atom_name: :amazon_bedrock,
      env_vars: [],
      default_secret_name: "llm_amazon_bedrock_api_key",
      aliases: ["amazon-bedrock", "bedrock", "aws"]
    },
    "bedrock_converse_stream" => %{
      config_name: "amazon_bedrock",
      atom_name: :bedrock_converse_stream,
      env_vars: [],
      default_secret_name: "llm_amazon_bedrock_api_key",
      aliases: ["bedrock-converse-stream"]
    },
    "kimi" => %{
      config_name: "kimi",
      atom_name: :kimi,
      env_vars: ["KIMI_API_KEY", "MOONSHOT_API_KEY"],
      default_secret_name: "llm_kimi_api_key",
      aliases: ["moonshot"]
    },
    "kimi_coding" => %{
      config_name: "kimi_coding",
      atom_name: :kimi_coding,
      env_vars: ["KIMI_API_KEY", "MOONSHOT_API_KEY"],
      default_secret_name: "llm_kimi_coding_api_key",
      aliases: ["kimi-coding", "kimi-for-coding"]
    },
    "zai" => %{
      config_name: "zai",
      atom_name: :zai,
      env_vars: ["ZAI_API_KEY"],
      default_secret_name: "llm_zai_api_key",
      aliases: ["z-ai", "z.ai", "glm"]
    },
    "minimax" => %{
      config_name: "minimax",
      atom_name: :minimax,
      env_vars: ["MINIMAX_API_KEY"],
      default_secret_name: "llm_minimax_api_key",
      aliases: ["mini-max", "minimax-m2"]
    },
    "minimax_cn" => %{
      config_name: "minimax_cn",
      atom_name: :minimax_cn,
      env_vars: ["MINIMAX_API_KEY"],
      default_secret_name: "llm_minimax_cn_api_key",
      aliases: ["minimax-cn"]
    },
    "fireworks" => %{
      config_name: "fireworks",
      atom_name: :fireworks,
      env_vars: ["FIREWORKS_API_KEY"],
      default_secret_name: "llm_fireworks_api_key",
      aliases: ["fireworks_ai", "fireworks-ai"]
    },
    "openrouter" => %{
      config_name: "openrouter",
      atom_name: :openrouter,
      env_vars: ["OPENROUTER_API_KEY"],
      default_secret_name: "llm_openrouter_api_key",
      aliases: []
    },
    "groq" => %{
      config_name: "groq",
      atom_name: :groq,
      env_vars: ["GROQ_API_KEY"],
      default_secret_name: "llm_groq_api_key",
      aliases: []
    },
    "xai" => %{
      config_name: "xai",
      atom_name: :xai,
      env_vars: ["XAI_API_KEY"],
      default_secret_name: "llm_xai_api_key",
      aliases: ["x-ai", "grok"]
    },
    "cerebras" => %{
      config_name: "cerebras",
      atom_name: :cerebras,
      env_vars: ["CEREBRAS_API_KEY"],
      default_secret_name: "llm_cerebras_api_key",
      aliases: []
    },
    "deepseek" => %{
      config_name: "deepseek",
      atom_name: :deepseek,
      env_vars: ["DEEPSEEK_API_KEY"],
      default_secret_name: "llm_deepseek_api_key",
      aliases: ["deep-seek"]
    },
    "mistral" => %{
      config_name: "mistral",
      atom_name: :mistral,
      env_vars: ["MISTRAL_API_KEY"],
      default_secret_name: "llm_mistral_api_key",
      aliases: []
    },
    "huggingface" => %{
      config_name: "huggingface",
      atom_name: :huggingface,
      env_vars: ["HUGGINGFACE_HUB_TOKEN", "HF_TOKEN"],
      default_secret_name: "llm_huggingface_api_key",
      aliases: ["hugging-face", "hf"]
    },
    "qwen" => %{
      config_name: "qwen",
      atom_name: :qwen,
      env_vars: ["DASHSCOPE_API_KEY"],
      default_secret_name: "llm_qwen_api_key",
      aliases: ["dashscope"]
    },
    "vercel_ai_gateway" => %{
      config_name: "vercel_ai_gateway",
      atom_name: :vercel_ai_gateway,
      env_vars: ["AI_GATEWAY_API_KEY"],
      default_secret_name: "llm_vercel_ai_gateway_api_key",
      aliases: ["vercel-ai-gateway", "vercel"]
    }
  }

  # OpenAI-compatible presets (`LemonAi.Models.Presets`): env vars and aliases
  # follow omp; local presets are keyless (credential-ready without a key).
  @preset_providers Map.new(LemonAi.Models.Presets.all(), fn preset ->
                      canonical = Atom.to_string(preset.id)

                      {canonical,
                       %{
                         config_name: canonical,
                         atom_name: preset.id,
                         env_vars: preset.env_vars,
                         default_secret_name: "llm_#{canonical}_api_key",
                         aliases: preset.aliases,
                         keyless: preset.keyless
                       }}
                    end)

  @providers Map.merge(@preset_providers, @providers)

  @spec canonical_name(atom() | String.t() | nil) :: String.t() | nil
  def canonical_name(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> canonical_name()

  def canonical_name(provider) when is_binary(provider) do
    normalized =
      provider
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      normalized == "" ->
        nil

      Map.has_key?(@providers, normalized) ->
        normalized

      true ->
        Enum.find_value(@providers, fn {canonical, meta} ->
          names =
            [canonical, meta.config_name, dashed_name(canonical) | Map.get(meta, :aliases, [])]
            |> Enum.map(&normalize_candidate/1)
            |> Enum.reject(&is_nil/1)

          if normalized in names, do: canonical, else: nil
        end)
    end
  end

  def canonical_name(_), do: nil

  @spec config_name(atom() | String.t() | nil) :: String.t() | nil
  def config_name(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> provider_meta(canonical).config_name
    end
  end

  @spec dashed_name(atom() | String.t() | nil) :: String.t() | nil
  def dashed_name(provider) do
    case config_name(provider) do
      nil -> nil
      config_name -> String.replace(config_name, "_", "-")
    end
  end

  @spec provider_atom(atom() | String.t() | nil) :: atom() | nil
  def provider_atom(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> provider_meta(canonical).atom_name
    end
  end

  @spec env_vars(atom() | String.t() | nil) :: [String.t()]
  def env_vars(provider) do
    case canonical_name(provider) do
      nil -> []
      canonical -> Map.get(provider_meta(canonical), :env_vars, [])
    end
  end

  @spec default_secret_name(atom() | String.t() | nil) :: String.t() | nil
  def default_secret_name(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> Map.get(provider_meta(canonical), :default_secret_name)
    end
  end

  @spec oauth_default_secret_name(atom() | String.t() | nil) :: String.t() | nil
  def oauth_default_secret_name(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> Map.get(provider_meta(canonical), :oauth_default_secret_name)
    end
  end

  @doc """
  Whether the provider can be used without a credential (local OpenAI-compatible
  servers such as Ollama or LM Studio).
  """
  @spec keyless?(atom() | String.t() | nil) :: boolean()
  def keyless?(provider) do
    case canonical_name(provider) do
      nil -> false
      canonical -> Map.get(provider_meta(canonical), :keyless, false)
    end
  end

  @spec all_names(atom() | String.t() | nil) :: [String.t()]
  def all_names(provider) do
    case canonical_name(provider) do
      nil ->
        []

      canonical ->
        meta = provider_meta(canonical)

        [canonical, meta.config_name, dashed_name(canonical) | Map.get(meta, :aliases, [])]
        |> Enum.map(&normalize_candidate/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  @spec all_canonical_names() :: [String.t()]
  def all_canonical_names do
    @providers
    |> Map.keys()
    |> Enum.sort()
  end

  @spec provider_config(map() | nil, atom() | String.t()) :: map() | nil
  def provider_config(providers_map, provider) when is_map(providers_map) do
    provider_keys = all_names(provider)

    providers_map
    |> unwrap_providers_map()
    |> Enum.find_value(fn
      {key, value} when is_map(value) ->
        if normalize_candidate(key) in provider_keys, do: value, else: nil

      _ ->
        nil
    end)
  end

  def provider_config(_, _), do: nil

  defp provider_meta(canonical), do: Map.fetch!(@providers, canonical)

  defp unwrap_providers_map(%{providers: providers}) when is_map(providers), do: providers
  defp unwrap_providers_map(%{"providers" => providers}) when is_map(providers), do: providers
  defp unwrap_providers_map(providers), do: providers

  defp normalize_candidate(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_candidate()

  defp normalize_candidate(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_candidate(_), do: nil
end
