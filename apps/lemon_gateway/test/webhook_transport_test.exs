defmodule LemonGateway.WebhookTransportTestOrchestrator do
  @behaviour LemonCore.RouterBridge.RunOrchestrator

  def submit(request) do
    send(
      Application.fetch_env!(:lemon_gateway, :webhook_transport_test_pid),
      {:webhook_submit, request}
    )

    case Application.fetch_env!(:lemon_gateway, :webhook_transport_submit_result) do
      {:raise, message} -> raise message
      result -> result
    end
  end
end

defmodule LemonGateway.WebhookTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonGateway.Transports.Webhook
  alias LemonGateway.Transports.Webhook.{Idempotency, InvocationDispatch, ResponseBuilder}
  alias Plug.Conn
  alias Plug.Test

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)

    original_webhook_env = Application.get_env(:lemon_gateway, :webhook)
    original_override = Application.get_env(:lemon_gateway, LemonGateway.Config)
    original_bridge = Application.get_env(:lemon_core, :router_bridge)
    original_test_pid = Application.get_env(:lemon_gateway, :webhook_transport_test_pid)

    original_submit_result =
      Application.get_env(:lemon_gateway, :webhook_transport_submit_result)

    clear_idempotency_table()

    Application.delete_env(:lemon_gateway, :webhook)
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
    Application.put_env(:lemon_gateway, :webhook_transport_test_pid, self())

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:ok, "run-webhook-default"}
    )

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonGateway.WebhookTransportTestOrchestrator,
        router: original_bridge && original_bridge[:router]
      )

    on_exit(fn ->
      restore_env(:lemon_gateway, :webhook, original_webhook_env)
      restore_env(:lemon_gateway, LemonGateway.Config, original_override)
      restore_env(:lemon_core, :router_bridge, original_bridge)
      restore_env(:lemon_gateway, :webhook_transport_test_pid, original_test_pid)

      restore_env(
        :lemon_gateway,
        :webhook_transport_submit_result,
        original_submit_result
      )

      clear_idempotency_table()
    end)

    :ok
  end

  test "ambiguous submission returns a non-retryable HTTP receipt without claiming acceptance" do
    run_id = "run-webhook-unknown-#{System.unique_integer([:positive])}"

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:error, :outcome_unknown}
    )

    assert {:ok, run_ctx} = dispatch_webhook(run_id, nil)
    assert_receive {:webhook_submit, %{run_id: ^run_id}}

    assert {:ok, 200, payload} = ResponseBuilder.response_for_run(run_ctx)
    assert payload.run_id == run_id
    assert payload.status == "outcome_unknown"
    assert payload.retry_safe == false
    refute Map.has_key?(payload, :accepted)
    refute_receive {:webhook_submit, _request}
  end

  test "idempotency-key redelivery replays an ambiguous receipt without resubmission" do
    integration_id = "demo-unknown-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-unknown-#{System.unique_integer([:positive])}"
    run_id = "run-webhook-unknown-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, idempotency_ctx} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:error, :outcome_unknown}
    )

    assert {:ok, run_ctx} = dispatch_webhook(run_id, idempotency_ctx, integration_id)
    assert_receive {:webhook_submit, %{run_id: ^run_id}}
    assert {:ok, 200, payload} = ResponseBuilder.response_for_run(run_ctx)

    assert {:duplicate, 202, pending_payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert pending_payload.run_id == run_id
    assert pending_payload.status == "outcome_unknown"
    assert pending_payload.retry_safe == false

    assert :ok = Idempotency.store_response(idempotency_ctx, 200, payload)

    assert {:duplicate, 200, ^payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    refute_receive {:webhook_submit, _request}
  end

  test "submission exceptions and explicit rejection terms cannot expose adversarial secrets" do
    secret = "webhook-router-secret-#{System.unique_integer([:positive])}"
    run_id = "run-webhook-secret-#{System.unique_integer([:positive])}"

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:raise, secret}
    )

    log =
      capture_log(fn ->
        assert {:ok, run_ctx} = dispatch_webhook(run_id, nil)
        assert {:ok, 200, payload} = ResponseBuilder.response_for_run(run_ctx)
        assert payload.status == "outcome_unknown"
        refute inspect(payload) =~ secret
      end)

    assert_receive {:webhook_submit, %{run_id: ^run_id}}
    refute log =~ secret

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:error, {:rejected_with_secret, secret}}
    )

    assert {:error, :submit_rejected} = dispatch_webhook(run_id <> "-rejected", nil)
    assert_receive {:webhook_submit, %{run_id: rejected_run_id}}
    assert rejected_run_id == run_id <> "-rejected"
    refute_receive {:webhook_submit, _request}
  end

  test "idempotency helper reserves key and returns processing duplicate while pending" do
    integration_id = "demo-pending-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-pending-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, %{store_key: store_key}} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert %{} = Store.get(Webhook.idempotency_table_for_test(), store_key)

    assert {:duplicate, 202, response_payload} =
             Webhook.idempotency_context_for_test(conn, %{}, integration_id, %{})

    assert response_payload.status == "processing"
  end

  test "normalizes prompt, attachments, and metadata from webhook payloads" do
    payload = %{
      "content" => %{"text" => "Ship this"},
      "files" => [%{"name" => "spec.txt", "url" => "https://example.test/spec.txt"}],
      "urls" => ["https://example.test/mock.png"],
      "metadata" => %{"source" => "zapier", "workflow_id" => "wf_123"}
    }

    assert {:ok, normalized} = Webhook.normalize_payload_for_test(payload)
    assert normalized.prompt =~ "Ship this"
    assert normalized.prompt =~ "Attachments:"
    assert normalized.prompt =~ "https://example.test/spec.txt"
    assert normalized.prompt =~ "https://example.test/mock.png"
    assert length(normalized.attachments) == 2
    assert normalized.metadata["source"] == "zapier"
    assert normalized.metadata["workflow_id"] == "wf_123"
  end

  test "secure token compare accepts exact match and rejects mismatches" do
    assert Webhook.secure_compare_for_test("secret-token", "secret-token")
    refute Webhook.secure_compare_for_test("secret-token", "secret-token-2")
    refute Webhook.secure_compare_for_test("secret-token", nil)
    refute Webhook.secure_compare_for_test(nil, "secret-token")
  end

  test "callback success status only accepts HTTP 2xx" do
    assert Webhook.callback_success_status_for_test(200)
    assert Webhook.callback_success_status_for_test(204)
    assert Webhook.callback_success_status_for_test(299)

    refute Webhook.callback_success_status_for_test(199)
    refute Webhook.callback_success_status_for_test(300)
    refute Webhook.callback_success_status_for_test(500)
  end

  test "callback URL validation enforces canonicalization, scheme, and private host policy" do
    public_dns = fn _host -> [] end

    assert {:ok, "https://example.test/callback"} =
             Webhook.validate_callback_url_for_test("https://EXAMPLE.TEST./callback", false,
               dns_resolver: public_dns
             )

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("ftp://example.test/callback", false,
               dns_resolver: public_dns
             )

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("http://localhost./callback", false)

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("http://127.0.0.1/callback", false)

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("http://[::ffff:127.0.0.1]/callback", false)

    assert {:ok, "http://127.0.0.1/callback"} =
             Webhook.validate_callback_url_for_test("http://127.0.0.1/callback", true)

    private_dns = fn
      "internal.example" -> [{10, 1, 2, 3}, {93, 184, 216, 34}]
      _ -> []
    end

    assert {:error, :invalid_callback_url} =
             Webhook.validate_callback_url_for_test("https://INTERNAL.EXAMPLE./callback", false,
               dns_resolver: private_dns
             )

    assert {:ok, "https://internal.example/callback"} =
             Webhook.validate_callback_url_for_test("https://INTERNAL.EXAMPLE./callback", true,
               dns_resolver: private_dns
             )
  end

  test "request metadata redacts query secrets" do
    conn = Test.conn(:post, "/webhooks/demo?token=topsecret&foo=bar&api_key=abc123", "")
    metadata = Webhook.request_metadata_for_test(conn)

    assert is_binary(metadata.query)
    redacted_query = URI.decode_query(metadata.query)

    assert redacted_query["token"] == "[REDACTED]"
    assert redacted_query["api_key"] == "[REDACTED]"
    assert redacted_query["foo"] == "bar"
  end

  test "wait helper returns completion payload published on run topic" do
    run_id = "run_webhook_wait_#{System.unique_integer([:positive])}"

    Task.start(fn ->
      Process.sleep(40)

      LemonCore.Bus.broadcast(
        LemonCore.Bus.run_topic(run_id),
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{ok: true, answer: "done"},
            duration_ms: 10
          },
          %{run_id: run_id}
        )
      )
    end)

    assert {:ok, payload} = Webhook.wait_for_run_completion_for_test(run_id, 1_000)
    assert payload.completed.ok == true
    assert payload.completed.answer == "done"
    assert payload.duration_ms == 10
  end

  test "wait helper times out when no run completion event is received" do
    run_id = "run_webhook_timeout_#{System.unique_integer([:positive])}"

    assert {:error, :timeout} = Webhook.wait_for_run_completion_for_test(run_id, 25)
  end

  test "callback waiter timeout resolves per integration, global, then default" do
    assert 300_000 ==
             Webhook.resolve_callback_wait_timeout_ms_for_test(
               %{callback_wait_timeout_ms: 300_000},
               %{callback_wait_timeout_ms: 120_000}
             )

    assert 120_000 ==
             Webhook.resolve_callback_wait_timeout_ms_for_test(
               %{},
               %{callback_wait_timeout_ms: 120_000}
             )

    assert 600_000 == Webhook.resolve_callback_wait_timeout_ms_for_test(%{}, %{})
  end

  test "auth accepts headers by default and query/payload only when explicitly enabled" do
    integration = %{"token" => "secret-token"}

    header_conn =
      Test.conn(:post, "/webhooks/demo", "")
      |> Conn.put_req_header("authorization", "Bearer secret-token")

    assert :ok = Webhook.authorize_request_for_test(header_conn, %{}, integration)

    webhook_header_conn =
      Test.conn(:post, "/webhooks/demo", "")
      |> Conn.put_req_header("x-webhook-token", "secret-token")

    assert :ok = Webhook.authorize_request_for_test(webhook_header_conn, %{}, integration)

    query_conn = Test.conn(:post, "/webhooks/demo?token=secret-token", "")

    assert {:error, :unauthorized} =
             Webhook.authorize_request_for_test(query_conn, %{}, integration)

    payload_conn = %{
      Test.conn(:post, "/webhooks/demo", "")
      | body_params: %{"token" => "secret-token"}
    }

    assert {:error, :unauthorized} =
             Webhook.authorize_request_for_test(
               payload_conn,
               %{"token" => "secret-token"},
               integration
             )

    assert :ok =
             Webhook.authorize_request_for_test(query_conn, %{}, %{
               "token" => "secret-token",
               "allow_query_token" => true
             })

    assert :ok =
             Webhook.authorize_request_for_test(payload_conn, %{"token" => "secret-token"}, %{
               "token" => "secret-token",
               "allow_payload_token" => true
             })
  end

  test "idempotency helper returns duplicate response for existing key and supports payload opt-in" do
    integration_id = "demo-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-#{System.unique_integer([:positive])}"

    header_conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, idempotency_ctx} =
             Webhook.idempotency_context_for_test(header_conn, %{}, integration_id, %{})

    assert :ok =
             Store.put(Webhook.idempotency_table_for_test(), idempotency_ctx.store_key, %{
               run_id: "run-123",
               session_key: "agent:demo:main",
               mode: "async"
             })

    assert {:duplicate, 202, response_payload} =
             Webhook.idempotency_context_for_test(header_conn, %{}, integration_id, %{})

    assert response_payload.run_id == "run-123"
    assert response_payload.session_key == "agent:demo:main"
    assert response_payload.mode == "async"

    payload_conn = %{
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      | body_params: %{"idempotency_key" => "payload-idem"}
    }

    assert {:ok, nil} =
             Webhook.idempotency_context_for_test(payload_conn, %{}, integration_id, %{})

    assert {:ok, %{idempotency_key: "payload-idem"}} =
             Webhook.idempotency_context_for_test(payload_conn, %{}, integration_id, %{
               "allow_payload_idempotency_key" => true
             })
  end

  defp clear_idempotency_table do
    Webhook.idempotency_table_for_test()
    |> Store.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(Webhook.idempotency_table_for_test(), key)
    end)
  end

  defp dispatch_webhook(run_id, idempotency_ctx, integration_id \\ "demo") do
    conn = Test.conn(:post, "/webhooks/#{integration_id}", "")
    integration = %{"agent_id" => "webhook-test", "mode" => "async"}
    normalized = %{prompt: "safe prompt", attachments: [], metadata: %{}}

    InvocationDispatch.submit_run(
      conn,
      integration_id,
      integration,
      %{},
      normalized,
      idempotency_ctx,
      webhook_config: %{},
      default_timeout_ms: 100,
      default_callback_wait_timeout_ms: 100,
      callback_waiter_ready_timeout_ms: 100,
      run_id: run_id,
      validate_callback_url: fn _url, _allow_private, _opts -> {:ok, nil} end,
      request_metadata_fun: fn _conn -> %{} end
    )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
