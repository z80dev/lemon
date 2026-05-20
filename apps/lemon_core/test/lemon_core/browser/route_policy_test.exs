defmodule LemonCore.Browser.RoutePolicyTest do
  use ExUnit.Case, async: true

  alias LemonCore.Browser.RoutePolicy

  describe "validate_navigation/2" do
    test "classifies public http navigation in auto mode" do
      assert {:ok, policy} = RoutePolicy.validate_navigation("https://example.com/path")

      assert policy.route == "auto"
      assert policy.effective_route == "public"
      assert policy.target_kind == "public_network"
      assert policy.scheme == "https"
      assert policy.private == false
      assert policy.metadata == false
    end

    test "classifies local documents as local navigation" do
      assert {:ok, policy} = RoutePolicy.validate_navigation("data:text/plain,hello")

      assert policy.effective_route == "local"
      assert policy.target_kind == "local_document"
      assert policy.private == true
    end

    test "blocks metadata endpoints in every route" do
      assert {:error, "browser navigation blocked metadata endpoint"} =
               RoutePolicy.validate_navigation(
                 "http://169.254.169.254/latest/meta-data",
                 "auto"
               )

      assert {:error, "browser navigation blocked metadata endpoint"} =
               RoutePolicy.validate_navigation("http://metadata.google.internal/", "local")
    end

    test "public route rejects private network targets" do
      assert {:error, "browser navigation requires a public http(s) URL"} =
               RoutePolicy.validate_navigation("http://127.0.0.1:4000", "public")
    end

    test "local route rejects public network targets" do
      assert {:error, "browser navigation requires a local or private URL"} =
               RoutePolicy.validate_navigation("https://example.com", "local")
    end

    test "rejects unsupported schemes and routes" do
      assert {:error, "unsupported browser navigation scheme: ftp"} =
               RoutePolicy.validate_navigation("ftp://example.com")

      assert {:error, "unsupported browser navigation route: external"} =
               RoutePolicy.validate_navigation("https://example.com", "external")
    end
  end

  describe "safe/1" do
    test "omits false and nil fields from public policy metadata" do
      assert {:ok, policy} = RoutePolicy.validate_navigation("https://example.com", "public")

      assert RoutePolicy.safe(policy) == %{
               "route" => "public",
               "effectiveRoute" => "public",
               "targetKind" => "public_network"
             }
    end

    test "keeps private and metadata fields when true" do
      assert {:ok, policy} = RoutePolicy.validate_navigation("file:///tmp/example.html", "local")

      assert RoutePolicy.safe(policy) == %{
               "route" => "local",
               "effectiveRoute" => "local",
               "targetKind" => "local_document",
               "private" => true
             }
    end
  end
end
