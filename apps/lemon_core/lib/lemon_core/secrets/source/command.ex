defmodule LemonCore.Secrets.Source.Command do
  @moduledoc false

  @behaviour LemonCore.Secrets.Source

  alias LemonCore.Config.Secrets.Source, as: SourceConfig
  alias LemonCore.Secrets.SourceRunner

  @name ~r/^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$/

  @impl true
  def configured?(%SourceConfig{argv: [_program | _args]}), do: true
  def configured?(_source), do: false

  @impl true
  def bootstrap_ready?(%SourceConfig{secret_env: secret_env}, opts) do
    Enum.all?(secret_env, fn {_env_name, secret_name} ->
      LemonCore.Secrets.exists_local?(secret_name, opts)
    end)
  end

  @impl true
  def fetch(%SourceConfig{} = source, opts) do
    with {:ok, env} <- command_env(source, opts),
         {:ok, result} <-
           SourceRunner.run(source.argv,
             timeout_ms: source.timeout_ms,
             max_output_bytes: source.max_output_bytes,
             env: env
           ),
         {:ok, values} <- parse_values(result.output) do
      {:ok, %{values: values, byte_count: result.byte_count}}
    end
  end

  defp command_env(source, opts) do
    inherited =
      Enum.reduce(source.pass_env, %{}, fn name, acc ->
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> Map.put(acc, name, value)
          _ -> acc
        end
      end)

    Enum.reduce_while(source.secret_env, {:ok, inherited}, fn {env_name, secret_name},
                                                              {:ok, acc} ->
      case LemonCore.Secrets.resolve_local(secret_name, opts) do
        {:ok, value, _source} -> {:cont, {:ok, Map.put(acc, env_name, value)}}
        {:error, _reason} -> {:halt, {:error, :bootstrap_secret_missing}}
      end
    end)
  end

  defp parse_values(output) when is_binary(output) do
    if String.valid?(output) do
      output
      |> String.split(~r/\r?\n/, trim: false)
      |> Enum.reduce_while({:ok, %{}}, &parse_line/2)
      |> case do
        {:ok, values} when map_size(values) > 0 -> {:ok, values}
        _ -> {:error, :invalid_output}
      end
    else
      {:error, :invalid_output}
    end
  end

  defp parse_line(line, {:ok, acc}) do
    cond do
      line == "" ->
        {:cont, {:ok, acc}}

      String.starts_with?(line, "#") ->
        {:cont, {:ok, acc}}

      true ->
        case String.split(line, "=", parts: 2) do
          [name, value] when value != "" ->
            cond do
              not Regex.match?(@name, name) -> {:halt, {:error, :invalid_output}}
              Map.has_key?(acc, name) -> {:halt, {:error, :invalid_output}}
              true -> {:cont, {:ok, Map.put(acc, name, value)}}
            end

          _ ->
            {:halt, {:error, :invalid_output}}
        end
    end
  end
end
