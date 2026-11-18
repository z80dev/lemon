defmodule LemonBrowser.RoutePolicySsrfTest do
  use ExUnit.Case, async: true

  alias LemonBrowser.RoutePolicy

  @public [resolve_host: &__MODULE__.public_resolver/1]

  def public_resolver(_host), do: {:ok, [{93, 184, 216, 34}]}

  test "metadata aliases, IPv4-mapped and 6to4 targets are never public and metadata is blocked" do
    for url <- [
          "http://2852039166/",
          "http://0xA9FEA9FE/",
          "http://[::ffff:169.254.169.254]/",
          "http://[2002:a9fe:a9fe::]/",
          "http://metadata.google.internal/"
        ] do
      for route <- ["auto", "public", "local"] do
        assert {:error, "browser navigation blocked metadata endpoint"} =
                 RoutePolicy.validate_navigation(url, route, @public),
               "#{url} #{route}"
      end
    end

    for url <- ["http://[2002:7f00:0001::]/", "http://[2002:0a00:0001::1]/"] do
      assert {:error, _} = RoutePolicy.validate_navigation(url, "public", @public), url
      assert {:ok, %{private: true}} = RoutePolicy.validate_navigation(url, "local", @public), url
    end
  end

  test "hostnames whose answers include a 6to4 metadata address are blocked" do
    resolver = fn _ -> {:ok, [{93, 184, 216, 34}, {0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 0}]} end

    assert {:error, "browser navigation blocked metadata endpoint"} =
             RoutePolicy.validate_navigation("https://rebind.example/", "auto",
               resolve_host: resolver
             )
  end
end
