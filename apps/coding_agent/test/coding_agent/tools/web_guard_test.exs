defmodule CodingAgent.Tools.WebGuardTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.WebGuard

  test "rejects non-http schemes before networking" do
    resolver = fn _host -> flunk("resolver should not be called") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:invalid_url, "Invalid URL: must be http or https"}} =
             WebGuard.guarded_get("file:///etc/passwd", resolve_host: resolver, http_get: http_get)
  end

  test "blocks localhost before resolver or http_get" do
    resolver = fn _host -> flunk("resolver should not be called") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://localhost/admin",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message =~ "Blocked hostname: localhost"
  end

  test "blocks metadata.google.internal before resolver or http_get even when allow_private_network is true" do
    resolver = fn _host -> flunk("resolver should not be called") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://metadata.google.internal/latest/meta-data",
               resolve_host: resolver,
               http_get: http_get,
               allow_private_network: true
             )

    assert message =~ "Blocked hostname: metadata.google.internal"
  end

  test "blocks metadata.google.internal even when explicitly allowlisted" do
    resolver = fn _host -> flunk("resolver should not be called") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://metadata.google.internal/latest/meta-data",
               resolve_host: resolver,
               http_get: http_get,
               allowed_hostnames: ["metadata.google.internal"]
             )

    assert message =~ "Blocked hostname: metadata.google.internal"
  end

  test "blocks metadata IP literals even when allow_private_network is true" do
    resolver = fn _host -> flunk("resolver should not be called for IP literals") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://169.254.169.254/latest/meta-data",
               resolve_host: resolver,
               http_get: http_get,
               allow_private_network: true
             )

    assert message =~ "metadata IP"
  end

  test "blocks nonstandard private IPv4 literals before networking" do
    resolver = fn _host -> flunk("resolver should not be called for IP literals") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message_oct}} =
             WebGuard.guarded_get("http://0177.0.0.1/private",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message_oct =~ "private/internal"

    assert {:error, {:ssrf_blocked, message_hex}} =
             WebGuard.guarded_get("http://0x7f.0x0.0x0.0x1/private",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message_hex =~ "private/internal"
  end

  test "blocks standard private IPv4 literals before networking" do
    resolver = fn _host -> flunk("resolver should not be called for IP literals") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://127.0.0.1/private",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message =~ "private/internal"
  end

  test "blocks private IPv6 literals before networking" do
    resolver = fn _host -> flunk("resolver should not be called for IP literals") end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://[::1]/private",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message =~ "private/internal"
  end

  test "pins outbound request to resolved IP and preserves original host in headers" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn
      "example.com" -> {:ok, [{203, 0, 113, 7}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %Req.Response{status: 200}, "https://example.com/docs?a=1"} =
             WebGuard.guarded_get("https://example.com/docs?a=1",
               http_get: http_get,
               resolve_host: resolver,
               cacerts: [:dummy_cert]
             )

    assert_receive {:http_get, "https://203.0.113.7/docs?a=1", request_opts}

    assert {"host", "example.com"} in request_opts[:headers]
    assert request_opts[:redirect] == false
    assert request_opts[:decode_body] == false

    connect_options = request_opts[:connect_options]
    assert connect_options[:hostname] == "example.com"

    transport_opts = connect_options[:transport_opts]
    assert transport_opts[:verify] == :verify_peer
    assert transport_opts[:server_name_indication] == ~c"example.com"
    assert transport_opts[:cacerts] == [:dummy_cert]
  end

  test "pins outbound request to resolved IPv6 and preserves original host in headers" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn
      "ipv6.example.com" -> {:ok, [{8193, 3512, 0, 0, 0, 0, 0, 1}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %Req.Response{status: 200}, "https://ipv6.example.com/docs?a=1"} =
             WebGuard.guarded_get("https://ipv6.example.com/docs?a=1",
               http_get: http_get,
               resolve_host: resolver,
               cacerts: [:dummy_cert]
             )

    assert_receive {:http_get, "https://[2001:db8::1]/docs?a=1", request_opts}
    assert {"host", "ipv6.example.com"} in request_opts[:headers]
    assert request_opts[:connect_options][:hostname] == "ipv6.example.com"
  end

  test "keeps non-default ports in host header and pinned URL" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn
      "example.com" -> {:ok, [{203, 0, 113, 12}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %Req.Response{status: 200}, "https://example.com:8443/path?q=1"} =
             WebGuard.guarded_get("https://example.com:8443/path?q=1",
               http_get: http_get,
               resolve_host: resolver,
               cacerts: [:dummy_cert]
             )

    assert_receive {:http_get, "https://203.0.113.12:8443/path?q=1", request_opts}
    assert {"host", "example.com:8443"} in request_opts[:headers]
    assert request_opts[:connect_options][:hostname] == "example.com"
  end

  test "overrides caller-provided host header" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts[:headers]})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn
      "example.com" -> {:ok, [{203, 0, 113, 13}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %Req.Response{status: 200}, _} =
             WebGuard.guarded_get("https://example.com/index",
               http_get: http_get,
               resolve_host: resolver,
               headers: [{"host", "attacker.invalid"}, {"x-test", "1"}],
               cacerts: [:dummy_cert]
             )

    assert_receive {:http_get, "https://203.0.113.13/index", headers}
    assert {"host", "example.com"} in headers
    refute {"host", "attacker.invalid"} in headers
    assert {"x-test", "1"} in headers
  end

  test "http requests do not add tls connect options" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn
      "plain.example.com" -> {:ok, [{203, 0, 113, 14}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %Req.Response{status: 200}, _} =
             WebGuard.guarded_get("http://plain.example.com/docs",
               http_get: http_get,
               resolve_host: resolver
             )

    assert_receive {:http_get, "http://203.0.113.14/docs", request_opts}
    connect_options = request_opts[:connect_options]
    assert connect_options[:timeout] == 30_000
    refute Keyword.has_key?(connect_options, :hostname)
    refute Keyword.has_key?(connect_options, :transport_opts)
  end

  test "respects cacertfile override when provided" do
    parent = self()

    http_get = fn _url, opts ->
      send(parent, {:connect_options, opts[:connect_options]})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn "example.com" -> {:ok, [{203, 0, 113, 15}]} end

    assert {:ok, %Req.Response{status: 200}, _} =
             WebGuard.guarded_get("https://example.com/secure",
               http_get: http_get,
               resolve_host: resolver,
               cacertfile: "/tmp/ca.pem"
             )

    assert_receive {:connect_options, connect_options}
    transport_opts = connect_options[:transport_opts]
    assert transport_opts[:cacertfile] == "/tmp/ca.pem"
    refute Keyword.has_key?(transport_opts, :cacerts)
  end

  test "prefers explicit cacerts over cacertfile when both are provided" do
    parent = self()

    http_get = fn _url, opts ->
      send(parent, {:connect_options, opts[:connect_options]})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn "example.com" -> {:ok, [{203, 0, 113, 16}]} end

    assert {:ok, %Req.Response{status: 200}, _} =
             WebGuard.guarded_get("https://example.com/secure",
               http_get: http_get,
               resolve_host: resolver,
               cacerts: [:explicit_cert],
               cacertfile: "/tmp/ca.pem"
             )

    assert_receive {:connect_options, connect_options}
    transport_opts = connect_options[:transport_opts]
    assert transport_opts[:cacerts] == [:explicit_cert]
    refute Keyword.has_key?(transport_opts, :cacertfile)
  end

  test "re-validates and re-pins each redirect hop" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts[:headers]})

      case url do
        "http://203.0.113.10/start" ->
          {:ok,
           %Req.Response{
             status: 302,
             headers: [{"location", "https://next.example.net/final"}],
             body: ""
           }}

        "https://198.51.100.9/final" ->
          {:ok, %Req.Response{status: 200, headers: [{"content-type", "text/plain"}], body: "ok"}}
      end
    end

    resolver = fn
      "start.example.com" -> {:ok, [{203, 0, 113, 10}]}
      "next.example.net" -> {:ok, [{198, 51, 100, 9}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %Req.Response{status: 200}, "https://next.example.net/final"} =
             WebGuard.guarded_get("http://start.example.com/start",
               http_get: http_get,
               resolve_host: resolver,
               cacerts: [:dummy_cert]
             )

    assert_receive {:http_get, "http://203.0.113.10/start", first_headers}
    assert_receive {:http_get, "https://198.51.100.9/final", second_headers}

    assert {"host", "start.example.com"} in first_headers
    assert {"host", "next.example.net"} in second_headers
  end

  test "follows relative redirects against original URI" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:http_get, url})

      case url do
        "https://203.0.113.18/base/path" ->
          {:ok, %Req.Response{status: 302, headers: [{"location", "../next"}], body: ""}}

        "https://203.0.113.18/next" ->
          {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
      end
    end

    resolver = fn "rel.example.com" -> {:ok, [{203, 0, 113, 18}]} end

    assert {:ok, %Req.Response{status: 200}, "https://rel.example.com/next"} =
             WebGuard.guarded_get("https://rel.example.com/base/path",
               http_get: http_get,
               resolve_host: resolver,
               cacerts: [:dummy_cert]
             )

    assert_receive {:http_get, "https://203.0.113.18/base/path"}
    assert_receive {:http_get, "https://203.0.113.18/next"}
  end

  test "returns error when redirect is missing location header" do
    http_get = fn _url, _opts ->
      {:ok, %Req.Response{status: 302, headers: [{"x-test", "1"}], body: ""}}
    end

    resolver = fn "redir.example.com" -> {:ok, [{203, 0, 113, 19}]} end

    assert {:error, {:redirect_error, message}} =
             WebGuard.guarded_get("https://redir.example.com/start",
               http_get: http_get,
               resolve_host: resolver,
               cacerts: [:dummy_cert]
             )

    assert message =~ "Redirect missing location header"
  end

  test "enforces redirect limit" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:http_get, url})

      case url do
        "https://203.0.113.20/a" ->
          {:ok, %Req.Response{status: 302, headers: [{"location", "/b"}], body: ""}}

        "https://203.0.113.20/b" ->
          {:ok, %Req.Response{status: 302, headers: [{"location", "/c"}], body: ""}}
      end
    end

    resolver = fn "limit.example.com" -> {:ok, [{203, 0, 113, 20}]} end

    assert {:error, {:redirect_error, "Too many redirects (limit: 1)"}} =
             WebGuard.guarded_get("https://limit.example.com/a",
               http_get: http_get,
               resolve_host: resolver,
               max_redirects: 1,
               cacerts: [:dummy_cert]
             )

    assert_receive {:http_get, "https://203.0.113.20/a"}
    assert_receive {:http_get, "https://203.0.113.20/b"}
  end

  test "detects redirect loops" do
    http_get = fn url, _opts ->
      case url do
        "https://203.0.113.21/a" ->
          {:ok, %Req.Response{status: 302, headers: [{"location", "/b"}], body: ""}}

        "https://203.0.113.21/b" ->
          {:ok, %Req.Response{status: 302, headers: [{"location", "/a"}], body: ""}}
      end
    end

    resolver = fn "loop.example.com" -> {:ok, [{203, 0, 113, 21}]} end

    assert {:error, {:redirect_error, "Redirect loop detected"}} =
             WebGuard.guarded_get("https://loop.example.com/a",
               http_get: http_get,
               resolve_host: resolver,
               max_redirects: 5,
               cacerts: [:dummy_cert]
             )
  end

  test "blocks redirect targets that resolve to private IPs" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:http_get, url})

      {:ok,
       %Req.Response{
         status: 302,
         headers: [{"location", "http://private.example.com/secret"}],
         body: ""
       }}
    end

    resolver = fn
      "public.example.com" -> {:ok, [{203, 0, 113, 11}]}
      "private.example.com" -> {:ok, [{127, 0, 0, 1}]}
      _ -> {:error, :nxdomain}
    end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("http://public.example.com/start",
               http_get: http_get,
               resolve_host: resolver
             )

    assert message =~ "private/internal"
    assert_receive {:http_get, "http://203.0.113.11/start"}
    refute_receive {:http_get, "http://127.0.0.1/secret"}
  end

  test "allowed_hostnames permits explicitly allowlisted private targets" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts[:headers]})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn
      "internal.example.local" -> {:ok, [{127, 0, 0, 1}]}
      _ -> {:error, :nxdomain}
    end

    assert {:ok, %Req.Response{status: 200}, "http://internal.example.local/health"} =
             WebGuard.guarded_get("http://internal.example.local/health",
               http_get: http_get,
               resolve_host: resolver,
               allowed_hostnames: ["internal.example.local"]
             )

    assert_receive {:http_get, "http://127.0.0.1/health", headers}
    assert {"host", "internal.example.local"} in headers
  end

  test "allow_private_network permits localhost requests" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:http_get, url})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    assert {:ok, %Req.Response{status: 200}, "http://localhost/status"} =
             WebGuard.guarded_get("http://localhost/status",
               http_get: http_get,
               allow_private_network: true
             )

    assert_receive {:http_get, "http://127.0.0.1/status"}
  end

  test "blocks when any DNS result resolves to private IP" do
    resolver = fn
      "mixed.example.com" -> {:ok, [{203, 0, 113, 50}, {10, 0, 0, 5}]}
      _ -> {:error, :nxdomain}
    end

    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:ssrf_blocked, message}} =
             WebGuard.guarded_get("https://mixed.example.com/data",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message =~ "private/internal"
  end

  test "supports resolver returning string IPs" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:http_get, url})
      {:ok, %Req.Response{status: 200, headers: [], body: "ok"}}
    end

    resolver = fn "string-ip.example.com" -> {:ok, ["203.0.113.51"]} end

    assert {:ok, %Req.Response{status: 200}, _} =
             WebGuard.guarded_get("http://string-ip.example.com/ok",
               resolve_host: resolver,
               http_get: http_get
             )

    assert_receive {:http_get, "http://203.0.113.51/ok"}
  end

  test "resolver error is normalized to network_error" do
    resolver = fn "broken.example.com" -> {:error, :nxdomain} end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:network_error, message}} =
             WebGuard.guarded_get("http://broken.example.com/health",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message =~ "Unable to resolve hostname: broken.example.com"
    assert message =~ "nxdomain"
  end

  test "unexpected resolver payload is normalized to network_error" do
    resolver = fn "broken.example.com" -> :unexpected end
    http_get = fn _url, _opts -> flunk("http_get should not be called") end

    assert {:error, {:network_error, message}} =
             WebGuard.guarded_get("http://broken.example.com/health",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message =~ "unexpected resolver result"
  end

  test "transport errors from http_get are normalized" do
    resolver = fn "timeout.example.com" -> {:ok, [{203, 0, 113, 60}]} end
    http_get = fn _url, _opts -> {:error, :timeout} end

    assert {:error, {:network_error, "timeout"}} =
             WebGuard.guarded_get("http://timeout.example.com/data",
               resolve_host: resolver,
               http_get: http_get
             )
  end

  test "unexpected http_get response shape is normalized" do
    resolver = fn "shape.example.com" -> {:ok, [{203, 0, 113, 61}]} end
    http_get = fn _url, _opts -> :ok end

    assert {:error, {:network_error, message}} =
             WebGuard.guarded_get("http://shape.example.com/data",
               resolve_host: resolver,
               http_get: http_get
             )

    assert message =~ "Unexpected HTTP result"
  end

  test "ssrf_blocked?/1 identifies blocked error envelopes" do
    assert WebGuard.ssrf_blocked?({:ssrf_blocked, "blocked"}) == true
    assert WebGuard.ssrf_blocked?({:error, {:ssrf_blocked, "blocked"}}) == true
    assert WebGuard.ssrf_blocked?({:network_error, "timeout"}) == false
    assert WebGuard.ssrf_blocked?(:anything_else) == false
  end
end
