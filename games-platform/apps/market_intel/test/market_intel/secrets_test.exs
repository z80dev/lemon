defmodule MarketIntel.SecretsTest do
  use ExUnit.Case

  @env_var "MARKET_INTEL_BASESCAN_KEY"

  setup do
    # Disable secrets store so we only test env fallback
    original = Application.get_all_env(:market_intel)
    Application.put_env(:market_intel, :use_secrets, false)

    # Clean up any env var we might set
    original_env = System.get_env(@env_var)

    on_exit(fn ->
      Application.delete_env(:market_intel, :use_secrets)

      # Restore original app env
      for {key, _} <- Application.get_all_env(:market_intel),
          do: Application.delete_env(:market_intel, key)

      for {key, val} <- original,
          do: Application.put_env(:market_intel, key, val)

      # Restore or delete env var
      if original_env do
        System.put_env(@env_var, original_env)
      else
        System.delete_env(@env_var)
      end

      # Clean up any other env vars we may have set
      System.delete_env("MARKET_INTEL_OPENAI_KEY")
      System.delete_env("MARKET_INTEL_DEXSCREENER_KEY")
    end)

    :ok
  end

  describe "get/1" do
    test "returns {:error, :unknown_secret} for unrecognized name" do
      assert {:error, :unknown_secret} = MarketIntel.Secrets.get(:nonexistent_secret)
    end

    test "returns {:error, :not_in_env} when env var is not set" do
      System.delete_env(@env_var)
      assert {:error, _reason} = MarketIntel.Secrets.get(:basescan_key)
    end

    test "returns {:ok, value} when env var is set" do
      System.put_env(@env_var, "test_api_key_123")
      assert {:ok, "test_api_key_123"} = MarketIntel.Secrets.get(:basescan_key)
    end

    test "returns error for empty env var" do
      System.put_env(@env_var, "")
      assert {:error, :empty_in_env} = MarketIntel.Secrets.get(:basescan_key)
    end
  end

  describe "get!/1" do
    test "returns value when secret is available" do
      System.put_env(@env_var, "my_key")
      assert "my_key" = MarketIntel.Secrets.get!(:basescan_key)
    end

    test "raises when secret is not available" do
      System.delete_env(@env_var)

      assert_raise RuntimeError, ~r/Failed to get secret basescan_key/, fn ->
        MarketIntel.Secrets.get!(:basescan_key)
      end
    end

    test "raises for unknown secret name" do
      assert_raise RuntimeError, ~r/Failed to get secret/, fn ->
        MarketIntel.Secrets.get!(:totally_unknown)
      end
    end
  end

  describe "configured?/1" do
    test "returns false when env var is not set" do
      System.delete_env(@env_var)
      refute MarketIntel.Secrets.configured?(:basescan_key)
    end

    test "returns true when env var is set with a value" do
      System.put_env(@env_var, "configured_value")
      assert MarketIntel.Secrets.configured?(:basescan_key)
    end

    test "returns false for empty env var" do
      System.put_env(@env_var, "")
      refute MarketIntel.Secrets.configured?(:basescan_key)
    end

    test "returns false for unknown secret name" do
      refute MarketIntel.Secrets.configured?(:unknown_name)
    end
  end

  describe "all_configured/0" do
    test "returns a map" do
      result = MarketIntel.Secrets.all_configured()
      assert is_map(result)
    end

    test "includes configured secrets with masked values" do
      System.put_env(@env_var, "abcdefghijklmnop")
      result = MarketIntel.Secrets.all_configured()

      assert Map.has_key?(result, :basescan_key)
      # Value should be masked (not the raw key)
      masked = result[:basescan_key]
      assert is_binary(masked)
      refute masked == "abcdefghijklmnop"
    end

    test "does not include unconfigured secrets" do
      System.delete_env(@env_var)
      System.delete_env("MARKET_INTEL_OPENAI_KEY")
      result = MarketIntel.Secrets.all_configured()

      refute Map.has_key?(result, :basescan_key)
      refute Map.has_key?(result, :openai_key)
    end
  end

  describe "put/2" do
    test "returns {:error, :unknown_secret} for unrecognized name" do
      assert {:error, :unknown_secret} = MarketIntel.Secrets.put(:nonexistent, "value")
    end

    test "returns {:error, :secrets_disabled} when secrets store is disabled" do
      # use_secrets is already set to false in setup
      assert {:error, :secrets_disabled} = MarketIntel.Secrets.put(:basescan_key, "new_value")
    end
  end

  describe "mask behavior via all_configured/0" do
    test "short secrets are fully masked" do
      System.put_env(@env_var, "short")
      result = MarketIntel.Secrets.all_configured()

      # Strings <= 8 chars get "***"
      assert result[:basescan_key] == "***"
    end

    test "long secrets show prefix and suffix" do
      System.put_env(@env_var, "abcdefghijklmnop")
      result = MarketIntel.Secrets.all_configured()

      masked = result[:basescan_key]
      # Should be "abcd...mnop"
      assert String.starts_with?(masked, "abcd")
      assert String.ends_with?(masked, "mnop")
      assert String.contains?(masked, "...")
    end
  end
end
