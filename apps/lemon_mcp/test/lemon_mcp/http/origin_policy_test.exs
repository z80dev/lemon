defmodule LemonMCP.HTTP.OriginPolicyTest do
  use ExUnit.Case, async: true

  alias LemonMCP.HTTP.OriginPolicy

  @origin "https://mcp.example"
  @url "https://mcp.example/mcp?token=not-for-errors"
  @public_v4 {93, 184, 216, 34}
  @public_v6 {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

  defp policy(origins \\ [@origin]), do: %{allowed_origins: origins}
  defp resolver(addresses), do: [resolver: fn _host -> {:ok, addresses} end]

  describe "canonical_origin/1" do
    test "normalizes scheme, DNS case, root dot and default ports without losing URL identity" do
      assert {:ok, "https://mcp.example"} =
               OriginPolicy.canonical_origin("HTTPS://MCP.Example.:443/mcp?query=1")

      assert {:ok, "http://mcp.example"} =
               OriginPolicy.canonical_origin("http://mcp.example:80")

      assert {:ok, "https://mcp.example:8443"} =
               OriginPolicy.canonical_origin("https://mcp.example:8443/mcp")
    end

    test "uses non-transitional UTS46 IDNA consistently for Unicode and A-labels" do
      assert {:ok, "https://xn--bcher-kva.example"} =
               OriginPolicy.canonical_origin("https://BÜCHER.example/mcp")

      assert {:ok, "https://xn--bcher-kva.example"} =
               OriginPolicy.canonical_origin("https://xn--bcher-kva.example")

      assert {:ok, "https://xn--fa-hia.example"} =
               OriginPolicy.canonical_origin("https://faß.example")

      assert {:error, :invalid_url} = OriginPolicy.canonical_origin("https://_mcp.example")
      assert {:error, :invalid_url} = OriginPolicy.canonical_origin("https://xn--.example")
    end

    test "canonicalizes IP literal hosts and brackets IPv6 origins" do
      assert {:ok, "http://127.0.0.1:8080"} =
               OriginPolicy.canonical_origin("http://127.0.0.1:8080/mcp")

      assert {:ok, "https://[2606:4700:4700::1111]"} =
               OriginPolicy.canonical_origin("https://[2606:4700:4700:0:0:0:0:1111]:443/mcp")
    end

    test "rejects credentials, fragments, ambiguous authorities and non-HTTP URLs" do
      for url <- [
            "https://user:password@mcp.example/mcp",
            "https://@mcp.example/mcp",
            "https://mcp.example/mcp#fragment",
            "https://mcp.example/mcp#",
            "file:///etc/passwd",
            "ftp://mcp.example/mcp",
            "//mcp.example/mcp",
            "/mcp",
            "https:///mcp",
            "https://mcp.example:",
            "https://mcp.example:0",
            "https://mcp.example:65536",
            "https://mcp.example:443:80",
            "https://[fe80::1%25en0]/mcp",
            "https://mcp%2eexample/mcp",
            "https://mcp.example..",
            "https://mcp..example",
            "https://mcp.example\\@other.example/mcp",
            "https://mcp.example/\r\nAuthorization: secret",
            "https://mcp.example/ has-space",
            "https://#{String.duplicate("a", 64)}.example",
            String.duplicate("a", 8_193),
            <<255>>,
            nil,
            %URI{scheme: "https", host: "mcp.example"}
          ] do
        assert {:error, :invalid_url} = OriginPolicy.canonical_origin(url)
      end
    end
  end

  describe "pin/3 authorization and pin identity" do
    test "nil policy preserves legacy networking and never resolves" do
      opts = [resolver: fn _ -> flunk("legacy policy must not resolve") end]
      assert {:ok, nil} = OriginPolicy.pin(@url, nil, opts)
      assert {:ok, nil} = OriginPolicy.pin("http://127.0.0.1/mcp", nil, opts)
      assert {:ok, nil} = OriginPolicy.pin(:legacy_validation_is_transport_owned, nil, opts)
    end

    test "retains original URL while pinning canonical hostname identity" do
      url = "https://MCP.Example.:443/mcp?secret=opaque"
      test_pid = self()

      opts = [
        resolver: fn host ->
          send(test_pid, {:resolved, host})
          {:ok, [@public_v4]}
        end
      ]

      assert {:ok,
              %{
                url: ^url,
                origin: @origin,
                scheme: "https",
                host: "mcp.example",
                port: 443,
                address: @public_v4
              }} = OriginPolicy.pin(url, policy(), opts)

      assert_received {:resolved, "mcp.example"}
    end

    test "authorizes exact scheme, effective port and host before DNS" do
      opts = [resolver: fn _ -> flunk("unauthorized origins must not resolve") end]

      for url <- [
            "http://mcp.example/mcp",
            "https://mcp.example:8443/mcp",
            "https://other.example/mcp",
            "https://mcp.example.evil.example/mcp"
          ] do
        assert {:error, :origin_not_allowed} = OriginPolicy.pin(url, policy(), opts)
      end

      assert {:error, :origin_not_allowed} = OriginPolicy.pin(@url, policy([]), opts)
    end

    test "accepts canonical JSON keys with optional private approval omitted" do
      assert {:ok, %{address: @public_v4}} =
               OriginPolicy.pin(@url, %{"allowedOrigins" => [@origin]}, resolver([@public_v4]))
    end

    test "normalizes requested Unicode hostname but requires ASCII canonical policy entries" do
      opts = [resolver: fn "xn--bcher-kva.example" -> {:ok, [@public_v4]} end]

      assert {:ok, %{origin: "https://xn--bcher-kva.example", host: "xn--bcher-kva.example"}} =
               OriginPolicy.pin(
                 "https://bücher.example/mcp",
                 policy(["https://xn--bcher-kva.example"]),
                 opts
               )

      assert {:error, :invalid_origin_policy} =
               OriginPolicy.pin(@url, policy(["https://bücher.example"]), resolver([@public_v4]))
    end

    test "bounds and validates policy strings, types and ambiguous fields" do
      for invalid <- [
            %{},
            [],
            %{allowed_origins: nil},
            %{allowed_origins: "https://mcp.example"},
            policy([@origin <> "/"]),
            policy([@origin <> "/mcp"]),
            policy([@origin <> "?query=1"]),
            policy(["https://MCP.example"]),
            policy([@origin <> ":443"]),
            policy([String.duplicate("a", 513)]),
            policy([nil]),
            policy([@origin, @origin]),
            %{allowed_origins: [@origin], approved_private_origins: [@origin, @origin]},
            %{allowed_origins: [@origin], approved_private_origins: ["https://other.example"]},
            policy(List.duplicate(@origin, 129)),
            %{allowed_origins: [@origin], approved_private_origins: List.duplicate(@origin, 129)},
            %{allowed_origins: [@origin], approved_private_origins: "all"},
            %{:allowed_origins => [@origin], "allowedOrigins" => ["https://other.example"]}
          ] do
        assert {:error, :invalid_origin_policy} =
                 OriginPolicy.pin(@url, invalid, resolver([@public_v4]))
      end
    end

    test "private approval never bypasses allowlist, syntax or valid address requirements" do
      private = {127, 0, 0, 1}
      approved = %{allowed_origins: [@origin], approved_private_origins: [@origin]}

      assert {:ok, %{address: ^private}} = OriginPolicy.pin(@url, approved, resolver([private]))

      assert {:error, :origin_not_allowed} =
               OriginPolicy.pin(
                 "http://mcp.example/mcp",
                 approved,
                 resolver([private])
               )

      assert {:error, :invalid_url} =
               OriginPolicy.pin(
                 "https://user:secret@mcp.example/mcp",
                 approved,
                 resolver([private])
               )

      assert {:error, :invalid_dns_answer} =
               OriginPolicy.pin(@url, approved, resolver([{127, 0, 0, 999}]))

      assert {:error, :destination_not_public} =
               OriginPolicy.pin(
                 @url,
                 %{
                   allowed_origins: [@origin, "http://mcp.example"],
                   approved_private_origins: ["http://mcp.example"]
                 },
                 resolver([private])
               )
    end

    test "caller-supplied policy addresses are never pin authority" do
      untrusted =
        Map.merge(policy(), %{address: @public_v4, destination_pin: %{address: @public_v4}})

      assert {:error, :destination_not_public} =
               OriginPolicy.pin(@url, untrusted, resolver([{127, 0, 0, 1}]))
    end
  end

  describe "DNS and address validation" do
    test "pins deterministically across answer order and validates both address families" do
      for addresses <- [
            [@public_v4, @public_v6],
            [@public_v6, @public_v4],
            [@public_v4, @public_v4]
          ] do
        assert {:ok, %{address: @public_v4}} =
                 OriginPolicy.pin(@url, policy(), resolver(addresses))
      end

      assert {:ok, %{address: @public_v6}} =
               OriginPolicy.pin(@url, policy(), resolver([@public_v6]))
    end

    test "denies non-global IPv4 including local, metadata, carrier-grade and reserved ranges" do
      for address <- [
            {0, 0, 0, 0},
            {0, 1, 2, 3},
            {10, 1, 2, 3},
            {100, 64, 0, 1},
            {100, 127, 255, 254},
            {127, 0, 0, 1},
            {127, 100, 10, 1},
            {169, 254, 169, 254},
            {169, 254, 0, 1},
            {172, 16, 0, 1},
            {172, 31, 255, 254},
            {192, 0, 0, 8},
            {192, 0, 2, 1},
            {192, 88, 99, 1},
            {192, 168, 1, 1},
            {198, 18, 0, 1},
            {198, 19, 255, 254},
            {198, 51, 100, 1},
            {203, 0, 113, 1},
            {224, 0, 0, 1},
            {239, 255, 255, 255},
            {240, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        assert {:error, :destination_not_public} =
                 OriginPolicy.pin(@url, policy(), resolver([address]))
      end
    end

    test "denies non-global IPv6 including local, link-local, metadata, transition and documentation" do
      for literal <- [
            "::",
            "::1",
            "::127.0.0.1",
            "fc00::1",
            "fd00:ec2::254",
            "fe80::1",
            "fec0::1",
            "ff02::1",
            "64:ff9b::a9fe:a9fe",
            "64:ff9b:1::1",
            "100::1",
            "2001::1",
            "2001:2::1",
            "2001:10::1",
            "2001:20::1",
            "2001:db8::1",
            "2002:7f00:1::1",
            "3fff::1",
            "5f00::1"
          ] do
        {:ok, address} = :inet.parse_strict_address(String.to_charlist(literal))

        assert {:error, :destination_not_public} =
                 OriginPolicy.pin(@url, policy(), resolver([address]))
      end
    end

    test "classifies IPv4-mapped IPv6 by its underlying IPv4 address" do
      for literal <- ["::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:192.168.1.1"] do
        {:ok, address} = :inet.parse_strict_address(String.to_charlist(literal))

        assert {:error, :destination_not_public} =
                 OriginPolicy.pin(@url, policy(), resolver([address]))
      end

      {:ok, public} = :inet.parse_strict_address(~c"::ffff:93.184.216.34")
      assert {:ok, %{address: ^public}} = OriginPolicy.pin(@url, policy(), resolver([public]))
    end

    test "rejects every mixed public/private DNS result regardless of selected address or ordering" do
      for addresses <- [
            [@public_v4, {127, 0, 0, 1}],
            [{127, 0, 0, 1}, @public_v4],
            [@public_v6, {169, 254, 169, 254}],
            [@public_v4, {0, 0, 0, 0, 0, 0, 0, 1}]
          ] do
        assert {:error, :destination_not_public} =
                 OriginPolicy.pin(@url, policy(), resolver(addresses))
      end
    end

    test "public IPv4 range boundaries remain eligible" do
      for address <- [
            {100, 63, 255, 254},
            {100, 128, 0, 1},
            {172, 15, 255, 254},
            {172, 32, 0, 1},
            {198, 17, 255, 254},
            {198, 20, 0, 1},
            {223, 255, 255, 254}
          ] do
        assert {:ok, %{address: ^address}} = OriginPolicy.pin(@url, policy(), resolver([address]))
      end
    end

    test "bounds DNS answers before deduplication and refuses malformed answers even with approval" do
      assert {:ok, %{address: @public_v4}} =
               OriginPolicy.pin(@url, policy(), resolver(List.duplicate(@public_v4, 64)))

      assert {:error, :too_many_dns_addresses} =
               OriginPolicy.pin(@url, policy(), resolver(List.duplicate(@public_v4, 65)))

      approved = %{allowed_origins: [@origin], approved_private_origins: [@origin]}

      for invalid <- [
            "127.0.0.1",
            {1, 2, 3},
            {1, 2, 3, -1},
            {1, 2, 3, 256},
            {0, 0, 0, 0, 0, 0, 0, 65_536},
            nil
          ] do
        assert {:error, :invalid_dns_answer} =
                 OriginPolicy.pin(@url, approved, resolver([@public_v4, invalid]))
      end
    end

    test "resolver errors, exceptions and invalid return values are bounded classified errors" do
      for result <- [{:error, {:timeout, @url}}, {:ok, []}, {:ok, :invalid}, @url] do
        assert {:error, :dns_resolution_failed} =
                 OriginPolicy.pin(@url, policy(), resolver: fn _ -> result end)
      end

      assert {:error, :dns_resolution_failed} =
               OriginPolicy.pin(@url, policy(), resolver: fn _ -> raise @url end)

      assert {:error, :dns_resolution_failed} =
               OriginPolicy.pin(@url, policy(), resolver: fn _ -> throw({:secret, @url}) end)
    end

    test "IP literals cannot be rebound through DNS resolver injection" do
      opts = [resolver: fn _ -> flunk("IP literals must not resolve") end]

      assert {:error, :destination_not_public} =
               OriginPolicy.pin("http://127.0.0.1/mcp", policy(["http://127.0.0.1"]), opts)

      assert {:ok, %{address: @public_v6}} =
               OriginPolicy.pin(
                 "https://[2606:4700:4700::1111]/mcp",
                 policy(["https://[2606:4700:4700::1111]"]),
                 opts
               )
    end

    test "explicit private approval supports real IPv4 and IPv6 literal fixture destinations" do
      for {origin, address} <- [
            {"http://127.0.0.1:8080", {127, 0, 0, 1}},
            {"http://[::1]:8080", {0, 0, 0, 0, 0, 0, 0, 1}}
          ] do
        url = origin <> "/mcp"
        approved = %{allowed_origins: [origin], approved_private_origins: [origin]}
        opts = [resolver: fn _ -> flunk("literal destinations must never resolve") end]

        assert {:ok, %{url: ^url, origin: ^origin, address: ^address}} =
                 OriginPolicy.pin(url, approved, opts)
      end
    end

    test "real executing-host resolver rejects localhost unless exact origin is approved" do
      origin = "http://localhost:8080"
      url = origin <> "/mcp"

      assert {:error, :destination_not_public} = OriginPolicy.pin(url, policy([origin]))

      assert {:ok, %{origin: ^origin, address: address}} =
               OriginPolicy.pin(url, %{
                 "allowedOrigins" => [origin],
                 "approvedPrivateOrigins" => [origin]
               })

      assert address in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
    end
  end
end
