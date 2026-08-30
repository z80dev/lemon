defmodule LemonAgent.ModelRuntime.ProviderConfiguration do
  @moduledoc """
  Comment-preserving provider fallback and credential-pool configuration.

  This is the single mutation boundary used by packaged/source CLI and control
  plane operator surfaces. It edits only `runtime.provider_routing`, validates
  the resulting TOML before an atomic same-directory replacement, and returns
  redacted routing metadata. Credential references are accepted for targeted
  pool edits but are never included in results or errors.

  Mutations default to preview-only. Callers must pass `apply: true`; destructive
  actions additionally require the operation-specific confirmation value
  returned in `confirmation`.
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonCore.Config
  alias LemonCore.Config.{Modular, TomlPatch}

  @routing_table "runtime.provider_routing"
  @pool_prefix @routing_table <> ".credential_pools."
  @name_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @secret_ref_regex ~r/^secret:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/
  @env_ref_regex ~r/^env:[A-Za-z_][A-Za-z0-9_]{0,127}$/
  @strategies ~w(priority round_robin)

  @type result :: {:ok, map()} | {:error, atom(), String.t()}

  @doc "Return redacted effective routing configuration from a loaded config."
  @spec snapshot(Config.t() | map()) :: map()
  def snapshot(%Config{agent: agent}) when is_map(agent) do
    agent
    |> map_value(:provider_routing)
    |> routing_snapshot()
  end

  def snapshot(routing) when is_map(routing), do: routing_snapshot(routing)
  def snapshot(_), do: routing_snapshot(%{})

  @doc "Preview or apply one bounded provider-routing mutation."
  @spec configure(map() | keyword()) :: result()
  def configure(params) do
    params = normalize_params(params)
    project_dir = project_dir(params)

    with {:ok, action} <- required_string(params, "action"),
         {:ok, target} <- target(params, project_dir) do
      :global.trans({__MODULE__, target.path}, fn ->
        configure_locked(action, params, target, project_dir)
      end)
    end
  rescue
    _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
  catch
    :exit, _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
  end

  defp configure_locked(action, params, target, project_dir) do
    with {:ok, original} <- read_config(target.path),
         {:ok, decoded} <- decode_config(original),
         {:ok, mutation} <- mutate(action, params, original, decoded),
         {:ok, decoded_after} <- decode_config(mutation.content),
         {:ok, proposed} <- validate_candidate(decoded_after, target, project_dir),
         :ok <- validate_confirmation(mutation, params),
         :ok <- maybe_write(mutation, target.path, params) do
      effective =
        if apply?(params) and mutation.changed do
          Config.reload(project_dir)
        else
          Config.load(project_dir, cache: false)
        end

      {:ok,
       %{
         "action" => action,
         "applied" => apply?(params) and mutation.changed,
         "changed" => mutation.changed,
         "targetScope" => target.scope,
         "destructive" => mutation.destructive,
         "confirmation" => confirmation_summary(mutation),
         "routingConfig" => snapshot(effective),
         "proposedRoutingConfig" => proposed,
         "cleanup" => cleanup()
       }}
    end
  end

  defp mutate("fallback.add", params, content, decoded) do
    with {:ok, provider} <- required_provider(params) do
      current = fallback_providers(decoded)
      updated = Enum.uniq(current ++ [provider])

      {:ok,
       mutation(
         content,
         upsert_string_array(content, @routing_table, "fallback_providers", updated),
         false,
         nil
       )}
    end
  end

  defp mutate("fallback.remove", params, content, decoded) do
    with {:ok, provider} <- required_provider(params) do
      current = fallback_providers(decoded)
      updated = Enum.reject(current, &(normalize_provider(&1) == normalize_provider(provider)))

      {:ok,
       mutation(
         content,
         upsert_string_array(content, @routing_table, "fallback_providers", updated),
         current != updated,
         provider
       )}
    end
  end

  defp mutate("fallback.clear", _params, content, decoded) do
    current = fallback_providers(decoded)
    updated = TomlPatch.delete_key(content, @routing_table, "fallback_providers")
    {:ok, mutation(content, updated, current != [], "clear")}
  end

  defp mutate("pool.upsert", params, content, decoded) do
    with {:ok, pool} <- required_name(params, "pool"),
         {:ok, providers} <- required_providers(params),
         {:ok, strategy} <- strategy(params) do
      table = pool_table(pool)

      updated =
        content
        |> upsert_string_array(table, "providers", providers)
        |> TomlPatch.upsert_string(table, "strategy", strategy)
        |> maybe_activate_pool(pool, truthy?(param(params, "activate")))

      confirmation = if pool_exists?(decoded, pool), do: pool, else: nil
      {:ok, mutation(content, updated, not is_nil(confirmation), confirmation)}
    end
  end

  defp mutate("pool.delete", params, content, decoded) do
    with {:ok, pool} <- required_name(params, "pool") do
      exists? = pool_exists?(decoded, pool)
      active? = get_in(decoded, ["runtime", "provider_routing", "default_pool"]) == pool

      updated =
        content
        |> TomlPatch.delete_table_tree(pool_table(pool))
        |> maybe_clear_default_pool(decoded, pool)

      {:ok, mutation(content, updated, exists? or active?, pool)}
    end
  end

  defp mutate("pool.credential.add", params, content, decoded) do
    with {:ok, pool} <- required_name(params, "pool"),
         {:ok, provider} <- required_provider(params),
         {:ok, credential_ref} <- required_credential_ref(params) do
      refs = pool_credential_refs(decoded, pool, provider)
      providers = Enum.uniq(pool_providers(decoded, pool) ++ [provider])

      updated =
        content
        |> upsert_string_array(pool_table(pool), "providers", providers)
        |> upsert_string_array(
          credentials_table(pool),
          provider,
          Enum.uniq(refs ++ [credential_ref])
        )

      {:ok, mutation(content, updated, false, nil)}
    end
  end

  defp mutate("pool.credential.remove", params, content, decoded) do
    with {:ok, pool} <- required_name(params, "pool"),
         {:ok, provider} <- required_provider(params),
         {:ok, credential_ref} <- required_credential_ref(params) do
      refs = pool_credential_refs(decoded, pool, provider)
      updated_refs = Enum.reject(refs, &(&1 == credential_ref))

      updated =
        if updated_refs == [] do
          TomlPatch.delete_key(content, credentials_table(pool), provider)
        else
          upsert_string_array(content, credentials_table(pool), provider, updated_refs)
        end

      {:ok, mutation(content, updated, refs != updated_refs, pool)}
    end
  end

  defp mutate("pool.credential.clear", params, content, decoded) do
    with {:ok, pool} <- required_name(params, "pool"),
         {:ok, provider} <- required_provider(params) do
      refs = pool_credential_refs(decoded, pool, provider)
      updated = TomlPatch.delete_key(content, credentials_table(pool), provider)
      {:ok, mutation(content, updated, refs != [], pool)}
    end
  end

  defp mutate(_action, _params, _content, _decoded) do
    {:error, :invalid_action, "Unsupported provider configuration action"}
  end

  defp mutation(original, updated, destructive, confirmation) do
    %{
      content: updated,
      changed: original != updated,
      destructive: destructive,
      confirmation: confirmation
    }
  end

  defp validate_confirmation(mutation, params) do
    cond do
      not mutation.changed ->
        :ok

      not mutation.destructive ->
        :ok

      not apply?(params) ->
        :ok

      is_binary(param(params, "confirm")) and
          secure_compare(param(params, "confirm"), mutation.confirmation) ->
        :ok

      true ->
        {:error, :confirmation_required,
         "Destructive provider configuration change requires confirmation"}
    end
  end

  defp maybe_write(%{changed: false}, _path, _params), do: :ok
  defp maybe_write(_mutation, _path, params) when not is_map(params), do: :ok

  defp maybe_write(mutation, path, params) do
    if apply?(params), do: atomic_write(path, mutation.content), else: :ok
  end

  defp apply?(params), do: truthy?(param(params, "apply"))

  defp confirmation_summary(%{destructive: true, changed: true, confirmation: expected}) do
    %{"required" => true, "value" => expected}
  end

  defp confirmation_summary(_), do: %{"required" => false, "value" => nil}

  defp routing_snapshot(routing) do
    pools = map_value(routing, :credential_pools) || %{}

    pool_summaries =
      pools
      |> Enum.map(fn {name, pool} ->
        counts = credential_counts(map_value(pool, :credentials))

        %{
          "name" => to_string(name),
          "providers" => normalize_provider_list(map_value(pool, :providers)),
          "strategy" => normalize_strategy(map_value(pool, :strategy)),
          "credentialCounts" => counts,
          "credentialReferenceCount" => counts |> Map.values() |> Enum.sum()
        }
      end)
      |> Enum.sort_by(& &1["name"])

    %{
      "enabled" => map_value(routing, :enabled) != false,
      "requireCredentials" => map_value(routing, :require_credentials) != false,
      "fallbackProviders" => normalize_provider_list(map_value(routing, :fallback_providers)),
      "defaultPool" => normalize_optional_name(map_value(routing, :default_pool)),
      "defaultProfile" => normalize_optional_name(map_value(routing, :default_profile)),
      "credentialPools" => pool_summaries,
      "credentialPoolCount" => length(pool_summaries),
      "credentialReferenceCount" =>
        pool_summaries |> Enum.map(& &1["credentialReferenceCount"]) |> Enum.sum(),
      "cleanup" => cleanup()
    }
  end

  defp validate_candidate(decoded, target, project_dir) do
    with {:ok, settings} <- candidate_settings(decoded, target, project_dir),
         {:ok, modular} <- Modular.validate_settings(settings) do
      {:ok, modular.agent.provider_routing |> routing_snapshot()}
    else
      _ -> {:error, :invalid_config, "Provider configuration is not valid Lemon config"}
    end
  rescue
    _ -> {:error, :invalid_config, "Provider configuration is not valid Lemon config"}
  end

  defp candidate_settings(decoded, %{scope: "project"}, _project_dir) do
    with {:ok, global} <- read_decoded_config(Config.global_path()) do
      {:ok, LemonCore.MapHelpers.deep_merge(global, decoded)}
    end
  end

  defp candidate_settings(decoded, %{scope: "global"}, project_dir) do
    with {:ok, project} <- read_decoded_config(Config.project_path(project_dir)) do
      {:ok, LemonCore.MapHelpers.deep_merge(decoded, project)}
    end
  end

  defp candidate_settings(decoded, _target, _project_dir), do: {:ok, decoded}

  defp read_decoded_config(path) do
    with {:ok, content} <- read_config(path),
         {:ok, decoded} <- decode_config(content) do
      {:ok, decoded}
    end
  end

  defp cleanup do
    %{
      "includesRawApiKeys" => false,
      "includesSecretNames" => false,
      "includesCredentialReferences" => false,
      "includesRawBaseUrls" => false,
      "includesEnvVarNames" => false,
      "preservesUnrelatedConfig" => true
    }
  end

  defp credential_counts(credentials) when is_map(credentials) do
    Map.new(credentials, fn {provider, refs} ->
      {normalize_provider(provider), refs |> List.wrap() |> length()}
    end)
  end

  defp credential_counts(_), do: %{}

  defp fallback_providers(decoded) do
    decoded
    |> get_in(["runtime", "provider_routing", "fallback_providers"])
    |> normalize_provider_list()
  end

  defp pool_providers(decoded, pool) do
    decoded
    |> get_in(["runtime", "provider_routing", "credential_pools", pool, "providers"])
    |> normalize_provider_list()
  end

  defp pool_credential_refs(decoded, pool, provider) do
    credentials =
      get_in(decoded, ["runtime", "provider_routing", "credential_pools", pool, "credentials"]) ||
        %{}

    provider_names = ProviderNames.all_names(provider)

    Enum.find_value(credentials, [], fn {key, refs} ->
      if normalize_provider(key) in provider_names do
        refs |> List.wrap() |> Enum.filter(&is_binary/1)
      end
    end)
  end

  defp pool_exists?(decoded, pool) do
    decoded
    |> get_in(["runtime", "provider_routing", "credential_pools", pool])
    |> is_map()
  end

  defp maybe_activate_pool(content, _pool, false), do: content

  defp maybe_activate_pool(content, pool, true) do
    TomlPatch.upsert_string(content, @routing_table, "default_pool", pool)
  end

  defp maybe_clear_default_pool(content, decoded, pool) do
    if get_in(decoded, ["runtime", "provider_routing", "default_pool"]) == pool do
      TomlPatch.delete_key(content, @routing_table, "default_pool")
    else
      content
    end
  end

  defp required_provider(params) do
    with {:ok, value} <- required_string(params, "provider"),
         canonical when is_binary(canonical) <- ProviderNames.canonical_name(value) do
      {:ok, ProviderNames.config_name(canonical)}
    else
      _ -> {:error, :invalid_provider, "Provider must be a known Lemon provider"}
    end
  end

  defp required_providers(params) do
    values = param(params, "providers") |> List.wrap()

    with false <- values == [],
         normalized when is_list(normalized) <- Enum.map(values, &normalize_known_provider/1),
         false <- Enum.any?(normalized, &is_nil/1) do
      {:ok, Enum.uniq(normalized)}
    else
      _ ->
        {:error, :invalid_providers,
         "Providers must be a non-empty list of known Lemon providers"}
    end
  end

  defp normalize_known_provider(value) do
    case ProviderNames.canonical_name(value) do
      canonical when is_binary(canonical) -> ProviderNames.config_name(canonical)
      _ -> nil
    end
  end

  defp required_credential_ref(params) do
    with {:ok, value} <- required_string(params, "credentialRef"),
         true <- Regex.match?(@secret_ref_regex, value) or Regex.match?(@env_ref_regex, value) do
      {:ok, value}
    else
      _ ->
        {:error, :invalid_credential_reference,
         "Credential reference must use secret:NAME or env:NAME"}
    end
  end

  defp required_name(params, key) do
    with {:ok, value} <- required_string(params, key),
         value <- String.downcase(value),
         true <- Regex.match?(@name_regex, value) do
      {:ok, value}
    else
      _ ->
        {:error, :invalid_name,
         "Pool name must use lowercase letters, digits, underscores, or hyphens"}
    end
  end

  defp strategy(params) do
    strategy = param(params, "strategy") || "priority"

    if strategy in @strategies,
      do: {:ok, strategy},
      else: {:error, :invalid_strategy, "Strategy must be priority or round_robin"}
  end

  defp required_string(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_parameter, "Missing required provider configuration parameter"}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_parameter, "Missing required provider configuration parameter"}
    end
  end

  defp target(params, project_dir) do
    case param(params, "configPath") do
      path when is_binary(path) and path != "" ->
        {:ok, %{path: Path.expand(path), scope: "explicit"}}

      _ ->
        case param(params, "scope") || "global" do
          "global" -> {:ok, %{path: Config.global_path(), scope: "global"}}
          "project" -> {:ok, %{path: Config.project_path(project_dir), scope: "project"}}
          _ -> {:error, :invalid_scope, "Provider configuration scope must be global or project"}
        end
    end
  end

  defp project_dir(params) do
    case param(params, "projectDir") || param(params, "cwd") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> File.cwd!()
    end
  end

  defp read_config(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, _} -> {:error, :config_read_failed, "Could not read provider configuration"}
    end
  end

  defp decode_config(""), do: {:ok, %{}}

  defp decode_config(content) do
    case Toml.decode(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_config, "Provider configuration is not valid TOML"}
    end
  end

  defp atomic_write(path, content) do
    path = Path.expand(path)
    dir = Path.dirname(path)
    temp = Path.join(dir, ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")
    mode = existing_mode(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(temp, content, [:binary]),
         :ok <- File.chmod(temp, mode),
         :ok <- File.rename(temp, path) do
      :ok
    else
      _ ->
        _ = File.rm(temp)
        {:error, :config_write_failed, "Could not write provider configuration"}
    end
  end

  defp existing_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o777)
      _ -> 0o600
    end
  end

  defp upsert_string_array(content, table, key, values) do
    encoded = Jason.encode!(values)
    TomlPatch.upsert_raw_line(content, table, key, "#{key} = #{encoded}")
  end

  defp pool_table(pool), do: @pool_prefix <> pool
  defp credentials_table(pool), do: pool_table(pool) <> ".credentials"

  defp normalize_provider_list(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_configured_provider/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_configured_provider(value) when is_binary(value) do
    normalize_known_provider(value) ||
      case String.trim(value) do
        "" -> nil
        provider -> provider
      end
  end

  defp normalize_configured_provider(_), do: nil

  defp normalize_strategy(strategy) when strategy in @strategies, do: strategy
  defp normalize_strategy(_), do: "priority"

  defp normalize_optional_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_name(_), do: nil

  defp normalize_provider(value) do
    ProviderNames.canonical_name(value) ||
      value |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  defp map_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
      true -> nil
    end
  end

  defp map_value(_, _), do: nil

  defp param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp normalize_params(params) when is_map(params),
    do: Map.new(params, fn {key, value} -> {to_string(key), value} end)

  defp normalize_params(params) when is_list(params),
    do: params |> Map.new() |> normalize_params()

  defp normalize_params(_), do: %{}

  defp truthy?(value), do: value in [true, 1, "1", "true", "yes"]

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  rescue
    _ -> false
  end

  defp secure_compare(_, _), do: false
end
