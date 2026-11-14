defmodule LemonGateway.DrainGuardTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias LemonGateway.DrainGuard

  test "a draining runtime refuses webhook work with 503 and Retry-After" do
    conn =
      DrainGuard.call(conn(:post, "/webhooks/abc"), DrainGuard.init(draining?: fn -> true end))

    assert conn.halted
    assert conn.status == 503
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["30"]
  end

  test "a serving runtime passes the request through" do
    conn =
      DrainGuard.call(conn(:post, "/webhooks/abc"), DrainGuard.init(draining?: fn -> false end))

    refute conn.halted
    assert conn.status == nil
  end
end
