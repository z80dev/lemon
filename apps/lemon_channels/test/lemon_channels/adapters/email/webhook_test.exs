defmodule LemonChannels.Adapters.Email.WebhookTest do
  @moduledoc """
  The inbound endpoint's one decision: whether to accept a request at all.

  An open mail endpoint is a spam relay into someone's agent, so the failure
  mode that matters is not "rejects a good request" but "accepts a bad one" —
  most of these tests are about the second.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias LemonChannels.Adapters.Email
  alias LemonChannels.Adapters.Email.Webhook
  alias LemonChannels.InboundHttp.Router

  defmodule AcceptingRouter do
    @moduledoc false
    def handle_inbound(message) do
      send(self(), {:routed, message})
      :ok
    end
  end

  defmodule DeadRouter do
    @moduledoc false
    # Stands in for a router that is configured but whose process is not
    # running: `GenServer.call` to a dead named process exits, and an exit is
    # not an exception, so `RouterBridge` does not convert it.
    def handle_inbound(_message), do: exit({:noproc, {GenServer, :call, []}})
  end

  setup do
    previous_email = Application.get_env(:lemon_channels, Email)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)

    on_exit(fn ->
      restore(:lemon_channels, Email, previous_email)
      restore(:lemon_core, :router_bridge, previous_bridge)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp route_to(module) do
    previous = Application.get_env(:lemon_core, :router_bridge, %{})
    Application.put_env(:lemon_core, :router_bridge, Map.put(previous, :router, module))
  end

  defp configure(opts), do: Application.put_env(:lemon_channels, Email, opts)

  defp request(headers) do
    Enum.reduce(headers, conn(:post, "/email", ""), fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
  end

  defp authorized_payload do
    :post
    |> conn("/email", "")
    |> put_req_header("x-webhook-token", "s3cret")
    |> Map.put(:body_params, %{
      "from" => "sender@example.com",
      "to" => "agent@lemon.test",
      "subject" => "hello",
      "text" => "anyone home?",
      "message_id" => "<webhook-#{System.unique_integer([:positive])}@example.com>"
    })
  end

  describe "the pre-parse auth callback is actually wired" do
    # `LemonChannels.InboundHttp.Router` finds this callback with
    # `function_exported?/3` and, finding none, lets the request through to be
    # parsed — the right default for handlers that sign over the body. The cost
    # of that default is that making `authorized?/1` private here would not
    # break anything loudly: it would downgrade this endpoint from
    # authenticate-then-parse to parse-then-authenticate, with only a compile
    # warning to say so. These two tests are what makes that loud.

    test "authorized?/1 is public, so the router can see it" do
      # `function_exported?/3` answers false for a module that has not been
      # loaded yet, which makes this assertion depend on whatever ran before it.
      # Load it first so the test measures the export and not the load order.
      {:module, Webhook} = Code.ensure_loaded(Webhook)

      assert function_exported?(Webhook, :authorized?, 1),
             "authorized?/1 must be `def`, not `defp` — the router resolves it " <>
               "with function_exported?/3 and silently allows the request when it is missing"
    end

    test "an unauthorized request is refused before its body is parsed" do
      # End-to-end through the real router, with a body that `Plug.Parsers`
      # cannot parse. A clean 401 proves auth ran first; if parsing ran first
      # this raises instead.
      configure(webhook_token: "s3cret")
      :ok = LemonChannels.InboundHttp.register("email", Webhook)

      on_exit(fn ->
        if pid = Process.whereis(LemonChannels.InboundHttp.Routes) do
          Agent.update(pid, &Map.delete(&1, "email"))
        end
      end)

      conn =
        :post
        |> conn("/email", "{ this is not json")
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 401
      assert conn.resp_body == "unauthorized"
    end
  end

  describe "authorized?/1" do
    test "rejects everything when no token is configured" do
      configure([])

      refute Webhook.authorized?(request([]))
      refute Webhook.authorized?(request([{"x-webhook-token", "guess"}]))
    end

    test "accepts the configured token" do
      configure(webhook_token: "s3cret")

      assert Webhook.authorized?(request([{"x-webhook-token", "s3cret"}]))
    end

    test "rejects a wrong token, including a prefix of the real one" do
      configure(webhook_token: "s3cret")

      refute Webhook.authorized?(request([{"x-webhook-token", "s3cre"}]))
      refute Webhook.authorized?(request([{"x-webhook-token", "s3crets"}]))
      refute Webhook.authorized?(request([{"x-webhook-token", ""}]))
      refute Webhook.authorized?(request([]))
    end

    test "a blank configured token counts as no token, not as a valid empty one" do
      configure(webhook_token: "   ")

      refute Webhook.authorized?(request([{"x-webhook-token", "   "}]))
      refute Webhook.authorized?(request([]))
    end

    test "map-shaped config degrades to unconfigured instead of raising" do
      # Config can arrive as a map from the TOML layer. Reading it must not
      # raise: an exception here would surface as a 500, telling a caller their
      # unauthenticated request hit something real.
      configure(%{webhook_token: "s3cret"})

      assert Webhook.authorized?(request([{"x-webhook-token", "s3cret"}]))
    end
  end

  describe "handle_inbound/1" do
    test "answers 401 without touching the payload when unauthorized" do
      configure([])

      conn = Webhook.handle_inbound(request([]))

      assert conn.status == 401
      assert conn.resp_body == "unauthorized"
    end

    test "accepts an authorized, well-formed payload with 202" do
      configure(webhook_token: "s3cret")
      route_to(AcceptingRouter)

      conn = Webhook.handle_inbound(authorized_payload())

      # 202 rather than 200: the provider's job is done once the message is
      # taken; whether a run results is not something it should wait on.
      assert conn.status == 202
      assert_received {:routed, %LemonCore.InboundMessage{channel_id: "email"}}
    end

    test "asks for redelivery when the router is not wired at all" do
      configure(webhook_token: "s3cret")
      route_to(nil)

      conn = Webhook.handle_inbound(authorized_payload())

      # Not 202: the message is gone, and telling the provider "accepted" is
      # how mail goes missing silently.
      assert conn.status == 503
      assert conn.resp_body == "unavailable"
    end

    test "asks for redelivery when the router is wired but its process is dead" do
      # The case `RouterBridge` cannot report on its own: it rescues exceptions,
      # and this is an exit. Left unhandled it reaches the listener's catch-all
      # and the provider gets an opaque 500.
      configure(webhook_token: "s3cret")
      route_to(DeadRouter)

      conn = Webhook.handle_inbound(authorized_payload())

      assert conn.status == 503
    end

    test "answers 400 for an authorized payload it cannot make sense of" do
      configure(webhook_token: "s3cret")

      conn =
        :post
        |> conn("/email", "")
        |> put_req_header("x-webhook-token", "s3cret")
        |> Map.put(:body_params, %{"subject" => "no sender anywhere"})
        |> Webhook.handle_inbound()

      assert conn.status == 400
    end
  end
end
