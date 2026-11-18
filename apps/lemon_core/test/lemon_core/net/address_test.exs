defmodule LemonCore.Net.AddressTest do
  use ExUnit.Case, async: true

  alias LemonCore.Net.Address

  @public_v4 {93, 184, 216, 34}
  @public_v6 {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

  defp classify_literal(host) do
    {:ok, address} = Address.parse_literal(host)
    Address.classify(address)
  end

  test "metadata aliases are metadata in every literal form" do
    for host <- [
          "169.254.169.254",
          "2852039166",
          "0xA9FEA9FE",
          "0xa9.0xfe.0xa9.0xfe",
          "0251.0376.0251.0376",
          "169.254.43518",
          "[::ffff:169.254.169.254]",
          "::ffff:a9fe:a9fe",
          "64:ff9b::169.254.169.254",
          "::169.254.169.254",
          "2002:a9fe:a9fe::",
          "100.100.100.200",
          "fd00:ec2::254",
          "fe80::1"
        ] do
      assert classify_literal(host) == :metadata, host
    end
  end

  test "non-global ranges are private, including all of 6to4" do
    for host <- [
          "127.0.0.1",
          "2130706433",
          "0x7f000001",
          "10.0.0.1",
          "0x7f.0x0.0x0.0x1",
          "0177.1",
          "172.16.0.1",
          "192.168.1.1",
          "100.64.0.1",
          "0.0.0.0",
          "192.0.0.1",
          "192.0.2.1",
          "198.18.0.1",
          "198.51.100.1",
          "203.0.113.1",
          "224.0.0.1",
          "255.255.255.255",
          "::",
          "::1",
          "::ffff:127.0.0.1",
          "64:ff9b::10.0.0.1",
          "fc00::1",
          "fec0::1",
          "ff02::1",
          "2001:db8::1",
          "2001::1",
          "2002:0808:0808::1",
          "2002:7f00:1::"
        ] do
      assert classify_literal(host) == :private, host
    end
  end

  test "allocated global unicast is public" do
    assert Address.classify(@public_v4) == :public
    assert Address.classify(@public_v6) == :public
    assert classify_literal("::ffff:93.184.216.34") == :public
    assert Address.public?(@public_v4)
    refute Address.public?({300, 0, 0, 1})
  end

  test "a host takes the strictest class of all answers" do
    resolver = fn _ -> {:ok, [@public_v4, {0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 0}]} end
    assert {:ok, :metadata, _} = Address.classify_host("rebind.example", resolver: resolver)

    resolver = fn _ -> {:ok, [@public_v6, {10, 0, 0, 1}]} end
    assert {:ok, :private, _} = Address.classify_host("rebind.example", resolver: resolver)
  end

  test "names are classified without DNS where the name decides" do
    no_dns = [resolver: fn _ -> flunk("resolved") end]

    for name <- ["metadata", "metadata.goog", "METADATA.google.internal."] do
      assert {:ok, :metadata, []} = Address.classify_host(name, no_dns)
    end

    for name <- ["localhost", "LOCALHOST.", "api.localhost", "ip6-loopback"] do
      assert {:ok, :private, []} = Address.classify_host(name, no_dns)
    end
  end

  test "DNS failure, empty, malformed or oversized answers fail closed" do
    for resolver <- [
          fn _ -> {:error, :nxdomain} end,
          fn _ -> {:ok, []} end,
          fn _ -> {:ok, [:not_an_ip]} end,
          fn _ -> {:ok, [{256, 0, 0, 1}]} end,
          fn _ -> :garbage end,
          fn _ -> raise "boom" end
        ] do
      assert {:error, :dns_resolution_failed} =
               Address.authorize("callback.example", resolver: resolver)
    end

    many = List.duplicate(@public_v4, 65)

    assert {:error, :too_many_dns_addresses} =
             Address.authorize("callback.example", resolver: fn _ -> {:ok, many} end)
  end

  test "authorize refuses metadata even when private is allowed" do
    assert {:error, :metadata_blocked} = Address.authorize("169.254.169.254", allow_private: true)
    assert {:error, :metadata_blocked} = Address.authorize("2852039166", allow_private: true)
    assert {:error, :destination_not_public} = Address.authorize("127.0.0.1")
    assert {:ok, [{127, 0, 0, 1}]} = Address.authorize("127.0.0.1", allow_private: true)
    assert {:ok, [{127, 0, 0, 1}]} = Address.authorize("localhost", allow_private: true)
    assert {:error, :invalid_host} = Address.authorize("bad host")
  end
end
