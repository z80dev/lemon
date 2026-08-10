defmodule LemonChannels.InboundHttpTest do
  @moduledoc """
  Covers the listener's two jobs: staying out of the way when unconfigured, and
  routing to the right adapter when it is. The router is exercised directly
  through `Plug.Test` so the tests never bind a port.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias LemonChannels.InboundHttp
  alias LemonChannels.InboundHttp.Router

  defmodule EchoHandler do
    @moduledoc false
    @behaviour LemonChannels.InboundHttp.Handler

    @impl true
    def handle_inbound(conn) do
      Plug.Conn.send_resp(conn, 200, "echo:#{inspect(conn.body_params["hello"])}")
    end
  end

  defmodule CrashHandler do
    @moduledoc false
    @behaviour LemonChannels.InboundHttp.Handler

    @impl true
    def handle_inbound(_conn), do: raise("boom")
  end

  defmodule TokenHandler do
    @moduledoc false
    @behaviour LemonChannels.InboundHttp.Handler

    @impl true
    def authorized?(conn) do
      Plug.Conn.get_req_header(conn, "x-token") == ["let-me-in"]
    end

    @impl true
    def handle_inbound(conn) do
      # Records that parsing happened, so a test can prove it did *not* happen
      # for an unauthorized caller.
      send(self(), {:parsed, conn.body_params})
      Plug.Conn.send_resp(conn, 200, "ok")
    end
  end

  defmodule CrashingAuthHandler do
    @moduledoc false
    @behaviour LemonChannels.InboundHttp.Handler

    @impl true
    def authorized?(_conn), do: raise("auth exploded")

    @impl true
    def handle_inbound(conn), do: Plug.Conn.send_resp(conn, 200, "should never happen")
  end

  setup do
    # The Agent is started by the InboundHttp supervisor; registrations are
    # global, so clean up whatever a test adds.
    on_exit(fn ->
      if pid = Process.whereis(LemonChannels.InboundHttp.Routes) do
        Agent.update(pid, fn _ -> %{} end)
      end
    end)

    :ok
  end

  describe "configuration" do
    test "is disabled by default so nothing binds a port" do
      refute InboundHttp.enabled?()
    end

    test "defaults to loopback rather than all interfaces" do
      assert InboundHttp.ip() == {127, 0, 0, 1}
    end

    test "reads enabled/port/ip from app env" do
      original = Application.get_env(:lemon_channels, InboundHttp)

      Application.put_env(:lemon_channels, InboundHttp,
        enabled: true,
        port: 4099,
        ip: {0, 0, 0, 0}
      )

      on_exit(fn ->
        if original do
          Application.put_env(:lemon_channels, InboundHttp, original)
        else
          Application.delete_env(:lemon_channels, InboundHttp)
        end
      end)

      assert InboundHttp.enabled?()
      assert InboundHttp.port() == 4099
      assert InboundHttp.ip() == {0, 0, 0, 0}
    end
  end

  describe "registration" do
    test "registers and resolves a handler by path segment" do
      assert :ok = InboundHttp.register("echo", EchoHandler)
      assert InboundHttp.handler_for("echo") == EchoHandler
      assert InboundHttp.handlers()["echo"] == EchoHandler
    end

    test "returns nil for an unregistered segment" do
      assert InboundHttp.handler_for("nope") == nil
    end

    test "re-registering a segment replaces the handler" do
      assert :ok = InboundHttp.register("echo", EchoHandler)
      assert :ok = InboundHttp.register("echo", CrashHandler)
      assert InboundHttp.handler_for("echo") == CrashHandler
    end
  end

  describe "routing" do
    test "dispatches to the handler registered for the first path segment" do
      :ok = InboundHttp.register("echo", EchoHandler)

      conn =
        :post
        |> conn("/echo/anything", Jason.encode!(%{"hello" => "world"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      assert conn.resp_body == ~s(echo:"world")
    end

    test "answers 404 for an unregistered segment" do
      conn = Router.call(conn(:post, "/unregistered", ""), Router.init([]))

      assert conn.status == 404
    end

    test "serves a health endpoint without any registration" do
      conn = Router.call(conn(:get, "/health"), Router.init([]))

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "a crashing handler becomes a 500 and leaks nothing to the caller" do
      :ok = InboundHttp.register("crash", CrashHandler)

      conn = Router.call(conn(:post, "/crash", ""), Router.init([]))

      assert conn.status == 500
      assert conn.resp_body == "internal error"
      refute conn.resp_body =~ "boom"
    end
  end

  describe "authenticating before the body is parsed" do
    setup do
      :ok = InboundHttp.register("token", TokenHandler)
    end

    test "lets an authorized request through to the handler" do
      conn =
        :post
        |> conn("/token", Jason.encode!(%{"hello" => "world"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-token", "let-me-in")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      assert_received {:parsed, %{"hello" => "world"}}
    end

    test "rejects an unauthorized request without parsing its body" do
      # The point of the callback: the 401 costs one header comparison, not a
      # decode of whatever the caller chose to send.
      conn =
        :post
        |> conn("/token", Jason.encode!(%{"hello" => "world"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 401
      assert conn.resp_body == "unauthorized"
      refute_received {:parsed, _}
    end

    test "a handler that raises while authenticating is not authorized" do
      :ok = InboundHttp.register("badauth", CrashingAuthHandler)

      conn = Router.call(conn(:post, "/badauth", ""), Router.init([]))

      assert conn.status == 401
    end

    test "a handler with no pre-parse check is still reached" do
      # Signature-over-body schemes cannot authenticate this early, so omitting
      # the callback must mean "check later", not "deny".
      :ok = InboundHttp.register("echo", EchoHandler)

      conn =
        :post
        |> conn("/echo", Jason.encode!(%{"hello" => "world"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 200
    end

    test "an unauthorized request to an unregistered segment is still a 404" do
      conn = Router.call(conn(:post, "/nothing-here", ""), Router.init([]))

      assert conn.status == 404
    end
  end

  describe "body limit" do
    setup do
      previous = Application.get_env(:lemon_channels, InboundHttp)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:lemon_channels, InboundHttp)
          value -> Application.put_env(:lemon_channels, InboundHttp, value)
        end
      end)

      :ok
    end

    test "defaults well under Plug.Parsers' own 8 MB" do
      assert InboundHttp.max_body_bytes() == 2_000_000
    end

    test "is configurable, and read per request rather than at compile time" do
      Application.put_env(:lemon_channels, InboundHttp, max_body_bytes: 64)
      assert InboundHttp.max_body_bytes() == 64

      :ok = InboundHttp.register("echo", EchoHandler)

      body = Jason.encode!(%{"hello" => String.duplicate("x", 200)})

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        :post
        |> conn("/echo", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))
      end
    end

    test "ignores a nonsensical configured value rather than removing the limit" do
      for value <- [0, -1, "big", nil] do
        Application.put_env(:lemon_channels, InboundHttp, max_body_bytes: value)
        assert InboundHttp.max_body_bytes() == 2_000_000
      end
    end
  end
end
