defmodule LemonAgent.ModelRuntime.OmpAuthConfig do
  @moduledoc "Configuration and on-device readiness of the external authentication integration."
  @behaviour LemonCore.Config.Providers.AuthExtension

  alias LemonCore.Config.Providers
  alias LemonCore.Config.Validator
  alias LemonCore.Doctor.Check

  @fields [:omp_path, :omp_provider, :omp_account]
  @kimi_names ~w(kimi-coding kimi-for-coding)
  @gateway_names ~w(omp-gateway omp-auth-gateway)

  @impl true
  def settings(config) do
    Enum.reduce(@fields, %{}, fn key, fields ->
      case value(config, key) do
        value when value in [nil, ""] -> fields
        value -> Map.put(fields, key, value)
      end
    end)
  end

  @impl true
  def sources(provider) when provider in ["kimi_coding" | @kimi_names], do: ["omp", "omp_broker"]
  def sources(_provider), do: ["omp_broker"]

  @impl true
  def source?(source), do: source in ["omp", "omp_broker"]

  @impl true
  def public_provider?(name), do: name == "omp" or name in @gateway_names

  @impl true
  def external?(provider, config) do
    source = auth_source(config)
    name = normalize_provider(provider)

    source == "omp_broker" or (source == "omp" and name in @kimi_names) or
      name in @gateway_names
  end

  @impl true
  def validate(errors, name, config, prefix) do
    source = auth_source(config)
    provider = name |> to_string() |> String.trim() |> String.downcase()

    errors =
      if source == "omp" and
           provider not in ["openai-codex", "anthropic", "kimi_coding" | @kimi_names],
         do: ["#{prefix}.#{name}.auth_source: omp is only supported for kimi_coding" | errors],
         else: errors

    errors
    |> validate_path(name, config, prefix)
    |> validate_broker(name, config, prefix, source == "omp_broker")
  end

  defp validate_broker(errors, name, config, prefix, broker?) do
    Enum.reduce([:omp_provider, :omp_account], errors, fn field, acc ->
      path = "#{prefix}.#{name}.#{field}"

      case value(config, field) do
        nil ->
          acc

        value when is_binary(value) ->
          cond do
            String.trim(value) == "" -> ["#{path}: cannot be empty" | acc]
            not broker? -> [~s(#{path}: requires auth_source = "omp_broker") | acc]
            true -> acc
          end

        other ->
          ["#{path}: must be a string (got #{Validator.describe_type(other)})" | acc]
      end
    end)
  end

  defp validate_path(errors, name, config, prefix) do
    path = "#{prefix}.#{name}.omp_path"

    case value(config, :omp_path) do
      nil ->
        errors

      value when is_binary(value) ->
        if String.valid?(value) and not String.contains?(value, <<0>>) and
             Path.type(value) == :absolute and not String.ends_with?(value, "/") do
          errors
        else
          ["#{path}: must be an absolute executable path" | errors]
        end

      other ->
        ["#{path}: must be a string (got #{Validator.describe_type(other)})" | errors]
    end
  end

  @impl true
  def credential_check(provider, config, ready?) do
    source = auth_source(config)

    cond do
      source == "omp_broker" and ready? ->
        Check.pass(
          "providers.credentials",
          "omp_broker (reads omp's auth broker): credential usable."
        )

      source == "omp_broker" ->
        Check.fail(
          "providers.credentials",
          "omp's auth broker could not provide a usable credential.",
          "Check `omp auth-broker status`, OMP_AUTH_BROKER_URL/OMP_AUTH_BROKER_TOKEN, " <>
            "omp_provider/omp_account, and `omp auth-broker login <provider>`."
        )

      normalize_provider(provider) in @gateway_names and ready? ->
        Check.pass("providers.credentials", "omp auth gateway bearer is available.")

      normalize_provider(provider) in @gateway_names ->
        Check.fail(
          "providers.credentials",
          "No omp auth gateway bearer is available.",
          "Set OMP_AUTH_GATEWAY_TOKEN or providers.omp_gateway.api_key_secret, or run " <>
            "`omp auth-gateway token` on this host."
        )

      source == "omp" and ready? ->
        Check.pass(
          "providers.credentials",
          "omp (reuses omp's Kimi Code login): credentials usable."
        )

      source == "omp" ->
        Check.fail(
          "providers.credentials",
          "omp could not provide a usable Kimi Code token.",
          "Check providers.kimi_coding.omp_path; run `omp` and `/login kimi-code`."
        )

      true ->
        nil
    end
  end

  defp auth_source(config), do: config |> value(:auth_source) |> Providers.normalize_auth_source()

  defp normalize_provider(nil), do: nil

  defp normalize_provider(name),
    do: name |> to_string() |> String.trim() |> String.downcase() |> String.replace("_", "-")

  defp value(config, key), do: Map.get(config, key, Map.get(config, Atom.to_string(key)))
end
