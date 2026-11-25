defmodule LemonSkills.Context.URLFetcherTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Context.URLFetcher

  @public {93, 184, 216, 34}

  defp public_resolver, do: fn _ -> {:ok, [@public]} end
  defp unsafe_send, do: fn _request -> flunk("unsafe request was attempted") end
  defp redirect(location), do: {:ok, %{status: 302, headers: [{"location", location}], body: ""}}

  test "blocks localhost, private DNS answers, URL credentials, and private redirects" do
    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("http://localhost/a", send_fun: unsafe_send())

    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("https://example.test/a",
               resolve_fun: fn _ -> {:ok, [{127, 0, 0, 1}]} end,
               send_fun: unsafe_send()
             )

    assert {:error, :url_credentials_forbidden} =
             URLFetcher.fetch("https://user:pass@example.test/a",
               resolve_fun: public_resolver(),
               send_fun: unsafe_send()
             )

    send_fun = fn request ->
      assert request.address == @public
      redirect("http://127.0.0.1/secret")
    end

    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("https://example.test/a",
               resolve_fun: fn host ->
                 if host == "example.test",
                   do: {:ok, [@public]},
                   else: {:ok, [{127, 0, 0, 1}]}
               end,
               send_fun: send_fun
             )
  end

  test "rejects discarded ports before normalization, DNS, or requests" do
    opts = [
      resolve_fun: fn _ -> flunk("invalid port reached DNS") end,
      send_fun: fn _ -> flunk("invalid port reached transport") end
    ]

    for port <- ["65536", "99999", "100000", "00065536"] do
      assert {:error, :invalid_url} =
               URLFetcher.fetch("https://example.test:#{port}/a", opts)
    end
  end

  test "rejects invalid absolute and network-path redirect ports before serialization" do
    for location <- ["https://example.test:65536/b", "//example.test:65536/b"] do
      send_fun = fn request ->
        assert request.address == @public
        assert request.path == "/a"
        redirect(location)
      end

      assert {:error, :invalid_redirect} =
               URLFetcher.fetch("https://example.test/a",
                 resolve_fun: public_resolver(),
                 send_fun: send_fun
               )
    end
  end

  test "network-path redirects with no explicit port retain the scheme default" do
    send_fun = fn
      %{path: "/a", port: 443, scheme: scheme} when scheme in [:https, "https"] ->
        redirect("//example.test/b")

      %{path: "/b", port: 443} ->
        {:ok, %{status: 200, headers: [], body: "done"}}
    end

    assert {:ok, "done", %{redirects: 1}} =
             URLFetcher.fetch("https://example.test/a",
               resolve_fun: public_resolver(),
               send_fun: send_fun
             )
  end

  test "blocks IPv4-mapped IPv6 loopback, RFC1918, link-local, and CGNAT answers" do
    mapped_private = [
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xAC10, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0x0102},
      {0, 0, 0, 0, 0, 0xFFFF, 0x6440, 0x0001}
    ]

    for address <- mapped_private do
      assert {:error, :ssrf_blocked} =
               URLFetcher.fetch("https://example.test/a",
                 resolve_fun: fn _ -> {:ok, [address]} end,
                 send_fun: unsafe_send()
               )
    end
  end

  test "detects A to B to A redirects on the first return to the initial URL" do
    parent = self()

    send_fun = fn request ->
      send(parent, {:requested, request.address, request.path})

      if request.path == "/a",
        do: redirect("https://example.test/b"),
        else: redirect("https://example.test/a")
    end

    assert {:error, :redirect_loop} =
             URLFetcher.fetch("https://EXAMPLE.test/a#fragment",
               resolve_fun: public_resolver(),
               send_fun: send_fun
             )

    assert_received {:requested, @public, "/a"}
    assert_received {:requested, @public, "/b"}
    refute_received {:requested, _, _}
  end

  test "pins the request IP, retains host header, and strips query metadata" do
    parent = self()

    send_fun = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "hello"}}
    end

    assert {:ok, "hello", metadata} =
             URLFetcher.fetch("https://example.test/path?token=secret#frag",
               resolve_fun: public_resolver(),
               send_fun: send_fun,
               max_input_bytes: 10
             )

    assert metadata.final_url == "https://example.test/path"
    assert metadata.content_type == "text/plain"
    assert_received {:request, request}
    assert request.address == @public
    assert request.host == "example.test"
    assert request.path == "/path?token=secret"
    assert request.max_body_bytes == 10
  end

  test "rejects a body over the limit even from an injected transport" do
    assert {:error, :input_too_large} =
             URLFetcher.fetch("https://example.test/",
               resolve_fun: public_resolver(),
               send_fun: fn _ -> {:ok, %{status: 200, headers: [], body: "123456"}} end,
               max_input_bytes: 5
             )
  end

  test "maps non-2xx status and transport failures" do
    assert {:error, {:http_status, 404}} =
             URLFetcher.fetch("https://example.test/missing",
               resolve_fun: public_resolver(),
               send_fun: fn _ -> {:ok, %{status: 404, headers: [], body: ""}} end
             )

    assert {:error, :network_error} =
             URLFetcher.fetch("https://example.test/",
               resolve_fun: public_resolver(),
               send_fun: fn _ -> {:error, :econnrefused} end
             )

    assert {:error, :dns_failed} =
             URLFetcher.fetch("https://example.test/",
               resolve_fun: fn _ -> {:error, :nxdomain} end,
               send_fun: unsafe_send()
             )
  end

  test "rejects ambiguous request targets before reaching the transport" do
    for url <- ["http://example.test/has space", "http://example.test/bad\tpath"] do
      assert {:error, :invalid_url} =
               URLFetcher.fetch(url,
                 resolve_fun: public_resolver(),
                 send_fun: fn _ -> flunk("invalid target reached the transport") end
               )
    end
  end
end
