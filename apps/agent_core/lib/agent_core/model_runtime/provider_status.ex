defmodule AgentCore.ModelRuntime.ProviderStatus do
  @moduledoc """
  Redacted provider credential readiness diagnostics.
  """

  alias AgentCore.ModelRuntime.ProviderNames
  alias LemonCore.Config

  @spec snapshot(map() | nil) :: map()
  def snapshot(params \\ %{}) do
    params = params || %{}
    cwd = project_dir(params)
    config = Config.load(cwd, cache: false)
    providers = provider_ids(params, config)

    statuses =
      providers
      |> Enum.map(&provider_status(&1, config, cwd))
      |> Enum.sort_by(&{&1["known"] != true, &1["provider"]})

    %{
      "providers" => statuses,
      "count" => length(statuses),
      "readyCount" => Enum.count(statuses, & &1["credentialReady"]),
      "defaultProvider" => default_agent_value(config, :default_provider),
      "defaultModel" => default_agent_value(config, :default_model),
      "routing" => AgentCore.ModelRuntime.ProviderRouting.preview(params, config, statuses),
      "liveProofs" => live_proofs(cwd),
      "cleanup" => %{
        "includesRawApiKeys" => false,
        "includesSecretNames" => false,
        "includesRawBaseUrls" => false,
        "includesEnvVarNames" => false
      }
    }
  end

  defp project_dir(params) do
    value = get_param(params, "projectDir") || get_param(params, "cwd")
    if present?(value), do: value, else: File.cwd!()
  end

  defp provider_ids(params, config) do
    requested =
      [
        get_param(params, "provider")
        | get_param(params, "providers") |> List.wrap()
      ]
      |> Enum.filter(&present?/1)
      |> Enum.map(&to_string/1)

    cond do
      requested != [] ->
        (requested ++
           AgentCore.ModelRuntime.ProviderRouting.candidate_provider_ids(params, config))
        |> Enum.uniq_by(&normalize_provider/1)

      include_catalog?(params) ->
        (config_provider_ids(config) ++
           catalog_provider_ids() ++ ProviderNames.all_canonical_names())
        |> Enum.uniq_by(&normalize_provider/1)

      true ->
        (config_provider_ids(config) ++
           default_provider_ids(config) ++
           AgentCore.ModelRuntime.ProviderRouting.candidate_provider_ids(params, config))
        |> Enum.uniq_by(&normalize_provider/1)
    end
  end

  defp include_catalog?(params) do
    get_param(params, "includeCatalog") == true or get_param(params, "include_catalog") == true
  end

  defp config_provider_ids(%Config{providers: providers}) when is_map(providers),
    do: Map.keys(providers)

  defp config_provider_ids(_), do: []

  defp catalog_provider_ids do
    if Code.ensure_loaded?(Ai.Models) do
      Ai.Models.list_models(discover_openai: false)
      |> Enum.map(&model_provider/1)
      |> Enum.filter(&present?/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp default_provider_ids(config) do
    [
      default_agent_value(config, :default_provider),
      "anthropic",
      "openai",
      "openai-codex",
      "google",
      "zai",
      "kimi",
      "minimax",
      "openrouter"
    ]
    |> Enum.filter(&present?/1)
  end

  defp provider_status(provider, %Config{} = config, cwd) do
    canonical = ProviderNames.canonical_name(provider)
    config_name = ProviderNames.config_name(provider) || normalize_provider(provider)
    provider_cfg = ProviderNames.provider_config(config.providers, provider) || %{}
    env_configured? = env_configured?(provider)

    %{
      "provider" => canonical || normalize_provider(provider),
      "configName" => config_name,
      "known" => is_binary(canonical),
      "configured" => map_size(provider_cfg) > 0,
      "credentialReady" =>
        if(canonical,
          do: credential_ready?(canonical, config.providers, provider_cfg, env_configured?, cwd),
          else: false
        ),
      "config" => %{
        "apiKeyConfigured" => present?(provider_config_value(provider_cfg, :api_key)),
        "apiKeySecretConfigured" =>
          present?(provider_config_value(provider_cfg, :api_key_secret)),
        "oauthSecretConfigured" => present?(provider_config_value(provider_cfg, :oauth_secret)),
        "baseUrlConfigured" => present?(provider_config_value(provider_cfg, :base_url)),
        "authSource" => safe_auth_source(provider_cfg)
      },
      "ambient" => %{
        "envConfigured" => env_configured?
      }
    }
  end

  defp provider_status(provider, _config, _cwd) do
    %{
      "provider" => normalize_provider(provider),
      "configName" => normalize_provider(provider),
      "known" => false,
      "configured" => false,
      "credentialReady" => false,
      "config" => %{
        "apiKeyConfigured" => false,
        "apiKeySecretConfigured" => false,
        "oauthSecretConfigured" => false,
        "baseUrlConfigured" => false,
        "authSource" => nil
      },
      "ambient" => %{"envConfigured" => false}
    }
  end

  defp live_proofs(cwd) do
    status = LemonCore.Doctor.ProofDiagnostics.status(project_dir: cwd, limit: 1_000)
    proofs = Map.get(status, :recent_proofs, [])

    fallback = fallback_proof(proofs)

    %{
      "fallback" => fallback_summary(fallback),
      "proofScopeCounts" => Map.get(status, :proof_scope_counts, %{}),
      "cleanup" => %{
        "includesRawApiKeys" => false,
        "includesRawPrompts" => false,
        "includesProviderAnswers" => false,
        "includesProviderResponses" => false
      }
    }
  rescue
    _ ->
      %{
        "fallback" => fallback_summary(nil),
        "proofScopeCounts" => %{},
        "cleanup" => %{
          "includesRawApiKeys" => false,
          "includesRawPrompts" => false,
          "includesProviderAnswers" => false,
          "includesProviderResponses" => false
        }
      }
  end

  defp fallback_proof(proofs) do
    proofs
    |> Enum.filter(&fallback_proof?/1)
    |> Enum.sort_by(
      fn proof ->
        {proof_rank(Map.get(proof, :status)), Map.get(proof, :modified_at) || ""}
      end,
      fn {rank_a, modified_a}, {rank_b, modified_b} ->
        rank_a < rank_b or (rank_a == rank_b and modified_a >= modified_b)
      end
    )
    |> List.first()
  end

  defp fallback_proof?(proof) do
    "provider_fallback" in List.wrap(Map.get(proof, :proof_scopes, [])) or
      present?(Map.get(proof, :fallback_provider)) or
      present?(Map.get(proof, :final_provider))
  end

  defp fallback_summary(nil) do
    %{
      "status" => "missing",
      "proofStatus" => nil,
      "proofObject" => nil,
      "primaryProvider" => nil,
      "fallbackProvider" => nil,
      "finalProvider" => nil,
      "modifiedAt" => nil,
      "proofHash" => nil,
      "nextAction" => "run scripts/live_provider_fallback_smoke.exs"
    }
  end

  defp fallback_summary(proof) do
    proof_status = Map.get(proof, :status)

    %{
      "status" => proof_status_label(proof_status),
      "proofStatus" => proof_status,
      "proofObject" => Map.get(proof, :proof_object),
      "primaryProvider" => Map.get(proof, :primary_provider),
      "fallbackProvider" => Map.get(proof, :fallback_provider),
      "finalProvider" => Map.get(proof, :final_provider),
      "modifiedAt" => Map.get(proof, :modified_at),
      "proofHash" => Map.get(proof, :proof_hash),
      "nextAction" => proof_next_action(proof_status)
    }
  end

  defp proof_status_label("completed"), do: "proven"
  defp proof_status_label("skipped"), do: "skipped"
  defp proof_status_label("failed"), do: "blocked"
  defp proof_status_label(_), do: "unknown"

  defp proof_rank("completed"), do: 0
  defp proof_rank("failed"), do: 1
  defp proof_rank("skipped"), do: 2
  defp proof_rank(_), do: 3

  defp proof_next_action("completed"), do: "keep live fallback proof current"
  defp proof_next_action("skipped"), do: "enable live credentials and rerun fallback proof"
  defp proof_next_action("failed"), do: "inspect provider diagnostics and rerun proof"
  defp proof_next_action(_), do: "run scripts/live_provider_fallback_smoke.exs"

  defp provider_config_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp credential_ready?("openai_codex", providers, provider_cfg, env_configured?, cwd) do
    AgentCore.ModelRuntime.Credentials.provider_has_credentials?("openai_codex", providers,
      cwd: cwd
    ) or
      (not present?(provider_config_value(provider_cfg, :auth_source)) && not env_configured? &&
         AgentCore.ModelRuntime.Credentials.provider_has_credentials?(
           "openai_codex",
           %{"openai-codex" => %{"auth_source" => "oauth"}},
           cwd: cwd
         ))
  end

  defp credential_ready?("anthropic", providers, _provider_cfg, _env_configured?, cwd) do
    AgentCore.ModelRuntime.Credentials.provider_has_credentials?("anthropic", providers, cwd: cwd)
  end

  defp credential_ready?(canonical, providers, _provider_cfg, _env_configured?, cwd) do
    AgentCore.ModelRuntime.Credentials.provider_has_credentials?(canonical, providers, cwd: cwd)
  end

  defp env_configured?(provider) do
    provider
    |> ProviderNames.env_vars()
    |> Enum.any?(&(System.get_env(&1) |> present?()))
  end

  defp safe_auth_source(provider_cfg) do
    case provider_config_value(provider_cfg, :auth_source) do
      value when value in ["api_key", "oauth"] -> value
      _ -> nil
    end
  end

  defp default_agent_value(%Config{agent: agent}, key) when is_map(agent) do
    Map.get(agent, key) || Map.get(agent, to_string(key))
  end

  defp default_agent_value(_, _), do: nil

  defp model_provider(model) when is_struct(model), do: Map.get(model, :provider)
  defp model_provider(model) when is_map(model), do: model[:provider] || model["provider"]
  defp model_provider(_), do: nil

  defp get_param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp normalize_provider(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_provider(_), do: "unknown"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
