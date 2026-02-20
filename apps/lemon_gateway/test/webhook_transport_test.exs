defmodule LemonGateway.WebhookTransportTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Transports.Webhook

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    :ok
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
end
