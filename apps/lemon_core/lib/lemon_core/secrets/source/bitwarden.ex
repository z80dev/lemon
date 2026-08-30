defmodule LemonCore.Secrets.Source.Bitwarden do
  @moduledoc false

  @behaviour LemonCore.Secrets.Source

  alias LemonCore.Config.Secrets.Source, as: SourceConfig
  alias LemonCore.Secrets.SourceRunner

  @name ~r/^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$/

  @impl true
  def configured?(%SourceConfig{project_id: project_id, access_token_secret: token_secret}) do
    is_binary(project_id) and project_id != "" and is_binary(token_secret) and token_secret != ""
  end

  @impl true
  def bootstrap_ready?(%SourceConfig{access_token_secret: secret}, opts) do
    LemonCore.Secrets.exists_local?(secret, opts)
  end

  @impl true
  def fetch(%SourceConfig{} = source, opts) do
    with {:ok, token, _source} <-
           LemonCore.Secrets.resolve_local(source.access_token_secret, opts),
         env <- bitwarden_env(source, token),
         executable <- source.executable || "bws",
         {:ok, result} <-
           SourceRunner.run(
             [executable, "secret", "list", source.project_id, "--output", "json"],
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
