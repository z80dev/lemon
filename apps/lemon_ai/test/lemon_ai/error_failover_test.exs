defmodule LemonAi.ErrorFailoverTest do
  use ExUnit.Case, async: true

  alias LemonAi.Error
  alias LemonAi.Providers.RetryHelper
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

    test "missing local API keys remain credential failures through stream terminals" do
      for text <- [
            "No API key provided for Anthropic. Set ANTHROPIC_API_KEY or pass api_key in options.",
            "No API key provided for Kimi. Set KIMI_API_KEY (or MOONSHOT_API_KEY) or pass api_key in options.",
            "No API key provided for provider together. Configure an API key for it.",
            "OpenAI API key is required. Set OPENAI_API_KEY environment variable or pass it as an argument.",
            "OpenCode API key is required. Set OPENCODE_API_KEY environment variable or pass it as an argument."
          ] do
        event = stream_error_event(text)
        {:error, :error, message} = event

        for error <- [text, message, event, %RuntimeError{message: text}] do
          assert Error.classify(error) == :auth
          assert Error.failover_action(error) == :next_credential
          refute Error.retryable?(error)
          refute Error.stream_terminal_breaker_failure?(error)
        end
      end
    end

    test "unknown for unclassifiable terms" do
      assert Error.classify({:weird, :tuple}) == :unknown
      assert Error.classify("provider_unavailable") == :unknown
      assert Error.classify(nil) == :unknown
    end
  end

  describe "classification and same-credential retry contract" do
    test "HTTP errors keep the same decision through the public terminal boundary" do
      cases = [
        {429, %{"error" => %{"message" => "Too many requests"}}, :rate_limit, true},
        {400, %{"error" => %{"type" => "overloaded_error", "message" => "Overloaded"}},
         :transient, true},
        {400, %{"error" => %{"type" => "rate_limit_error", "message" => "Slow down"}},
         :rate_limit, true},
        {408, "Request Timeout", :transient, true},
        {409, "Request conflict", :transient, true},
        {425, "Too early", :transient, true},
        {500, "Internal Server Error", :server, true},
        {503, "Service Unavailable", :transient, true},
        {401, "Unauthorized. Please try again later.", :auth, false},
        {500, %{"error" => %{"code" => "invalid_api_key", "message" => "Try again later"}}, :auth,
         false},
        {400, "Invalid request: timeout must be positive", :client, false},
        {429, %{"error" => %{"type" => "invalid_request_error", "message" => "Bad request"}},
         :client, false},
        {503,
         %{
           "error" => %{
             "type" => "invalid_request_error",
             "code" => "context_length_exceeded",
             "message" => "Too much input. Please try again later"
           }
         }, :context_length, false},
        {429,
         %{
           "error" => %{
             "type" => "rate_limit_error",
             "code" => "insufficient_quota",
             "message" => "Please try again later"
           }
         }, :rate_limit, false}
      ]

      for {status, body, category, retryable} <- cases do
        parsed = Error.parse_http_error(status, body, [{"retry-after", "2.5"}])
        event = stream_error_event(parsed.message)
        {:error, :error, message} = event

        assert parsed.category == category
        assert parsed.retryable == retryable
        assert parsed.rate_limit_info.retry_after == 2_500

        for error <- [
              parsed,
              {:http_error, status, body},
              {:http_error, status, Jason.encode!(body)},
              {:http_error, status, body, %{"retry-after" => ["2.5"]}},
              message,
              event,
              parsed.message
            ] do
          assert Error.classify(error) == category
          assert Error.retryable?(error) == retryable
          assert Error.failover_action(error) == Error.failover_action(parsed)
        end
      end
    end

    test "parsed categories cannot enable permanent retries or lose an explicit stop decision" do
      for category <- [:rate_limit, :transient, :server] do
        assert Error.retryable?(%{category: category})
        refute Error.retryable?(%{category: category, retryable: false})
      end

      for category <- [:auth, :client, :context_length, :unknown] do
        refute Error.retryable?(%{category: category, retryable: true})
      end
    end

    test "account quota, credit and spend exhaustion never spin despite transient wording" do
      for text <- [
            "usage_limit_reached",
            "usage_not_included",
            "You have hit your ChatGPT usage limit. Please try again later.",
            "This request would exceed your account's monthly spend limit. Please try again later.",
            "This request would exceed your account's rate limit. Please try again later.",
            "You exceeded your current quota, please check your plan and billing details.",
            "Insufficient credits. Please try again later.",
            "This request would exceed your available credits given your current in-flight requests.",
            "You have exhausted your capacity on this model. Your quota will reset after 2h.",
            "配额已耗尽"
          ] do
        parsed = Error.parse_http_error(429, %{"error" => %{"message" => text}})

        for error <- [text, parsed, stream_error_event(text), {:error, text}] do
          assert Error.classify(error) == :rate_limit
          refute Error.retryable?(error)
          assert Error.failover_action(error) == :next_credential
        end
      end
    end

    test "structured Google account-quota reasons survive generic resource-exhausted text" do
      body = %{
        "error" => %{
          "status" => "RESOURCE_EXHAUSTED",
          "message" => "Resource exhausted. Please try again later.",
          "details" => [
            %{
              "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
              "reason" => "QUOTA_EXHAUSTED"
            }
          ]
        }
      }

      parsed = Error.parse_http_error(429, body)
      assert parsed.provider_message =~ "QUOTA_EXHAUSTED"

      for error <- [parsed, stream_error_event(parsed.message), {:http_error, 429, body}] do
        assert Error.classify(error) == :rate_limit
        refute Error.retryable?(error)
        assert Error.failover_action(error) == :next_credential
      end
    end

    test "per-minute caps and documented DashScope token throttles remain retryable" do
      for text <- [
            "This request would exceed your account's rate limit per minute.",
            "Quota exceeded for quota metric requests per minute",
            "You exceeded your current quota, please check your plan and billing details. " <>
              "https://help.aliyun.com/error-code#token-limit (type=insufficient_quota)"
          ] do
        parsed = Error.parse_http_error(429, %{"error" => %{"message" => text}})
        assert Error.classify(parsed) == :rate_limit
        assert Error.retryable?(parsed)
        assert Error.retryable?(stream_error_event(parsed.message))
      end
    end

    test "real context overflow phrases compact instead of retrying" do
      for text <- [
            "prompt is too long: 250000 tokens > 200000 maximum",
            "input is too long for requested model",
            "input token count 150000 exceeds the maximum 128000",
            "Input exceeds the context window of this model.",
            "maximum prompt length is 131072",
            "reduce the length of the messages",
            "Requested tokens exceed the available context size",
            "model_context_window_exceeded",
            "Too many tokens. Please try again later."
          ] do
        for error <- [
              text,
              stream_error_event(text),
              {:http_error, 400, %{"error" => %{"message" => text}}},
              {:http_error, 503, text}
            ] do
          assert Error.classify(error) == :context_length
          refute Error.retryable?(error)
          assert Error.failover_action(error) == :compact
        end
      end
    end

    test "transport terms and Req exceptions use the same network decision" do
      reasons = [
        :timeout,
        :closed,
        :econnrefused,
        :econnreset,
        :nxdomain,
        :enetdown,
        :enetunreach,
        :enetwork_unreachable,
        :ehostunreach,
        :unreachable,
        {:closed, :socket},
        {:failed_connect,
         [{:to_address, {~c"example.invalid", 443}}, {:inet, [:inet], :nxdomain}]},
        {:tls_alert, {:bad_record_mac, "TLS record corruption"}},
        {:socket_error, :timeout}
      ]

      for reason <- reasons,
          error <- [reason, {:error, reason}, %Req.TransportError{reason: reason}] do
        assert Error.classify(error) == :transient
        assert Error.retryable?(error)
        assert RetryHelper.retryable_transport_error?(error)
      end

      for error <- [
            {:tls_alert, {:unknown_ca, "Failed to verify certificate"}},
            %Req.TransportError{
              reason: {:tls_alert, {:certificate_expired, "Expired certificate"}}
            }
          ] do
        assert Error.classify(error) == :unknown
        refute Error.retryable?(error)
        refute RetryHelper.retryable_transport_error?(error)
      end
    end
  end

  test "malformed final tool arguments fail without retries or failover" do
    text = "Invalid tool arguments for timeout: expected a JSON object"

    for error <- [text, stream_error_event(text), %RuntimeError{message: text}] do
      assert Error.classify(error) == :client
      refute Error.retryable?(error)
      assert Error.failover_action(error) == :fail
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

    test "consumer-driven cancel terminals are exempt" do
      refute Error.stream_terminal_breaker_failure?({:canceled, :aborted})
      refute Error.stream_terminal_breaker_failure?({:canceled, :redirected})
      refute Error.stream_terminal_breaker_failure?({:canceled, :user_abort})
      refute Error.stream_terminal_breaker_failure?({:canceled, :assistant_aborted})
      refute Error.stream_terminal_breaker_failure?({:canceled, :canceled})
      refute Error.stream_terminal_breaker_failure?({:canceled, :shutdown})
    end

    test "hang and crash cancel terminals still count" do
      assert Error.stream_terminal_breaker_failure?({:canceled, :timeout})
      assert Error.stream_terminal_breaker_failure?({:canceled, :owner_down})
    end
  end

  describe "transport_retry_statuses/0" do
    test "RetryHelper sources its default set from Error" do
      for status <- Error.transport_retry_statuses() do
        assert RetryHelper.retryable_http_status?(status)
      end

      refute RetryHelper.retryable_http_status?(400)
      refute RetryHelper.retryable_http_status?(401)
    end

    test "Anthropic overloaded (529) and rate limits (429) retry in place" do
      assert RetryHelper.retryable_http_status?(529)
      assert RetryHelper.retryable_http_status?(429)
    end
  end
end
