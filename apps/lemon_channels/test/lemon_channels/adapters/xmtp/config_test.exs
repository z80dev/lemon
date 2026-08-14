defmodule LemonChannels.Adapters.Xmtp.ConfigTest do
  @moduledoc """
  The vendor half of the XMTP gateway-config contract.

  Resolution and validation of `[gateway.xmtp]` live here, byte-equivalent to
  the old `LemonCore.Config.Gateway` xmtp code (see
  `LemonChannels.Adapters.Xmtp.Config`). The generic mechanism that routes
  sections through registered channel modules is tested in
  `LemonCore.Config.GatewayTest` with a stub channel.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Xmtp.Config

  @env_vars ~w(XMTP_WALLET_KEY LEMON_GATEWAY_ENABLE_XMTP)

  setup do
    original = Map.new(@env_vars, fn key -> {key, System.get_env(key)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "resolve/1" do
    test "resolves wallet_key_secret and passes everything else through atomized" do
      resolved =
        Config.resolve(%{
          "wallet_key_secret" => "xmtp_wallet_key",
          "environment" => "production",
          "api_url" => "https://api.xmtp.network",
          "poll_interval_ms" => 1000
        })

      assert resolved.wallet_key_secret == "xmtp_wallet_key"
      assert resolved.environment == "production"
      assert resolved.api_url == "https://api.xmtp.network"
      assert resolved.poll_interval_ms == 1000
    end

    test "normalizes blank wallet_key_secret to nil and drops it" do
      resolved = Config.resolve(%{"wallet_key_secret" => "", "environment" => "dev"})
      refute Map.has_key?(resolved, :wallet_key_secret)
      assert resolved.environment == "dev"
    end

    test "uses the default section when absent" do
      assert Config.resolve(%{}) == %{}
      assert Config.resolve(nil) == %{}
    end
  end

  describe "enabled?/1" do
    test "honours the LEMON_GATEWAY_ENABLE_XMTP environment override" do
      assert Config.enabled?(false) == false

      System.put_env("LEMON_GATEWAY_ENABLE_XMTP", "true")
      assert Config.enabled?(false) == true
    end
  end

  describe "validate/2" do
    test "validates xmtp wallet_key" do
      valid_key = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
      assert Config.validate(%{wallet_key: valid_key}, []) == []

      assert Config.validate(%{wallet_key: "0x" <> valid_key}, []) == []

      for key <- ["a1b2c3d4", "g1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"] do
        errors = Config.validate(%{wallet_key: key}, [])
        assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.wallet_key"))
      end

      assert Config.validate(%{wallet_key: "${XMTP_WALLET_KEY}"}, []) == []
    end

    test "validates xmtp environment" do
      assert Config.validate(%{environment: "production"}, []) == []
      assert Config.validate(%{env: "production"}, []) == []
      assert Config.validate(%{environment: "dev"}, []) == []
      assert Config.validate(%{environment: "local"}, []) == []

      errors = Config.validate(%{environment: "invalid"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.environment"))

      errors = Config.validate(%{environment: 123}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.environment"))
    end

    test "validates xmtp wallet_address" do
      errors =
        Config.validate(%{wallet_address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"}, [])

      assert errors == []

      errors = Config.validate(%{wallet_address: "abcdef"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.wallet_address"))
    end

    test "validates xmtp api_url" do
      assert Config.validate(%{api_url: "https://api.xmtp.network"}, []) == []
      assert Config.validate(%{api_url: "http://localhost:5555"}, []) == []

      errors = Config.validate(%{api_url: "invalid-url"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.api_url"))

      errors = Config.validate(%{api_url: 123}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.api_url"))
    end

    test "validates xmtp max_connections" do
      assert Config.validate(%{max_connections: 10}, []) == []

      for value <- [0, -1, "not-an-integer"] do
        errors = Config.validate(%{max_connections: value}, [])
        assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.max_connections"))
      end
    end

    test "validates xmtp poll_interval_ms and connect_timeout_ms" do
      errors = Config.validate(%{poll_interval_ms: 1000, connect_timeout_ms: 5000}, [])
      assert errors == []

      errors = Config.validate(%{poll_interval_ms: 0}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.poll_interval_ms"))

      errors = Config.validate(%{connect_timeout_ms: -1}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.connect_timeout_ms"))
    end

    test "validates xmtp enable_relay, mock_mode and require_live booleans" do
      assert Config.validate(%{enable_relay: true, mock_mode: false, require_live: true}, []) ==
               []

      for field <- [:enable_relay, :mock_mode, :require_live] do
        errors = Config.validate(%{field => "yes"}, [])
        assert Enum.any?(errors, &String.contains?(&1, "gateway.xmtp.#{field}"))
      end
    end

    test "validates a complete xmtp config" do
      errors =
        Config.validate(
          %{
            wallet_key: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
            wallet_address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
            env: "production",
            api_url: "https://api.xmtp.network",
            poll_interval_ms: 1000,
            connect_timeout_ms: 5000,
            mock_mode: false,
            require_live: true,
            max_connections: 10,
            enable_relay: false
          },
          []
        )

      assert errors == []
    end

    test "rejects non-map sections" do
      assert Config.validate(nil, []) == ["gateway.xmtp: must be a map"]
    end
  end
end
