defmodule LemonAgent.Secrets.Source.OnePassword do
  @moduledoc false

  @behaviour LemonCore.Secrets.Source

  import LemonCore.Config.Secrets,
    only: [
      contains_control?: 1,
      optional_string: 1,
      string_map: 1,
      validate_env_name: 3,
      validate_names: 3,
      validate_non_empty_map: 3,
      validate_optional_string_field: 4,
      validate_safe_name: 3,
      validate_string_map_field: 4
    ]

  alias LemonCore.Config.Secrets.Source, as: SourceConfig
  alias LemonCore.Secrets.SourceRunner

  @impl true
  def config_keys, do: ~w(refs account auth_secret auth_env)

  @impl true
  def options(raw) do
    %{
      refs: string_map(raw["refs"]),
      account: optional_string(raw["account"]),
      auth_secret: optional_string(raw["auth_secret"]),
      auth_env: optional_string(raw["auth_env"]) || "OP_SERVICE_ACCOUNT_TOKEN"
    }
  end

  @impl true
  def validate(errors, config, raw, path) do
    errors
    |> validate_string_map_field(raw, "refs", path)
    |> validate_non_empty_map(config.refs, "#{path}.refs")
    |> validate_names(config.refs, "#{path}.refs")
    |> validate_refs(config.refs, "#{path}.refs")
    |> validate_optional_string_field(raw, "account", path)
    |> validate_safe_name(config.auth_secret, "#{path}.auth_secret")
    |> validate_env_name(config.auth_env, "#{path}.auth_env")
  end

  defp validate_refs(errors, refs, path) do
    Enum.reduce(refs, errors, fn {_name, ref}, acc ->
      if String.starts_with?(ref, "op://") and byte_size(ref) <= 4_096 and
           not contains_control?(ref) do
        acc
      else
        acc ++ ["#{path}: every reference must be a bounded op:// reference"]
      end
    end)
  end

  @impl true
  def executable(source), do: source.executable || "op"

  @impl true
  def scope(%SourceConfig{options: %{refs: refs} = settings} = source, name) do
    case Map.fetch(refs, name) do
      {:ok, ref} -> %{source | options: %{settings | refs: %{name => ref}}}
      :error -> nil
    end
  end

  @impl true
  def runs(%SourceConfig{options: %{refs: refs}}), do: max(map_size(refs), 1)

  @impl true
  def configured?(%SourceConfig{options: %{refs: refs}}), do: is_map(refs) and map_size(refs) > 0
  def configured?(_source), do: false

  @impl true
  def bootstrap_ready?(%SourceConfig{options: %{auth_secret: nil}}, _bootstrap), do: true

  def bootstrap_ready?(%SourceConfig{options: %{auth_secret: secret}}, bootstrap),
    do: match?({:ok, _, _}, bootstrap.(secret))

  def bootstrap_ready?(_source, _bootstrap), do: false

  @impl true
  def fetch(%SourceConfig{options: settings} = source, bootstrap) do
    with {:ok, env} <- auth_env(settings, bootstrap) do
      fetch_refs(source, settings, env)
    end
  end

  defp fetch_refs(source, settings, env) do
    executable = executable(source)

    settings.refs
    |> Enum.sort_by(fn {name, _ref} -> name end)
    |> Enum.reduce_while({:ok, %{values: %{}, byte_count: 0}}, fn {name, ref}, {:ok, acc} ->
      remaining = source.max_output_bytes - acc.byte_count

      if remaining <= 0 do
        {:halt, {:error, :output_too_large}}
      else
        argv =
          [executable, "read", "--no-newline"] ++
            account_args(settings.account) ++ ["--", ref]

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

  defp auth_env(%{auth_secret: nil, auth_env: env_name}, _bootstrap) do
    {:ok, copy_system_env(env_name)}
  end

  defp auth_env(%{auth_secret: secret, auth_env: env_name}, bootstrap) do
    case bootstrap.(secret) do
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
