defmodule LemonWebTest do
  @moduledoc """
  Basic tests for the LemonWeb application.
  """
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest

  test "bundled favicon is served instead of producing a first-load router error" do
    conn = get(build_conn(), "/favicon.svg")
    assert response(conn, 200) =~ ~s|<svg xmlns="http://www.w3.org/2000/svg"|
  end

  test "static LiveView entrypoint uses vendored Phoenix assets" do
    static_root = Path.expand("../priv/static/assets", __DIR__)
    app_js = File.read!(Path.join(static_root, "app.js"))

    assert app_js =~ ~s|from "/assets/vendor/phoenix.mjs"|
    assert app_js =~ ~s|from "/assets/vendor/phoenix_live_view.esm.js"|
    refute app_js =~ "cdn.jsdelivr.net"
    assert File.exists?(Path.join(static_root, "vendor/phoenix.mjs"))
    assert File.exists?(Path.join(static_root, "vendor/phoenix_live_view.esm.js"))

    umbrella_root = Path.expand("../../..", __DIR__)

    assert File.read!(Path.join(static_root, "vendor/phoenix.mjs")) ==
             File.read!(Path.join(umbrella_root, "deps/phoenix/priv/static/phoenix.mjs"))

    assert File.read!(Path.join(static_root, "vendor/phoenix_live_view.esm.js")) ==
             File.read!(
               Path.join(
                 umbrella_root,
                 "deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js"
               )
             )

    assert File.exists?(Path.join(static_root, "vendor/highlight/highlight.min.js"))

    root_layout =
      Path.expand("../lib/lemon_web/components/layouts/root.html.heex", __DIR__)
      |> File.read!()

    assert root_layout =~ ~s|href={~p"/assets/app.css"}|
    refute root_layout =~ "session.css"
    refute root_layout =~ "management.css"
    assert root_layout =~ ~s|href="#main-content"|
    refute root_layout =~ "cdn.tailwindcss.com"
  end
end
