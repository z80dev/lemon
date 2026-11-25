defmodule CodingAgent.Tools.WebSearch do
  @moduledoc """
  WebSearch tool for the coding agent.

  Uses the capability-aware search provider registry. Bundled providers include
  Brave Search, Exa, Perplexity Sonar, Tavily, Kagi, Jina, Keenable, Kimi Code,
  keyless DuckDuckGo, and configurable SearXNG.
  """

  alias CodingAgent.Search.{Operators, Provider}
  alias CodingAgent.Search.Registry, as: SearchRegistry
  alias CodingAgent.Search.SingleFlight
  alias CodingAgent.Tools.WebCache
  alias LemonAgent.Security.ExternalContent
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonCore.Secrets

  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @default_search_count 5
  @max_search_count 10
  @max_query_length 500
  @default_timeout_seconds 30
  @default_cache_ttl_minutes 15
  @default_cache_max_entries 100
  @default_failover_enabled true
  @default_perplexity_base_url "https://openrouter.ai/api/v1"
  @perplexity_direct_base_url "https://api.perplexity.ai"
  @default_perplexity_model "perplexity/sonar-pro"
  @default_content_max_chars 12_000
  @default_snippet_max_chars 600
  @default_max_citations 8
  @default_citation_max_chars 300
  @max_content_max_chars 50_000
  @max_snippet_max_chars 5_000
  @max_citation_max_chars 2_000
  @max_citations 20
  @rate_limit_window_ms 1_000
  @rate_limit_max_requests 5
  @rate_limit_table :coding_agent_websearch_rate_limit
  @search_cache_table :coding_agent_websearch_cache
  @perplexity_key_prefixes ["pplx-"]
  @keyed_providers %{
    "tavily" => "TAVILY_API_KEY",
    "kagi" => "KAGI_API_KEY",
    "jina" => "JINA_API_KEY",
    "keenable" => "KEENABLE_API_KEY"
  }
  @openrouter_key_prefixes ["sk-or-"]
  @brave_freshness_shortcuts MapSet.new(["pd", "pw", "pm", "py"])

  @tool_description "Search the web through registered providers with deterministic fallback. Returns structured JSON."

  @tool_parameters %{
    "type" => "object",
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Search query string."
      },
      "provider" => %{
        "type" => "string",
        "description" =>
          "Optional registered provider id for this call. Omit to use configured automatic selection."
      },
      "fallbackProviders" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" =>
          "Optional ordered registered provider ids to try after the requested provider."
      },
      "count" => %{
        "type" => "integer",
        "description" => "Number of results to return (1-10)."
      },
      "max_results" => %{
        "type" => "integer",
        "description" => "Backward-compatible alias for count."
      },
      "country" => %{
        "type" => "string",
        "description" => "2-letter country code (e.g., US, DE) for Brave."
      },
      "search_lang" => %{
        "type" => "string",
        "description" => "ISO language code for results."
      },
      "ui_lang" => %{
        "type" => "string",
        "description" => "ISO language code for UI elements."
      },
      "region" => %{
        "type" => "string",
        "description" => "Backward-compatible alias (e.g., us-en)."
      },
      "freshness" => %{
        "type" => "string",
        "description" =>
          "Time filter: pd, pw, pm, py, or YYYY-MM-DDtoYYYY-MM-DD; uses capable providers in the chain."
      },
      "recency" => %{
        "type" => "string",
        "enum" => ["day", "week", "month", "year"],
        "description" => "Relative time filter (alias for freshness)."
      },
      "maxChars" => %{
        "type" => "integer",
        "description" =>
          "Maximum characters for long response content (Perplexity content and result descriptions)."
      },
      "snippetMaxChars" => %{
        "type" => "integer",
        "description" => "Maximum characters per short result snippet/title."
      },
      "maxCitations" => %{
        "type" => "integer",
        "description" => "Maximum number of citations to return for Perplexity responses."
      }
    },
    "required" => ["query"]
  }

  @doc """
  Returns the WebSearch tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    runtime = build_runtime(opts)

    %AgentTool{
      name: "websearch",
      description: @tool_description,
      label: "Web Search",
      parameters: @tool_parameters,
      execute: build_execute_fn(runtime)
    }
  end

  defp build_execute_fn(runtime) do
    fn tool_call_id, params, signal, on_update ->
      execute(tool_call_id, params, signal, on_update, runtime)
    end
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, on_update) do
    execute(tool_call_id, params, signal, on_update, build_runtime([]))
  end

  defp execute(_tool_call_id, params, signal, _on_update, runtime) do
    if runtime.enabled do
      with :ok <- check_abort(signal),
           :ok <- enforce_rate_limit(),
           {:ok, query} <- normalize_query(Map.get(params, "query")),
           {:ok, runtime} <- apply_provider_overrides(runtime, params),
           {:ok, freshness} <- normalize_recency(params),
           :ok <- check_abort(signal),
           request <- normalize_request_params(params, runtime),
           :ok <- check_abort(signal) do
        run_search(query, freshness, request, runtime)
      end
    else
      {:error, "websearch is disabled by configuration"}
    end
  end

  @doc false
  def reset_rate_limit do
    ensure_rate_limit_table()
    :ets.insert(@rate_limit_table, {:window, System.monotonic_time(:millisecond), 0})
    :ok
  end

  @doc false
  def reset_cache(opts \\ []) do
    WebCache.clear_cache(@search_cache_table, opts)
  end

  defp run_search(query, freshness, request, runtime) do
    providers = [runtime.provider | runtime.fallback_providers] |> Enum.uniq()

    if is_nil(freshness) or Enum.any?(providers, &supports_freshness?(&1, freshness)) do
      run_provider_chain(providers, providers, query, freshness, request, runtime, [])
    else
      {:error, "No provider in the search chain supports the requested freshness filter"}
    end
  end

  defp run_provider_chain(
         [],
         all_providers,
         _query,
         _freshness,
         _request,
         _runtime,
         failures
       ) do
    render_chain_failure(all_providers, Enum.reverse(failures))
  end

  defp run_provider_chain(
         [provider | rest],
         all_providers,
         query,
         freshness,
         request,
         runtime,
         failures
       ) do
    requested_provider = hd(all_providers)

    if not is_nil(freshness) and not supports_freshness?(provider, freshness) do
      failure = {:runtime_error, "#{provider} does not support the requested freshness filter"}

      run_provider_chain(
        rest,
        all_providers,
        query,
        freshness,
        request,
        runtime,
        [{provider, failure} | failures]
      )
    else
      case run_provider_attempt(provider, query, freshness, request, runtime) do
        {:ok, payload, cached?} ->
          failures = Enum.reverse(failures)
          used_failover? = provider != requested_provider

          reason =
            failures
            |> Enum.map(fn {_id, failure} -> failure_summary(failure) end)
            |> Enum.join("; ")

          payload =
            payload
            |> annotate_payload(
              requested_provider,
              provider,
              failover_payload(
                failures != [],
                used_failover?,
                requested_provider,
                if(reason == "", do: nil, else: reason)
              )
            )
            |> Map.put("provider_attempts", provider_attempts(failures, provider))
            |> maybe_mark_cached(cached?)

          json_result(payload)

        # An unreadable credential secret is an error for this provider, not a
        # reason to fail over to another provider.
        {:setup_error, %{"error" => "secret_unavailable"}} = failure ->
          render_chain_failure(all_providers, Enum.reverse([{provider, failure} | failures]))

        failure ->
          run_provider_chain(
            rest,
            all_providers,
            query,
            freshness,
            request,
            runtime,
            [{provider, failure} | failures]
          )
      end
    end
  end

  defp provider_attempts(failures, used_provider) do
    Enum.map(failures, fn {provider, failure} ->
      %{"provider" => provider, "status" => "error", "reason" => failure_summary(failure)}
    end) ++ [%{"provider" => used_provider, "status" => "ok"}]
  end

  defp run_provider_attempt(provider, query, freshness, request, runtime) do
    cache_key = build_cache_key(query, freshness, request, provider)

    case WebCache.read_cache(@search_cache_table, cache_key, runtime.cache_opts) do
      {:hit, payload} ->
        {:ok, payload, true}

      :miss ->
        SingleFlight.run(
          cache_key,
          fn ->
            run_uncached_provider(provider, query, freshness, request, runtime, cache_key)
          end,
          runtime.timeout_ms + 1_000
        )
    end
  end

  defp run_uncached_provider(provider, query, freshness, request, runtime, cache_key) do
    case WebCache.read_cache(@search_cache_table, cache_key, runtime.cache_opts) do
      {:hit, payload} ->
        {:ok, payload, true}

      :miss ->
        case resolve_api_config(provider, runtime) do
          {:error, payload} ->
            {:setup_error, payload}

          {:ok, api_cfg} ->
            case perform_search(provider, query, freshness, request, api_cfg, runtime) do
              {:ok, payload} ->
                WebCache.write_cache(
                  @search_cache_table,
                  cache_key,
                  payload,
                  runtime.cache_ttl_ms,
                  runtime.cache_max_entries,
                  runtime.cache_opts
                )

                {:ok, payload, false}

              {:error, reason} ->
                {:runtime_error, reason}
            end
        end
    end
  end

  defp perform_search(provider, query, freshness, request, api_cfg, runtime) do
    with {:ok, spec} <- SearchRegistry.fetch(provider),
         :ok <- ensure_search_capability(spec),
         context <-
           api_cfg
           |> Map.merge(%{
             timeout_ms: runtime.timeout_ms,
             http_get: runtime.http_get,
             http_post: runtime.http_post
           }),
         :ok <- spec.module.available?(:search, context) do
      prepared = Operators.prepare(query, Provider.search_features(spec.module))

      provider_request =
        Map.merge(request, %{
          query: prepared.query,
          freshness: freshness,
          operator_tokens: prepared.tokens
        })

      case spec.module.search(provider_request, context) do
        {:ok, payload} -> {:ok, Operators.finish(payload, query, prepared)}
        error -> error
      end
    else
      {:error, :not_found} -> {:error, "websearch provider is not registered: #{provider}"}
      {:error, reason} -> {:error, provider_error_text(provider, reason)}
    end
  end

  defp ensure_search_capability(%{capabilities: capabilities}) do
    if :search in capabilities, do: :ok, else: {:error, :unsupported_search_capability}
  end

  defp provider_error_text(_provider, reason) when is_binary(reason), do: reason

  defp provider_error_text(provider, reason),
    do: "#{provider} provider unavailable: #{inspect(reason)}"

  defp failover_payload(attempted, used, from, reason) do
    %{
      "attempted" => attempted,
      "used" => used,
      "from" => from,
      "reason" => reason
    }
  end

  defp annotate_payload(payload, requested_provider, used_provider, failover)
       when is_map(payload) do
    failover = Map.put(failover, "to", if(failover["used"], do: used_provider, else: nil))

    payload
    |> Map.put("provider", used_provider)
    |> Map.put("provider_requested", requested_provider)
    |> Map.put("provider_used", used_provider)
    |> Map.put("failover", failover)
  end

  defp maybe_mark_cached(payload, true), do: Map.put(payload, "cached", true)
  defp maybe_mark_cached(payload, _), do: payload

  defp render_chain_failure([primary | _], failures) do
    summary =
      failures
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {{provider, failure}, index} ->
        label = if index == 0, do: "Primary provider", else: "Failover provider"
        "#{label} #{provider} failed: #{failure_summary(failure)}."
      end)

    failover = failover_payload(length(failures) > 1, false, primary, summary)

    case Enum.find(failures, fn {_provider, failure} -> match?({:setup_error, _}, failure) end) do
      {_provider, {:setup_error, payload}} ->
        payload
        |> annotate_payload(primary, primary, failover)
        |> Map.put("provider_attempts", provider_failure_attempts(failures))
        |> Map.put("warning", summary)
        |> json_result()

      nil ->
        {:error, summary}
    end
  end

  defp render_chain_failure([], _failures), do: {:error, "No websearch providers configured"}

  defp provider_failure_attempts(failures) do
    Enum.map(failures, fn {provider, failure} ->
      %{"provider" => provider, "status" => "error", "reason" => failure_summary(failure)}
    end)
  end

  defp failure_summary({:setup_error, payload}) when is_map(payload) do
    Map.get(payload, "error") || Map.get(payload, "message") || "setup_error"
  end

  defp failure_summary({:runtime_error, reason}) when is_binary(reason), do: reason
  defp failure_summary({:runtime_error, reason}), do: inspect(reason)

  defp build_cache_key(query, freshness, request, provider) do
    {:operators_v1, provider, query, freshness, request}
    |> :erlang.term_to_binary()
    |> Base.encode16(case: :lower)
    |> WebCache.normalize_cache_key()
  end

  defp resolve_api_config("perplexity", runtime) do
    with {:ok, api_key, source} <- resolve_perplexity_credential(runtime.perplexity),
         {:ok, base_url} <- resolve_perplexity_base_url(runtime.perplexity, source, api_key) do
      {:ok,
       %{
         api_key: api_key,
         base_url: base_url,
         model: runtime.perplexity.model || @default_perplexity_model
       }}
    end
  end

  defp resolve_api_config("duckduckgo", _runtime), do: {:ok, %{}}

  defp resolve_api_config("exa", runtime) do
    config = provider_config(runtime, "exa")

    case resolve_api_key("exa", [
           {:configured, {:value, get_map_value(config, :api_key, nil)}},
           {:configured, {:secret, get_map_value(config, :api_key_secret, nil)}},
           {:env, {:secret, "EXA_API_KEY"}}
         ]) do
      {:ok, api_key, _source} ->
        {:ok,
         %{
           api_key: api_key,
           base_url:
             normalize_optional_string(get_map_value(config, :base_url, nil)) ||
               "https://api.exa.ai"
         }}

      {:error, payload} ->
        {:error, payload}

      :none ->
        {:error,
         %{
           "error" => "missing_exa_api_key",
           "message" =>
             "websearch (exa) needs an API key. Set EXA_API_KEY or configure runtime.tools.web.search.providers.exa.api_key.",
           "docs" => "docs/tools/web.md"
         }}
    end
  end

  defp resolve_api_config("searxng", runtime) do
    config = provider_config(runtime, "searxng")
    base_url = normalize_optional_string(get_map_value(config, :base_url, nil))

    with {:base_url, base_url} when is_binary(base_url) <- {:base_url, base_url},
         {:ok, api_key} <-
           optional_api_key("searxng", [
             {:configured, {:value, get_map_value(config, :api_key, nil)}},
             {:configured, {:secret, get_map_value(config, :api_key_secret, nil)}}
           ]) do
      {:ok, %{base_url: base_url, api_key: api_key}}
    else
      {:error, payload} ->
        {:error, payload}

      {:base_url, nil} ->
        {:error,
         %{
           "error" => "missing_searxng_base_url",
           "message" =>
             "websearch (searxng) needs agent.tools.web.search.providers.searxng.base_url.",
           "docs" => "docs/tools/web.md"
         }}
    end
  end

  defp resolve_api_config("brave", runtime) do
    case resolve_api_key("brave", [
           {:configured, {:value, runtime.api_key}},
           {:configured, {:secret, runtime.api_key_secret}},
           {:env, {:secret, "BRAVE_API_KEY"}}
         ]) do
      {:ok, api_key, _source} ->
        {:ok, %{api_key: api_key}}

      {:error, payload} ->
        {:error, payload}

      :none ->
        {:error,
         %{
           "error" => "missing_brave_api_key",
           "message" =>
             "websearch needs a Brave Search API key. Set BRAVE_API_KEY or configure agent.tools.web.search.api_key.",
           "docs" => "docs/tools/web.md"
         }}
    end
  end

  # Explicit search keys first; otherwise the `kimi_coding` model credential
  # (subscription login, omp login or API key) and its endpoint.
  defp resolve_api_config("kimi", runtime) do
    config = provider_config(runtime, "kimi")
    configured_base_url = normalize_optional_string(get_map_value(config, :base_url, nil))

    case resolve_api_key("kimi", [
           {:configured, {:value, get_map_value(config, :api_key, nil)}},
           {:configured, {:secret, get_map_value(config, :api_key_secret, nil)}},
           {:env, {:secret, "KIMI_SEARCH_API_KEY"}},
           {:env, {:secret, "MOONSHOT_SEARCH_API_KEY"}}
         ]) do
      {:ok, api_key, _source} ->
        {:ok, %{api_key: api_key, base_url: configured_base_url}}

      {:error, payload} ->
        {:error, payload}

      :none ->
        case runtime.kimi_code_credential.() do
          {api_key, base_url} when is_binary(api_key) and api_key != "" ->
            {:ok, %{api_key: api_key, base_url: configured_base_url || base_url}}

          _ ->
            {:error,
             %{
               "error" => "missing_kimi_api_key",
               "message" =>
                 "websearch (kimi) needs a Kimi Code credential. Sign in with `lemon model kimi-code`, set KIMI_SEARCH_API_KEY, or configure runtime.tools.web.search.providers.kimi.api_key. A Moonshot Open Platform key is not accepted.",
               "docs" => "docs/tools/web.md"
             }}
        end
    end
  end

  defp resolve_api_config(provider, runtime) when is_map_key(@keyed_providers, provider) do
    config = provider_config(runtime, provider)
    env = Map.fetch!(@keyed_providers, provider)

    case resolve_api_key(provider, [
           {:configured, {:value, get_map_value(config, :api_key, nil)}},
           {:configured, {:secret, get_map_value(config, :api_key_secret, nil)}},
           {:env, {:secret, env}}
         ]) do
      {:ok, api_key, _source} ->
        {:ok, %{api_key: api_key}}

      {:error, payload} ->
        {:error, payload}

      :none ->
        {:error,
         %{
           "error" => "missing_#{provider}_api_key",
           "message" =>
             "websearch (#{provider}) needs an API key. Set #{env} or configure runtime.tools.web.search.providers.#{provider}.api_key.",
           "docs" => "docs/tools/web.md"
         }}
    end
  end

  defp resolve_api_config(provider, runtime), do: {:ok, provider_config(runtime, provider)}

  defp provider_config(runtime, provider) do
    configs = Map.get(runtime, :provider_configs, %{})

    Map.get(configs, provider) ||
      Enum.find_value(configs, %{}, fn {key, value} ->
        if to_string(key) == provider, do: value
      end)
  end

  # Resolves the credential together with its provenance so the destination
  # host is always derived from the credential actually sent. Configured keys
  # (inline or `api_key_secret`) carry no provider identity of their own, so
  # their host comes from an explicit `base_url` or an unambiguous key prefix.
  defp resolve_perplexity_credential(perplexity_cfg) do
    case resolve_api_key("perplexity", [
           {:configured, {:value, perplexity_cfg.api_key}},
           {:configured, {:secret, Map.get(perplexity_cfg, :api_key_secret)}},
           {:perplexity_env, {:secret, "PERPLEXITY_API_KEY"}},
           {:openrouter_env, {:secret, "OPENROUTER_API_KEY"}}
         ]) do
      {:ok, key, source} ->
        {:ok, key, source}

      {:error, payload} ->
        {:error, payload}

      :none ->
        {:error,
         %{
           "error" => "missing_perplexity_api_key",
           "message" =>
             "websearch (perplexity) needs an API key. Set PERPLEXITY_API_KEY or OPENROUTER_API_KEY, or configure agent.tools.web.search.perplexity.api_key.",
           "docs" => "docs/tools/web.md"
         }}
    end
  end

  # Walks a credential chain in order. Only a definite miss advances to the next
  # candidate; any other secret-store failure stops the chain so an ambient env
  # key or alias is never used in place of an unreadable configured secret.
  defp resolve_api_key(provider, candidates) do
    Enum.reduce_while(candidates, :none, fn {source, candidate}, :none ->
      case read_candidate(candidate) do
        {:ok, key} -> {:halt, {:ok, key, source}}
        :not_found -> {:cont, :none}
        {:error, name, reason} -> {:halt, {:error, secret_unavailable(provider, name, reason)}}
      end
    end)
  end

  defp optional_api_key(provider, candidates) do
    case resolve_api_key(provider, candidates) do
      {:ok, key, _source} -> {:ok, key}
      :none -> {:ok, nil}
      {:error, payload} -> {:error, payload}
    end
  end

  defp read_candidate({:value, value}) do
    case normalize_optional_string(value) do
      nil -> :not_found
      key -> {:ok, key}
    end
  end

  defp read_candidate({:secret, name}) when is_binary(name) and name != "" do
    case Secrets.resolve(name) do
      {:ok, value, _source} ->
        case normalize_optional_string(value) do
          nil -> :not_found
          key -> {:ok, key}
        end

      {:error, :not_found} ->
        :not_found

      {:error, reason} ->
        {:error, name, reason}
    end
  rescue
    error -> {:error, name, {:exception, error.__struct__}}
  catch
    kind, _reason -> {:error, name, kind}
  end

  defp read_candidate({:secret, _name}), do: :not_found

  defp secret_unavailable(provider, name, reason) do
    %{
      "error" => "secret_unavailable",
      "message" =>
        "websearch (#{provider}) could not read credential secret #{name} (#{inspect(reason)}). " <>
          "Fix or remove the stored secret; other credentials and providers are not used in its place.",
      "docs" => "docs/tools/web.md"
    }
  end

  defp resolve_perplexity_base_url(perplexity_cfg, source, api_key) do
    perplexity_key? = key_has_prefix?(api_key, @perplexity_key_prefixes)
    openrouter_key? = key_has_prefix?(api_key, @openrouter_key_prefixes)

    cond do
      present?(perplexity_cfg.base_url) ->
        {:ok, perplexity_cfg.base_url}

      source == :perplexity_env and not openrouter_key? ->
        {:ok, @perplexity_direct_base_url}

      source == :openrouter_env and not perplexity_key? ->
        {:ok, @default_perplexity_base_url}

      source == :configured and perplexity_key? ->
        {:ok, @perplexity_direct_base_url}

      source == :configured and openrouter_key? ->
        {:ok, @default_perplexity_base_url}

      true ->
        {:error,
         %{
           "error" => "ambiguous_perplexity_endpoint",
           "message" =>
             "websearch (perplexity) cannot tell whether the configured API key belongs to Perplexity or OpenRouter. Set agent.tools.web.search.perplexity.base_url explicitly.",
           "docs" => "docs/tools/web.md"
         }}
    end
  end

  defp normalize_request_params(params, runtime) do
    count =
      read_integer(params, ["count", "max_results"], runtime.max_results)
      |> clamp(1, @max_search_count)

    country = read_string(params, ["country"])
    search_lang = read_string(params, ["search_lang"])
    ui_lang = read_string(params, ["ui_lang"])
    region = read_string(params, ["region"])

    max_chars =
      read_integer(params, ["maxChars", "max_chars"], runtime.max_chars)
      |> normalize_limit(runtime.max_chars, @max_content_max_chars)

    snippet_max_chars =
      read_integer(params, ["snippetMaxChars", "snippet_max_chars"], runtime.snippet_max_chars)
      |> normalize_limit(runtime.snippet_max_chars, @max_snippet_max_chars)

    max_citations =
      read_integer(params, ["maxCitations", "max_citations"], runtime.max_citations)
      |> normalize_limit(runtime.max_citations, @max_citations)

    citation_max_chars =
      read_integer(params, ["citationMaxChars", "citation_max_chars"], runtime.citation_max_chars)
      |> normalize_limit(runtime.citation_max_chars, @max_citation_max_chars)

    {country, search_lang, ui_lang} =
      apply_region_alias(%{
        country: country,
        search_lang: search_lang,
        ui_lang: ui_lang,
        region: region
      })

    %{
      count: count,
      country: country,
      search_lang: search_lang,
      ui_lang: ui_lang,
      max_chars: max_chars,
      snippet_max_chars: snippet_max_chars,
      max_citations: max_citations,
      citation_max_chars: citation_max_chars
    }
  end

  defp apply_region_alias(%{
         country: country,
         search_lang: search_lang,
         ui_lang: ui_lang,
         region: region
       }) do
    if is_nil(region) do
      {normalize_country(country), normalize_optional_string(search_lang),
       normalize_optional_string(ui_lang)}
    else
      case String.split(region, "-", parts: 2) do
        [country_part, lang_part] ->
          {
            normalize_country(country || country_part),
            normalize_optional_string(search_lang || lang_part),
            normalize_optional_string(ui_lang || lang_part)
          }

        [country_part] ->
          {
            normalize_country(country || country_part),
            normalize_optional_string(search_lang),
            normalize_optional_string(ui_lang)
          }

        _ ->
          {normalize_country(country), normalize_optional_string(search_lang),
           normalize_optional_string(ui_lang)}
      end
    end
  end

  defp normalize_freshness(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:ok, nil}

      MapSet.member?(@brave_freshness_shortcuts, String.downcase(trimmed)) ->
        {:ok, String.downcase(trimmed)}

      true ->
        case Regex.run(~r/^(\d{4}-\d{2}-\d{2})to(\d{4}-\d{2}-\d{2})$/, trimmed) do
          [_, start_date, end_date] ->
            if valid_iso_date?(start_date) and valid_iso_date?(end_date) and
                 start_date <= end_date do
              {:ok, "#{start_date}to#{end_date}"}
            else
              {:error,
               "freshness must be one of pd, pw, pm, py, or a range like YYYY-MM-DDtoYYYY-MM-DD"}
            end

          _ ->
            {:error,
             "freshness must be one of pd, pw, pm, py, or a range like YYYY-MM-DDtoYYYY-MM-DD"}
        end
    end
  end

  defp normalize_freshness(_), do: {:error, "freshness must be a string"}

  defp normalize_recency(params) do
    case {Map.get(params, "freshness"), Map.get(params, "recency")} do
      {nil, nil} ->
        {:ok, nil}

      {nil, recency} when recency in ["day", "week", "month", "year"] ->
        {:ok, %{"day" => "pd", "week" => "pw", "month" => "pm", "year" => "py"}[recency]}

      {nil, _} ->
        {:error, "recency must be day, week, month, or year"}

      {freshness, _} ->
        normalize_freshness(freshness)
    end
  end

  defp supports_freshness?(provider, freshness) do
    case SearchRegistry.fetch(provider) do
      {:ok, spec} ->
        support = Map.get(Provider.search_features(spec.module), :freshness, [])

        if freshness in ["pd", "pw", "pm", "py"],
          do: :relative in support,
          else: :range in support

      _ ->
        false
    end
  end

  defp valid_iso_date?(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> true
      _ -> false
    end
  end

  defp normalize_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        {:error, "Query is required"}

      String.length(trimmed) > @max_query_length ->
        {:error, "Query is too long (max #{@max_query_length} characters)"}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_query(_), do: {:error, "Query is required"}

  defp enforce_rate_limit do
    ensure_rate_limit_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@rate_limit_table, :window) do
      [] ->
        :ets.insert(@rate_limit_table, {:window, now, 1})
        :ok

      [{:window, started_at, count}] ->
        if now - started_at > @rate_limit_window_ms do
          :ets.insert(@rate_limit_table, {:window, now, 1})
          :ok
        else
          if count < @rate_limit_max_requests do
            :ets.insert(@rate_limit_table, {:window, started_at, count + 1})
            :ok
          else
            {:error, "Rate limit exceeded. Please try again later."}
          end
        end
    end
  end

  defp ensure_rate_limit_table do
    CodingAgent.RuntimeTables.ensure_table(@rate_limit_table)
    :ok
  end

  defp read_integer(params, keys, fallback) do
    keys
    |> Enum.find_value(fn key ->
      case Map.get(params, key) do
        nil -> nil
        value -> normalize_integer(value)
      end
    end)
    |> case do
      nil -> fallback
      value -> value
    end
  end

  defp read_string(params, keys) do
    keys
    |> Enum.find_value(fn key ->
      params
      |> Map.get(key)
      |> normalize_optional_string()
    end)
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp normalize_limit(nil, fallback, _max_allowed), do: fallback

  defp normalize_limit(value, fallback, max_allowed) do
    value
    |> case do
      n when is_integer(n) -> n
      _ -> fallback
    end
    |> max(1)
    |> min(max_allowed)
  end

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp normalize_country(nil), do: nil

  defp normalize_country(country) when is_binary(country) do
    country
    |> String.trim()
    |> String.upcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_country(_), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_provider(value, fallback) when is_binary(value) do
    candidate = String.downcase(String.trim(value))

    case SearchRegistry.fetch(candidate) do
      {:ok, _spec} -> candidate
      {:error, :not_found} -> fallback
    end
  end

  defp normalize_provider(value, fallback) when is_atom(value) or is_integer(value) do
    normalize_provider(to_string(value), fallback)
  end

  defp normalize_provider(_value, fallback), do: fallback

  defp normalize_provider_optional(nil), do: nil

  defp normalize_provider_optional(value) when is_binary(value) do
    candidate = String.downcase(String.trim(value))

    case SearchRegistry.fetch(candidate) do
      {:ok, _spec} -> candidate
      {:error, :not_found} -> nil
    end
  end

  defp normalize_provider_optional(_), do: nil

  defp resolve_secondary_provider(_primary, false, _configured), do: nil

  defp resolve_secondary_provider(primary, true, configured) do
    candidate =
      cond do
        is_binary(configured) ->
          configured

        primary == "brave" ->
          "perplexity"

        true ->
          "brave"
      end

    if candidate == primary, do: nil, else: candidate
  end

  defp apply_provider_overrides(runtime, params) do
    requested = normalize_optional_string(Map.get(params, "provider"))

    with {:ok, provider} <- validate_requested_provider(requested, runtime.provider),
         {:ok, fallbacks} <- validate_fallback_providers(Map.get(params, "fallbackProviders")) do
      fallbacks =
        if is_nil(Map.get(params, "fallbackProviders")),
          do: runtime.fallback_providers,
          else: fallbacks

      {:ok,
       %{
         runtime
         | provider: provider,
           fallback_providers: Enum.reject(fallbacks, &(&1 == provider))
       }}
    end
  end

  defp validate_requested_provider(nil, configured), do: {:ok, configured}

  defp validate_requested_provider(value, _configured) do
    candidate = String.downcase(value)

    case SearchRegistry.fetch(candidate) do
      {:ok, %{capabilities: capabilities}} ->
        if :search in capabilities,
          do: {:ok, candidate},
          else: {:error, "Provider #{candidate} does not support search"}

      {:error, :not_found} ->
        {:error, "Unknown websearch provider: #{candidate}"}
    end
  end

  defp validate_fallback_providers(nil), do: {:ok, []}

  defp validate_fallback_providers(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_optional_string(value) do
        nil ->
          {:cont, {:ok, acc}}

        candidate ->
          case validate_requested_provider(candidate, nil) do
            {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp validate_fallback_providers(_),
    do: {:error, "fallbackProviders must be an array of provider ids"}

  defp present?(value), do: not is_nil(normalize_optional_string(value))

  defp key_has_prefix?(key, prefixes) when is_binary(key) do
    lower = String.downcase(key)
    Enum.any?(prefixes, &String.starts_with?(lower, &1))
  end

  defp key_has_prefix?(_, _), do: false

  defp json_result(payload) do
    ExternalContent.untrusted_json_result(payload)
  end

  defp build_runtime(opts) do
    settings_manager = Keyword.get(opts, :settings_manager)
    search_cfg = extract_search_config(settings_manager)
    cache_cfg = extract_cache_config(settings_manager)
    failover_cfg = extract_failover_config(search_cfg)
    perplexity_cfg = extract_perplexity_config(search_cfg)

    provider = resolve_provider(search_cfg)
    secondary_provider = resolve_failover_provider(provider, failover_cfg)
    cache_settings = build_cache_settings(cache_cfg, search_cfg)
    http_functions = build_http_functions(opts)

    Map.merge(
      %{
        provider: provider,
        secondary_provider: secondary_provider,
        fallback_providers: if(is_nil(secondary_provider), do: [], else: [secondary_provider]),
        provider_configs: search_cfg |> get_map_value(:providers, %{}) |> ensure_map(),
        enabled: truthy?(get_map_value(search_cfg, :enabled, true)),
        api_key: normalize_optional_string(get_map_value(search_cfg, :api_key, nil)),
        api_key_secret:
          normalize_optional_string(get_map_value(search_cfg, :api_key_secret, nil)),
        max_results: resolve_max_results(search_cfg),
        timeout_ms: cache_settings.timeout_ms,
        cache_ttl_ms: cache_settings.cache_ttl_ms,
        cache_max_entries: cache_settings.cache_max_entries,
        cache_opts: cache_settings.cache_opts
      },
      Map.merge(build_char_limits(search_cfg), build_perplexity_config(perplexity_cfg))
    )
    |> Map.merge(http_functions)
    |> Map.put(
      :kimi_code_credential,
      Keyword.get(opts, :kimi_code_credential, &kimi_code_credential/0)
    )
  end

  defp kimi_code_credential do
    cfg = LemonCore.Config.cached()
    provider_cfg = LemonAgent.ModelRuntime.ProviderNames.provider_config(cfg, :kimi_coding) || %{}
    base_url = Map.get(provider_cfg, :base_url) || Map.get(provider_cfg, "base_url")
    api_key = LemonAgent.ModelRuntime.Credentials.build_get_api_key(cfg).(:kimi_coding)

    {api_key, normalize_optional_string(base_url)}
  end

  # Extract nested configuration maps from settings
  defp extract_search_config(settings_manager) do
    settings_manager
    |> get_struct_field(:tools, %{})
    |> ensure_map()
    |> get_map_value(:web, %{})
    |> ensure_map()
    |> get_map_value(:search, %{})
    |> ensure_map()
  end

  defp extract_cache_config(settings_manager) do
    settings_manager
    |> get_struct_field(:tools, %{})
    |> ensure_map()
    |> get_map_value(:web, %{})
    |> ensure_map()
    |> get_map_value(:cache, %{})
    |> ensure_map()
  end

  defp extract_failover_config(search_cfg) do
    search_cfg |> get_map_value(:failover, %{}) |> ensure_map()
  end

  defp extract_perplexity_config(search_cfg) do
    search_cfg |> get_map_value(:perplexity, %{}) |> ensure_map()
  end

  # Provider resolution
  defp resolve_provider(search_cfg) do
    search_cfg
    |> get_map_value(:provider, "brave")
    |> normalize_provider("brave")
  end

  defp resolve_failover_provider(primary, failover_cfg) do
    failover_enabled = truthy?(get_map_value(failover_cfg, :enabled, @default_failover_enabled))

    configured_secondary =
      failover_cfg
      |> get_map_value(:provider, get_map_value(failover_cfg, :secondary_provider, nil))
      |> normalize_provider_optional()

    resolve_secondary_provider(primary, failover_enabled, configured_secondary)
  end

  # Cache settings
  defp build_cache_settings(cache_cfg, search_cfg) do
    cache_max_entries =
      WebCache.resolve_cache_max_entries(
        get_map_value(cache_cfg, :max_entries, @default_cache_max_entries),
        @default_cache_max_entries
      )

    timeout_seconds =
      WebCache.resolve_timeout_seconds(
        get_map_value(search_cfg, :timeout_seconds, @default_timeout_seconds),
        @default_timeout_seconds
      )

    cache_ttl_ms =
      WebCache.resolve_cache_ttl_ms(
        get_map_value(search_cfg, :cache_ttl_minutes, @default_cache_ttl_minutes),
        @default_cache_ttl_minutes
      )

    cache_opts = %{
      "persistent" => truthy?(get_map_value(cache_cfg, :persistent, true)),
      "path" => normalize_optional_string(get_map_value(cache_cfg, :path, nil)),
      "max_entries" => cache_max_entries
    }

    %{
      timeout_ms: timeout_seconds * 1_000,
      cache_ttl_ms: cache_ttl_ms,
      cache_max_entries: cache_max_entries,
      cache_opts: cache_opts
    }
  end

  # Character limit settings
  defp build_char_limits(search_cfg) do
    %{
      max_chars:
        normalize_limit(
          normalize_integer(get_map_value(search_cfg, :max_chars, nil)),
          @default_content_max_chars,
          @max_content_max_chars
        ),
      snippet_max_chars:
        normalize_limit(
          normalize_integer(get_map_value(search_cfg, :snippet_max_chars, nil)),
          @default_snippet_max_chars,
          @max_snippet_max_chars
        ),
      max_citations:
        normalize_limit(
          normalize_integer(get_map_value(search_cfg, :max_citations, nil)),
          @default_max_citations,
          @max_citations
        ),
      citation_max_chars:
        normalize_limit(
          normalize_integer(get_map_value(search_cfg, :citation_max_chars, nil)),
          @default_citation_max_chars,
          @max_citation_max_chars
        )
    }
  end

  defp resolve_max_results(search_cfg) do
    clamp(
      normalize_integer(get_map_value(search_cfg, :max_results, nil)) || @default_search_count,
      1,
      @max_search_count
    )
  end

  # Perplexity configuration
  defp build_perplexity_config(perplexity_cfg) do
    %{
      perplexity: %{
        api_key: normalize_optional_string(get_map_value(perplexity_cfg, :api_key, nil)),
        api_key_secret:
          normalize_optional_string(get_map_value(perplexity_cfg, :api_key_secret, nil)),
        base_url: normalize_optional_string(get_map_value(perplexity_cfg, :base_url, nil)),
        model:
          normalize_optional_string(
            get_map_value(perplexity_cfg, :model, @default_perplexity_model)
          )
      }
    }
  end

  # HTTP functions
  defp build_http_functions(opts) do
    %{
      http_get: Keyword.get(opts, :http_get, &Req.get/2),
      http_post: Keyword.get(opts, :http_post, &Req.post/2)
    }
  end

  defp get_struct_field(nil, _field, default), do: default

  defp get_struct_field(struct, field, default) when is_map(struct) do
    Map.get(struct, field, default)
  end

  defp get_struct_field(_struct, _field, default), do: default

  defp get_map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp get_map_value(_map, _key, default), do: default

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp truthy?(value) when value in [false, "false", "0", 0], do: false
  defp truthy?(_), do: true
end
