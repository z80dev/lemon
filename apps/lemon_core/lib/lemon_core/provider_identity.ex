defmodule LemonCore.ProviderIdentity do
  @moduledoc """
  Built-in provider identity table: canonical ids, config table names, ambient
  environment variables, default secret names and accepted aliases.

  This is pure data shared by core diagnostics and the model runtime
  (`LemonAgent.ModelRuntime.ProviderNames` adds the OpenAI-compatible presets
  on top). Whether a provider's credential is usable is answered only by the
  registered credential readiness implementation (`LemonCore.CredentialReadiness`).
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
      atom_name: :openai_codex,
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

  @typedoc "One built-in provider's identity entry."
  @type entry :: %{
          required(:config_name) => String.t(),
          required(:atom_name) => atom(),
          required(:env_vars) => [String.t()],
          required(:default_secret_name) => String.t(),
          required(:aliases) => [String.t()],
          optional(:oauth_default_secret_name) => String.t(),
          optional(:keyless) => boolean()
        }

  @doc "The built-in table keyed by canonical provider id."
  @spec table() :: %{String.t() => entry()}
  def table, do: @providers

  @doc """
  The shareable form of a provider name: a built-in provider id or alias is
  shown as its lowercase dashed name, any other (custom) name as
  `"custom:<hash>"`. Runtime-registered built-ins (OpenAI-compatible presets)
  are recognized through the `:provider_names` doctor runtime module's
  `builtin?/1`. Apply it only when rendering output; comparisons use raw
  normalized names.
  """
  @spec public_name(term()) :: String.t() | nil
  def public_name(nil), do: nil
  def public_name(""), do: nil

  def public_name(name) do
    dashed = name |> to_string() |> String.trim() |> String.downcase() |> String.replace("_", "-")

    if builtin_name?(dashed) or runtime_builtin?(name),
      do: dashed,
      else: "custom:" <> hash(dashed)
  end

  defp builtin_name?(dashed) do
    normalized = String.replace(dashed, "-", "_")

    LemonCore.Config.Providers.AuthExtension.call(:public_provider?, [dashed], false) or
      Enum.any?(@providers, fn {canonical, meta} ->
        normalized in [canonical, String.replace(meta.config_name, "-", "_")] or
          normalized in Enum.map(meta.aliases, &String.replace(&1, "-", "_"))
      end)
  end

  defp runtime_builtin?(name) do
    mod = LemonCore.Doctor.RuntimeModules.fetch(:provider_names)

    mod != nil and Code.ensure_loaded?(mod) and function_exported?(mod, :builtin?, 1) and
      mod.builtin?(to_string(name)) == true
  rescue
    _ -> false
  end

  defp hash(name) do
    :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
