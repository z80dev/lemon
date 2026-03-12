defmodule LemonCore.ProviderConfigResolver do
  @moduledoc """
  Resolves provider configuration from canonical config + env + secrets.

  This module centralizes provider settings resolution so that provider
  implementations don't need to read env vars or secrets directly.

  Each provider function returns a map of resolved settings that can be
  merged into StreamOptions or used directly by the provider.
  """

  @doc """
  Resolve stream options for a given provider from canonical config.

  Returns a map of resolved settings. Keys with nil values are excluded.
  """
  @spec resolve_for_provider(atom(), map()) :: map()
  def resolve_for_provider(provider_id, opts \\ %{})

  def resolve_for_provider(:google_vertex, opts) do
    config = get_provider_config("google_vertex", opts)

    project =
      Map.get(opts, :project) ||
        resolve_secret(config[:project_secret]) ||
        System.get_env("GOOGLE_CLOUD_PROJECT") ||
        System.get_env("GCLOUD_PROJECT")

    location =
      Map.get(opts, :location) ||
        resolve_secret(config[:location_secret]) ||
        System.get_env("GOOGLE_CLOUD_LOCATION")

    service_account_json =
      Map.get(opts, :service_account_json) ||
        resolve_secret(config[:service_account_json_secret])

    %{
      project: project,
      location: location,
      service_account_json: service_account_json,
      api_key: config[:api_key]
    }
    |> reject_nil_values()
  end

  def resolve_for_provider(:google_gemini_cli, opts) do
    config = get_provider_config("google_gemini_cli", opts)

    project =
      first_non_empty_binary([
        Map.get(opts, :project),
        Map.get(opts, :project_id),
        Map.get(opts, "project_id"),
        Map.get(opts, :projectId),
        Map.get(opts, "projectId"),
        resolve_secret(Map.get(opts, :project_secret) || Map.get(opts, "project_secret")),
        config[:project],
        config[:project_id],
        resolve_secret(config[:project_secret]),
        System.get_env("LEMON_GEMINI_PROJECT_ID"),
        System.get_env("GOOGLE_CLOUD_PROJECT"),
        System.get_env("GOOGLE_CLOUD_PROJECT_ID"),
        System.get_env("GCLOUD_PROJECT")
      ])

    %{project: project}
    |> reject_nil_values()
  end

  def resolve_for_provider(:azure_openai_responses, opts) do
    config = get_provider_config("azure_openai_responses", opts)
    azure_opts = Map.get(opts, :thinking_budgets, %{})

    api_key =
      Map.get(opts, :api_key) ||
        resolve_secret(config[:api_key_secret]) ||
        config[:api_key] ||
        fetch_secret_value("AZURE_OPENAI_API_KEY")

    base_url =
      first_non_empty_binary([
        Map.get(azure_opts, :azure_base_url),
        config[:base_url],
        System.get_env("AZURE_OPENAI_BASE_URL")
      ])

    resource_name =
      first_non_empty_binary([
        Map.get(azure_opts, :azure_resource_name),
        config[:resource_name],
        System.get_env("AZURE_OPENAI_RESOURCE_NAME")
      ])

    api_version =
      first_non_empty_binary([
        Map.get(azure_opts, :azure_api_version),
        config[:api_version],
        System.get_env("AZURE_OPENAI_API_VERSION")
      ])

    deployment_name_map =
      Map.merge(
        parse_deployment_name_map(System.get_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")),
        Map.get(config, :deployment_name_map, %{})
      )
      |> Map.merge(Map.get(azure_opts, :azure_deployment_name_map, %{}))

    %{
      api_key: api_key,
      base_url: base_url,
      resource_name: resource_name,
      api_version: api_version,
      deployment_name_map: deployment_name_map
    }
    |> reject_nil_values()
  end

  def resolve_for_provider(:bedrock_converse_stream, opts) do
    config = get_provider_config("amazon_bedrock", opts)

    region =
      get_in_headers(opts, "aws_region") ||
        config[:region] ||
        System.get_env("AWS_REGION") ||
        System.get_env("AWS_DEFAULT_REGION") ||
        "us-east-1"

    access_key_id =
      get_in_headers(opts, "aws_access_key_id") ||
        resolve_secret(config[:access_key_id_secret]) ||
        fetch_secret_value("AWS_ACCESS_KEY_ID")

    secret_access_key =
      get_in_headers(opts, "aws_secret_access_key") ||
        resolve_secret(config[:secret_access_key_secret]) ||
        fetch_secret_value("AWS_SECRET_ACCESS_KEY")

    session_token =
      get_in_headers(opts, "aws_session_token") ||
        resolve_secret(config[:session_token_secret]) ||
        fetch_secret_value("AWS_SESSION_TOKEN")

    %{
      headers: %{
        "aws_region" => region,
        "aws_access_key_id" => access_key_id,
        "aws_secret_access_key" => secret_access_key,
        "aws_session_token" => session_token
      }
    }
    |> reject_nil_header_values()
  end

  def resolve_for_provider(_provider_id, _opts), do: %{}

  # ============================================================================
  # Internal helpers
  # ============================================================================

  defp get_provider_config(name, opts) do
    cwd = if is_map(opts), do: Map.get(opts, :cwd), else: nil
    config = LemonCore.Config.cached(cwd)
    Map.get(config.providers, name, %{})
  rescue
    _ -> %{}
  end

  defp resolve_secret(nil), do: nil

  defp resolve_secret(secret_name) when is_binary(secret_name) do
    if Code.ensure_loaded?(LemonCore.Secrets) and
         function_exported?(LemonCore.Secrets, :resolve, 2) do
      case LemonCore.Secrets.resolve(secret_name, env_fallback: true) do
        {:ok, value, _source} -> value
        _ -> nil
      end
    else
      System.get_env(secret_name)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp fetch_secret_value(name) do
    if Code.ensure_loaded?(LemonCore.Secrets) and
         function_exported?(LemonCore.Secrets, :fetch_value, 1) do
      LemonCore.Secrets.fetch_value(name)
    else
      System.get_env(name)
    end
  rescue
    _ -> System.get_env(name)
  catch
    :exit, _ -> System.get_env(name)
  end

  defp get_in_headers(%{headers: headers}, key) when is_map(headers) do
    Map.get(headers, key)
  end

  defp get_in_headers(_, _key), do: nil

  defp first_non_empty_binary(values) when is_list(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
  end

  defp parse_deployment_name_map(nil), do: %{}

  defp parse_deployment_name_map(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.reduce(%{}, fn entry, acc ->
      entry = String.trim(entry)

      case String.split(entry, "=", parts: 2) do
        [model_id, deployment_name] ->
          Map.put(acc, String.trim(model_id), String.trim(deployment_name))

        _ ->
          acc
      end
    end)
  end

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
  end

  defp reject_nil_header_values(%{headers: headers} = map) do
    cleaned_headers = headers |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    %{map | headers: cleaned_headers}
  end
end
