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
  @source_modules %{
    onepassword: LemonCore.Secrets.Source.OnePassword,
    bitwarden: LemonCore.Secrets.Source.Bitwarden,
    command: LemonCore.Secrets.Source.Command
  }

  @type provenance :: String.t()

  @spec resolve(String.t(), keyword()) ::
          {:ok, String.t(), provenance()} | {:error, LemonCore.Secrets.Source.error_kind()}
  def resolve(name, opts \\ []) when is_binary(name) do
    config = source_config(opts)
    enabled = enabled_sources(config)

    cond do
      enabled == [] ->
        {:error, :not_found}

      config.errors != [] or Enum.any?(enabled, &(not &1.valid?)) ->
        {:error, :invalid_config}

      true ->
        resolve_from_sources(name, enabled, opts)
    end
  end

  @doc "Returns redacted readiness metadata without invoking a source."
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    config = source_config(opts)
    enabled = enabled_sources(config)
    statuses = Enum.map(config.sources, &source_status(&1, opts))

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
  @spec test(keyword()) :: map()
  def test(opts \\ []) do
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
          Enum.map(sources, &test_source(&1, Keyword.put(opts, :force, true)))
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
        LemonCore.Config.cached(project_dir).secrets
    end
  rescue
    _ -> %SecretsConfig{errors: ["secrets: configuration could not be loaded"]}
  end

  defp enabled_sources(%SecretsConfig{sources: sources}) do
    Enum.filter(sources, &(&1.enabled === true))
  end

  defp resolve_from_sources(name, sources, opts) do
    Enum.reduce_while(sources, {:error, :not_found}, fn source, _acc ->
      case fetch_source(source, opts) do
        {:ok, %{values: values}} ->
          case Map.fetch(values, name) do
            {:ok, value} when is_binary(value) and value != "" ->
              {:halt, {:ok, value, provenance(source)}}

            _ ->
              {:cont, {:error, :not_found}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_source(%SourceConfig{} = source, opts) do
    module = Map.fetch!(@source_modules, source.type)
    cache_key = cache_key(source)

    case cache_get(source, cache_key, opts) do
      {:ok, result} ->
        {:ok, result}

      :miss ->
        result = supervised_fetch(module, source, opts)
        maybe_cache(result, source, cache_key)
        result
    end
  end

  defp supervised_fetch(module, source, opts) do
    case Process.whereis(@task_supervisor) do
      nil ->
        {:error, :source_supervisor_unavailable}

      _pid ->
        task =
          Task.Supervisor.async_nolink(@task_supervisor, fn -> module.fetch(source, opts) end)

        case Task.yield(task, source.timeout_ms) do
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

  defp source_status(%SourceConfig{} = source, opts) do
    module = Map.get(@source_modules, source.type)
    configured? = not is_nil(module) and module.configured?(source)
    binary_available? = executable_available?(source)

    bootstrap_ready? =
      not is_nil(module) and
        (not function_exported?(module, :bootstrap_ready?, 2) or
           module.bootstrap_ready?(source, opts))

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

  defp executable_available?(%SourceConfig{type: :onepassword} = source),
    do: SourceRunner.executable_available?(source.executable || "op")

  defp executable_available?(%SourceConfig{type: :bitwarden} = source),
    do: SourceRunner.executable_available?(source.executable || "bws")

  defp executable_available?(%SourceConfig{type: :command, argv: [program | _]}),
    do: SourceRunner.executable_available?(program)

  defp executable_available?(_source), do: false

  defp test_source(source, opts) do
    started_at = System.monotonic_time(:millisecond)

    result = fetch_source(source, opts)
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
