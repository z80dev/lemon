defmodule MarketIntel.ConfigTest do
  use ExUnit.Case

  setup do
    original = Application.get_all_env(:market_intel)

    on_exit(fn ->
      # Clear all market_intel env and restore original
      for {key, _} <- Application.get_all_env(:market_intel),
          do: Application.delete_env(:market_intel, key)

      for {key, val} <- original,
          do: Application.put_env(:market_intel, key, val)
    end)

    :ok
  end

  describe "tracked_token/0 defaults" do
    test "returns keyword list with expected default keys" do
      Application.delete_env(:market_intel, :tracked_token)

      config = MarketIntel.Config.tracked_token()
      assert Keyword.get(config, :name) == "Tracked Token"
      assert Keyword.get(config, :symbol) == "TOKEN"
      assert Keyword.get(config, :address) == nil
      assert Keyword.get(config, :signal_key) == :tracked_token
      assert Keyword.get(config, :price_cache_key) == :tracked_token_price
    end
  end

  describe "tracked_token_symbol/0" do
    test "returns TOKEN by default" do
      Application.delete_env(:market_intel, :tracked_token)
      assert MarketIntel.Config.tracked_token_symbol() == "TOKEN"
    end

    test "returns configured symbol" do
      Application.put_env(:market_intel, :tracked_token, symbol: "LEMON")
      assert MarketIntel.Config.tracked_token_symbol() == "LEMON"
    end

    test "falls back to TOKEN for empty string" do
      Application.put_env(:market_intel, :tracked_token, symbol: "  ")
      assert MarketIntel.Config.tracked_token_symbol() == "TOKEN"
    end

    test "falls back to TOKEN for nil" do
      Application.put_env(:market_intel, :tracked_token, symbol: nil)
      assert MarketIntel.Config.tracked_token_symbol() == "TOKEN"
    end
  end

  describe "tracked_token_ticker/0" do
    test "prepends $ to the symbol" do
      Application.delete_env(:market_intel, :tracked_token)
      assert MarketIntel.Config.tracked_token_ticker() == "$TOKEN"
    end

    test "does not double the $ prefix" do
      Application.put_env(:market_intel, :tracked_token, symbol: "$LEMON")
      assert MarketIntel.Config.tracked_token_ticker() == "$LEMON"
    end
  end

  describe "x/0" do
    test "returns defaults when no app env set" do
      Application.delete_env(:market_intel, :x)
      Application.delete_env(:market_intel, :x_account_id)

      config = MarketIntel.Config.x()
      assert Keyword.keyword?(config)
      assert Keyword.has_key?(config, :account_id)
      assert Keyword.has_key?(config, :account_handle)
    end

    test "uses configured values" do
      Application.put_env(:market_intel, :x, account_handle: "testbot")

      config = MarketIntel.Config.x()
      assert Keyword.get(config, :account_handle) == "testbot"
    end
  end

  describe "x_account_handle backfill" do
    test "uses explicit account_handle when provided" do
      Application.put_env(:market_intel, :x, account_handle: "somename")

      assert MarketIntel.Config.x_account_handle() == "somename"
    end

    test "strips @ from explicit handle" do
      Application.put_env(:market_intel, :x, account_handle: "@somename")

      assert MarketIntel.Config.x_account_handle() == "somename"
    end

    test "strips @ from handle" do
      Application.put_env(:market_intel, :x, account_handle: "@mybot")

      assert MarketIntel.Config.x_account_handle() == "mybot"
    end
  end

  describe "commentary_persona/0" do
    test "returns defaults when no app env set" do
      Application.delete_env(:market_intel, :commentary_persona)
      Application.delete_env(:market_intel, :x)
      Application.delete_env(:market_intel, :x_account_id)

      config = MarketIntel.Config.commentary_persona()
      assert Keyword.get(config, :x_handle) == "@marketintel"
      assert is_binary(Keyword.get(config, :voice))
      assert is_binary(Keyword.get(config, :lemon_persona_instructions))
    end

    test "uses configured values" do
      Application.put_env(:market_intel, :commentary_persona, voice: "serious and analytical")

      config = MarketIntel.Config.commentary_persona()
      assert Keyword.get(config, :voice) == "serious and analytical"
    end
  end

  describe "eth_address/0" do
    test "returns default address" do
      Application.delete_env(:market_intel, :eth_address)
      assert MarketIntel.Config.eth_address() == "0x4200000000000000000000000000000000000006"
    end

    test "returns configured address" do
      Application.put_env(:market_intel, :eth_address, "0xCUSTOM")
      assert MarketIntel.Config.eth_address() == "0xCUSTOM"
    end
  end

  describe "tracked_token with map config" do
    test "handles map config (normalize_keyword)" do
      Application.put_env(:market_intel, :tracked_token, %{symbol: "MAP", name: "MapToken"})

      assert MarketIntel.Config.tracked_token_symbol() == "MAP"
      assert MarketIntel.Config.tracked_token_name() == "MapToken"
    end
  end

  describe "helper accessors" do
    test "tracked_token_price_cache_key returns default" do
      Application.delete_env(:market_intel, :tracked_token)
      assert MarketIntel.Config.tracked_token_price_cache_key() == :tracked_token_price
    end

    test "tracked_token_signal_key returns default" do
      Application.delete_env(:market_intel, :tracked_token)
      assert MarketIntel.Config.tracked_token_signal_key() == :tracked_token
    end

    test "commentary_handle returns default" do
      Application.delete_env(:market_intel, :commentary_persona)
      Application.delete_env(:market_intel, :x)
      Application.delete_env(:market_intel, :x_account_id)
      assert MarketIntel.Config.commentary_handle() == "@marketintel"
    end
  end
end
