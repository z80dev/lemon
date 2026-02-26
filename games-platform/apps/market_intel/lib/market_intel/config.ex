defmodule MarketIntel.Config do
  @moduledoc false

  @tracked_token_defaults [
    name: "Tracked Token",
    symbol: "TOKEN",
    address: nil,
    signal_key: :tracked_token,
    price_cache_key: :tracked_token_price,
    transfers_cache_key: :tracked_token_transfers,
    large_transfers_cache_key: :tracked_token_large_transfers,
    price_change_signal_threshold_pct: 10,
    large_transfer_threshold_base_units: 1_000_000_000_000_000_000_000_000
  ]

  @x_defaults [
    account_id: nil,
    account_handle: nil
  ]

  @commentary_persona_defaults [
    x_handle: "@marketintel",
    voice: "witty, technical, crypto-native, occasionally self-deprecating",
    lemon_persona_instructions:
      "Write in a playful Lemon house style. Use metaphors sparingly and keep it natural.",
    developer_alias: nil
  ]

  @eth_default_address "0x4200000000000000000000000000000000000006"

  def tracked_token do
    config =
      :market_intel
      |> Application.get_env(:tracked_token, [])
      |> normalize_keyword()

    Keyword.merge(@tracked_token_defaults, config)
  end

  def tracked_token_name, do: tracked_token()[:name]

  def tracked_token_symbol do
    tracked_token()
    |> Keyword.get(:symbol)
    |> normalize_symbol("TOKEN")
  end

  def tracked_token_ticker do
    "$" <> String.trim_leading(tracked_token_symbol(), "$")
  end

  def tracked_token_address, do: tracked_token()[:address]
  def tracked_token_signal_key, do: tracked_token()[:signal_key]
  def tracked_token_price_cache_key, do: tracked_token()[:price_cache_key]
  def tracked_token_transfers_cache_key, do: tracked_token()[:transfers_cache_key]
  def tracked_token_large_transfers_cache_key, do: tracked_token()[:large_transfers_cache_key]

  def tracked_token_price_change_signal_threshold_pct do
    tracked_token()[:price_change_signal_threshold_pct]
  end

  def tracked_token_large_transfer_threshold_base_units do
    tracked_token()[:large_transfer_threshold_base_units]
  end

  def x do
    config =
      :market_intel
      |> Application.get_env(:x, [])
      |> normalize_keyword()

    @x_defaults
    |> Keyword.merge(config)
    |> maybe_backfill_legacy_x_account_id()
    |> maybe_backfill_x_account_handle()
  end

  def x_account_id, do: x()[:account_id]
  def x_account_handle, do: x()[:account_handle]

  def commentary_persona do
    config =
      :market_intel
      |> Application.get_env(:commentary_persona, [])
      |> normalize_keyword()

    @commentary_persona_defaults
    |> Keyword.merge(config)
    |> maybe_backfill_commentary_handle()
  end

  def commentary_handle, do: commentary_persona()[:x_handle]
  def commentary_voice, do: commentary_persona()[:voice]

  def commentary_lemon_persona_instructions do
    commentary_persona()[:lemon_persona_instructions]
  end

  def commentary_developer_alias, do: commentary_persona()[:developer_alias]

  def eth_address do
    Application.get_env(:market_intel, :eth_address, @eth_default_address)
  end

  # Legacy backfill: reads a flat :x_account_id key that predates the nested
  # :x config structure.  No config file sets this key any more, so the
  # backfill is effectively a no-op.  Kept for defensive compatibility —
  # safe to remove once all environments have migrated (tracked in
  # PLN-20260222-debt-phase-10-monolith-footprint-reduction, M1).
  defp maybe_backfill_legacy_x_account_id(config) do
    case config[:account_id] do
      nil -> Keyword.put(config, :account_id, Application.get_env(:market_intel, :x_account_id))
      "" -> Keyword.put(config, :account_id, Application.get_env(:market_intel, :x_account_id))
      _ -> config
    end
  end

  defp maybe_backfill_x_account_handle(config) do
    case normalize_account_handle(config[:account_handle]) do
      nil ->
        case normalize_account_handle(config[:account_id]) do
          nil -> config
          handle -> Keyword.put(config, :account_handle, handle)
        end

      handle ->
        Keyword.put(config, :account_handle, handle)
    end
  end

  defp maybe_backfill_commentary_handle(config) do
    case normalize_optional_string(config[:x_handle]) do
      nil ->
        case x_account_handle() do
          nil -> config
          handle -> Keyword.put(config, :x_handle, "@#{handle}")
        end

      handle ->
        Keyword.put(config, :x_handle, handle)
    end
  end

  defp normalize_symbol(nil, fallback), do: fallback

  defp normalize_symbol(symbol, fallback) do
    case symbol |> to_string() |> String.trim() do
      "" -> fallback
      value -> value
    end
  end

  defp normalize_account_handle(value) do
    value
    |> normalize_optional_string()
    |> case do
      nil -> nil
      account -> if(numeric_id?(account), do: nil, else: String.trim_leading(account, "@"))
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_optional_string()
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value
    |> to_string()
    |> normalize_optional_string()
  rescue
    _ -> nil
  end

  defp normalize_keyword(config) when is_list(config), do: config
  defp normalize_keyword(config) when is_map(config), do: Enum.into(config, [])
  defp normalize_keyword(_), do: []

  defp numeric_id?(value) when is_binary(value), do: Regex.match?(~r/^\d+$/, value)
end
