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

defmodule LemonGateway.WebhookSecondDeleteFailureBackend do
  @behaviour LemonCore.Store.Backend

  @impl true
  def init(_opts), do: {:ok, %{data: %{}, delete_count: 0}}

  @impl true
  def put(state, table, key, value), do: {:ok, put_in(state, [:data, {table, key}], value)}

  @impl true
  def put_new(state, table, key, value) do
    if Map.has_key?(state.data, {table, key}),
      do: {:exists, state},
      else: put(state, table, key, value)
  end

  @impl true
  def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

  @impl true
  def delete(%{delete_count: 1}, _table, _key), do: {:error, :injected_second_delete}

  def delete(state, table, key) do
    {:ok,
     %{state | data: Map.delete(state.data, {table, key}), delete_count: state.delete_count + 1}}
  end

  @impl true
  def list(state, table) do
    entries = for {{^table, key}, value} <- state.data, do: {key, value}
    {:ok, entries, state}
  end
end

defmodule LemonGateway.WebhookListFailureBackend do
  @behaviour LemonCore.Store.Backend

  @impl true
  def init(_opts), do: {:ok, %{data: %{}, fail_table: nil}}

  @impl true
  def put(state, table, key, value), do: {:ok, put_in(state, [:data, {table, key}], value)}

  @impl true
  def put_new(state, table, key, value) do
    if Map.has_key?(state.data, {table, key}),
      do: {:exists, state},
      else: put(state, table, key, value)
  end

  @impl true
  def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

  @impl true
  def delete(state, table, key), do: {:ok, %{state | data: Map.delete(state.data, {table, key})}}

  @impl true
  def list(%{fail_table: table}, table), do: {:error, :injected_list_failure}

  def list(state, table) do
    entries = for {{^table, key}, value} <- state.data, do: {key, value}
    {:ok, entries, state}
  end
end

