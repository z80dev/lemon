defmodule LemonGateway.Transports.Webhook.RoutingTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Transports.Webhook.Routing

  describe "resolve_session_key/1" do
    test "returns configured session_key" do
      assert Routing.resolve_session_key(%{"session_key" => "custom:key"}) == "custom:key"
    end

    test "derives session key from agent_id when session_key is blank" do
      result = Routing.resolve_session_key(%{"agent_id" => "myagent"})
      assert is_binary(result)
      assert result =~ "myagent"
    end

    test "uses 'default' agent_id when neither session_key nor agent_id is set" do
      result = Routing.resolve_session_key(%{})
      assert is_binary(result)
      assert result =~ "default"
    end
  end

  describe "resolve_engine/1" do
    test "returns configured default_engine" do
      assert Routing.resolve_engine(%{"default_engine" => "custom"}) == "custom"
    end

    test "falls back to global default when not configured" do
      result = Routing.resolve_engine(%{})
      assert is_binary(result)
    end
  end

  describe "resolve_queue_mode/1" do
    test "returns atom queue modes" do
      assert Routing.resolve_queue_mode(%{queue_mode: :collect}) == :collect
      assert Routing.resolve_queue_mode(%{queue_mode: :followup}) == :followup
      assert Routing.resolve_queue_mode(%{queue_mode: :steer}) == :steer
      assert Routing.resolve_queue_mode(%{queue_mode: :steer_backlog}) == :steer_backlog
      assert Routing.resolve_queue_mode(%{queue_mode: :interrupt}) == :interrupt
    end

    test "parses string queue modes" do
      assert Routing.resolve_queue_mode(%{"queue_mode" => "collect"}) == :collect
      assert Routing.resolve_queue_mode(%{"queue_mode" => "followup"}) == :followup
      assert Routing.resolve_queue_mode(%{"queue_mode" => "steer"}) == :steer
    end

    test "defaults to :collect for unknown modes" do
      assert Routing.resolve_queue_mode(%{"queue_mode" => "unknown"}) == :collect
      assert Routing.resolve_queue_mode(%{}) == :collect
    end
  end

  describe "resolve_mode/2" do
    test "returns :sync when integration is sync" do
      assert Routing.resolve_mode(%{"mode" => "sync"}, %{}) == :sync
      assert Routing.resolve_mode(%{mode: :sync}, %{}) == :sync
    end

    test "returns :async when integration is async" do
      assert Routing.resolve_mode(%{"mode" => "async"}, %{}) == :async
    end

    test "falls back to webhook config mode" do
      assert Routing.resolve_mode(%{}, %{"mode" => "sync"}) == :sync
    end

    test "defaults to :async" do
      assert Routing.resolve_mode(%{}, %{}) == :async
    end
  end

  describe "normalize_mode_string/1" do
    test "converts atoms to strings" do
      assert Routing.normalize_mode_string(:sync) == "sync"
      assert Routing.normalize_mode_string(:async) == "async"
    end

    test "passes through valid strings" do
      assert Routing.normalize_mode_string("sync") == "sync"
      assert Routing.normalize_mode_string("async") == "async"
    end

    test "returns nil for unknown values" do
      assert Routing.normalize_mode_string(:other) == nil
      assert Routing.normalize_mode_string("other") == nil
      assert Routing.normalize_mode_string(nil) == nil
    end
  end

  describe "resolve_timeout_ms/2" do
    test "uses integration-level timeout" do
      assert Routing.resolve_timeout_ms(%{"timeout_ms" => 5000}, %{"timeout_ms" => 10000}) == 5000
    end

    test "falls back to webhook-level timeout" do
      assert Routing.resolve_timeout_ms(%{}, %{"timeout_ms" => 10000}) == 10000
    end

    test "defaults to 30_000" do
      assert Routing.resolve_timeout_ms(%{}, %{}) == 30_000
    end
  end

  describe "resolve_callback_wait_timeout_ms/2" do
    test "uses integration-level timeout" do
      assert Routing.resolve_callback_wait_timeout_ms(
               %{callback_wait_timeout_ms: 300_000},
               %{callback_wait_timeout_ms: 120_000}
             ) == 300_000
    end

    test "falls back to webhook-level timeout" do
      assert Routing.resolve_callback_wait_timeout_ms(
               %{},
               %{callback_wait_timeout_ms: 120_000}
             ) == 120_000
    end

    test "defaults to 600_000" do
      assert Routing.resolve_callback_wait_timeout_ms(%{}, %{}) == 600_000
    end

    test "enforces minimum of 1ms" do
      assert Routing.resolve_callback_wait_timeout_ms(%{callback_wait_timeout_ms: 0}, %{}) == 1
    end
  end

  describe "callback_retry_config/2" do
    test "uses integration-level settings" do
      config =
        Routing.callback_retry_config(
          %{
            "callback_max_attempts" => 5,
            "callback_backoff_ms" => 1000,
            "callback_backoff_max_ms" => 10_000
          },
          %{}
        )

      assert config.max_attempts == 5
      assert config.backoff_ms == 1000
      assert config.backoff_max_ms == 10_000
    end

    test "returns defaults when nothing configured" do
      config = Routing.callback_retry_config(%{}, %{})
      assert config.max_attempts == 3
      assert config.backoff_ms == 500
      assert config.backoff_max_ms == 5000
    end

    test "enforces minimums" do
      config =
        Routing.callback_retry_config(
          %{
            "callback_max_attempts" => 0,
            "callback_backoff_ms" => -1,
            "callback_backoff_max_ms" => 0
          },
          %{}
        )

      assert config.max_attempts >= 1
      assert config.backoff_ms >= 0
      assert config.backoff_max_ms >= config.backoff_ms
    end
  end

  describe "resolve_callback_url/3" do
    test "returns configured callback URL" do
      assert Routing.resolve_callback_url(%{}, %{"callback_url" => "https://example.test"}, %{}) ==
               "https://example.test"
    end

    test "uses payload callback when override is allowed" do
      url =
        Routing.resolve_callback_url(
          %{"callback_url" => "https://payload.test"},
          %{"callback_url" => "https://config.test", "allow_callback_override" => true},
          %{}
        )

      assert url == "https://payload.test"
    end

    test "ignores payload callback when override is not allowed" do
      url =
        Routing.resolve_callback_url(
          %{"callback_url" => "https://payload.test"},
          %{"callback_url" => "https://config.test"},
          %{}
        )

      assert url == "https://config.test"
    end

    test "returns nil when no callback URL configured" do
      assert Routing.resolve_callback_url(%{}, %{}, %{}) == nil
    end
  end

  describe "integration flags" do
    test "allow_private_callback_hosts? defaults to false" do
      refute Routing.allow_private_callback_hosts?(%{}, %{})
    end

    test "allow_private_callback_hosts? returns true when set" do
      assert Routing.allow_private_callback_hosts?(%{"allow_private_callback_hosts" => true}, %{})
    end

    test "allow_query_token? defaults to false" do
      refute Routing.allow_query_token?(%{}, %{})
    end

    test "allow_payload_token? defaults to false" do
      refute Routing.allow_payload_token?(%{}, %{})
    end

    test "allow_payload_idempotency_key? defaults to false" do
      refute Routing.allow_payload_idempotency_key?(%{}, %{})
    end

    test "allow_callback_override? defaults to false" do
      refute Routing.allow_callback_override?(%{}, %{})
    end
  end

  describe "integration_metadata/2" do
    test "builds comprehensive metadata map" do
      meta = Routing.integration_metadata(%{"agent_id" => "test"}, %{})
      assert is_map(meta)
      assert Map.has_key?(meta, :session_key)
      assert Map.has_key?(meta, :queue_mode)
      assert Map.has_key?(meta, :mode)
      assert Map.has_key?(meta, :timeout_ms)
      assert meta.queue_mode == :collect
      assert meta.mode == :async
    end
  end
end
