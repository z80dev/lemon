defmodule LemonAi.Models.Presets do
  @moduledoc """
  Built-in OpenAI-compatible provider presets: local inference servers and
  hosted "open model" APIs that have no bundled JSON catalog.

  Each preset is a compile-time entry carrying the provider atom (an explicit
  allowlist entry; never created from input), wire API, default base URL, model
  discovery kind, credential environment variables and the conservative
  defaults used when a model is not in any catalog. Model IDs come from runtime
  discovery (`LemonAi.Models.Discovery`) or are accepted as-is: a preset
  provider answers `LemonAi.Models.get_model/2` for any model ID.

  Local presets (`ollama`, `lm_studio`, `llama_cpp`, `vllm`, `litellm`) are
  keyless by default: their models carry `compat.allow_missing_api_key` so the
  request is sent without an `Authorization` header when no key resolves.
  Cloud presets require a key.

  Base URLs, environment variable names and discovery shapes follow omp's
  provider descriptors (`packages/catalog/src/provider-models`). `base_url_env`
  values are honored by `LemonAi.Models.CLI`; Lemon config applies the same
  variables through `LemonCore.Config.Providers`.
  """

  alias LemonAi.Types.{Model, ModelCost}

  @type discovery_kind :: :openai_models | :ollama

  @type t :: %{
          id: atom(),
          name: String.t(),
          api: :openai_completions,
          base_url: String.t(),
          discovery: discovery_kind(),
          local: boolean(),
          keyless: boolean(),
          env_vars: [String.t()],
          base_url_env: [String.t()],
          aliases: [String.t()],
          model_defaults: map()
        }

  @default_context_window 128_000
  @default_max_tokens 16_384

  # OpenAI-compatible servers vary; send only widely accepted request fields.
  @base_compat %{
    supports_store: false,
    supports_developer_role: false,
    supports_reasoning_effort: false,
    supports_usage_in_streaming: true,
    max_tokens_field: "max_tokens"
  }

  @local_compat Map.put(@base_compat, :allow_missing_api_key, true)

  @presets [
    # ---- Local, keyless by default ----
    %{
      id: :ollama,
      name: "Ollama",
      base_url: "http://127.0.0.1:11434/v1",
      discovery: :ollama,
      local: true,
      env_vars: ["OLLAMA_API_KEY"],
      base_url_env: ["OLLAMA_BASE_URL", "OLLAMA_HOST"],
      aliases: [],
      # omp: OLLAMA_DEFAULT_MAX_TOKENS
      model_defaults: %{max_tokens: 8_192}
    },
    %{
      id: :lm_studio,
      name: "LM Studio",
      base_url: "http://127.0.0.1:1234/v1",
      discovery: :openai_models,
      local: true,
      env_vars: ["LM_STUDIO_API_KEY"],
      base_url_env: ["LM_STUDIO_BASE_URL"],
      aliases: ["lm-studio", "lmstudio"]
    },
    %{
      id: :llama_cpp,
      name: "llama.cpp",
      base_url: "http://127.0.0.1:8080/v1",
      discovery: :openai_models,
      local: true,
      env_vars: ["LLAMA_CPP_API_KEY"],
      base_url_env: ["LLAMA_CPP_BASE_URL"],
      aliases: ["llama.cpp", "llama-cpp", "llamacpp"]
    },
    %{
      id: :vllm,
      name: "vLLM",
      base_url: "http://127.0.0.1:8000/v1",
      discovery: :openai_models,
      local: true,
      env_vars: ["VLLM_API_KEY"],
      base_url_env: [],
      aliases: []
    },
    %{
      id: :litellm,
      name: "LiteLLM",
      base_url: "http://localhost:4000/v1",
      discovery: :openai_models,
      local: true,
      env_vars: ["LITELLM_API_KEY"],
      base_url_env: ["LITELLM_BASE_URL"],
      aliases: ["lite-llm"]
    },
    # ---- Cloud, API key required ----
    %{
      id: :ollama_cloud,
      name: "Ollama Cloud",
      base_url: "https://ollama.com/v1",
      discovery: :ollama,
      env_vars: ["OLLAMA_CLOUD_API_KEY"],
      aliases: ["ollama-cloud"]
    },
    %{
      id: :together,
      name: "Together",
      base_url: "https://api.together.xyz/v1",
      env_vars: ["TOGETHER_API_KEY"],
      aliases: ["togetherai", "together-ai"]
    },
    %{
      id: :deepinfra,
      name: "DeepInfra",
      base_url: "https://api.deepinfra.com/v1/openai",
      env_vars: ["DEEPINFRA_API_KEY"],
      aliases: ["deep-infra"]
    },
    %{
      id: :nvidia,
      name: "NVIDIA",
      base_url: "https://integrate.api.nvidia.com/v1",
      env_vars: ["NVIDIA_API_KEY"],
      aliases: ["nvidia-nim", "nim"]
    },
    %{
      id: :novita,
      name: "Novita",
      base_url: "https://api.novita.ai/openai/v1",
      env_vars: ["NOVITA_API_KEY"],
      aliases: ["novita-ai"]
    },
    %{
      id: :baseten,
      name: "Baseten",
      base_url: "https://inference.baseten.co/v1",
      env_vars: ["BASETEN_API_KEY"],
      aliases: []
    },
    %{
      id: :venice,
      name: "Venice",
      base_url: "https://api.venice.ai/api/v1",
      env_vars: ["VENICE_API_KEY"],
      aliases: ["venice-ai"]
    },
    %{
      id: :synthetic,
      name: "Synthetic",
      base_url: "https://api.synthetic.new/openai/v1",
      env_vars: ["SYNTHETIC_API_KEY"],
      aliases: []
    },
    %{
      id: :nanogpt,
      name: "NanoGPT",
      base_url: "https://nano-gpt.com/api/v1",
      env_vars: ["NANO_GPT_API_KEY"],
      aliases: ["nano-gpt"]
    },
    %{
      id: :zenmux,
      name: "ZenMux",
      base_url: "https://zenmux.ai/api/v1",
      env_vars: ["ZENMUX_API_KEY"],
      aliases: []
    },
    %{
      id: :aimlapi,
      name: "AIML API",
      base_url: "https://api.aimlapi.com/v1",
      env_vars: ["AIMLAPI_API_KEY"],
      aliases: ["aiml-api"]
    },
    %{
      id: :siliconflow,
      name: "SiliconFlow",
      base_url: "https://api.siliconflow.com/v1",
      env_vars: ["SILICONFLOW_API_KEY"],
      aliases: ["silicon-flow"]
    },
    %{
      id: :siliconflow_cn,
      name: "SiliconFlow (China)",
      base_url: "https://api.siliconflow.cn/v1",
      env_vars: ["SILICONFLOW_CN_API_KEY"],
      aliases: ["siliconflow-cn"]
    },
    %{
      id: :gmi_cloud,
      name: "GMI Cloud",
      base_url: "https://api.gmi-serving.com/v1",
      env_vars: ["GMI_API_KEY"],
      aliases: ["gmi-cloud", "gmi"]
    },
    %{
      id: :qianfan,
      name: "Qianfan",
      base_url: "https://qianfan.baidubce.com/v2",
      env_vars: ["QIANFAN_API_KEY"],
      aliases: []
    },
    %{
      id: :aiand,
      name: "ai&",
      base_url: "https://api.aiand.com/v1",
      env_vars: ["AIAND_API_KEY"],
      aliases: []
    },
    %{
      id: :wafer_serverless,
      name: "Wafer Serverless",
      base_url: "https://pass.wafer.ai/v1",
      env_vars: ["WAFER_SERVERLESS_API_KEY"],
      aliases: ["wafer-serverless", "wafer"]
    },
    %{
      id: :kilo,
      name: "Kilo Gateway",
      base_url: "https://api.kilo.ai/api/gateway",
      env_vars: ["KILO_API_KEY"],
      aliases: ["kilo-gateway"]
    }
  ]

  @presets Enum.map(@presets, fn preset ->
             local = Map.get(preset, :local, false)

             preset
             |> Map.put_new(:api, :openai_completions)
             |> Map.put_new(:discovery, :openai_models)
             |> Map.put(:local, local)
             |> Map.put(:keyless, local)
             |> Map.put_new(:base_url_env, [])
             |> Map.update(:model_defaults, %{}, & &1)
           end)

  @by_id Map.new(@presets, &{&1.id, &1})
  @ids Enum.map(@presets, & &1.id)

  @lookup @presets
          |> Enum.flat_map(fn preset ->
            names = [Atom.to_string(preset.id) | preset.aliases]

            Enum.map(names, fn name ->
              {name |> String.downcase() |> String.replace(["-", "."], "_"), preset.id}
            end)
          end)
          |> Map.new()

  @doc "All presets in display order."
  @spec all() :: [t()]
  def all, do: @presets

  @doc "Preset provider atoms in display order."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc "The preset for a provider atom, or `nil`."
  @spec get(atom()) :: t() | nil
  def get(provider) when is_atom(provider), do: Map.get(@by_id, provider)
  def get(_), do: nil

  @doc "Whether `provider` is a preset provider atom."
  @spec preset?(term()) :: boolean()
  def preset?(provider) when is_atom(provider), do: Map.has_key?(@by_id, provider)
  def preset?(_), do: false

  @doc """
  Resolve a user-supplied provider name (`"lm-studio"`, `"llama.cpp"`,
  `"ollama_cloud"`) to a preset atom without creating atoms.
  """
  @spec resolve(atom() | String.t() | nil) :: atom() | nil
  def resolve(provider) when is_atom(provider) and not is_nil(provider) do
    if preset?(provider), do: provider, else: resolve(Atom.to_string(provider))
  end

  def resolve(provider) when is_binary(provider) do
    key =
      provider
      |> String.trim()
      |> String.downcase()
      |> String.replace(["-", "."], "_")

    Map.get(@lookup, key)
  end

  def resolve(_), do: nil

  @doc "Whether requests may omit credentials for the preset."
  @spec keyless?(term()) :: boolean()
  def keyless?(provider) do
    case get(provider) do
      %{keyless: keyless} -> keyless
      nil -> false
    end
  end

  @doc "API-key environment variables for a preset (first non-empty wins)."
  @spec env_vars(term()) :: [String.t()]
  def env_vars(provider) do
    case get(provider) do
      %{env_vars: vars} -> vars
      nil -> []
    end
  end

  @doc "The first non-empty API key from the preset's environment variables."
  @spec env_api_key(term()) :: String.t() | nil
  def env_api_key(provider) do
    provider
    |> env_vars()
    |> Enum.find_value(fn var ->
      case System.get_env(var) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  @doc """
  Effective default base URL: the first set `base_url_env` variable, normalized
  to an OpenAI-compatible `/v1` root, else the preset default.
  """
  @spec base_url(atom()) :: String.t() | nil
  def base_url(provider) do
    case get(provider) do
      nil ->
        nil

      preset ->
        Enum.find_value(preset.base_url_env, preset.base_url, fn var ->
          normalize_env_base_url(var, System.get_env(var))
        end)
    end
  end

  @doc false
  def normalize_env_base_url(_var, nil), do: nil

  def normalize_env_base_url("OLLAMA_HOST", value), do: value |> ollama_host_url() |> ensure_v1()

  def normalize_env_base_url(_var, value), do: ensure_v1(value)

  defp ollama_host_url(value) do
    trimmed = String.trim(value)

    candidate =
      cond do
        trimmed == "" -> nil
        String.contains?(trimmed, "://") -> trimmed
        String.starts_with?(trimmed, "//") -> "http:" <> trimmed
        String.starts_with?(trimmed, ":") -> "http://127.0.0.1" <> trimmed
        true -> "http://" <> trimmed
      end

    with candidate when is_binary(candidate) <- candidate,
         %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and host != "" <-
           URI.parse(candidate) do
      port_suffix =
        cond do
          String.match?(candidate, ~r{^[a-z]+://(\[[^\]]*\]|[^/:\[]*):\d+}i) -> ":#{uri.port}"
          scheme == "http" -> ":11434"
          true -> ""
        end

      host = if String.contains?(host, ":"), do: "[#{host}]", else: host
      "#{scheme}://#{host}#{port_suffix}"
    else
      _ -> nil
    end
  end

  defp ensure_v1(nil), do: nil

  defp ensure_v1(value) do
    trimmed = value |> String.trim() |> String.trim_trailing("/")

    cond do
      trimmed == "" -> nil
      String.ends_with?(trimmed, "/v1") -> trimmed
      true -> trimmed <> "/v1"
    end
  end

  @doc """
  Synthesize a model for a preset provider with the preset API and conservative
  defaults. `overrides` may replace any `LemonAi.Types.Model` field.
  """
  @spec model(atom(), String.t(), map()) :: Model.t() | nil
  def model(provider, model_id, overrides \\ %{})
      when is_binary(model_id) and is_map(overrides) do
    case get(provider) do
      nil ->
        nil

      preset ->
        compat = if preset.keyless, do: @local_compat, else: @base_compat

        base = %Model{
          id: model_id,
          name: model_id,
          api: preset.api,
          provider: preset.id,
          base_url: preset.base_url,
          reasoning: false,
          input: [:text],
          cost: %ModelCost{},
          context_window: @default_context_window,
          max_tokens: @default_max_tokens,
          headers: %{},
          compat: compat
        }

        base
        |> struct(preset.model_defaults)
        |> struct(Map.drop(overrides, [:__struct__]))
        |> clamp_max_tokens()
    end
  end

  @doc "Model fields every discovered model of the preset starts from."
  @spec model_defaults(atom()) :: map()
  def model_defaults(provider) do
    case model(provider, "") do
      nil -> %{}
      model -> model |> Map.from_struct() |> Map.drop([:id, :name])
    end
  end

  defp clamp_max_tokens(%Model{context_window: context, max_tokens: max} = model)
       when is_integer(context) and context > 0 and is_integer(max) and max > context,
       do: %{model | max_tokens: context}

  defp clamp_max_tokens(model), do: model
end
