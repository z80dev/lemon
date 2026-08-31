defmodule LemonCore.Secrets.Source.OnePassword do
  @moduledoc false

  @behaviour LemonCore.Secrets.Source

  alias LemonCore.Config.Secrets.Source, as: SourceConfig
  alias LemonCore.Secrets.SourceRunner

  @impl true
  def configured?(%SourceConfig{refs: refs}), do: is_map(refs) and map_size(refs) > 0

  @impl true
  def bootstrap_ready?(%SourceConfig{auth_secret: nil}, _opts), do: true

  def bootstrap_ready?(%SourceConfig{auth_secret: secret}, opts) do
    LemonCore.Secrets.exists_local?(secret, opts)
  end

  @impl true
  def fetch(%SourceConfig{} = source, opts) do
    with {:ok, env} <- auth_env(source, opts) do
      fetch_refs(source, env)
    end
  end

  defp fetch_refs(source, env) do
    executable = source.executable || "op"

    source.refs
    |> Enum.sort_by(fn {name, _ref} -> name end)
    |> Enum.reduce_while({:ok, %{values: %{}, byte_count: 0}}, fn {name, ref}, {:ok, acc} ->
      remaining = source.max_output_bytes - acc.byte_count

      if remaining <= 0 do
        {:halt, {:error, :output_too_large}}
      else
        argv =
          [executable, "read", "--no-newline"] ++
            account_args(source.account) ++ ["--", ref]

        case SourceRunner.run(argv,
               timeout_ms: source.timeout_ms,
               max_output_bytes: remaining,
               env: env
             ) do
          {:ok, %{output: value, byte_count: byte_count}}
          when byte_count > 0 and is_binary(value) ->
            if String.valid?(value) do
              {:cont,
               {:ok,
                %{
                  values: Map.put(acc.values, name, value),
                  byte_count: acc.byte_count + byte_count
                }}}
            else
              {:halt, {:error, :invalid_output}}
            end

          {:ok, _empty} ->
            {:halt, {:error, :invalid_output}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp account_args(nil), do: []
  defp account_args(account), do: ["--account", account]

  defp auth_env(%SourceConfig{auth_secret: nil, auth_env: env_name}, _opts) do
    {:ok, copy_system_env(env_name)}
  end

  defp auth_env(%SourceConfig{auth_secret: secret, auth_env: env_name}, opts) do
    case LemonCore.Secrets.resolve_local(secret, opts) do
      {:ok, value, _source} -> {:ok, %{env_name => value}}
      {:error, _reason} -> {:error, :bootstrap_secret_missing}
    end
  end

  defp copy_system_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> %{name => value}
      _ -> %{}
    end
  end
end