defmodule LemonGateway.WebhookTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonGateway.Transports.Webhook
  alias LemonGateway.Transports.Webhook.{Config, Idempotency, InvocationDispatch, Request, Response}
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

    assert {:ok, 200, payload} = Response.response_for_run(run_ctx, [])
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
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:error, :outcome_unknown}
    )

    assert {:ok, run_ctx} = dispatch_webhook(run_id, idempotency_ctx, integration_id)
    assert_receive {:webhook_submit, %{run_id: ^run_id}}
    assert {:ok, 200, payload} = Response.response_for_run(run_ctx, [])

    assert {:duplicate, 202, pending_payload} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert pending_payload.run_id == run_id
    assert pending_payload.status == "outcome_unknown"
    assert pending_payload.retry_safe == false

    assert :ok = Idempotency.store_response(idempotency_ctx, 200, payload)

    assert {:duplicate, 200, ^payload} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

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
        assert {:ok, 200, payload} = Response.response_for_run(run_ctx, [])
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

  test "idempotency helper reserves key and returns a retryable pending receipt" do
    integration_id = "demo-pending-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-pending-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, %{store_key: store_key, idempotency_digest: digest} = ctx} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert {:v1, ^digest} = store_key
    stored = Store.get(Idempotency.table(), store_key)
    assert stored.idempotency_digest == digest
    refute Map.has_key?(ctx, :idempotency_key)
    refute Map.has_key?(stored, :idempotency_key)
    refute inspect({store_key, stored, ctx}) =~ idempotency_key

    assert {:duplicate, 503, response_payload} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert response_payload.status == "reservation_pending"
    assert response_payload.retry_safe == true
  end

  test "legacy raw-key receipts migrate without creating a second run" do
    cases = [
      {"pending", :retry},
      {"rejected", :retry},
      {"submitted", {:duplicate, 202, "accepted"}},
      {"outcome_unknown", {:duplicate, 202, "outcome_unknown"}},
      {"completed", {:duplicate, 207, "complete"}}
    ]

    Enum.each(cases, fn {state, expectation} ->
      suffix = System.unique_integer([:positive])
      integration_id = "legacy-#{state}-#{suffix}"
      idempotency_key = "raw-secret-#{state}-#{suffix}"
      run_id = "legacy-run-#{state}-#{suffix}"
      reservation_id = "legacy-reservation-#{state}-#{suffix}"
      raw_key = {integration_id, idempotency_key}

      legacy = %{
        idempotency_key: idempotency_key,
        integration_id: integration_id,
        run_id: run_id,
        reservation_id: reservation_id,
        session_key: "agent:legacy:#{state}",
        mode: "async",
        state: state,
        lease_expires_at_ms: 0,
        updated_at_ms: 1,
        response_status: if(state == "completed", do: 207),
        response_payload: if(state == "completed", do: %{run_id: run_id, status: "complete"})
      }

      assert :ok = Store.put(Idempotency.table(), raw_key, legacy)

      conn =
        Test.conn(:post, "/webhooks/#{integration_id}", "")
        |> Conn.put_req_header("idempotency-key", idempotency_key)

      result = Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

      case expectation do
        :retry ->
          assert {:ok, %{run_id: ^run_id}} = result

        {:duplicate, status, receipt_state} ->
          assert {:duplicate, ^status, payload} = result
          assert payload.run_id == run_id
          assert payload.status == receipt_state
      end

      assert Store.get(Idempotency.table(), raw_key) == nil

      assert [{hashed_key, migrated}] =
               Idempotency.table()
               |> Store.list()
               |> Enum.filter(fn {_key, entry} -> entry[:run_id] == run_id end)

      assert {:v1, _digest} = hashed_key
      refute Map.has_key?(migrated, :idempotency_key)
      refute Map.has_key?(migrated, "idempotency_key")
      refute inspect({hashed_key, migrated}) =~ idempotency_key
    end)
  end

  test "released bare pending receipt remains an ambiguous permanent fence after upgrade" do
    suffix = System.unique_integer([:positive])
    integration_id = "legacy-bare-pending-#{suffix}"
    idempotency_key = "legacy-bare-pending-secret-#{suffix}"
    raw_key = {integration_id, idempotency_key}

    # This is the exact released shape: the old build persisted pending before
    # submission but did not yet store any lease or execution identity.
    legacy = %{
      idempotency_key: idempotency_key,
      integration_id: integration_id,
      state: "pending",
      updated_at_ms: 1
    }

    assert :ok = Store.put(Idempotency.table(), raw_key, legacy)

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:duplicate, 200, ambiguity} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert ambiguity == %{
             status: "legacy_outcome_unknown",
             duplicate: true,
             retry_safe: false
           }

    assert Store.get(Idempotency.table(), raw_key) == nil

    assert [{{:v1, _digest} = hashed_key, migrated}] =
             Store.list(Idempotency.table())

    assert migrated.state == "legacy_pending_unknown"
    refute Map.has_key?(migrated, :run_id)
    refute Map.has_key?(migrated, :reservation_id)
    refute Map.has_key?(migrated, :lease_expires_at_ms)
    refute inspect({hashed_key, migrated}) =~ idempotency_key

    # A later process/version sees the same durable ambiguity and never
    # manufactures a new run ID from the old acceptance window.
    assert {:duplicate, 200, ^ambiguity} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert Store.get(Idempotency.table(), hashed_key) == migrated
    refute_receive {:webhook_submit, _request}
  end

  test "legacy ambiguous fence suppresses endpoint retries without a retry-safe claim" do
    suffix = System.unique_integer([:positive])
    integration_id = "legacy-endpoint-ambiguous-#{suffix}"
    idempotency_key = "legacy-endpoint-secret-#{suffix}"
    raw_key = {integration_id, idempotency_key}

    assert :ok =
             Store.put(Idempotency.table(), raw_key, %{
               idempotency_key: idempotency_key,
               integration_id: integration_id,
               state: "pending",
               updated_at_ms: 1
             })

    config_pid = ensure_config_started()
    original_config_state = :sys.get_state(config_pid)

    :sys.replace_state(config_pid, fn state ->
      Map.put(state, :webhook, %{
        integrations: %{
          integration_id => %{
            agent_id: "webhook-test",
            mode: "async",
            token: "endpoint-test-token"
          }
        }
      })
    end)

    on_exit(fn ->
      if Process.alive?(config_pid) do
        :sys.replace_state(config_pid, fn _state -> original_config_state end)
      end
    end)

    conn =
      Test.conn(
        :post,
        "/webhooks/#{integration_id}",
        Jason.encode!(%{prompt: "do not submit twice"})
      )
      |> Conn.put_req_header("content-type", "application/json")
      |> Conn.put_req_header("authorization", "Bearer endpoint-test-token")
      |> Conn.put_req_header("idempotency-key", idempotency_key)
      |> Webhook.call([])

    assert conn.status == 200
    payload = Jason.decode!(conn.resp_body)
    assert payload["status"] == "legacy_outcome_unknown"
    assert payload["duplicate"] == true
    assert payload["retry_safe"] == false
    refute Map.has_key?(payload, "accepted")
    refute_receive {:webhook_submit, _request}
  end

  test "legacy exact response receipt migrates before the raw primary is deleted" do
    suffix = System.unique_integer([:positive])
    integration_id = "legacy-response-#{suffix}"
    idempotency_key = "legacy-response-secret-#{suffix}"
    raw_key = {integration_id, idempotency_key}
    reservation_id = "legacy-response-reservation-#{suffix}"
    run_id = "legacy-response-run-#{suffix}"
    now_ms = System.system_time(:millisecond)

    legacy = %{
      idempotency_key: idempotency_key,
      integration_id: integration_id,
      run_id: run_id,
      reservation_id: reservation_id,
      session_key: "agent:legacy-response:main",
      mode: "sync",
      state: "submitted",
      updated_at_ms: now_ms
    }

    receipt = %{
      status: 200,
      payload: %{run_id: run_id, exact: true},
      stored_at_ms: now_ms
    }

    assert :ok = Store.put(Idempotency.table(), raw_key, legacy)
    assert :ok = Store.put(Idempotency.response_table(), {raw_key, reservation_id}, receipt)

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:duplicate, 200, %{run_id: ^run_id, exact: true}} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert Store.get(Idempotency.table(), raw_key) == nil
    assert Store.get(Idempotency.response_table(), {raw_key, reservation_id}) == nil

    assert [{{{:v1, _digest}, ^reservation_id}, ^receipt}] =
             Store.list(Idempotency.response_table())
  end

  test "legacy migration is serialized across concurrent redeliveries" do
    suffix = System.unique_integer([:positive])
    integration_id = "legacy-concurrent-#{suffix}"
    idempotency_key = "legacy-concurrent-secret-#{suffix}"
    run_id = "legacy-concurrent-run-#{suffix}"
    raw_key = {integration_id, idempotency_key}

    assert :ok =
             Store.put(Idempotency.table(), raw_key, %{
               idempotency_key: idempotency_key,
               integration_id: integration_id,
               run_id: run_id,
               reservation_id: "legacy-concurrent-reservation-#{suffix}",
               session_key: "agent:legacy-concurrent:main",
               mode: "async",
               state: "submitted",
               updated_at_ms: 1
             })

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    results =
      1..12
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
        end)
      end)
      |> Enum.map(&Task.await(&1, 2_000))

    assert Enum.all?(results, &match?({:duplicate, 202, %{run_id: ^run_id}}, &1))
    assert Store.get(Idempotency.table(), raw_key) == nil

    assert 1 ==
             Idempotency.table()
             |> Store.list()
             |> Enum.count(fn {_key, entry} -> entry[:run_id] == run_id end)
  end

  test "legacy migration fails closed when raw deletion fails after hashing" do
    suffix = System.unique_integer([:positive])
    integration_id = "legacy-delete-fault-#{suffix}"
    idempotency_key = "legacy-delete-secret-#{suffix}"
    raw_key = {integration_id, idempotency_key}

    legacy = %{
      idempotency_key: idempotency_key,
      integration_id: integration_id,
      run_id: "legacy-delete-run-#{suffix}",
      reservation_id: "legacy-delete-reservation-#{suffix}",
      session_key: "agent:legacy-delete:main",
      mode: "async",
      state: "submitted",
      updated_at_ms: 1
    }

    backend_state = %{
      data: %{{Idempotency.table(), raw_key} => legacy},
      delete_count: 1
    }

    original_store_state = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      %{
        state
        | backend: LemonGateway.WebhookSecondDeleteFailureBackend,
          backend_state: backend_state
      }
    end)

    on_exit(fn -> :sys.replace_state(Store, fn _state -> original_store_state end) end)

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    log =
      capture_log(fn ->
        assert {:error, :idempotency_unavailable} =
                 Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
      end)

    refute log =~ idempotency_key

    assert Store.get(Idempotency.table(), raw_key) == legacy

    assert [{{:v1, _digest}, hashed}] =
             Idempotency.table()
             |> Store.list()
             |> Enum.reject(fn {key, _entry} -> key == raw_key end)

    assert hashed.run_id == legacy.run_id
    refute Map.has_key?(hashed, :idempotency_key)
  end

  test "sweeper migrates every legacy receipt state even before expiry" do
    suffix = System.unique_integer([:positive])

    raw_keys =
      Enum.map(["pending", "submitted", "completed", "outcome_unknown", "rejected"], fn state ->
        integration_id = "legacy-sweep-#{state}-#{suffix}"
        idempotency_key = "legacy-sweep-secret-#{state}-#{suffix}"
        raw_key = {integration_id, idempotency_key}

        assert :ok =
                 Store.put(Idempotency.table(), raw_key, %{
                   idempotency_key: idempotency_key,
                   integration_id: integration_id,
                   run_id: "legacy-sweep-run-#{state}-#{suffix}",
                   reservation_id: "legacy-sweep-reservation-#{state}-#{suffix}",
                   state: state,
                   lease_expires_at_ms: 0,
                   updated_at_ms: 100
                 })

        raw_key
      end)

    assert :ok = Idempotency.sweep_expired(1_000, 10_000)
    assert Enum.all?(raw_keys, &(Store.get(Idempotency.table(), &1) == nil))

    assert 5 ==
             Idempotency.table()
             |> Store.list()
             |> Enum.count(fn {key, _entry} -> match?({:v1, _digest}, key) end)
  end

  test "invalid payload idempotency values are rejected without collisions" do
    integration_id = "invalid-idempotency-#{System.unique_integer([:positive])}"
    integration = %{"allow_payload_idempotency_key" => true}

    for invalid <- [123, 999, [123], %{"nested" => "value"}, "", "   "] do
      conn = %{
        Test.conn(:post, "/webhooks/#{integration_id}", "")
        | body_params: %{"idempotency_key" => invalid}
      }

      assert {:error, :invalid_idempotency_key} =
               Idempotency.context(conn, %{}, integration_id, integration, Config.config())
    end

    valid_conn = %{
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      | body_params: %{"idempotency_key" => "{"}
    }

    assert {:ok, %{run_id: run_id}} =
             Idempotency.context(valid_conn, %{}, integration_id, integration, Config.config())

    assert is_binary(run_id)
  end

  test "sweep list failure propagates and does not advance its schedule" do
    sweep_key = {Idempotency, :last_response_sweep_ms}
    original_sweep_ms = :persistent_term.get(sweep_key, 0)
    original_store_state = :sys.get_state(Store)

    :persistent_term.put(sweep_key, 0)

    on_exit(fn ->
      :sys.replace_state(Store, fn _state -> original_store_state end)
      :persistent_term.put(sweep_key, original_sweep_ms)
    end)

    Enum.each(
      [Idempotency.response_table(), Idempotency.table()],
      fn fail_table ->
        :sys.replace_state(Store, fn state ->
          %{
            state
            | backend: LemonGateway.WebhookListFailureBackend,
              backend_state: %{data: %{}, fail_table: fail_table}
          }
        end)

        assert {:error, :idempotency_unavailable} = Idempotency.sweep_expired(1_000, 1)
      end
    )

    conn = Test.conn(:post, "/webhooks/no-idempotency", "")
    assert {:ok, nil} = Idempotency.context(conn, %{}, "no-idempotency", %{}, Config.config())
    assert :persistent_term.get(sweep_key) == 0
  end

  test "an expired pending lease is reclaimed with the same durable run id" do
    integration_id = "demo-reclaim-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-reclaim-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, first_ctx} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    entry = Store.get(Idempotency.table(), first_ctx.store_key)

    assert :ok =
             Store.put(
               Idempotency.table(),
               first_ctx.store_key,
               Map.put(entry, :lease_expires_at_ms, 0)
             )

    assert {:ok, reclaimed_ctx} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert reclaimed_ctx.run_id == first_ctx.run_id
    refute reclaimed_ctx.reservation_id == first_ctx.reservation_id
  end

  test "gateway retries keep one semantic replay identity across request-local ids" do
    integration_id = "demo-stable-replay-#{System.unique_integer([:positive])}"
    idempotency_key = "stable-replay-#{System.unique_integer([:positive])}"

    base_conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} =
             Idempotency.context(base_conn, %{}, integration_id, %{}, Config.config())

    Application.put_env(:lemon_gateway, :webhook_transport_submit_result, {:ok, ctx.run_id})

    assert {:ok, _run_ctx} =
             dispatch_webhook(
               Conn.put_req_header(base_conn, "x-request-id", "delivery-attempt-one"),
               ctx.run_id,
               ctx,
               integration_id
             )

    assert_receive {:webhook_submit, first_request}

    assert {:ok, _run_ctx} =
             dispatch_webhook(
               Conn.put_req_header(base_conn, "x-request-id", "delivery-attempt-two"),
               ctx.run_id,
               ctx,
               integration_id
             )

    assert_receive {:webhook_submit, second_request}
    assert first_request.meta.webhook.request.request_id == "delivery-attempt-one"
    assert second_request.meta.webhook.request.request_id == "delivery-attempt-two"

    assert first_request.meta.router_replay_identity ==
             second_request.meta.router_replay_identity

    assert String.starts_with?(first_request.meta.router_replay_identity, "webhook:v1:")
    refute inspect(first_request) =~ idempotency_key
    refute inspect(second_request) =~ idempotency_key

    refute inspect(Store.list(Idempotency.table())) =~ idempotency_key
    refute inspect(Store.list(Idempotency.response_table())) =~ idempotency_key
    refute Jason.encode!(first_request.meta) =~ idempotency_key
  end

  test "response persistence fails closed when its durable reservation disappears" do
    integration_id = "demo-response-store-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", "response-store")

    assert {:ok, ctx} = Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
    assert :ok = Store.delete(Idempotency.table(), ctx.store_key)

    assert {:error, :idempotency_unavailable} =
             Idempotency.store_response(ctx, 202, %{run_id: ctx.run_id})
  end

  test "a sync response receipt replays the exact response if the primary completion update is lost" do
    integration_id = "demo-sync-response-#{System.unique_integer([:positive])}"
    idempotency_key = "sync-response-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} = Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
    assert :ok = Idempotency.store_submission(ctx, ctx.run_id, "agent:sync:main", :sync)

    exact_payload = %{
      run_id: ctx.run_id,
      session_key: "agent:sync:main",
      mode: "sync",
      completed: %{ok: true, answer: "exact answer"},
      duration_ms: 17
    }

    assert :ok = Idempotency.store_response(ctx, 200, exact_payload)

    # This is the durable shape left when the independent response receipt commits
    # but the primary idempotency-row completion update does not.
    primary = Store.get(Idempotency.table(), ctx.store_key)

    assert :ok =
             Store.put(
               Idempotency.table(),
               ctx.store_key,
               primary
               |> Map.drop([:response_status, :response_payload])
               |> Map.put(:state, "submitted")
             )

    assert {:duplicate, 200, ^exact_payload} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
  end

  test "expired exact response receipts are swept with their primary reservation" do
    integration_id = "demo-response-retention-#{System.unique_integer([:positive])}"
    idempotency_key = "response-retention-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} = Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
    assert :ok = Idempotency.store_response(ctx, 200, %{run_id: ctx.run_id, exact: true})

    receipt_key = {ctx.store_key, ctx.reservation_id}
    receipt = Store.get(Idempotency.response_table(), receipt_key)

    primary = Store.get(Idempotency.table(), ctx.store_key)

    assert :ok =
             Store.put(Idempotency.table(), ctx.store_key, %{
               primary
               | updated_at_ms: 0
             })

    assert :ok = Idempotency.sweep_expired(10, 1)
    assert Store.get(Idempotency.table(), ctx.store_key) != nil
    assert Store.get(Idempotency.response_table(), receipt_key) == receipt

    assert :ok =
             Store.put(Idempotency.response_table(), receipt_key, %{receipt | stored_at_ms: 0})

    assert :ok = Idempotency.sweep_expired(10, 1)
    assert Store.get(Idempotency.response_table(), receipt_key) == nil
    assert Store.get(Idempotency.table(), ctx.store_key) == nil

    assert {:ok, replacement_ctx} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    refute replacement_ctx.reservation_id == ctx.reservation_id
  end

  test "a second-delete failure preserves the primary execution fence" do
    integration_id = "demo-response-sweep-fault-#{System.unique_integer([:positive])}"
    idempotency_key = "response-sweep-fault-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} = Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
    assert :ok = Idempotency.store_submission(ctx, ctx.run_id, "agent:sweep-fault:main", :sync)
    assert :ok = Idempotency.store_response(ctx, 200, %{run_id: ctx.run_id, exact: true})

    receipt_key = {ctx.store_key, ctx.reservation_id}
    receipt = Store.get(Idempotency.response_table(), receipt_key)
    primary = Store.get(Idempotency.table(), ctx.store_key)

    expired_receipt = %{receipt | stored_at_ms: 0}
    expired_primary = %{primary | updated_at_ms: 0}

    backend_state = %{
      data: %{
        {Idempotency.response_table(), receipt_key} => expired_receipt,
        {Idempotency.table(), ctx.store_key} => expired_primary
      },
      delete_count: 0
    }

    original_store_state = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      %{
        state
        | backend: LemonGateway.WebhookSecondDeleteFailureBackend,
          backend_state: backend_state
      }
    end)

    on_exit(fn -> :sys.replace_state(Store, fn _state -> original_store_state end) end)

    assert {:error, :idempotency_unavailable} = Idempotency.sweep_expired(10, 1)
    assert Store.get(Idempotency.response_table(), receipt_key) == nil

    assert Store.get(Idempotency.table(), ctx.store_key) == expired_primary

    assert {:duplicate, 200, replay} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert replay.run_id == ctx.run_id
    assert replay.exact == true
  end

  test "a sync submission without a durable response never replays generic accepted" do
    integration_id = "demo-sync-unavailable-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", "sync-unavailable")

    assert {:ok, ctx} = Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
    assert :ok = Idempotency.store_submission(ctx, ctx.run_id, "agent:sync:main", :sync)

    assert {:duplicate, 503, payload} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert payload.run_id == ctx.run_id
    assert payload.status == "response_persistence_unknown"
    assert payload.retry_safe == false
  end

  test "accepted submission fails closed when its durable reservation disappears" do
    integration_id = "demo-submission-store-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", "submission-store")

    assert {:ok, ctx} = Idempotency.context(conn, %{}, integration_id, %{}, Config.config())
    assert :ok = Store.delete(Idempotency.table(), ctx.store_key)

    Application.put_env(
      :lemon_gateway,
      :webhook_transport_submit_result,
      {:ok, ctx.run_id}
    )

    assert {:error, :idempotency_unavailable} =
             dispatch_webhook(ctx.run_id, ctx, integration_id)

    assert_receive {:webhook_submit, %{run_id: run_id}}
    assert run_id == ctx.run_id
  end

  test "an unreadable existing idempotency claim fails closed without submission" do
    integration_id = "demo-corrupt-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-corrupt-#{System.unique_integer([:positive])}"

    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, ctx} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    assert :ok =
             Store.put(Idempotency.table(), ctx.store_key, %{
               integration_id: integration_id,
               idempotency_digest: ctx.idempotency_digest,
               state: "completed"
             })

    assert {:error, :idempotency_unavailable} =
             Idempotency.context(conn, %{}, integration_id, %{}, Config.config())

    refute_receive {:webhook_submit, _request}
  end

  test "normalizes prompt, attachments, and metadata from webhook payloads" do
    payload = %{
      "content" => %{"text" => "Ship this"},
      "files" => [%{"name" => "spec.txt", "url" => "https://example.test/spec.txt"}],
      "urls" => ["https://example.test/mock.png"],
      "metadata" => %{"source" => "zapier", "workflow_id" => "wf_123"}
    }

    assert {:ok, normalized} = Request.normalize_payload(payload)
    assert normalized.prompt =~ "Ship this"
    assert normalized.prompt =~ "Attachments:"
    assert normalized.prompt =~ "https://example.test/spec.txt"
    assert normalized.prompt =~ "https://example.test/mock.png"
    assert length(normalized.attachments) == 2
    assert normalized.metadata["source"] == "zapier"
    assert normalized.metadata["workflow_id"] == "wf_123"
  end

  test "secure token compare accepts exact match and rejects mismatches" do
    assert Request.secure_compare("secret-token", "secret-token")
    refute Request.secure_compare("secret-token", "secret-token-2")
    refute Request.secure_compare("secret-token", nil)
    refute Request.secure_compare(nil, "secret-token")
  end

  test "callback success status only accepts HTTP 2xx" do
    assert Response.callback_success_status?(200)
    assert Response.callback_success_status?(204)
    assert Response.callback_success_status?(299)

    refute Response.callback_success_status?(199)
    refute Response.callback_success_status?(300)
    refute Response.callback_success_status?(500)
  end

  test "callback URL validation enforces canonicalization, scheme, and private host policy" do
    public_dns = fn _host -> [] end

    assert {:ok, "https://example.test/callback"} =
             Request.validate_callback_url("https://EXAMPLE.TEST./callback", false,
               dns_resolver: public_dns
             )

    assert {:error, :invalid_callback_url} =
             Request.validate_callback_url("ftp://example.test/callback", false,
               dns_resolver: public_dns
             )

    assert {:error, :invalid_callback_url} =
             Request.validate_callback_url("http://localhost./callback", false)

    assert {:error, :invalid_callback_url} =
             Request.validate_callback_url("http://127.0.0.1/callback", false)

    assert {:error, :invalid_callback_url} =
             Request.validate_callback_url("http://[::ffff:127.0.0.1]/callback", false)

    assert {:ok, "http://127.0.0.1/callback"} =
             Request.validate_callback_url("http://127.0.0.1/callback", true)

    private_dns = fn
      "internal.example" -> [{10, 1, 2, 3}, {93, 184, 216, 34}]
      _ -> []
    end

    assert {:error, :invalid_callback_url} =
             Request.validate_callback_url("https://INTERNAL.EXAMPLE./callback", false,
               dns_resolver: private_dns
             )

    assert {:ok, "https://internal.example/callback"} =
             Request.validate_callback_url("https://INTERNAL.EXAMPLE./callback", true,
               dns_resolver: private_dns
             )
  end

  test "callback URLs reject discarded ports even when private hosts are approved" do
    for port <- ["65536", "99999", "100000", "00065536"],
        allow_private <- [false, true] do
      assert {:error, :invalid_callback_url} =
               Request.validate_callback_url(
                 "https://example.test:#{port}/callback",
                 allow_private,
                 dns_resolver: fn _ -> flunk("invalid callback port reached DNS") end
               )
    end
  end

  test "request metadata redacts query secrets" do
    conn = Test.conn(:post, "/webhooks/demo?token=topsecret&foo=bar&api_key=abc123", "")
    metadata = Request.request_metadata(conn)

    assert is_binary(metadata.query)
    redacted_query = URI.decode_query(metadata.query)

    assert redacted_query["token"] == "[REDACTED]"
    assert redacted_query["api_key"] == "[REDACTED]"
    assert redacted_query["foo"] == "bar"
  end

  test "wait helper returns completion payload published on run topic" do
    run_id = "run_webhook_wait_#{System.unique_integer([:positive])}"

    event =
      LemonCore.Event.new(
        :run_completed,
        %{
          completed: %{ok: true, answer: "done"},
          duration_ms: 10
        },
        %{run_id: run_id}
      )

    # The waiter subscribes when it starts; keep publishing until it has the
    # completion so a late subscription cannot miss a single broadcast.
    publisher =
      spawn_link(fn ->
        publish = fn publish ->
          LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), event)

          receive do
            :stop -> :ok
          after
            10 -> publish.(publish)
          end
        end

        publish.(publish)
      end)

    assert {:ok, payload} = Response.wait_for_run_completion(run_id, 5_000)
    send(publisher, :stop)
    assert payload.completed.ok == true
    assert payload.completed.answer == "done"
    assert payload.duration_ms == 10
  end

  test "wait helper times out when no run completion event is received" do
    run_id = "run_webhook_timeout_#{System.unique_integer([:positive])}"

    assert {:error, :timeout} = Response.wait_for_run_completion(run_id, 25)
  end

  test "callback waiter timeout resolves per integration, global, then default" do
    assert 300_000 ==
             Request.resolve_callback_wait_timeout_ms(
               %{callback_wait_timeout_ms: 300_000},
               %{callback_wait_timeout_ms: 120_000},
               600_000
             )

    assert 120_000 ==
             Request.resolve_callback_wait_timeout_ms(
               %{},
               %{callback_wait_timeout_ms: 120_000},
               600_000
             )

    assert 600_000 == Request.resolve_callback_wait_timeout_ms(%{}, %{}, 600_000)
  end

  test "auth accepts headers by default and query/payload only when explicitly enabled" do
    integration = %{"token" => "secret-token"}

    header_conn =
      Test.conn(:post, "/webhooks/demo", "")
      |> Conn.put_req_header("authorization", "Bearer secret-token")

    assert :ok = Request.authorize_request(header_conn, %{}, integration, Config.config())

    webhook_header_conn =
      Test.conn(:post, "/webhooks/demo", "")
      |> Conn.put_req_header("x-webhook-token", "secret-token")

    assert :ok = Request.authorize_request(webhook_header_conn, %{}, integration, Config.config())

    query_conn = Test.conn(:post, "/webhooks/demo?token=secret-token", "")

    assert {:error, :unauthorized} =
             Request.authorize_request(query_conn, %{}, integration, Config.config())

    payload_conn = %{
      Test.conn(:post, "/webhooks/demo", "")
      | body_params: %{"token" => "secret-token"}
    }

    assert {:error, :unauthorized} =
             Request.authorize_request(
               payload_conn,
               %{"token" => "secret-token"},
               integration,
               Config.config()
             )

    assert :ok =
             Request.authorize_request(query_conn, %{}, %{
               "token" => "secret-token",
               "allow_query_token" => true
             }, Config.config())

    assert :ok =
             Request.authorize_request(payload_conn, %{"token" => "secret-token"}, %{
               "token" => "secret-token",
               "allow_payload_token" => true
             }, Config.config())
  end

  test "idempotency helper returns duplicate response for existing key and supports payload opt-in" do
    integration_id = "demo-#{System.unique_integer([:positive])}"
    idempotency_key = "idem-#{System.unique_integer([:positive])}"

    header_conn =
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      |> Conn.put_req_header("idempotency-key", idempotency_key)

    assert {:ok, idempotency_ctx} =
             Idempotency.context(header_conn, %{}, integration_id, %{}, Config.config())

    assert :ok =
             Store.put(Idempotency.table(), idempotency_ctx.store_key, %{
               run_id: "run-123",
               session_key: "agent:demo:main",
               mode: "async"
             })

    assert {:duplicate, 202, response_payload} =
             Idempotency.context(header_conn, %{}, integration_id, %{}, Config.config())

    assert response_payload.run_id == "run-123"
    assert response_payload.session_key == "agent:demo:main"
    assert response_payload.mode == "async"

    payload_conn = %{
      Test.conn(:post, "/webhooks/#{integration_id}", "")
      | body_params: %{"idempotency_key" => "payload-idem"}
    }

    assert {:ok, nil} =
             Idempotency.context(payload_conn, %{}, integration_id, %{}, Config.config())

    assert {:ok, %{idempotency_digest: digest} = payload_ctx} =
             Idempotency.context(payload_conn, %{}, integration_id, %{
               "allow_payload_idempotency_key" => true
             }, Config.config())

    assert is_binary(digest)
    refute Map.has_key?(payload_ctx, :idempotency_key)
    refute inspect(payload_ctx) =~ "payload-idem"
  end

  defp clear_idempotency_table do
    Idempotency.table()
    |> Store.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(Idempotency.table(), key)
    end)

    Idempotency.response_table()
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(Idempotency.response_table(), key) end)
  end

  defp dispatch_webhook(run_id, idempotency_ctx, integration_id \\ "demo") do
    conn = Test.conn(:post, "/webhooks/#{integration_id}", "")
    dispatch_webhook(conn, run_id, idempotency_ctx, integration_id)
  end

  defp dispatch_webhook(conn, run_id, idempotency_ctx, integration_id) do
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
      request_metadata_fun: &Request.request_metadata/1
    )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp ensure_config_started do
    Process.whereis(LemonGateway.Config) || start_supervised!(LemonGateway.Config)
  end
end
