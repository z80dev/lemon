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
  alias LemonCore.RunRequest

  defmodule AcceptingRouter do
    @moduledoc false
    def submit(request) do
      send(self(), {:routed, request})
      {:ok, request.run_id}
    end
  end

  defmodule DeadRouter do
    @moduledoc false
    # Stands in for an orchestrator whose process is not running. RouterBridge
    # catches the exit and reports the mutation as outcome-unknown because the
    # callback may have applied a side effect before reaching the dead process.
    def submit(_request), do: exit({:noproc, {GenServer, :call, []}})
  end

  defmodule RejectingRouter do
    @moduledoc false
    def submit(request) do
      send(self(), {:routed, request})
      {:error, :rejected}
    end
  end

  defmodule AmbiguousRouter do
    @moduledoc false
    def submit(request) do
      send(self(), {:routed, request})
      {:error, :outcome_unknown}
    end
  end

  defmodule EmailWebhookBlockingRouter do
    @owner_key {__MODULE__, :owner}

    def set_owner(pid), do: :persistent_term.put(@owner_key, pid)
    def clear_owner, do: :persistent_term.erase(@owner_key)

    def submit(request) do
      send(:persistent_term.get(@owner_key), {:email_submit_blocked, request, self()})

      receive do
        {:release_email_submit, result} -> result
      end
    end
  end

  defmodule AcceptedStateWriteFailureStore do
    @moduledoc false
    alias LemonCore.Store

    def put_new(table, key, value), do: Store.put_new(table, key, value)
    def get(table, key), do: Store.get(table, key)

    def compare_and_swap(_table, _key, _expected, %{"state" => state})
        when state in ["accepted", "outcome_unknown"],
        do: {:error, :injected_write_failure}

    def compare_and_swap(table, key, expected, value),
      do: Store.compare_and_swap(table, key, expected, value)
  end

  defmodule RejectStateWriteFailureStore do
    @moduledoc false
    alias LemonCore.Store

    def put_new(table, key, value), do: Store.put_new(table, key, value)
    def get(table, key), do: Store.get(table, key)

    def compare_and_swap(_table, _key, _expected, %{"state" => "rejected"}),
      do: {:error, :injected_write_failure}

    def compare_and_swap(table, key, expected, value),
      do: Store.compare_and_swap(table, key, expected, value)

    def put(_table, _key, %{"state" => "rejected"}), do: {:error, :injected_write_failure}
    def put(table, key, value), do: Store.put(table, key, value)
  end

  setup do
    previous_email = Application.get_env(:lemon_channels, Email)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_store = Application.get_env(:lemon_channels, :email_webhook_store)

    on_exit(fn ->
      restore(:lemon_channels, Email, previous_email)
      restore(:lemon_core, :router_bridge, previous_bridge)
      restore(:lemon_channels, :email_webhook_store, previous_store)
      EmailWebhookBlockingRouter.clear_owner()
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp route_to(module) do
    previous = Application.get_env(:lemon_core, :router_bridge, %{})

    Application.put_env(
      :lemon_core,
      :router_bridge,
      previous |> Map.put(:router, module) |> Map.put(:run_orchestrator, module)
    )
  end

  defp configure(opts), do: Application.put_env(:lemon_channels, Email, opts)

  defp request(headers) do
    Enum.reduce(headers, conn(:post, "/email", ""), fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
  end

  defp authorized_payload(message_id \\ nil) do
    message_id = message_id || "webhook-#{System.unique_integer([:positive])}@example.com"

    :post
    |> conn("/email", "")
    |> put_req_header("x-webhook-token", "s3cret")
    |> Map.put(:body_params, %{
      "from" => "sender@example.com",
      "to" => "agent@lemon.test",
      "subject" => "hello",
      "text" => "anyone home?",
      "message_id" => "<#{message_id}>"
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
      assert_received {:routed, %RunRequest{origin: :channel, run_id: run_id}}
      assert String.starts_with?(run_id, "run_email_")
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

    test "suppresses redelivery when the router process dies after dispatch begins" do
      configure(webhook_token: "s3cret")
      route_to(DeadRouter)

      conn = Webhook.handle_inbound(authorized_payload())

      assert conn.status == 200
      assert conn.resp_body == "outcome unknown"
    end

    test "asks for redelivery when the router explicitly rejects submission" do
      configure(webhook_token: "s3cret")
      route_to(RejectingRouter)
      message_id = "retryable@example.com"

      conn = Webhook.handle_inbound(authorized_payload(message_id))

      assert conn.status == 503
      assert conn.resp_body == "unavailable"
      assert_received {:routed, %RunRequest{run_id: run_id}}

      route_to(AcceptingRouter)
      retry_conn = Webhook.handle_inbound(authorized_payload(message_id))

      assert retry_conn.status == 202
      assert_received {:routed, %RunRequest{run_id: ^run_id}}
    end

    test "failed rejection persistence remains retryable through the reservation lease" do
      configure(webhook_token: "s3cret")
      route_to(RejectingRouter)
      Application.put_env(:lemon_channels, :email_webhook_store, RejectStateWriteFailureStore)
      message_id = "lease-retry@example.com"

      first = Webhook.handle_inbound(authorized_payload(message_id))
      assert first.status == 503
      assert_received {:routed, %RunRequest{run_id: run_id}}

      pending = Webhook.handle_inbound(authorized_payload(message_id))
      assert pending.status == 503
      refute_received {:routed, _request}

      digest = Base.encode16(:crypto.hash(:sha256, message_id), case: :lower)
      entry = LemonCore.Store.get(:email_inbound_idempotency, digest)

      assert :ok =
               LemonCore.Store.put(
                 :email_inbound_idempotency,
                 digest,
                 Map.put(entry, "lease_expires_at_ms", 0)
               )

      route_to(AcceptingRouter)
      retry_conn = Webhook.handle_inbound(authorized_payload(message_id))
      assert retry_conn.status == 202
      assert_received {:routed, %RunRequest{run_id: ^run_id}}
    end

    test "accepted handoff fails closed when its durable receipt cannot be written" do
      configure(webhook_token: "s3cret")
      route_to(AcceptingRouter)
      Application.put_env(:lemon_channels, :email_webhook_store, AcceptedStateWriteFailureStore)
      message_id = "accepted-write-failure@example.com"

      first = Webhook.handle_inbound(authorized_payload(message_id))
      assert first.status == 503
      assert_received {:routed, %RunRequest{run_id: run_id}}

      digest = Base.encode16(:crypto.hash(:sha256, message_id), case: :lower)

      assert %{"state" => "pending", "run_id" => ^run_id} =
               LemonCore.Store.get(:email_inbound_idempotency, digest)

      pending = Webhook.handle_inbound(authorized_payload(message_id))
      assert pending.status == 503
      refute_received {:routed, _request}
    end

    test "a stale reservation owner cannot overwrite a reclaimed accepted receipt" do
      configure(webhook_token: "s3cret")
      route_to(EmailWebhookBlockingRouter)
      EmailWebhookBlockingRouter.set_owner(self())
      message_id = "stale-owner@example.com"

      first_task = Task.async(fn -> Webhook.handle_inbound(authorized_payload(message_id)) end)
      assert_receive {:email_submit_blocked, %RunRequest{run_id: run_id}, first_runner}, 500

      digest = Base.encode16(:crypto.hash(:sha256, message_id), case: :lower)
      first_entry = LemonCore.Store.get(:email_inbound_idempotency, digest)

      assert :ok =
               LemonCore.Store.put(
                 :email_inbound_idempotency,
                 digest,
                 Map.put(first_entry, "lease_expires_at_ms", 0)
               )

      second_task = Task.async(fn -> Webhook.handle_inbound(authorized_payload(message_id)) end)
      assert_receive {:email_submit_blocked, %RunRequest{run_id: ^run_id}, second_runner}, 500

      send(second_runner, {:release_email_submit, {:ok, run_id}})
      assert Task.await(second_task, 1_000).status == 202
      accepted_entry = LemonCore.Store.get(:email_inbound_idempotency, digest)
      assert accepted_entry["state"] == "accepted"
      refute accepted_entry["reservation_id"] == first_entry["reservation_id"]

      send(first_runner, {:release_email_submit, {:ok, run_id}})
      assert Task.await(first_task, 1_000).status == 503
      assert LemonCore.Store.get(:email_inbound_idempotency, digest) == accepted_entry
    end

    test "rejects a routable payload without a Message-ID before submission" do
      configure(webhook_token: "s3cret")
      route_to(AcceptingRouter)

      conn =
        authorized_payload("temporary@example.com")
        |> Map.update!(:body_params, &Map.delete(&1, "message_id"))
        |> Webhook.handle_inbound()

      assert conn.status == 400
      assert conn.resp_body == "missing message id"
      refute_received {:routed, _request}
    end

    test "returns a truthful non-retry receipt and deduplicates an ambiguous handoff" do
      configure(webhook_token: "s3cret")
      route_to(AmbiguousRouter)
      message_id = "ambiguous@example.com"

      conn = Webhook.handle_inbound(authorized_payload(message_id))

      assert conn.status == 200
      assert conn.resp_body == "outcome unknown"
      assert_received {:routed, %RunRequest{run_id: run_id}}
      assert String.starts_with?(run_id, "run_email_")

      route_to(AcceptingRouter)
      duplicate_conn = Webhook.handle_inbound(authorized_payload(message_id))

      assert duplicate_conn.status == 200
      assert duplicate_conn.resp_body == "outcome unknown"
      refute_received {:routed, _request}
    end

    test "replays the accepted receipt without submitting the same Message-ID twice" do
      configure(webhook_token: "s3cret")
      route_to(AcceptingRouter)
      message_id = "accepted-duplicate@example.com"

      first_conn = Webhook.handle_inbound(authorized_payload(message_id))

      assert first_conn.status == 202
      assert_received {:routed, %RunRequest{run_id: run_id}}

      duplicate_conn = Webhook.handle_inbound(authorized_payload(message_id))

      assert duplicate_conn.status == 202
      assert duplicate_conn.resp_body == "accepted"
      refute_received {:routed, _request}
      assert String.starts_with?(run_id, "run_email_")
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
