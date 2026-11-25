defmodule LemonAgent.ModelRuntime.StreamOptions do
  @moduledoc """
  Lemon-owned `LemonAi.Types.StreamOptions` builder.

  This module normalizes caller-provided stream options and resolves provider-
  specific runtime inputs before `LemonAi.stream/3` or `LemonAi.complete/3` is invoked.

  Selected OAuth and omp credentials are resolved by the per-request credential
  callback, not fetched again here. Its concrete key must be applied before calling
  `LemonAi`; `api_key_authoritative` prevents lower layers from substituting
  static, environment or encoded secret values when that callback refuses.
  """

  alias LemonAi.Providers.RequestHeaders
  alias LemonAi.Types.StreamOptions
  alias LemonAgent.ModelRuntime.Credentials
  alias LemonAgent.ModelRuntime.CustomProviders
  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonAgent.ModelRuntime.StreamOptions.ProviderSettings

  @effort_budget_keys [
    :minimal,
    :low,
    :medium,
    :high,
    :xhigh,
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh"
  ]

  @doc """
  Removes provider-bound credentials and routing inputs before a provider switch.

  Request settings, observers, session identity and timeouts are retained.
  Selected-credential authority is cleared so the destination can resolve its own
  credentials instead of inheriting the previous provider's refusal.
  Only numeric effort entries survive in `thinking_budgets`; provider-specific
  URL/version/deployment overrides must be rebuilt from the destination config.
  """
  @spec sanitize_for_provider_switch(StreamOptions.t() | map() | nil) ::
          StreamOptions.t() | nil
  def sanitize_for_provider_switch(%StreamOptions{} = options) do
    thinking_budgets =
      Enum.reduce(options.thinking_budgets || %{}, %{}, fn {effort, budget}, acc ->
        if effort in @effort_budget_keys and is_number(budget),
          do: Map.put(acc, effort, budget),
          else: acc
      end)

    %{
      options
      | api_key: nil,
        api_key_authoritative: false,
        access_token: nil,
        project: nil,
        location: nil,
        headers: %{},
        caller_headers: %{},
        provider_options: %{},
        thinking_budgets: thinking_budgets
    }
  end

  def sanitize_for_provider_switch(options) when is_map(options) do
    options
    |> normalize_stream_options(nil)
    |> sanitize_for_provider_switch()
  end

  def sanitize_for_provider_switch(nil), do: nil

  @spec build_stream_options(
          LemonAi.Types.Model.t(),
          map() | nil,
          map() | StreamOptions.t() | nil,
          String.t() | nil
        ) ::
          StreamOptions.t()
  def build_stream_options(model, providers_map, existing_opts, cwd) do
    base_opts = normalize_stream_options(existing_opts, cwd)

    case CustomProviders.custom_provider(providers_map, Map.get(model, :provider)) do
      {provider_id, provider_cfg} ->
        base_opts
        |> responses_options(model, provider_cfg)
        |> custom_provider_options(provider_id, provider_cfg, providers_map)

      nil ->
        provider_stream_options(model, providers_map, base_opts)
    end
  end

  # Custom models already carry provider defaults beneath model overrides.
  # Only explicit caller headers belong in the final wire override layer.
  defp custom_provider_options(base_opts, provider_id, provider_cfg, providers_map) do
    api_key =
      first_non_empty_binary([
        base_opts.api_key,
        Credentials.resolve_provider_api_key(provider_id, providers_map)
      ])

    base_opts
    |> maybe_put_struct(:api_key, api_key)
    |> put_provider_options(provider_id, %{
      api_key: api_key,
      base_url: CustomProviders.base_url(provider_cfg)
    })
  end

  defp provider_stream_options(model, providers_map, base_opts) do
    provider_cfg =
      ProviderNames.provider_config(providers_map, provider_config_lookup_key(model)) ||
        CustomProviders.config_for(providers_map, Map.get(model, :provider)) || %{}

    base_opts = responses_options(base_opts, model, provider_cfg)

    # Catalog-only built-in models may not carry configured provider headers.
    # Keep model overrides above those defaults, then explicit caller headers.
    base_opts =
      case CustomProviders.headers(provider_cfg) do
        defaults when map_size(defaults) == 0 ->
          base_opts

        defaults ->
          headers =
            defaults
            |> RequestHeaders.merge(model.headers)
            |> RequestHeaders.merge(base_opts.headers)

          %{base_opts | headers: headers}
      end

    base_opts =
      if Credentials.authoritative_selected?(provider_cfg) do
        %{base_opts | api_key: nil, api_key_authoritative: true}
      else
        base_opts
      end

    case model do
      %{provider: :google_vertex} ->
        resolved =
          ProviderSettings.resolve(:google_vertex,
          google_vertex_input(base_opts, provider_cfg))

        base_opts
        |> maybe_put_struct(:project, resolved[:project])
        |> maybe_put_struct(:location, resolved[:location])
        |> put_provider_options(:google_vertex, %{
          project: resolved[:project],
          location: resolved[:location],
          credential_error: resolved[:credential_error]
        })

      %{api: :azure_openai_responses} ->
        resolved =
          ProviderSettings.resolve(:azure_openai_responses,
          azure_input(base_opts, provider_cfg))

        base_opts
        |> maybe_put_struct(:api_key, resolved[:api_key])
        |> apply_resolved_authority(resolved)
        |> put_provider_options(:azure_openai_responses, %{
          api_key: resolved[:api_key],
          base_url: resolved[:base_url],
          api_version: resolved[:api_version],
          resource_name: resolved[:resource_name],
          deployment_name: azure_override(base_opts, :deployment_name),
          deployment_name_map: resolved[:deployment_name_map]
        })

      %{api: :bedrock_converse_stream} ->
        resolved =
          ProviderSettings.resolve(:bedrock_converse_stream,
          bedrock_input(base_opts, provider_cfg))

        resolved_headers = Map.get(resolved, :headers, %{})
        headers = Map.merge(resolved_headers, base_opts.headers)

        base_opts
        |> Map.put(:headers, headers)
        |> put_provider_options(:bedrock_converse_stream, %{
          aws_region: headers["aws_region"],
          aws_access_key_id: headers["aws_access_key_id"],
          aws_secret_access_key: headers["aws_secret_access_key"],
          aws_session_token: headers["aws_session_token"]
        })

      %{provider: :google_gemini_cli} ->
        resolved =
          ProviderSettings.resolve(:google_gemini_cli,
          google_gemini_cli_input(base_opts, provider_cfg))

        base_opts
        |> maybe_put_struct(:project, resolved[:project])
        |> put_provider_options(:google_gemini_cli, %{project: resolved[:project]})

      %{api: :openai_completions} ->
        provider_id = provider_config_lookup_key(model)

        resolved =
          ProviderSettings.resolve(provider_id,
          openai_compatible_input(base_opts, provider_cfg))

        base_opts
        |> apply_resolved_authority(resolved)
        |> put_provider_options(provider_id, %{
          api_key: resolved[:api_key],
          base_url: resolved[:base_url]
        })

      _ ->
        base_opts
    end
  end

  defp responses_options(opts, %{api: api}, provider_cfg)
       when api in [:openai_responses, :openai_codex_responses] do
    configured = provider_config_value(provider_cfg, :provider_options) || %{}
    existing = opts.provider_options

    websocket =
      Map.get(
        existing,
        :responses_websocket,
        Map.get(
          existing,
          "responses_websocket",
          Map.get(configured, :responses_websocket, Map.get(configured, "responses_websocket"))
        )
      )

    if is_boolean(websocket) do
      %{opts | provider_options: Map.put(existing, :responses_websocket, websocket)}
    else
      opts
    end
  end

  defp responses_options(opts, _model, _provider_cfg), do: opts

  defp google_vertex_input(base_opts, provider_cfg) do
    stream_options_to_map(base_opts)
    |> Map.put(:provider_config, provider_cfg)
  end

  # Azure settings live only in `provider_options[:azure_openai_responses]`;
  # configured values win over per-request caller overrides there.
  defp azure_input(base_opts, provider_cfg) do
    azure_opts =
      [:base_url, :resource_name, :api_version, :deployment_name_map]
      |> Map.new(fn key ->
        {key, provider_config_value(provider_cfg, key) || azure_override(base_opts, key)}
      end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    stream_options_to_map(base_opts)
    |> Map.put(:azure, azure_opts)
    |> Map.put(:provider_config, provider_cfg)
    |> put_configured_api_key(base_opts, provider_cfg)
  end

  defp azure_override(%{provider_options: %{azure_openai_responses: %{} = overrides}}, key),
    do: Map.get(overrides, key)

  defp azure_override(_base_opts, _key), do: nil

  # The resolver reads the configured AWS secrets itself, stopping at an
  # unreadable one instead of continuing to the ambient AWS_* credentials.
  defp bedrock_input(base_opts, provider_cfg) do
    headers =
      maybe_put(base_opts.headers, "aws_region", provider_config_value(provider_cfg, :region))

    stream_options_to_map(base_opts)
    |> Map.put(:headers, headers)
    |> Map.put(:provider_config, provider_cfg)
  end

  defp google_gemini_cli_input(base_opts, provider_cfg) do
    stream_options_to_map(base_opts)
    |> maybe_put(:project, provider_config_value(provider_cfg, :project))
    |> maybe_put(:project_id, provider_config_value(provider_cfg, :project_id))
    |> maybe_put(:projectId, provider_config_value(provider_cfg, :projectId))
    |> maybe_put(:project_secret, provider_config_value(provider_cfg, :project_secret))
  end

  defp openai_compatible_input(base_opts, provider_cfg) do
    stream_options_to_map(base_opts)
    |> Map.put(:provider_config, provider_cfg)
    |> Map.put(:api_key, nil)
    |> put_configured_api_key(base_opts, provider_cfg)
    |> maybe_put(:base_url, provider_config_value(provider_cfg, :base_url))
  end

  defp apply_resolved_authority(opts, %{api_key_authoritative: true} = resolved),
    do: %{opts | api_key: resolved[:api_key], api_key_authoritative: true}

  defp apply_resolved_authority(opts, _resolved), do: opts

  # Caller key, then the configured secret, then the inline key. An unreadable
  # configured secret is an authoritative refusal (no key), never the inline key.
  defp put_configured_api_key(input, %StreamOptions{api_key_authoritative: true} = opts, _cfg),
    do: Map.put(input, :api_key, opts.api_key)

  defp put_configured_api_key(input, base_opts, provider_cfg) do
    candidate =
      if present_binary?(base_opts.api_key) do
        {:ok, base_opts.api_key}
      else
        case Credentials.fetch_secret_api_key(
               provider_config_value(provider_cfg, :api_key_secret),
               env_fallback: true
             ) do
          :miss -> inline_api_key(provider_cfg)
          other -> other
        end
      end

    case candidate do
      {:ok, api_key} -> Map.put(input, :api_key, api_key)
      :miss -> input
      :error -> input |> Map.put(:api_key, nil) |> Map.put(:api_key_authoritative, true)
    end
  end

  defp inline_api_key(provider_cfg) do
    api_key = provider_config_value(provider_cfg, :api_key)
    if present_binary?(api_key), do: {:ok, api_key}, else: :miss
  end

  defp present_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp put_provider_options(%StreamOptions{} = opts, provider_key, values) do
    filtered_values = reject_nil_values(values)

    if map_size(filtered_values) == 0 do
      opts
    else
      %{opts | provider_options: Map.put(opts.provider_options, provider_key, filtered_values)}
    end
  end

  defp normalize_stream_options(nil, cwd), do: %StreamOptions{cwd: cwd, caller_headers: %{}}

  defp normalize_stream_options(%StreamOptions{} = opts, cwd) do
    caller_headers = opts.caller_headers || opts.headers || %{}

    %{
      opts
      | cwd: opts.cwd || cwd,
        headers: caller_headers,
        caller_headers: caller_headers,
        thinking_budgets: opts.thinking_budgets || %{},
        provider_options: opts.provider_options || %{}
    }
  end

  defp normalize_stream_options(opts, cwd) when is_map(opts) do
    opts
    |> Map.new(fn {key, value} ->
      {normalize_option_key(key), value}
    end)
    |> Map.put_new(:cwd, cwd)
    |> then(&struct(StreamOptions, &1))
    |> normalize_stream_options(cwd)
  end

  defp normalize_stream_options(_opts, cwd), do: %StreamOptions{cwd: cwd, caller_headers: %{}}

  defp stream_options_to_map(%StreamOptions{} = opts), do: Map.from_struct(opts)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_struct(struct, _key, nil), do: struct
  defp maybe_put_struct(struct, key, value), do: Map.put(struct, key, value)

  defp first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
  end

  defp normalize_option_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp normalize_option_key(key), do: key

  defp provider_config_lookup_key(%{api: :azure_openai_responses}), do: :azure_openai_responses
  defp provider_config_lookup_key(%{api: :bedrock_converse_stream}), do: :amazon_bedrock

  defp provider_config_lookup_key(%{provider: provider}),
    do: ProviderNames.provider_atom(provider) || provider

  defp provider_config_lookup_key(_), do: nil

  defp provider_config_value(nil, _key), do: nil

  defp provider_config_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
