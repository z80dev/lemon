defmodule LemonCore.Config.CliResolvers do
  @moduledoc """
  Registry of per-vendor CLI config resolvers, one per engine that has a
  `[runtime.cli.<engine>]` section.

  `LemonCore.Config.Agent` resolves the `cli` section of the config, but what
  each vendor's section means — which keys exist, what their defaults are —
  belongs to whoever wraps that vendor's CLI. Vendor packages hand their
  resolver over when their application starts, the way they hand over subagent
  runners and resume formats:

      LemonCliRunners.Application.start/2
        -> LemonCore.Config.CliResolvers.register("codex", &CodexSubagent.resolve_cli_settings/1)

  A runtime without those packages still loads config; its `cli` map simply
  carries the raw TOML sections untouched instead of vendor-shaped defaults.

  ## Why application env and not a GenServer

  Same reasoning as `LemonCore.ResumeFormats`: resolution runs on the config
  hot path (inside `LemonCore.Config.load/2` cache misses), so lookups have to
  be cheap and must not depend on a process being alive. Registration happens
  once per application at boot, and OTP starts applications one at a time,
  which serialises the writes.

  ## Cache interaction

  `LemonCore.ConfigCache` caches *resolved* config, so a config loaded before
  a vendor package boots would be cached without that vendor's defaults.
  `register/2` therefore clears the default cache instance (when running) so
  the next read re-resolves with the newly registered resolver.
  """

  @key :cli_resolvers

  @typedoc "Resolves one vendor's raw TOML section into its settled settings map."
  @type resolver :: (map() -> map())

  @doc """
  Registers a resolver for `engine_id`, replacing any resolver already held
  for it, and clears the default `LemonCore.ConfigCache` instance so config
  resolved before this registration is not served without the new defaults.
  """
  @spec register(String.t(), resolver()) :: :ok
  def register(engine_id, resolver) when is_binary(engine_id) and is_function(resolver, 1) do
    put(upsert(registered(), {engine_id, resolver}))
    invalidate_config_cache()
  end

  @doc "Drops the resolver registered for `engine_id`. Always `:ok`."
  @spec unregister(String.t()) :: :ok
  def unregister(engine_id) when is_binary(engine_id) do
    put(Enum.reject(registered(), fn {id, _resolver} -> id == engine_id end))
  end

  @doc "Engine ids with a registered resolver, in registration order."
  @spec list_ids() :: [String.t()]
  def list_ids, do: Enum.map(registered(), fn {id, _resolver} -> id end)

  @doc """
  Resolves a raw `cli` settings map (string-keyed TOML sections) into the map
  runners read from `config.agent.cli`.

  Every registered resolver is applied to its own section — with `%{}` when
  the section is unconfigured, so vendor defaults still materialize — and its
  result lands under the atom spelling of its engine id (ids come from code,
  so the atom set is bounded). Sections no resolver claims pass through
  untouched under their raw keys: an unregistered vendor's config is carried,
  not dropped.
  """
  @spec resolve_all(map()) :: map()
  def resolve_all(raw_cli_settings) when is_map(raw_cli_settings) do
    registered = registered()

    resolved =
      Map.new(registered, fn {id, resolver} ->
        {String.to_atom(id), resolver.(section(raw_cli_settings, id))}
      end)

    known = MapSet.new(registered, fn {id, _resolver} -> id end)

    Enum.reduce(raw_cli_settings, resolved, fn {key, value}, acc ->
      if MapSet.member?(known, to_string(key)) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp section(raw, id) do
    case raw[id] do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp registered do
    :lemon_core
    |> Application.get_env(@key, [])
    |> List.wrap()
    |> Enum.filter(&match?({id, resolver} when is_binary(id) and is_function(resolver, 1), &1))
  end

  defp put(resolvers) do
    Application.put_env(:lemon_core, @key, resolvers)
    :ok
  end

  defp upsert(resolvers, {id, _resolver} = entry) do
    case Enum.find_index(resolvers, fn {existing, _} -> existing == id end) do
      nil -> resolvers ++ [entry]
      index -> List.replace_at(resolvers, index, entry)
    end
  end

  defp invalidate_config_cache do
    LemonCore.ConfigCache.clear()
  end
end
