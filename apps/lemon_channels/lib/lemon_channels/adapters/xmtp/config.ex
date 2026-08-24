defmodule LemonChannels.Adapters.Xmtp.Config do
  @moduledoc """
  Resolution and validation of the `[gateway.xmtp]` config section.

  Registered under `config :lemon_core, :gateway_channels`, so
  `LemonCore.Config.Gateway` never names XMTP: this module owns the section,
  the `enable_xmtp` flag, the `LEMON_GATEWAY_ENABLE_XMTP` variable declared in
  `LemonChannels.Env`, and the section's validation rules. See
  `LemonCore.Config.Gateway.Channel`.

  Only `wallet_key_secret` is normalized; everything else passes through
  atomized so the bridge keeps seeing the keys it reads.
  """

  @behaviour LemonCore.Config.Gateway.Channel

  import LemonChannels.Adapters.ConfigHelpers

  alias LemonCore.Config.Validator
  alias LemonCore.Env

  @valid_environments ["production", "dev", "local"]

  @impl LemonCore.Config.Gateway.Channel
  def id, do: :xmtp

  @impl LemonCore.Config.Gateway.Channel
  def enabled?(configured) do
    Env.get(:lemon_gateway_enable_xmtp, default: configured)
  end

  @impl LemonCore.Config.Gateway.Channel
  def resolve(section) when is_map(section) do
    base = %{wallet_key_secret: blank_to_nil(section["wallet_key_secret"])}

    section
    |> Enum.reduce(base, fn {key, value}, acc ->
      atom_key = safe_to_atom(key)

      if Map.has_key?(acc, atom_key), do: acc, else: Map.put(acc, atom_key, value)
    end)
    |> reject_nils()
  end

  def resolve(_section), do: resolve(%{})

  @impl LemonCore.Config.Gateway.Channel
  def validate(section, errors) when is_map(section) do
    environment = Map.get(section, :env) || Map.get(section, :environment)

    errors
    |> validate_wallet_key(Map.get(section, :wallet_key))
    |> validate_wallet_address(Map.get(section, :wallet_address))
    |> validate_environment(environment)
    |> validate_api_url(Map.get(section, :api_url))
    |> Validator.validate_positive_integer(
      Map.get(section, :poll_interval_ms),
      "gateway.xmtp.poll_interval_ms"
    )
    |> Validator.validate_positive_integer(
      Map.get(section, :connect_timeout_ms),
      "gateway.xmtp.connect_timeout_ms"
    )
    |> Validator.validate_boolean(Map.get(section, :mock_mode), "gateway.xmtp.mock_mode")
    |> Validator.validate_boolean(Map.get(section, :require_live), "gateway.xmtp.require_live")
    |> Validator.validate_positive_integer(
      Map.get(section, :max_connections),
      "gateway.xmtp.max_connections"
    )
    |> Validator.validate_boolean(Map.get(section, :enable_relay), "gateway.xmtp.enable_relay")
  end

  def validate(_section, errors), do: ["gateway.xmtp: must be a map" | errors]

  defp validate_wallet_key(errors, nil), do: errors

  defp validate_wallet_key(errors, key) when is_binary(key) do
    cond do
      Validator.env_var_reference?(key) ->
        errors

      key |> String.replace_prefix("0x", "") |> then(&Regex.match?(~r/^[0-9a-fA-F]{64}$/, &1)) ->
        errors

      true ->
        [
          "gateway.xmtp.wallet_key: invalid format (expected 64-character hex string, optionally with 0x prefix)"
          | errors
        ]
    end
  end

  defp validate_wallet_key(errors, _key),
    do: ["gateway.xmtp.wallet_key: must be a string" | errors]

  defp validate_wallet_address(errors, nil), do: errors

  defp validate_wallet_address(errors, address) when is_binary(address) do
    cond do
      Validator.env_var_reference?(address) ->
        errors

      address
      |> String.trim()
      |> String.downcase()
      |> String.trim_leading("0x")
      |> then(&Regex.match?(~r/^[0-9a-f]{40}$/, &1)) ->
        errors

      true ->
        [
          "gateway.xmtp.wallet_address: invalid format (expected 40-character hex Ethereum address)"
          | errors
        ]
    end
  end

  defp validate_wallet_address(errors, _address),
    do: ["gateway.xmtp.wallet_address: must be a string" | errors]

  defp validate_environment(errors, nil), do: errors

  defp validate_environment(errors, env) when is_binary(env) do
    if env in @valid_environments do
      errors
    else
      [
        "gateway.xmtp.environment: invalid environment '#{env}'. Valid: #{Enum.join(@valid_environments, ", ")}"
        | errors
      ]
    end
  end

  defp validate_environment(errors, _env),
    do: ["gateway.xmtp.environment: must be a string" | errors]

  defp validate_api_url(errors, nil), do: errors

  defp validate_api_url(errors, url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      errors
    else
      ["gateway.xmtp.api_url: must start with http:// or https://" | errors]
    end
  end

  defp validate_api_url(errors, _url), do: ["gateway.xmtp.api_url: must be a string" | errors]
end
