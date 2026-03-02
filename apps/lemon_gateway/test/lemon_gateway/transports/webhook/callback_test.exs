defmodule LemonGateway.Transports.Webhook.CallbackTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Transports.Webhook.Callback

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    :ok
  end

  describe "callback_success_status?/1" do
    test "accepts 2xx status codes" do
      assert Callback.callback_success_status?(200)
      assert Callback.callback_success_status?(201)
      assert Callback.callback_success_status?(204)
      assert Callback.callback_success_status?(299)
    end

    test "rejects non-2xx status codes" do
      refute Callback.callback_success_status?(199)
      refute Callback.callback_success_status?(300)
      refute Callback.callback_success_status?(404)
      refute Callback.callback_success_status?(500)
    end

    test "rejects non-integer input" do
      refute Callback.callback_success_status?("200")
      refute Callback.callback_success_status?(nil)
    end
  end

  describe "callback_payload/2" do
    test "builds correct payload structure" do
      run_ctx = %{
        integration_id: "demo",
        run_id: "run-123",
        session_key: "agent:demo:main",
        metadata: %{"source" => "test"},
        attachments: []
      }

      run_payload = %{
        completed: %{answer: "done"},
        duration_ms: 100
      }

      result = Callback.callback_payload(run_ctx, run_payload)

      assert result.integration_id == "demo"
      assert result.run_id == "run-123"
      assert result.session_key == "agent:demo:main"
      assert result.completed == %{answer: "done"}
      assert result.duration_ms == 100
      assert result.metadata == %{"source" => "test"}
    end
  end

  describe "completed_payload/1" do
    test "returns :completed key when present" do
      assert Callback.completed_payload(%{completed: %{ok: true}}) == %{ok: true}
    end

    test "returns entire payload when :completed key is missing" do
      payload = %{answer: "hello"}
      assert Callback.completed_payload(payload) == payload
    end
  end

  describe "wait_for_run_completion/3" do
    test "returns completion payload from Bus event" do
      run_id = "run_cb_test_#{System.unique_integer([:positive])}"

      Task.start(fn ->
        Process.sleep(40)

        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(
            :run_completed,
            %{completed: %{ok: true, answer: "done"}, duration_ms: 10},
            %{run_id: run_id}
          )
        )
      end)

      assert {:ok, payload} = Callback.wait_for_run_completion(run_id, 1_000)
      assert payload.completed.ok == true
      assert payload.duration_ms == 10
    end

    test "returns timeout when no event received" do
      run_id = "run_cb_timeout_#{System.unique_integer([:positive])}"
      assert {:error, :timeout} = Callback.wait_for_run_completion(run_id, 25)
    end

    test "returns error for non-string run_id" do
      assert {:error, :invalid_run_id} = Callback.wait_for_run_completion(nil, 1_000)
    end
  end

  describe "maybe_send_callback/3" do
    test "returns nil for nil URL" do
      assert Callback.maybe_send_callback(nil, %{}, 5_000) == nil
    end

    test "returns nil for empty URL" do
      assert Callback.maybe_send_callback("", %{}, 5_000) == nil
    end
  end

  describe "cleanup_wait_setup/1" do
    test "cleans up sync topic" do
      assert :ok = Callback.cleanup_wait_setup(%{sync_topic: "test_topic"})
    end

    test "handles empty wait setup" do
      assert :ok = Callback.cleanup_wait_setup(%{})
    end
  end

  describe "with_sync_subscription/2" do
    test "executes callback and returns result with sync topic" do
      result = Callback.with_sync_subscription(%{sync_topic: "test"}, fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "executes callback without sync topic" do
      result = Callback.with_sync_subscription(%{}, fn -> {:ok, 99} end)
      assert result == {:ok, 99}
    end
  end
end
