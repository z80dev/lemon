defmodule LemonAi.ErrorFailoverTest do
  use ExUnit.Case, async: true

  alias LemonAi.Error
  alias LemonAi.Types.{AssistantMessage, Usage}

  defp stream_error_event(error_message) do
    message = %AssistantMessage{
      role: :assistant,
      content: [],
      api: :anthropic_messages,
      provider: :anthropic,
      model: "test-model",
      usage: %Usage{},
      stop_reason: :error,
      error_message: error_message,
      timestamp: System.system_time(:millisecond)
    }

    {:error, :error, message}
  end

  describe "failover_action/1 with http_error tuples" do
    test "400 client error fails without failover" do
      assert Error.failover_action(
               {:http_error, 400, %{"error" => %{"message" => "Invalid request body"}}}
             ) == :fail
    end

    test "401 auth error rotates credentials" do
      assert Error.failover_action({:http_error, 401, %{"error" => "Invalid API key"}}) ==
               :next_credential
    end

    test "403 auth error rotates credentials" do
      assert Error.failover_action({:http_error, 403, "Forbidden"}) == :next_credential
    end

    test "429 rate limit rotates credentials" do
      assert Error.failover_action(
               {:http_error, 429, %{"error" => %{"message" => "Rate limit exceeded"}}}
             ) == :next_credential
    end

    test "503 transient error moves to the next provider" do
      assert Error.failover_action({:http_error, 503, "Service Unavailable"}) == :next_provider
    end

    test "500 server error moves to the next provider" do
      assert Error.failover_action({:http_error, 500, "Internal Server Error"}) == :next_provider
    end

    test "context length exceeded compacts instead of failing over" do
      assert Error.failover_action(
               {:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}}
             ) == :compact
    end
  end

  describe "failover_action/1 with flexible inputs" do
    test "parsed error maps classify by category" do
      assert Error.failover_action(%{category: :auth}) == :next_credential
      assert Error.failover_action(%{category: :rate_limit}) == :next_credential
      assert Error.failover_action(%{category: :client}) == :fail
      assert Error.failover_action(%{category: :context_length}) == :compact
      assert Error.failover_action(%{category: :server}) == :next_provider
      assert Error.failover_action(%{category: :transient}) == :next_provider
    end

    test "stream-terminal events classify on the message text" do
      assert Error.failover_action(stream_error_event("Rate limit exceeded (HTTP 429)")) ==
               :next_credential

      assert Error.failover_action(stream_error_event("HTTP 400: invalid request body")) ==
               :fail

      assert Error.failover_action(stream_error_event("invalid x-api-key")) == :next_credential

      assert Error.failover_action(
               stream_error_event(
                 "maximum context length is 8192 tokens, context length exceeded"
               )
             ) == :compact

      assert Error.failover_action(stream_error_event("Service temporarily unavailable")) ==
               :next_provider
    end

    test "transport reason atoms move to the next provider" do
      assert Error.failover_action(:timeout) == :next_provider
      assert Error.failover_action(:econnrefused) == :next_provider
    end

    test "exceptions classify on their message" do
      assert Error.failover_action(%RuntimeError{message: "connection timeout"}) ==
               :next_provider
    end

    test "unclassifiable errors fail open to the next provider" do
      assert Error.failover_action({:some, :weird_term}) == :next_provider
      assert Error.failover_action("provider_unavailable") == :next_provider

      assert Error.failover_action(stream_error_event("something inexplicable happened")) ==
               :next_provider
    end
  end

  describe "classify/1" do
    test "classifies http_error tuples via parse_http_error" do
      assert Error.classify({:http_error, 429, "Too Many Requests"}) == :rate_limit
      assert Error.classify({:http_error, 401, "Unauthorized"}) == :auth
      assert Error.classify({:http_error, 400, "Bad Request"}) == :client
      assert Error.classify({:http_error, 500, "Internal Server Error"}) == :server
      assert Error.classify({:http_error, 503, "Service Unavailable"}) == :transient
    end

    test "classifies known atoms" do
      assert Error.classify(:rate_limited) == :rate_limit
      assert Error.classify(:context_length_exceeded) == :context_length
      assert Error.classify(:timeout) == :transient
      assert Error.classify(:closed) == :transient
    end

    test "classifies message text embedded statuses" do
      assert Error.classify("Authentication failed (HTTP 401): bad key") == :auth
      assert Error.classify("Server error (HTTP 500)") == :server
      assert Error.classify("HTTP 400: no thanks") == :client
    end

    test "unknown for unclassifiable terms" do
      assert Error.classify({:weird, :tuple}) == :unknown
      assert Error.classify("provider_unavailable") == :unknown
      assert Error.classify(nil) == :unknown
    end
  end

  describe "circuit_breaker_failure?/1 (request-level set)" do
    test "5xx statuses are failures" do
      assert Error.circuit_breaker_failure?({:http_error, 500, "boom"})
      assert Error.circuit_breaker_failure?({:http_error, 503, "unavailable"})
    end

    test "4xx statuses are explicitly not failures" do
      refute Error.circuit_breaker_failure?({:http_error, 400, "bad request"})
      refute Error.circuit_breaker_failure?({:http_error, 401, "unauthorized"})
      refute Error.circuit_breaker_failure?({:http_error, 429, "rate limited"})
    end

    test "transport failures count" do
      assert Error.circuit_breaker_failure?(:timeout)
      assert Error.circuit_breaker_failure?(:closed)
      assert Error.circuit_breaker_failure?(:econnrefused)
      assert Error.circuit_breaker_failure?(:econnreset)
      assert Error.circuit_breaker_failure?(:nxdomain)
    end

    test "timeout-ish strings count, other strings do not" do
      assert Error.circuit_breaker_failure?("request timeout after 30s")
      assert Error.circuit_breaker_failure?("econnrefused")
      refute Error.circuit_breaker_failure?("invalid api key")
    end
  end

  describe "stream_terminal_breaker_failure?/1" do
    test "auth-shaped stream errors are exempt" do
      {:error, _reason, message} =
        stream_error_event("Authentication failed (HTTP 401): invalid x-api-key")

      refute Error.stream_terminal_breaker_failure?(message)
    end

    test "rate-limit-shaped stream errors are exempt" do
      {:error, _reason, message} = stream_error_event("Rate limit exceeded (HTTP 429)")
      refute Error.stream_terminal_breaker_failure?(message)
    end

    test "client-shaped and context-length stream errors are exempt" do
      {:error, _reason, message} = stream_error_event("HTTP 400: invalid request body")
      refute Error.stream_terminal_breaker_failure?(message)

      {:error, _reason, message} = stream_error_event("context_length_exceeded")
      refute Error.stream_terminal_breaker_failure?(message)
    end

    test "server, transient, and unclassifiable stream errors count" do
      {:error, _reason, message} = stream_error_event("Server error (HTTP 500)")
      assert Error.stream_terminal_breaker_failure?(message)

      {:error, _reason, message} = stream_error_event("stream failed")
      assert Error.stream_terminal_breaker_failure?(message)

      assert Error.stream_terminal_breaker_failure?(:timeout)
      assert Error.stream_terminal_breaker_failure?({:canceled, :owner_down})
    end
  end

  describe "transport_retry_statuses/0" do
    test "matches RetryHelper's historical retry-in-place set" do
      assert Error.transport_retry_statuses() ==
               [408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
    end

    test "RetryHelper sources its default set from Error" do
      for status <- Error.transport_retry_statuses() do
        assert LemonAi.Providers.RetryHelper.retryable_http_status?(status)
      end

      refute LemonAi.Providers.RetryHelper.retryable_http_status?(400)
      refute LemonAi.Providers.RetryHelper.retryable_http_status?(401)
      refute LemonAi.Providers.RetryHelper.retryable_http_status?(529)
    end
  end
end
