defmodule LemonAgent.Secrets.Source.Bitwarden do
  @moduledoc false

  @behaviour LemonCore.Secrets.Source

  import LemonCore.Config.Secrets,
    only: [
      optional_string: 1,
      validate_optional_string_field: 4,
      validate_safe_name: 3,
      validate_env_name: 3
    ]

  alias LemonCore.Config.Secrets.Source, as: SourceConfig
  alias LemonCore.Secrets.SourceRunner

  @name ~r/^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$/
  @project_id ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/

  @impl true
  def config_keys, do: ~w(project_id access_token_secret access_token_env server_url)

  @impl true
  def options(raw) do
    %{
      project_id: optional_string(raw["project_id"]),
      access_token_secret: optional_string(raw["access_token_secret"]) || "BWS_ACCESS_TOKEN",
      access_token_env: optional_string(raw["access_token_env"]) || "BWS_ACCESS_TOKEN",
      server_url: optional_string(raw["server_url"])
    }
  end

  @impl true
  def validate(errors, config, raw, path) do
    errors
    |> validate_optional_string_field(raw, "server_url", path)
    |> validate_project_id(config.project_id, "#{path}.project_id")
    |> validate_safe_name(config.access_token_secret, "#{path}.access_token_secret")
    |> validate_env_name(config.access_token_env, "#{path}.access_token_env")
    |> validate_server_url(config.server_url, "#{path}.server_url")
  end

  defp validate_project_id(errors, value, path) do
    if is_binary(value) and Regex.match?(@project_id, value),
      do: errors,
      else: errors ++ ["#{path}: must be a non-option project id"]
  end

  defp validate_server_url(errors, nil, _path), do: errors

  defp validate_server_url(errors, value, path) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        errors

      _ ->
        errors ++ ["#{path}: must be an HTTPS URL without credentials, query, or fragment"]
    end
  end

  @impl true
  def executable(source), do: source.executable || "bws"

  @impl true
  def configured?(%SourceConfig{
        options: %{project_id: project_id, access_token_secret: token_secret}
      }) do
    is_binary(project_id) and project_id != "" and is_binary(token_secret) and token_secret != ""
  end

  def configured?(_source), do: false

  @impl true
  def bootstrap_ready?(%SourceConfig{options: %{access_token_secret: secret}}, bootstrap),
    do: match?({:ok, _, _}, bootstrap.(secret))

  def bootstrap_ready?(_source, _bootstrap), do: false

  @impl true
  def fetch(%SourceConfig{options: settings} = source, bootstrap) do
    with {:ok, token, _source} <- bootstrap.(settings.access_token_secret),
         env <- bitwarden_env(settings, token),
         {:ok, result} <-
           SourceRunner.run(
             [executable(source), "secret", "list", settings.project_id, "--output", "json"],
             timeout_ms: source.timeout_ms,
             max_output_bytes: source.max_output_bytes,
             env: env
           ),
         {:ok, values} <- decode_values(result.output) do
      {:ok, %{values: values, byte_count: result.byte_count}}
    else
      {:error, :not_found} -> {:error, :bootstrap_secret_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bitwarden_env(source, token) do
    %{source.access_token_env => token}
    |> maybe_put("BWS_SERVER_URL", source.server_url)
  end

  defp decode_values(output) when is_binary(output) do
    with true <- String.valid?(output),
         {:ok, values} when is_list(values) <- Jason.decode(output) do
      reduce_values(values)
    else
      _ -> {:error, :invalid_output}
    end
  end

  defp reduce_values(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn item, {:ok, acc} ->
      case item do
        %{"key" => key, "value" => value}
        when is_binary(key) and is_binary(value) and value != "" ->
          cond do
            not Regex.match?(@name, key) -> {:halt, {:error, :invalid_output}}
            Map.has_key?(acc, key) -> {:halt, {:error, :invalid_output}}
            true -> {:cont, {:ok, Map.put(acc, key, value)}}
          end

        _ ->
          {:halt, {:error, :invalid_output}}
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
