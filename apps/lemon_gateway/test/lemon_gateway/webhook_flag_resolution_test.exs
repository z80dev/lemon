defmodule LemonGateway.WebhookFlagResolutionTestOrchestrator do
  @behaviour LemonCore.RouterBridge.RunOrchestrator

  def submit(request) do
    send(Application.fetch_env!(:lemon_gateway, :webhook_flag_test_pid), {:flag_submit, request})
    {:ok, request.run_id}
  end
end

defmodule LemonGateway.WebhookFlagResolutionTest do
  @moduledoc """
  Per-integration webhook security flags are resolved at the real plug
  boundary: an explicit integration value (including `false`) wins over the
  global `[gateway.webhook]` value, and only an unset integration value inherits.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonGateway.Transports.Webhook
  alias LemonGateway.Transports.Webhook.{Config, Idempotency}
  alias Plug.Conn
  alias Plug.Test

  @token "flag-test-token"
  @config_key :gateway_test_config

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    if Process.whereis(Idempotency) == nil, do: start_supervised!(Idempotency)

    original_bridge = Application.get_env(:lemon_core, :router_bridge)
    original_pid = Application.get_env(:lemon_gateway, :webhook_flag_test_pid)
    Application.put_env(:lemon_gateway, :webhook_flag_test_pid, self())

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonGateway.WebhookFlagResolutionTestOrchestrator,
        router: original_bridge && original_bridge[:router]
      )

    original_config = Application.get_env(:lemon_core, @config_key)

    on_exit(fn ->
      Application.put_env(:lemon_core, @config_key, original_config)

      if original_bridge,
        do: Application.put_env(:lemon_core, :router_bridge, original_bridge),
        else: Application.delete_env(:lemon_core, :router_bridge)

      if original_pid,
        do: Application.put_env(:lemon_gateway, :webhook_flag_test_pid, original_pid),
        else: Application.delete_env(:lemon_gateway, :webhook_flag_test_pid)
    end)

    :ok
  end

  defp put_webhook_config(_ctx, global, integration_id, integration) do
    integration =
      Map.merge(%{agent_id: "webhook-test", mode: "async", token: @token}, integration)

    Application.put_env(:lemon_core, @config_key, %{
      webhook: Map.put(global, :integrations, %{integration_id => integration})
    })
  end

  defp integration_id, do: "flags-#{System.unique_integer([:positive])}"

  defp post(path, body, headers \\ []) do
    conn =
      Test.conn(:post, path, Jason.encode!(body))
      |> Conn.put_req_header("content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> Conn.put_req_header(acc, k, v) end)
    |> Webhook.call([])
  end

  describe "allow_query_token" do
    test "integration false overrides global true and rejects a query-string token", ctx do
      id = integration_id()
      put_webhook_config(ctx, %{allow_query_token: true}, id, %{allow_query_token: false})

      conn = post("/webhooks/#{id}?token=#{@token}", %{prompt: "hello"})

      assert conn.status == 401
      refute_receive {:flag_submit, _}
    end

    test "string-keyed integration false also overrides global true", ctx do
      id = integration_id()

      put_webhook_config(ctx, %{allow_query_token: true}, id, %{"allow_query_token" => "false"})

      conn = post("/webhooks/#{id}?token=#{@token}", %{prompt: "hello"})

      assert conn.status == 401
      refute_receive {:flag_submit, _}
    end

    test "unset integration value inherits global true", ctx do
      id = integration_id()
      put_webhook_config(ctx, %{allow_query_token: true}, id, %{})

      conn = post("/webhooks/#{id}?token=#{@token}", %{prompt: "hello"})

      assert conn.status == 202
      assert_receive {:flag_submit, _}
    end

    test "integration true overrides global false", ctx do
      id = integration_id()
      put_webhook_config(ctx, %{allow_query_token: false}, id, %{allow_query_token: true})

      conn = post("/webhooks/#{id}?token=#{@token}", %{prompt: "hello"})

      assert conn.status == 202
      assert_receive {:flag_submit, _}
    end

    test "unrecognised integration value fails closed instead of inheriting global true",
         ctx do
      id = integration_id()
      put_webhook_config(ctx, %{allow_query_token: true}, id, %{allow_query_token: "maybe"})

      conn = post("/webhooks/#{id}?token=#{@token}", %{prompt: "hello"})

      assert conn.status == 401
      refute_receive {:flag_submit, _}
    end
  end

  describe "allow_payload_token" do
    test "integration false overrides global true", ctx do
      id = integration_id()
      put_webhook_config(ctx, %{allow_payload_token: true}, id, %{allow_payload_token: false})

      conn = post("/webhooks/#{id}", %{prompt: "hello", token: @token})

      assert conn.status == 401
      refute_receive {:flag_submit, _}
    end
  end

  describe "allow_private_callback_hosts" do
    @private_callback "http://127.0.0.1:9/callback"

    test "integration false overrides global true and blocks a private callback at submit",
         ctx do
      id = integration_id()

      put_webhook_config(
        ctx,
        %{allow_callback_override: true, allow_private_callback_hosts: true},
        id,
        %{allow_private_callback_hosts: false}
      )

      conn =
        post(
          "/webhooks/#{id}",
          %{prompt: "hello", callback_url: @private_callback},
          [{"authorization", "Bearer #{@token}"}]
        )

      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "invalid callback url"
      refute_receive {:flag_submit, _}
    end

    test "integration false overrides global true for allow_callback_override", ctx do
      id = integration_id()

      put_webhook_config(
        ctx,
        %{allow_callback_override: true, allow_private_callback_hosts: true},
        id,
        %{allow_callback_override: false, callback_wait_timeout_ms: 50}
      )

      conn =
        post(
          "/webhooks/#{id}",
          %{prompt: "hello", callback_url: @private_callback},
          [{"authorization", "Bearer #{@token}"}]
        )

      assert conn.status == 202
      assert_receive {:flag_submit, _}
      # The payload callback was ignored: no callback waiter was armed.
      refute Map.has_key?(Jason.decode!(conn.resp_body), "callback")
    end

    test "unset integration value inherits global true", ctx do
      id = integration_id()

      put_webhook_config(
        ctx,
        %{allow_callback_override: true, allow_private_callback_hosts: true},
        id,
        %{callback_wait_timeout_ms: 50}
      )

      conn =
        post(
          "/webhooks/#{id}",
          %{prompt: "hello", callback_url: @private_callback},
          [{"authorization", "Bearer #{@token}"}]
        )

      assert conn.status == 202
      assert_receive {:flag_submit, _}
      assert Map.has_key?(Jason.decode!(conn.resp_body), "callback")
    end
  end

  describe "allow_payload_idempotency_key" do
    test "integration false overrides global true and ignores the payload key", ctx do
      id = integration_id()

      put_webhook_config(ctx, %{allow_payload_idempotency_key: true}, id, %{
        allow_payload_idempotency_key: false
      })

      body = %{prompt: "hello", idempotency_key: "payload-key-#{id}"}
      headers = [{"authorization", "Bearer #{@token}"}]

      assert post("/webhooks/#{id}", body, headers).status == 202
      assert_receive {:flag_submit, _}
      assert post("/webhooks/#{id}", body, headers).status == 202
      # Without the payload key both deliveries are independent submissions.
      assert_receive {:flag_submit, _}

      refute Enum.any?(Store.list(Idempotency.table()), fn {_k, v} ->
               is_map(v) and Map.get(v, :integration_id) == id
             end)
    end
  end

  test "config warning names an integration flag the global value would override unsafely" do
    log =
      capture_log(fn ->
        Config.warn_unsafe_integration_flags(%{
          allow_query_token: true,
          integrations: %{"demo" => %{allow_query_token: "nope"}}
        })
      end)

    assert log =~ "demo"
    assert log =~ "allow_query_token"
  end
end
