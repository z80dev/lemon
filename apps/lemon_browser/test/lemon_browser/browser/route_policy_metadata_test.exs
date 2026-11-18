defmodule LemonBrowser.RoutePolicyMetadataTest do
  use ExUnit.Case, async: true

  alias LemonBrowser.RoutePolicy

  @blocked "browser navigation blocked metadata endpoint"
  @routes ["auto", "public", "local"]

  defp public_resolver(_host), do: {:ok, [{93, 184, 215, 14}]}

  describe "metadata address aliases" do
    for url <- [
          "http://2852039166/",
          "http://0xa9fea9fe/",
          "http://0251.0376.0251.0376/",
          "http://169.254.43518/",
          "http://[::ffff:169.254.169.254]/",
          "http://[::ffff:a9fe:a9fe]/",
          "http://169.254.169.254./",
          "http://METADATA.google.internal./",
          "http://[fd00:ec2::254]/",
          "http://169.254.1.1/",
          "http://[fe80::1]/"
        ] do
      test "#{url} is refused on every route" do
        for route <- @routes do
          assert {:error, @blocked} =
                   RoutePolicy.validate_navigation(unquote(url), route,
                     resolve_host: &public_resolver/1
                   ),
                 "route #{route} allowed #{unquote(url)}"
        end
      end
    end

    test "IPv4-mapped loopback is classified private, not public" do
      assert {:error, "browser navigation requires a public http(s) URL"} =
               RoutePolicy.validate_navigation("http://[::ffff:127.0.0.1]/", "public")

      assert {:ok, %{private: true}} =
               RoutePolicy.validate_navigation("http://[::ffff:7f00:1]/", "local")
    end
  end

  describe "DNS resolution" do
    test "hostname whose answers include a metadata address is refused on every route" do
      resolver = fn
        "rebind.example" -> {:ok, [{93, 184, 215, 14}, {169, 254, 169, 254}]}
      end

      for route <- @routes do
        assert {:error, @blocked} =
                 RoutePolicy.validate_navigation("http://rebind.example/", route,
                   resolve_host: resolver
                 )
      end
    end

    test "hostname resolving to IPv4-mapped metadata is refused" do
      resolver = fn _ -> {:ok, [{0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}]} end

      assert {:error, @blocked} =
               RoutePolicy.validate_navigation("http://v6.example/", "auto",
                 resolve_host: resolver
               )
    end

    test "hostname resolving to a private address is private, not public" do
      resolver = fn _ -> {:ok, [{10, 0, 0, 5}]} end

      assert {:error, "browser navigation requires a public http(s) URL"} =
               RoutePolicy.validate_navigation("http://intranet.example/", "public",
                 resolve_host: resolver
               )

      assert {:ok, %{effective_route: "local", private: true}} =
               RoutePolicy.validate_navigation("http://intranet.example/", "auto",
                 resolve_host: resolver
               )
    end

    test "resolution failure is refused under auto" do
      resolver = fn _ -> {:error, :nxdomain} end

      assert {:error, "browser navigation could not resolve host: nowhere.example"} =
               RoutePolicy.validate_navigation("http://nowhere.example/", "auto",
                 resolve_host: resolver
               )
    end

    test "public hostname resolving to public addresses stays public" do
      assert {:ok, %{effective_route: "public", private: false}} =
               RoutePolicy.validate_navigation("https://example.com/", "auto",
                 resolve_host: &public_resolver/1
               )
    end
  end
end
