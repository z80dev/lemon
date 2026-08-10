defmodule LemonChannels.Adapters.Email.Config do
  @moduledoc """
  Configuration for the email adapter, from two sources.

    * `config :lemon_channels, LemonChannels.Adapters.Email, ...` — the
      channels-native surface, and the one to document for new deployments.
    * the canonical TOML `[gateway]` config's `email` block, read through
      `LemonChannels.GatewayConfig`.

  The TOML source exists because email was configured there for as long as it
  lived in `lemon_gateway`. Keeping it readable means an existing deployment's
  relay credentials, sender address and webhook token survive the cutover
  without anyone editing a config file. Application env wins on conflict, so a
  channels-native setting is always the last word.

  Lookups accept a key or a path (`[:outbound, :relay]`) and try the atom key
  before its string form, since TOML-derived maps are not consistently keyed.
  `first_defined/2` walks a list of those in priority order — the nested
  `outbound`/`inbound` sub-map before the flat alias — which is the resolution
  order `LemonGateway.Transports.Email.Outbound` used and its characterization
  tests pin.
  """

  @app_key LemonChannels.Adapters.Email

  @doc """
  The merged configuration map.

  Never raises: an unreachable or malformed source contributes nothing rather
  than failing the send, because the caller is usually mid-delivery and a
  missing relay is already reported precisely by `Outbound.smtp_options/1`.
  """
  @spec get() :: map()
  def get do
    Map.merge(gateway_email(), app_env(), fn
      _key, %{} = from_toml, %{} = from_app -> Map.merge(from_toml, from_app)
      _key, _from_toml, from_app -> from_app
    end)
  rescue
    _ -> %{}
  end

  @doc """
  Reads `key` — an atom or a path of atoms — from a config map.

  Returns `nil` when any segment is missing or a non-final segment is not a map.
  """
  @spec fetch(map(), atom() | [atom()]) :: term()
  def fetch(cfg, [head | tail]) when is_map(cfg) do
    value = fetch_key(cfg, head)

    case tail do
      [] -> value
      _ when is_map(value) -> fetch(value, tail)
      _ -> nil
    end
  end

  def fetch(cfg, key) when is_map(cfg), do: fetch_key(cfg, key)
  def fetch(_cfg, _key), do: nil

  @doc """
  The first of `keys` that resolves to a non-nil value.

  `false` counts as defined; only `nil` moves on to the next key.
  """
  @spec first_defined(map(), [atom() | [atom()]]) :: term()
  def first_defined(cfg, keys) when is_map(cfg) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case fetch(cfg, key) do
        nil -> nil
        value -> {:value, value}
      end
    end)
    |> case do
      {:value, value} -> value
      _ -> nil
    end
  end

  def first_defined(_cfg, _keys), do: nil

  @doc """
  The shared token the inbound webhook requires, or `nil` when none is set.

  `nil` means the endpoint rejects everything — see
  `LemonChannels.Adapters.Email.Webhook`.
  """
  @spec webhook_token() :: binary() | nil
  def webhook_token do
    get()
    |> first_defined([[:inbound, :token], :webhook_token])
    |> case do
      value when is_binary(value) -> blank_to_nil(value)
      _ -> nil
    end
  end

  @doc "Trims a binary and maps the empty result to `nil`; anything else to `nil`."
  @spec blank_to_nil(term()) :: binary() | nil
  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_value), do: nil

  defp app_env do
    :lemon_channels
    |> Application.get_env(@app_key, [])
    |> to_map()
  end

  defp gateway_email do
    LemonChannels.GatewayConfig.get(:email, %{}) |> to_map()
  end

  defp to_map(value) when is_map(value), do: value
  defp to_map(value) when is_list(value), do: Enum.into(value, %{})
  defp to_map(_value), do: %{}

  defp fetch_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end
