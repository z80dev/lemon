defmodule LemonCore.Secrets.External do
  @moduledoc """
  Shared orchestrator for explicitly enabled external secret sources.

  Resolution is store-compatible and read-only. Source values exist only in a
  bounded task or the optional bounded process-local cache; they are never
  written into config, the encrypted store, logs, status, or errors.
  """

  alias LemonCore.Config.Secrets, as: SecretsConfig
  alias LemonCore.Config.Secrets.Source, as: SourceConfig
  alias LemonCore.Secrets.SourceCache
  alias LemonCore.Secrets.SourceRunner

  @task_supervisor LemonCore.Secrets.SourceTaskSupervisor
  # Headroom over the summed per-run helper timeouts for bootstrap reads and
  # task start-up; each helper run is still cut off at its own timeout.
  @fetch_grace_ms 1_000

  @type provenance :: String.t()

  @spec resolve(String.t(), keyword(), LemonCore.Secrets.Source.bootstrap()) ::
          {:ok, String.t(), provenance()} | {:error, LemonCore.Secrets.Source.error_kind()}
  def resolve(name, opts, bootstrap) when is_binary(name) do
    config = source_config(opts)
    enabled = enabled_sources(config)

    # An invalid `[secrets]` table (including one that could not be loaded)
    # may hide enabled sources, so it is an error rather than a miss.
    cond do
      config.errors != [] or Enum.any?(enabled, &(not &1.valid?)) ->
        {:error, :invalid_config}

      enabled == [] ->
        {:error, :not_found}

      true ->
        resolve_from_sources(name, enabled, opts, bootstrap)
    end
  end

  @doc """
  Whether an enabled, valid source declares a reference for `name`, without
  invoking any source. Sources that do not declare per-name references cannot
  be answered without running them and do not count.
  """
  @spec declared?(String.t(), keyword()) :: boolean()
  def declared?(name, opts \\ []) when is_binary(name) do
    config = source_config(opts)

    config.errors == [] and
      Enum.any?(enabled_sources(config), &(&1.valid? and Map.has_key?(&1.refs || %{}, name)))
  rescue
    _ -> false
  end

  @doc "Returns redacted readiness metadata without invoking a source."
  @spec status(keyword(), LemonCore.Secrets.Source.bootstrap()) :: map()
  def status(opts, bootstrap) do
    config = source_config(opts)
    enabled = enabled_sources(config)
    statuses = Enum.map(config.sources, &source_status(&1, bootstrap))

    %{
      status: overall_status(config, enabled, statuses),
      configured_count: length(config.sources),
      enabled_count: length(enabled),
      config_error_count: length(config.errors),
      config_errors: config.errors,
      sources: statuses,
      includes_secret_values: false
    }
  end

  @doc "Executes enabled sources and returns counts/provenance only."
  @spec test(keyword(), LemonCore.Secrets.Source.bootstrap()) :: map()
  def test(opts, bootstrap) do
    config = source_config(opts)
    requested_id = Keyword.get(opts, :source_id)

    sources =
      config
      |> enabled_sources()
      |> maybe_select_source(requested_id)

    results =
      cond do
        config.errors != [] ->
          []

        is_binary(requested_id) and sources == [] ->
          []

        true ->
          opts = Keyword.put(opts, :force, true)
          Enum.map(sources, &test_source(&1, opts, bootstrap))
      end

    status =
      cond do
        config.errors != [] -> :invalid_config
        sources == [] -> :not_configured
        Enum.all?(results, &(&1.status == :ready)) -> :ready
        true -> :failed
      end

    %{
      status: status,
      tested_count: length(results),
      source_id: requested_id,
      config_error_count: length(config.errors),
      config_errors: config.errors,
      results: results,
      includes_secret_values: false
    }
  end

  @doc false
  @spec source_config(keyword()) :: SecretsConfig.t()
  def source_config(opts) do
    case Keyword.get(opts, :sources) do
      sources when is_list(sources) -> %SecretsConfig{sources: sources, errors: []}
      _ -> config_from_runtime(opts)
    end
  end

  defp config_from_runtime(opts) do
    case Keyword.get(opts, :config) do
      %SecretsConfig{} = config ->
        config

      %{secrets: %SecretsConfig{} = config} ->
        config

      _ ->
        project_dir = Keyword.get(opts, :project_dir) || Keyword.get(opts, :cwd) || File.cwd!()
        runtime_secrets_config(project_dir)
    end
  end

  # The cached runtime config refuses to load when any section fails
  # validation. A problem elsewhere (say a provider table) says nothing about
  # `[secrets]`, so re-read just that table from the same trust-filtered
  # merge. Only when that also fails (unreadable or invalid TOML) is the
  # source configuration unknown, which fails closed as `:invalid_config`.
  defp runtime_secrets_config(project_dir) do
    LemonCore.Config.cached(project_dir).secrets
  rescue
    _ ->
      try do
        project_dir
        |> LemonCore.Config.Modular.merged_settings()
        |> SecretsConfig.resolve()
      rescue
        _ -> %SecretsConfig{errors: ["secrets: configuration could not be loaded"]}
      end
  end

  defp enabled_sources(%SecretsConfig{sources: sources}) do
    Enum.filter(sources, &(&1.enabled === true))
  end

  defp resolve_from_sources(name, sources, opts, bootstrap) do
    Enum.reduce_while(sources, {:error, :not_found}, fn source, miss ->
      module = source_module(source)

      cond do
        is_nil(module) ->
          {:halt, {:error, :invalid_config}}

        scoped = scope_to_name(module, source, name) ->
          case fetch_source(module, scoped, opts, bootstrap) do
            {:ok, %{values: values}} ->
              case Map.fetch(values, name) do
                {:ok, value} when is_binary(value) and value != "" ->
                  {:halt, {:ok, value, provenance(source)}}

                _ ->
                  {:cont, miss}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        true ->
          {:cont, miss}
      end
    end)
  end

  defp scope_to_name(module, source, name) do
    if function_exported?(module, :scope, 2), do: module.scope(source, name), else: source
  end

  defp source_module(%SourceConfig{type: :command}) do
    module = LemonCore.Secrets.Source.Command
    if Code.ensure_loaded?(module), do: module
  end

  defp source_module(%SourceConfig{type: type}) do
    with module when is_atom(module) and not is_nil(module) <- SecretsConfig.adapter(type),
         true <- Code.ensure_loaded?(module),
         do: module,
         else: (_ -> nil)
  end

  defp fetch_source(nil, _source, _opts, _bootstrap), do: {:error, :invalid_config}

  defp fetch_source(module, source, opts, bootstrap) do
    cache_key = if source.cache_ttl_ms > 0, do: cache_key(source)

    case cache_get(source, cache_key, opts) do
      {:ok, result} ->
        {:ok, result}

      :miss ->
        result = supervised_fetch(module, source, bootstrap)
        maybe_cache(result, source, cache_key)
        result
    end
  end

  defp supervised_fetch(module, source, bootstrap) do
    case LemonCore.TaskSupervisor.async_nolink(@task_supervisor, fn ->
           module.fetch(source, bootstrap)
         end) do
      {:error, :task_supervisor_unavailable} ->
        {:error, :source_supervisor_unavailable}

      {:error, _reason} ->
        {:error, :spawn_failed}

      {:ok, task} ->
        case Task.yield(task, fetch_budget_ms(module, source)) do
          {:ok, {:ok, %{values: values, byte_count: byte_count}} = result}
          when is_map(values) and is_integer(byte_count) and byte_count >= 0 ->
            result

          {:ok, {:error, reason}} when is_atom(reason) ->
            {:error, reason}

          {:ok, _invalid} ->
            {:error, :invalid_output}

          {:exit, _reason} ->
            {:error, :spawn_failed}

          nil ->
            _ = Task.shutdown(task, :brutal_kill)
            {:error, :timeout}
        end
    end
  end

  defp fetch_budget_ms(module, source) do
    runs = if function_exported?(module, :runs, 1), do: module.runs(source), else: 1
    source.timeout_ms * runs + @fetch_grace_ms
  end

  defp cache_get(source, key, opts) when is_list(opts) do
    if Keyword.get(opts, :force, false) do
      :miss
    else
      cache_get_enabled(source, key)
    end
  end

  defp cache_get_enabled(%SourceConfig{cache_ttl_ms: ttl}, _key) when ttl <= 0, do: :miss
  defp cache_get_enabled(_source, key), do: SourceCache.get(key)

  defp maybe_cache({:ok, result}, %SourceConfig{cache_ttl_ms: ttl}, key) when ttl > 0 do
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ok = SourceCache.put(key, result, expires_at)
  end

  defp maybe_cache(_result, _source, _key), do: :ok

  defp cache_key(source) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(source))
    {:external_secret_source, source.id, digest}
  end

  defp source_status(%SourceConfig{} = source, bootstrap) do
    module = source_module(source)
    configured? = not is_nil(module) and module.configured?(source)

    binary_available? =
      with true <- not is_nil(module),
           executable when is_binary(executable) <- module.executable(source) do
        SourceRunner.executable_available?(executable)
      else
        _ -> false
      end

    bootstrap_ready? =
      not is_nil(module) and
        (not function_exported?(module, :bootstrap_ready?, 2) or
           module.bootstrap_ready?(source, bootstrap))

    status =
      cond do
        not source.enabled -> :disabled
        not source.valid? -> :invalid_config
        not configured? -> :invalid_config
        not binary_available? -> :binary_missing
        not bootstrap_ready? -> :bootstrap_secret_missing
        true -> :ready
      end

    %{
      id: source.id,
      type: source.type,
      enabled: source.enabled,
      status: status,
      configured: configured?,
      executable_available: binary_available?,
      bootstrap_available: bootstrap_ready?,
      cache_enabled: source.cache_ttl_ms > 0,
      priority: source.priority,
      config_error_count: length(source.errors),
      config_errors: source.errors,
      provenance: provenance(source),
      includes_secret_values: false
    }
  end

  defp test_source(source, opts, bootstrap) do
    started_at = System.monotonic_time(:millisecond)

    result = fetch_source(source_module(source), source, opts, bootstrap)
    duration_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

    case result do
      {:ok, %{values: values, byte_count: byte_count}} ->
        %{
          id: source.id,
          type: source.type,
          status: :ready,
          provenance: provenance(source),
          secret_count: map_size(values),
          output_bytes: byte_count,
          duration_ms: duration_ms,
          includes_secret_values: false
        }

      {:error, reason} ->
        %{
          id: source.id,
          type: source.type,
          status: :failed,
          provenance: provenance(source),
          error_kind: reason,
          duration_ms: duration_ms,
          includes_secret_values: false
        }
    end
  end

  defp maybe_select_source(sources, nil), do: sources
  defp maybe_select_source(sources, id), do: Enum.filter(sources, &(&1.id == id))

  defp overall_status(config, enabled, statuses) do
    cond do
      config.errors != [] -> :invalid_config
      enabled == [] -> :not_configured
      Enum.all?(Enum.filter(statuses, & &1.enabled), &(&1.status == :ready)) -> :ready
      true -> :blocked
    end
  end

  defp provenance(source), do: "external:#{source.type}:#{source.id}"
end
