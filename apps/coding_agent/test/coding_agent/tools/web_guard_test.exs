defmodule CodingAgent.Tools.WebGuardTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.WebGuard

  @public {93, 184, 216, 34}
  @public_b {1, 1, 1, 1}
  @public_v6 {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

  defp no_send, do: fn _request -> flunk("transport should not be called") end

  # `LemonCore.Net.Address.resolve/2` fails closed on anything a resolver
  # raises, so a flunk there would be swallowed; record the call instead.
  defp no_resolver do
    parent = self()

    fn host ->
      send(parent, {:resolver_called, host})
      {:error, :unexpected_resolution}
    end
  end

  defp ok(status \\ 200, headers \\ [], body \\ "ok"),
    do: {:ok, %{status: status, headers: headers, body: body}}

  defp redirect(location), do: ok(302, [{"location", location}], "")

  defp observing(parent, response) do
    fn request ->
      send(parent, {:request, request})
      response
    end
  end

  test "rejects non-http schemes before networking" do
    assert {:error, {:invalid_url, "Invalid URL: must be http or https"}} =
             WebGuard.guarded_get("file:///etc/passwd",
               resolve_host: no_resolver(),
               send: no_send()
             )

    refute_received {:resolver_called, _}
  end

  test "rejects discarded ports before DNS or transport" do
    for port <- ["65536", "99999", "100000", "00065536"] do
      assert {:error, {:invalid_url, _}} =
               WebGuard.guarded_get("https://example.com:#{port}/",
                 resolve_host: no_resolver(),
                 send: no_send()
               )

      refute_received {:resolver_called, _}
    end
  end

  test "rejects discarded absolute and network-path redirect ports" do
    for location <- ["https://example.com:65536/b", "//example.com:65536/b"] do
      assert {:error, {:redirect_error, "Invalid redirect location"}} =
               WebGuard.guarded_get("https://example.com/a",
                 resolve_host: fn _ -> {:ok, [@public]} end,
                 send: fn request ->
                   assert {request.address, request.host, request.path} ==
                            {@public, "example.com", "/a"}

                   redirect(location)
                 end
               )
    end
  end

  test "network-path redirects with no explicit port retain the scheme default" do
    assert {:ok, %{status: 200}, "https://example.com/b"} =
             WebGuard.guarded_get("https://example.com/a",
               resolve_host: fn _ -> {:ok, [@public]} end,
               send: fn
                 %{path: "/a", port: 443} -> redirect("//example.com/b")
                 %{path: "/b", port: 443} -> ok(200, [], "done")
               end
             )
  end

  test "blocks localhost before resolver or transport" do
    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://localhost/admin",
               resolve_host: no_resolver(),
               send: no_send()
             )

    assert message =~ "private/internal"
    refute_received {:resolver_called, _}
  end

  test "blocks metadata.google.internal before resolver or transport even when allow_private_network is true" do
    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://metadata.google.internal/latest/meta-data",
               resolve_host: no_resolver(),
               send: no_send(),
               allow_private_network: true
             )

    assert message =~ "metadata"
    refute_received {:resolver_called, _}
  end

  test "blocks metadata.google.internal even when explicitly allowlisted" do
    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://metadata.google.internal/latest/meta-data",
               resolve_host: no_resolver(),
               send: no_send(),
               allowed_hostnames: ["metadata.google.internal"]
             )

    assert message =~ "metadata"
    refute_received {:resolver_called, _}
  end

  test "blocks metadata IP literals even when allow_private_network is true" do
    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://169.254.169.254/latest/meta-data",
               resolve_host: no_resolver(),
               send: no_send(),
               allow_private_network: true
             )

    assert message =~ "metadata"
    refute_received {:resolver_called, _}
  end

  test "blocks nonstandard private IPv4 literals before networking" do
    for url <- ["http://0177.0.0.1/private", "http://0x7f.0x0.0x0.0x1/private"] do
      assert {:error, {:ssrf_blocked, message}} =
               WebGuard.guarded_get(url, resolve_host: no_resolver(), send: no_send()),
             url

      assert message =~ "private/internal"
      refute_received {:resolver_called, _}
    end
  end

  test "blocks standard private IPv4 literals before networking" do
    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://127.0.0.1/private",
               resolve_host: no_resolver(),
               send: no_send()
             )

    assert message =~ "private/internal"
    refute_received {:resolver_called, _}
  end

  test "blocks private IPv6 literals before networking" do
    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://[::1]/private",
               resolve_host: no_resolver(),
               send: no_send()
             )

    assert message =~ "private/internal"
    refute_received {:resolver_called, _}
  end

  test "pins outbound request to resolved IP and keeps the original host for Host and TLS" do
    resolver = fn
      "example.com" -> {:ok, [@public]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %{status: 200, body: "ok"}, "https://example.com/docs?a=1"} =
             WebGuard.guarded_get("https://example.com/docs?a=1",
               send: observing(self(), ok()),
               resolve_host: resolver,
               cacerts: [:dummy_cert]
             )

    assert_receive {:request, request}
    assert request.method == "GET"
    assert request.scheme == "https"
    assert request.address == @public
    assert request.host == "example.com"
    assert request.port == 443
    assert request.path == "/docs?a=1"
    assert request.ssl == [cacerts: [:dummy_cert]]
  end

  test "pins outbound request to resolved IPv6 and keeps the original host" do
    resolver = fn
      "ipv6.example.com" -> {:ok, [@public_v6]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %{status: 200}, "https://ipv6.example.com/docs?a=1"} =
             WebGuard.guarded_get("https://ipv6.example.com/docs?a=1",
               send: observing(self(), ok()),
               resolve_host: resolver
             )

    assert_receive {:request, %{address: @public_v6, host: "ipv6.example.com", path: "/docs?a=1"}}
  end

  test "keeps non-default ports for the pinned connection and final URL" do
    resolver = fn
      "example.com" -> {:ok, [@public]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %{status: 200}, "https://example.com:8443/path?q=1"} =
             WebGuard.guarded_get("https://example.com:8443/path?q=1",
               send: observing(self(), ok()),
               resolve_host: resolver
             )

    assert_receive {:request,
                    %{address: @public, host: "example.com", port: 8443, path: "/path?q=1"}}
  end

  test "drops a caller-provided host header" do
    assert {:ok, %{status: 200}, _} =
             WebGuard.guarded_get("https://example.com/index",
               send: observing(self(), ok()),
               resolve_host: fn "example.com" -> {:ok, [@public]} end,
               headers: [{"host", "attacker.invalid"}, {"x-test", "1"}]
             )

    assert_receive {:request, request}
    assert request.host == "example.com"
    refute Enum.any?(request.headers, fn {key, _} -> key == "host" end)
    assert {"x-test", "1"} in request.headers
  end

  test "http requests carry no TLS options and use the default timeout" do
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{status: 200}, _} =
             WebGuard.guarded_get("http://plain.example.com/docs",
               send: observing(self(), ok()),
               resolve_host: fn "plain.example.com" -> {:ok, [@public]} end
             )

    finished = System.monotonic_time(:millisecond)
    assert_receive {:request, request}
    assert request.scheme == "http"
    assert request.address == @public
    assert request.path == "/docs"
    # The hop deadline is the default 30 s from when the request began;
    # `timeout_ms` is what remained of it when the transport was called.
    assert request.deadline in (started + 30_000)..(finished + 30_000)
    assert request.timeout_ms in (30_000 - (finished - started))..30_000
    assert request.ssl == []
  end

  test "passes timeout_ms and max_body_bytes through to the transport" do
    started = System.monotonic_time(:millisecond)

    assert {:ok, _, _} =
             WebGuard.guarded_get("https://example.com/",
               send: observing(self(), ok()),
               resolve_host: fn _ -> {:ok, [@public]} end,
               timeout_ms: 1_234,
               max_body_bytes: 99
             )

    finished = System.monotonic_time(:millisecond)
    assert_receive {:request, %{max_body_bytes: 99} = request}
    assert request.deadline in (started + 1_234)..(finished + 1_234)
  end

  test "respects cacertfile override when provided" do
    assert {:ok, _, _} =
             WebGuard.guarded_get("https://example.com/secure",
               send: observing(self(), ok()),
               resolve_host: fn "example.com" -> {:ok, [@public]} end,
               cacertfile: "/tmp/ca.pem"
             )

    assert_receive {:request, %{ssl: [cacertfile: "/tmp/ca.pem"]}}
  end

  test "prefers explicit cacerts over cacertfile when both are provided" do
    assert {:ok, _, _} =
             WebGuard.guarded_get("https://example.com/secure",
               send: observing(self(), ok()),
               resolve_host: fn "example.com" -> {:ok, [@public]} end,
               cacerts: [:explicit_cert],
               cacertfile: "/tmp/ca.pem"
             )

    assert_receive {:request, %{ssl: [cacerts: [:explicit_cert]]}}
  end

  test "re-validates and re-pins each redirect hop" do
    parent = self()

    send_fn = fn request ->
      send(parent, {:request, request})

      case request.path do
        "/start" -> redirect("https://next.example.net/final")
        "/final" -> ok(200, [{"content-type", "text/plain"}], "ok")
      end
    end

    resolver = fn
      "start.example.com" -> {:ok, [@public]}
      "next.example.net" -> {:ok, [@public_b]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %{status: 200}, "https://next.example.net/final"} =
             WebGuard.guarded_get("http://start.example.com/start",
               send: send_fn,
               resolve_host: resolver
             )

    assert_receive {:request,
                    %{scheme: "http", address: @public, host: "start.example.com", path: "/start"}}

    assert_receive {:request,
                    %{
                      scheme: "https",
                      address: @public_b,
                      host: "next.example.net",
                      path: "/final"
                    }}
  end

  test "follows relative redirects against original URI" do
    parent = self()

    send_fn = fn request ->
      send(parent, {:path, request.address, request.path})

      case request.path do
        "/base/path" -> redirect("../next")
        "/next" -> ok()
      end
    end

    assert {:ok, %{status: 200}, "https://rel.example.com/next"} =
             WebGuard.guarded_get("https://rel.example.com/base/path",
               send: send_fn,
               resolve_host: fn "rel.example.com" -> {:ok, [@public]} end
             )

    assert_receive {:path, @public, "/base/path"}
    assert_receive {:path, @public, "/next"}
  end

  test "returns error when redirect is missing location header" do
    assert {:error, {:redirect_error, "Invalid redirect location"}} =
             WebGuard.guarded_get("https://redir.example.com/start",
               send: fn _ -> ok(302, [{"x-test", "1"}], "") end,
               resolve_host: fn "redir.example.com" -> {:ok, [@public]} end
             )
  end

  test "enforces redirect limit" do
    parent = self()

    send_fn = fn request ->
      send(parent, {:path, request.path})

      case request.path do
        "/a" -> redirect("/b")
        "/b" -> redirect("/c")
      end
    end

    assert {:error, {:redirect_error, "Too many redirects (limit: 1)"}} =
             WebGuard.guarded_get("https://limit.example.com/a",
               send: send_fn,
               resolve_host: fn "limit.example.com" -> {:ok, [@public]} end,
               max_redirects: 1
             )

    assert_receive {:path, "/a"}
    assert_receive {:path, "/b"}
    refute_receive {:path, "/c"}
  end

  test "max_redirects 0 refuses any redirect" do
    assert {:error, {:redirect_error, "Too many redirects (limit: 0)"}} =
             WebGuard.guarded_get("https://limit.example.com/a",
               send: fn _ -> redirect("/b") end,
               resolve_host: fn "limit.example.com" -> {:ok, [@public]} end,
               max_redirects: 0
             )
  end

  test "detects redirect loops" do
    send_fn = fn request ->
      case request.path do
        "/a" -> redirect("/b")
        "/b" -> redirect("/a")
      end
    end

    assert {:error, {:redirect_error, "Redirect loop detected"}} =
             WebGuard.guarded_get("https://loop.example.com/a",
               send: send_fn,
               resolve_host: fn "loop.example.com" -> {:ok, [@public]} end,
               max_redirects: 5
             )
  end

  test "blocks redirect targets that resolve to private IPs" do
    parent = self()

    send_fn = fn request ->
      send(parent, {:request, request.address, request.path})
      redirect("http://private.example.com/secret")
    end

    resolver = fn
      "public.example.com" -> {:ok, [@public]}
      "private.example.com" -> {:ok, [{127, 0, 0, 1}]}
      _ -> {:error, :nxdomain}
    end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://public.example.com/start",
               send: send_fn,
               resolve_host: resolver
             )

    assert message =~ "private/internal"
    assert_receive {:request, @public, "/start"}
    refute_receive {:request, _, "/secret"}
  end

  test "allowed_hostnames permits explicitly allowlisted private targets" do
    resolver = fn
      "internal.example.local" -> {:ok, [{127, 0, 0, 1}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %{status: 200}, "http://internal.example.local/health"} =
             WebGuard.guarded_get("http://internal.example.local/health",
               send: observing(self(), ok()),
               resolve_host: resolver,
               allowed_hostnames: ["internal.example.local"]
             )

    assert_receive {:request,
                    %{address: {127, 0, 0, 1}, host: "internal.example.local", path: "/health"}}
  end

  test "allowed_hostnames does not extend to other private hosts" do
    assert {:error, {:ssrf_blocked, _}} =
             WebGuard.guarded_get("http://other.example.local/health",
               send: no_send(),
               resolve_host: fn _ -> {:ok, [{10, 0, 0, 1}]} end,
               allowed_hostnames: ["internal.example.local"]
             )
  end

  test "allow_private_network permits localhost requests pinned to loopback" do
    assert {:ok, %{status: 200}, "http://localhost/status"} =
             WebGuard.guarded_get("http://localhost/status",
               send: observing(self(), ok()),
               resolve_host: no_resolver(),
               allow_private_network: true
             )

    assert_receive {:request, %{address: {127, 0, 0, 1}, host: "localhost", path: "/status"}}
    refute_received {:resolver_called, _}
  end

  test "blocks when any DNS result resolves to private IP" do
    resolver = fn
      "mixed.example.com" -> {:ok, [@public, {10, 0, 0, 5}]}
      _ -> {:error, :nxdomain}
    end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("https://mixed.example.com/data",
               resolve_host: resolver,
               send: no_send()
             )

    assert message =~ "private/internal"
  end

  test "resolver answers that are not addresses fail closed" do
    assert {:error, {:network_error, message}} =
             WebGuard.guarded_get("http://string-ip.example.com/ok",
               resolve_host: fn "string-ip.example.com" -> {:ok, ["93.184.216.51"]} end,
               send: no_send()
             )

    assert message =~ "Unable to resolve hostname"
  end

  test "resolver error is a network_error that does not echo resolver internals" do
    assert {:error, {:network_error, message}} =
             WebGuard.guarded_get("http://broken.example.com/health",
               resolve_host: fn "broken.example.com" -> {:error, :nxdomain_internal_detail} end,
               send: no_send()
             )

    assert message =~ "Unable to resolve hostname"
    refute message =~ "nxdomain_internal_detail"
  end

  test "unexpected resolver payload is normalized to network_error" do
    assert {:error, {:network_error, message}} =
             WebGuard.guarded_get("http://broken.example.com/health",
               resolve_host: fn "broken.example.com" -> :unexpected end,
               send: no_send()
             )

    assert message =~ "Unable to resolve hostname"
  end

  test "transport timeouts are normalized" do
    assert {:error, {:network_error, "timeout"}} =
             WebGuard.guarded_get("http://timeout.example.com/data",
               resolve_host: fn "timeout.example.com" -> {:ok, [@public]} end,
               send: fn _ -> {:error, :timeout} end
             )
  end

  test "unexpected transport response shape is normalized" do
    assert {:error, {:network_error, "HTTP request failed"}} =
             WebGuard.guarded_get("http://shape.example.com/data",
               resolve_host: fn "shape.example.com" -> {:ok, [@public]} end,
               send: fn _ -> :ok end
             )
  end

  test "ssrf_blocked?/1 identifies blocked error envelopes" do
    assert WebGuard.ssrf_blocked?({:ssrf_blocked, "blocked"}) == true
    assert WebGuard.ssrf_blocked?({:error, {:ssrf_blocked, "blocked"}}) == true
    assert WebGuard.ssrf_blocked?({:network_error, "timeout"}) == false
    assert WebGuard.ssrf_blocked?(:anything_else) == false
  end
end
