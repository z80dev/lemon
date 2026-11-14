defmodule LemonGateway.BindAddressTest do
  use ExUnit.Case, async: true

  alias LemonGateway.BindAddress
  alias LemonGateway.Transports.Webhook.Config

  test "loopback and wildcard aliases are shared by gateway listeners" do
    for value <- [nil, "", "  ", "127.0.0.1", "localhost", "invalid", 123] do
      assert BindAddress.parse(value) == :loopback
      assert Config.bind_ip(%{bind: value}) == :loopback
    end

    for value <- ["0.0.0.0", "any", " any "] do
      assert BindAddress.parse(value) == :any
      assert Config.bind_ip(%{bind: value}) == :any
    end
  end

  test "accepts both IPv4 and IPv6 addresses" do
    assert BindAddress.parse("192.0.2.1") == {192, 0, 2, 1}
    assert BindAddress.parse(" ::1 ") == {0, 0, 0, 0, 0, 0, 0, 1}
    assert Config.bind_ip(%{"bind" => "2001:db8::1"}) == {8193, 3512, 0, 0, 0, 0, 0, 1}
    assert BindAddress.parse("256.0.0.1") == :loopback
  end
end
