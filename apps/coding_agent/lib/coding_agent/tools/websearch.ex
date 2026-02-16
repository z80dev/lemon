defmodule CodingAgent.Tools.WebSearch do
  @moduledoc """
  WebSearch tool for the coding agent.

  Supports Brave Search API (default) and Perplexity Sonar (direct/OpenRouter).
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.Security.ExternalContent
  alias CodingAgent.Tools.WebCache

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
  @brave_search_endpoint "https://api.search.brave.com/res/v1/web/search"
  @rate_limit_window_ms 1_000
  @rate_limit_max_requests 5
  @rate_limit_table :coding_agent_websearch_rate_limit
  @search_cache_table :coding_agent_websearch_cache
  @perplexity_key_prefixes ["pplx-"]
  @openrouter_key_prefixes ["sk-or-"]
  @brave_freshness_shortcuts MapSet.new(["pd", "pw", "pm", "py"])

  @doc """
  Returns the WebSearch tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    runtime = build_runtime(opts)

    %AgentTool{
      name: "websearch",
      description:
        "Search the web using Brave Search API (default) or Perplexity Sonar. Returns structured JSON.",
      label: "Web Search",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Search query string."
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
            "description" => "Brave-only time filter: pd, pw, pm, py, or YYYY-MM-DDtoYYYY-MM-DD."
          }
        },
        "required" => ["query"]
      },
      execute: fn tool_call_id, params, signal, on_update ->
        execute(tool_call_id, params, signal, on_update, runtime)
      end
    }
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
           {:ok, freshness} <- normalize_freshness(Map.get(params, "freshness")),
           :ok <- check_abort(signal),
           request <- normalize_request_params(params, runtime),
           :ok <- validate_freshness_provider(freshness, runtime.provider),
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
    primary_provider = runtime.provider
    failover = failover_context(runtime, freshness)

    case run_provider_attempt(primary_provider, query, freshness, request, runtime) do
      {:ok, payload, cached?} ->
        payload =
          annotate_payload(
            payload,
            primary_provider,
            primary_provider,
            failover_payload(false, false, primary_provider, nil)
          )
          |> maybe_mark_cached(cached?)

        json_result(payload)

      primary_failure ->
        maybe_failover(
          primary_failure,
          primary_provider,
          query,
          freshness,
          request,
          runtime,
          failover
        )
    end
  end

  defp maybe_failover(
         primary_failure,
         primary_provider,
         _query,
         _freshness,
         _request,
         _runtime,
         %{
           secondary_provider: nil
         }
       ) do
    render_failure(
      primary_failure,
      primary_provider,
      failover_payload(false, false, primary_provider, nil)
    )
  end

  defp maybe_failover(
         primary_failure,
         primary_provider,
         _query,
         _freshness,
         _request,
         _runtime,
         %{
           blocked_reason: blocked_reason
         }
       )
       when is_binary(blocked_reason) do
    render_failure(
      primary_failure,
      primary_provider,
      failover_payload(false, false, primary_provider, blocked_reason)
    )
  end

  defp maybe_failover(
         primary_failure,
         primary_provider,
         query,
         freshness,
         request,
         runtime,
         %{secondary_provider: secondary_provider}
       ) do
    case run_provider_attempt(secondary_provider, query, freshness, request, runtime) do
      {:ok, payload, cached?} ->
        payload =
          annotate_payload(
            payload,
            primary_provider,
            secondary_provider,
            failover_payload(
              true,
              true,
              primary_provider,
              failure_summary(primary_failure)
            )
          )
          |> maybe_mark_cached(cached?)

        json_result(payload)

      secondary_failure ->
        render_combined_failure(
          primary_failure,
          secondary_failure,
          primary_provider,
          secondary_provider
        )
    end
  end

  defp run_provider_attempt(provider, query, freshness, request, runtime) do
    cache_key = build_cache_key(query, freshness, request, provider)

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
    start_ms = System.monotonic_time(:millisecond)

    case provider do
      "perplexity" ->
        with {:ok, payload} <-
               run_perplexity_search(provider, query, request, api_cfg, runtime, start_ms) do
          {:ok, payload}
        end

      _ ->
        with {:ok, payload} <-
               run_brave_search(provider, query, freshness, request, api_cfg, runtime, start_ms) do
          {:ok, payload}
        end
    end
  end

  defp run_brave_search(provider, query, freshness, request, api_cfg, runtime, start_ms) do
    params =
      [
        {"q", query},
        {"count", Integer.to_string(request.count)}
      ]
      |> maybe_put_query_param("country", request.country)
      |> maybe_put_query_param("search_lang", request.search_lang)
      |> maybe_put_query_param("ui_lang", request.ui_lang)
      |> maybe_put_query_param("freshness", freshness)

    url = @brave_search_endpoint <> "?" <> URI.encode_query(params)

    case runtime.http_get.(url, brave_request_opts(api_cfg.api_key, runtime.timeout_ms)) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        body = decode_json_body(response.body)
        raw_results = get_in(body, ["web", "results"]) || []

        mapped =
          raw_results
          |> Enum.map(&map_brave_result/1)
          |> Enum.reject(&is_nil/1)

        {:ok,
         %{
           "query" => query,
           "provider" => provider,
           "count" => length(mapped),
           "took_ms" => elapsed_ms(start_ms),
           "results" => mapped,
           "trust_metadata" =>
             web_search_trust_metadata(["results[].title", "results[].description"])
         }}

      {:ok, %Req.Response{status: status} = response} ->
        detail = response.body |> to_string_safe() |> String.trim()

        {:error,
         "Brave Search API error (#{status}): #{if(detail == "", do: "request failed", else: detail)}"}

      {:error, reason} ->
        {:error, "Brave Search request failed: #{format_reason(reason)}"}

      other ->
        {:error, "Unexpected Brave Search result: #{inspect(other)}"}
    end
  end

  defp run_perplexity_search(provider, query, _request, api_cfg, runtime, start_ms) do
    endpoint = String.trim_trailing(api_cfg.base_url, "/") <> "/chat/completions"

    request_body = %{
      "model" => api_cfg.model,
      "messages" => [
        %{
          "role" => "user",
          "content" => query
        }
      ]
    }

    request_opts = [
      headers: [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{api_cfg.api_key}"},
        {"http-referer", "https://lemon.agent"},
        {"x-title", "Lemon Web Search"}
      ],
      json: request_body,
      connect_options: [timeout: runtime.timeout_ms],
      receive_timeout: runtime.timeout_ms
    ]

    case runtime.http_post.(endpoint, request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        body = decode_json_body(response.body)
        content = get_in(body, ["choices", Access.at(0), "message", "content"]) || "No response"
        citations = Map.get(body, "citations", [])

        {:ok,
         %{
           "query" => query,
           "provider" => provider,
           "model" => api_cfg.model,
           "took_ms" => elapsed_ms(start_ms),
           "content" => ExternalContent.wrap_web_content(to_string(content), :web_search),
           "citations" => citations,
           "trust_metadata" => web_search_trust_metadata(["content"])
         }}

      {:ok, %Req.Response{status: status} = response} ->
        detail = response.body |> to_string_safe() |> String.trim()

        {:error,
         "Perplexity API error (#{status}): #{if(detail == "", do: "request failed", else: detail)}"}

      {:error, reason} ->
        {:error, "Perplexity request failed: #{format_reason(reason)}"}

      other ->
        {:error, "Unexpected Perplexity result: #{inspect(other)}"}
    end
  end

  defp map_brave_result(entry) when is_map(entry) do
    title = normalize_optional_string(Map.get(entry, "title"))
    description = normalize_optional_string(Map.get(entry, "description"))
    url = normalize_optional_string(Map.get(entry, "url"))
    published = normalize_optional_string(Map.get(entry, "age"))
    site_name = site_name(url)

    %{
      "title" => if(title, do: ExternalContent.wrap_web_content(title, :web_search), else: ""),
      "url" => url || "",
      "description" =>
        if(description, do: ExternalContent.wrap_web_content(description, :web_search), else: ""),
      "published" => published,
      "site_name" => site_name
    }
  end

  defp map_brave_result(_), do: nil

  defp web_search_trust_metadata(wrapped_fields) do
    ExternalContent.trust_metadata(:web_search,
      warning_included: false,
      wrapped_fields: wrapped_fields
    )
  end

  defp brave_request_opts(api_key, timeout_ms) do
    [
      headers: [
        {"accept", "application/json"},
        {"x-subscription-token", api_key}
      ],
      connect_options: [timeout: timeout_ms],
      receive_timeout: timeout_ms
    ]
  end

  defp failover_context(runtime, freshness) do
    secondary_provider = runtime.secondary_provider

    blocked_reason =
      cond do
        is_nil(secondary_provider) ->
          nil

        not is_nil(freshness) and secondary_provider != "brave" ->
          "Failover to #{secondary_provider} skipped because freshness is only supported by Brave."

        true ->
          nil
      end

    %{
      secondary_provider: secondary_provider,
      blocked_reason: blocked_reason
    }
  end

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

  defp render_failure({:setup_error, payload}, primary_provider, failover) do
    payload
    |> annotate_payload(primary_provider, primary_provider, failover)
    |> json_result()
  end

  defp render_failure({:runtime_error, reason}, _primary_provider, failover) do
    reason_text = to_string(reason)

    case Map.get(failover, "reason") do
      nil -> {:error, reason_text}
      context -> {:error, "#{reason_text} (#{context})"}
    end
  end

  defp render_combined_failure(
         primary_failure,
         secondary_failure,
         primary_provider,
         secondary_provider
       ) do
    summary =
      "Primary provider #{primary_provider} failed: #{failure_summary(primary_failure)}. " <>
        "Failover provider #{secondary_provider} failed: #{failure_summary(secondary_failure)}."

    failover = failover_payload(true, false, primary_provider, summary)

    case {primary_failure, secondary_failure} do
      {{:setup_error, payload}, _} ->
        payload
        |> annotate_payload(primary_provider, primary_provider, failover)
        |> Map.put("warning", summary)
        |> json_result()

      {_, {:setup_error, payload}} ->
        payload
        |> annotate_payload(primary_provider, primary_provider, failover)
        |> Map.put("warning", summary)
        |> json_result()

      {{:runtime_error, reason}, _} ->
        {:error, "#{to_string(reason)} (#{summary})"}
    end
  end

  defp failure_summary({:setup_error, payload}) when is_map(payload) do
    Map.get(payload, "error") || Map.get(payload, "message") || "setup_error"
  end

  defp failure_summary({:runtime_error, reason}) when is_binary(reason), do: reason
  defp failure_summary({:runtime_error, reason}), do: inspect(reason)

  defp build_cache_key(query, freshness, request, provider) do
    key =
      if provider == "brave" do
        "#{provider}:#{query}:#{request.count}:#{request.country || "default"}:" <>
          "#{request.search_lang || "default"}:#{request.ui_lang || "default"}:#{freshness || "default"}"
      else
        "#{provider}:#{query}:#{request.count}:#{request.country || "default"}:" <>
          "#{request.search_lang || "default"}:#{request.ui_lang || "default"}"
      end

    WebCache.normalize_cache_key(key)
  end

  defp resolve_api_config("perplexity", runtime) do
    api_key = resolve_perplexity_api_key(runtime.perplexity)

    if is_nil(api_key) do
      {:error,
       %{
         "error" => "missing_perplexity_api_key",
         "message" =>
           "websearch (perplexity) needs an API key. Set PERPLEXITY_API_KEY or OPENROUTER_API_KEY, or configure agent.tools.web.search.perplexity.api_key.",
         "docs" => "docs/tools/web.md"
       }}
    else
      source = perplexity_api_key_source(runtime.perplexity)
      base_url = resolve_perplexity_base_url(runtime.perplexity, source, api_key)
      model = runtime.perplexity.model || @default_perplexity_model

      {:ok,
       %{
         api_key: api_key,
         base_url: base_url,
         model: model
       }}
    end
  end

  defp resolve_api_config(_provider, runtime) do
    api_key = normalize_optional_string(runtime.api_key) || env_optional("BRAVE_API_KEY")

    if is_nil(api_key) do
      {:error,
       %{
         "error" => "missing_brave_api_key",
         "message" =>
           "websearch needs a Brave Search API key. Set BRAVE_API_KEY or configure agent.tools.web.search.api_key.",
         "docs" => "docs/tools/web.md"
       }}
    else
      {:ok, %{api_key: api_key}}
    end
  end

  defp resolve_perplexity_api_key(perplexity_cfg) do
    normalize_optional_string(perplexity_cfg.api_key) ||
      env_optional("PERPLEXITY_API_KEY") ||
      env_optional("OPENROUTER_API_KEY")
  end

  defp perplexity_api_key_source(perplexity_cfg) do
    cond do
      present?(perplexity_cfg.api_key) -> :config
      present?(System.get_env("PERPLEXITY_API_KEY")) -> :perplexity_env
      present?(System.get_env("OPENROUTER_API_KEY")) -> :openrouter_env
      true -> :none
    end
  end

  defp resolve_perplexity_base_url(perplexity_cfg, source, api_key) do
    cond do
      present?(perplexity_cfg.base_url) ->
        perplexity_cfg.base_url

      source == :perplexity_env ->
        @perplexity_direct_base_url

      source == :openrouter_env ->
        @default_perplexity_base_url

      source == :config and key_has_prefix?(api_key, @perplexity_key_prefixes) ->
        @perplexity_direct_base_url

      source == :config and key_has_prefix?(api_key, @openrouter_key_prefixes) ->
        @default_perplexity_base_url

      true ->
        @default_perplexity_base_url
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
      ui_lang: ui_lang
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

  defp normalize_freshness(nil), do: {:ok, nil}

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

  defp validate_freshness_provider(nil, _provider), do: :ok
  defp validate_freshness_provider(_freshness, "brave"), do: :ok

  defp validate_freshness_provider(_freshness, _provider) do
    {:error, "freshness is only supported by the Brave websearch provider"}
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

  defp check_abort(nil), do: :ok

  defp check_abort(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end

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
    case :ets.whereis(@rate_limit_table) do
      :undefined ->
        try do
          :ets.new(@rate_limit_table, [:named_table, :set, :public, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp decode_json_body(body) when is_map(body), do: body

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_json_body(body) when is_list(body), do: decode_json_body(IO.iodata_to_binary(body))
  defp decode_json_body(_), do: %{}

  defp maybe_put_query_param(params, _key, nil), do: params
  defp maybe_put_query_param(params, _key, ""), do: params
  defp maybe_put_query_param(params, key, value), do: params ++ [{key, value}]

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

  defp site_name(nil), do: nil

  defp site_name(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_provider(value, fallback) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "perplexity" -> "perplexity"
      "brave" -> "brave"
      _ -> fallback
    end
  end

  defp normalize_provider(value, fallback) when is_atom(value) or is_integer(value) do
    normalize_provider(to_string(value), fallback)
  end

  defp normalize_provider(_value, fallback), do: fallback

  defp normalize_provider_optional(nil), do: nil

  defp normalize_provider_optional(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "perplexity" -> "perplexity"
      "brave" -> "brave"
      _ -> nil
    end
  end

  defp normalize_provider_optional(_), do: nil

  defp resolve_secondary_provider(_primary, false, _configured), do: nil

  defp resolve_secondary_provider(primary, true, configured) do
    candidate =
      cond do
        configured in ["brave", "perplexity"] ->
          configured

        primary == "brave" ->
          "perplexity"

        true ->
          "brave"
      end

    if candidate == primary, do: nil, else: candidate
  end

  defp env_optional(name), do: normalize_optional_string(System.get_env(name))

  defp present?(value), do: not is_nil(normalize_optional_string(value))

  defp key_has_prefix?(key, prefixes) when is_binary(key) do
    lower = String.downcase(key)
    Enum.any?(prefixes, &String.starts_with?(lower, &1))
  end

  defp key_has_prefix?(_, _), do: false

  defp to_string_safe(body) when is_binary(body), do: body
  defp to_string_safe(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp to_string_safe(body), do: inspect(body)

  defp elapsed_ms(start_monotonic_ms) do
    System.monotonic_time(:millisecond) - start_monotonic_ms
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp json_result(payload) do
    text = Jason.encode!(payload, pretty: true)

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: payload,
      trust: :untrusted
    }
  end

  defp build_runtime(opts) do
    settings_manager = Keyword.get(opts, :settings_manager)
    tools_cfg = settings_manager |> get_struct_field(:tools, %{}) |> ensure_map()
    web_cfg = tools_cfg |> get_map_value(:web, %{}) |> ensure_map()
    search_cfg = web_cfg |> get_map_value(:search, %{}) |> ensure_map()
    perplexity_cfg = search_cfg |> get_map_value(:perplexity, %{}) |> ensure_map()
    failover_cfg = search_cfg |> get_map_value(:failover, %{}) |> ensure_map()
    cache_cfg = web_cfg |> get_map_value(:cache, %{}) |> ensure_map()

    provider =
      search_cfg
      |> get_map_value(:provider, "brave")
      |> normalize_provider("brave")

    failover_enabled = truthy?(get_map_value(failover_cfg, :enabled, @default_failover_enabled))

    configured_secondary =
      failover_cfg
      |> get_map_value(:provider, get_map_value(failover_cfg, :secondary_provider, nil))
      |> normalize_provider_optional()

    secondary_provider =
      resolve_secondary_provider(provider, failover_enabled, configured_secondary)

    cache_max_entries =
      WebCache.resolve_cache_max_entries(
        get_map_value(cache_cfg, :max_entries, @default_cache_max_entries),
        @default_cache_max_entries
      )

    cache_opts = %{
      "persistent" => truthy?(get_map_value(cache_cfg, :persistent, true)),
      "path" => normalize_optional_string(get_map_value(cache_cfg, :path, nil)),
      "max_entries" => cache_max_entries
    }

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

    http_get = Keyword.get(opts, :http_get, &Req.get/2)
    http_post = Keyword.get(opts, :http_post, &Req.post/2)

    %{
      provider: provider,
      secondary_provider: secondary_provider,
      enabled: truthy?(get_map_value(search_cfg, :enabled, true)),
      api_key: normalize_optional_string(get_map_value(search_cfg, :api_key, nil)),
      max_results:
        clamp(
          normalize_integer(get_map_value(search_cfg, :max_results, nil)) || @default_search_count,
          1,
          @max_search_count
        ),
      timeout_ms: timeout_seconds * 1_000,
      cache_ttl_ms: cache_ttl_ms,
      cache_max_entries: cache_max_entries,
      cache_opts: cache_opts,
      perplexity: %{
        api_key: normalize_optional_string(get_map_value(perplexity_cfg, :api_key, nil)),
        base_url: normalize_optional_string(get_map_value(perplexity_cfg, :base_url, nil)),
        model:
          normalize_optional_string(
            get_map_value(perplexity_cfg, :model, @default_perplexity_model)
          )
      },
      http_get: http_get,
      http_post: http_post
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
