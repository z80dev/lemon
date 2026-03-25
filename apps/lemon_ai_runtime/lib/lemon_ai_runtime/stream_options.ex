defmodule LemonAiRuntime.StreamOptions do
  @moduledoc """
  Lemon-owned `Ai.Types.StreamOptions` builder.

  This module normalizes caller-provided stream options and resolves provider-
  specific runtime inputs before `Ai.stream/3` or `Ai.complete/3` is invoked.
  """

  alias Ai.Types.StreamOptions
  alias LemonAiRuntime.Credentials
  alias LemonAiRuntime.ProviderNames
  alias LemonCore.ProviderConfigResolver

  @spec build_stream_options(
          Ai.Types.Model.t(),
          map() | nil,
          map() | StreamOptions.t() | nil,
          String.t() | nil
        ) ::
          StreamOptions.t()
  def build_stream_options(model, providers_map, existing_opts, cwd) do
    base_opts = normalize_stream_options(existing_opts, cwd)

    provider_cfg =
      ProviderNames.provider_config(providers_map, provider_config_lookup_key(model)) || %{}

    case model do
      %{provider: :google_vertex} ->
        resolved =
          ProviderConfigResolver.resolve_for_provider(
            :google_vertex,
            google_vertex_input(base_opts, provider_cfg)
          )

        base_opts
        |> maybe_put_struct(:project, resolved[:project])
        |> maybe_put_struct(:location, resolved[:location])
        |> maybe_put_struct(:service_account_json, resolved[:service_account_json])
        |> put_provider_options(:google_vertex, %{
          project: resolved[:project],
          location: resolved[:location],
          service_account_json: resolved[:service_account_json]
        })

      %{api: :azure_openai_responses} ->
        resolved =
          ProviderConfigResolver.resolve_for_provider(
            :azure_openai_responses,
            azure_input(base_opts, provider_cfg)
          )

        thinking_budgets =
          base_opts.thinking_budgets
          |> maybe_put(:azure_api_version, resolved[:api_version])
          |> maybe_put(:azure_base_url, resolved[:base_url])
          |> maybe_put(:azure_resource_name, resolved[:resource_name])
          |> maybe_put(:azure_deployment_name_map, resolved[:deployment_name_map])

        base_opts
        |> maybe_put_struct(:api_key, resolved[:api_key])
        |> Map.put(:thinking_budgets, thinking_budgets)
        |> put_provider_options(:azure_openai_responses, %{
          api_key: resolved[:api_key],
          base_url: resolved[:base_url],
          api_version: resolved[:api_version],
          resource_name: resolved[:resource_name],
          deployment_name_map: resolved[:deployment_name_map]
        })

      %{api: :bedrock_converse_stream} ->
        resolved =
          ProviderConfigResolver.resolve_for_provider(
            :bedrock_converse_stream,
            bedrock_input(base_opts, provider_cfg)
          )

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
          ProviderConfigResolver.resolve_for_provider(
            :google_gemini_cli,
            google_gemini_cli_input(base_opts, provider_cfg)
          )

        base_opts
        |> maybe_put_struct(:project, resolved[:project])
        |> put_provider_options(:google_gemini_cli, %{project: resolved[:project]})

      _ ->
        base_opts
    end
  end

  defp google_vertex_input(base_opts, provider_cfg) do
    stream_options_to_map(base_opts)
    |> maybe_put(
      :project,
      first_non_empty_binary([
        base_opts.project,
        provider_config_value(provider_cfg, :project),
        provider_config_value(provider_cfg, :project_id),
        Credentials.resolve_secret_api_key(provider_config_value(provider_cfg, :project_secret),
          env_fallback: true
        )
      ])
    )
    |> maybe_put(
      :location,
      first_non_empty_binary([
        base_opts.location,
        provider_config_value(provider_cfg, :location),
        Credentials.resolve_secret_api_key(provider_config_value(provider_cfg, :location_secret),
          env_fallback: true
        )
      ])
    )
    |> maybe_put(
      :service_account_json,
      first_non_empty_binary([
        base_opts.service_account_json,
        provider_config_value(provider_cfg, :service_account_json),
        Credentials.resolve_secret_api_key(
          provider_config_value(provider_cfg, :service_account_json_secret),
          env_fallback: true
        )
      ])
    )
    |> maybe_put(:api_key, provider_config_value(provider_cfg, :api_key))
  end

  defp azure_input(base_opts, provider_cfg) do
    thinking_budgets =
      base_opts.thinking_budgets
      |> maybe_put(
        :azure_base_url,
        provider_config_value(provider_cfg, :base_url)
      )
      |> maybe_put(
        :azure_resource_name,
        provider_config_value(provider_cfg, :resource_name)
      )
      |> maybe_put(
        :azure_api_version,
        provider_config_value(provider_cfg, :api_version)
      )
      |> maybe_put(
        :azure_deployment_name_map,
        provider_config_value(provider_cfg, :deployment_name_map)
      )

    stream_options_to_map(base_opts)
    |> Map.put(:thinking_budgets, thinking_budgets)
    |> maybe_put(
      :api_key,
      first_non_empty_binary([
        base_opts.api_key,
        Credentials.resolve_secret_api_key(provider_config_value(provider_cfg, :api_key_secret),
          env_fallback: true
        ),
        provider_config_value(provider_cfg, :api_key)
      ])
    )
  end

  defp bedrock_input(base_opts, provider_cfg) do
    headers =
      base_opts.headers
      |> maybe_put("aws_region", provider_config_value(provider_cfg, :region))
      |> maybe_put(
        "aws_access_key_id",
        Credentials.resolve_secret_api_key(
          provider_config_value(provider_cfg, :access_key_id_secret),
          env_fallback: true
        )
      )
      |> maybe_put(
        "aws_secret_access_key",
        Credentials.resolve_secret_api_key(
          provider_config_value(provider_cfg, :secret_access_key_secret),
          env_fallback: true
        )
      )
      |> maybe_put(
        "aws_session_token",
        Credentials.resolve_secret_api_key(
          provider_config_value(provider_cfg, :session_token_secret),
          env_fallback: true
        )
      )

    stream_options_to_map(base_opts)
    |> Map.put(:headers, headers)
  end

  defp google_gemini_cli_input(base_opts, provider_cfg) do
    stream_options_to_map(base_opts)
    |> maybe_put(:project, provider_config_value(provider_cfg, :project))
    |> maybe_put(:project_id, provider_config_value(provider_cfg, :project_id))
    |> maybe_put(:projectId, provider_config_value(provider_cfg, :projectId))
    |> maybe_put(:project_secret, provider_config_value(provider_cfg, :project_secret))
  end

  defp put_provider_options(%StreamOptions{} = opts, provider_key, values) do
    filtered_values = reject_nil_values(values)

    if map_size(filtered_values) == 0 do
      opts
    else
      %{opts | provider_options: Map.put(opts.provider_options, provider_key, filtered_values)}
    end
  end

  defp normalize_stream_options(nil, cwd), do: %StreamOptions{cwd: cwd}

  defp normalize_stream_options(%StreamOptions{} = opts, cwd) do
    %{
      opts
      | cwd: opts.cwd || cwd,
        headers: opts.headers || %{},
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

  defp normalize_stream_options(_opts, cwd), do: %StreamOptions{cwd: cwd}

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

  defp first_non_empty_binary(_), do: nil

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
  defp provider_config_lookup_key(%{provider: provider}), do: provider
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
