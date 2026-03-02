defmodule LemonGateway.Transports.Webhook.CallbackUrlTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Transports.Webhook.CallbackUrl

  defp public_dns, do: fn _host -> [] end

  describe "validate/3" do
    test "accepts nil callback URL" do
      assert {:ok, nil} = CallbackUrl.validate(nil, false)
    end

    test "accepts empty string callback URL" do
      assert {:ok, nil} = CallbackUrl.validate("", false)
    end

    test "accepts valid https URL" do
      assert {:ok, "https://example.test/callback"} =
               CallbackUrl.validate("https://example.test/callback", false,
                 dns_resolver: public_dns()
               )
    end

    test "accepts valid http URL" do
      assert {:ok, "http://example.test/callback"} =
               CallbackUrl.validate("http://example.test/callback", false,
                 dns_resolver: public_dns()
               )
    end

    test "canonicalizes hostname (lowercase and trailing dot)" do
      assert {:ok, "https://example.test/callback"} =
               CallbackUrl.validate("https://EXAMPLE.TEST./callback", false,
                 dns_resolver: public_dns()
               )
    end

    test "rejects non-HTTP schemes" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("ftp://example.test/callback", false,
                 dns_resolver: public_dns()
               )
    end

    test "rejects localhost" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("http://localhost/callback", false)
    end

    test "rejects localhost with trailing dot" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("http://localhost./callback", false)
    end

    test "rejects 127.0.0.1" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("http://127.0.0.1/callback", false)
    end

    test "rejects IPv6 loopback mapped to IPv4" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("http://[::ffff:127.0.0.1]/callback", false)
    end

    test "allows localhost when allow_private_hosts is true" do
      assert {:ok, _url} = CallbackUrl.validate("http://localhost/callback", true)
    end

    test "allows private IP when allow_private_hosts is true" do
      assert {:ok, "http://127.0.0.1/callback"} =
               CallbackUrl.validate("http://127.0.0.1/callback", true)
    end

    test "rejects host resolving to private IP via DNS" do
      private_dns = fn "internal.example" -> [{10, 1, 2, 3}]; _ -> [] end

      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("https://internal.example/callback", false,
                 dns_resolver: private_dns
               )
    end

    test "allows host resolving to private IP when allow_private_hosts is true" do
      private_dns = fn "internal.example" -> [{10, 1, 2, 3}]; _ -> [] end

      assert {:ok, "https://internal.example/callback"} =
               CallbackUrl.validate("https://internal.example/callback", true,
                 dns_resolver: private_dns
               )
    end

    test "rejects non-string input" do
      assert {:error, :invalid_callback_url} = CallbackUrl.validate(123, false)
    end

    test "rejects 10.x.x.x private range" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("http://10.0.0.1/callback", false)
    end

    test "rejects 192.168.x.x private range" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("http://192.168.1.1/callback", false)
    end

    test "rejects 172.16-31.x.x private range" do
      assert {:error, :invalid_callback_url} =
               CallbackUrl.validate("http://172.16.0.1/callback", false)
    end
  end
end
