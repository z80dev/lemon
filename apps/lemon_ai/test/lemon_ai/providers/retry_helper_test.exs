defmodule LemonAi.Providers.RetryHelperTest do
  use ExUnit.Case, async: false

  alias LemonAi.Providers.RetryHelper

  test "healthy alternates surface rate limits without sleeping, not other errors" do
    parent = self()
    previous = Application.get_env(:lemon_ai, :provider_retry)

    Application.put_env(:lemon_ai, :provider_retry,
      sleep_fun: fn ms -> send(parent, {:sleep, ms}) end
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_ai, :provider_retry, previous),
        else: Application.delete_env(:lemon_ai, :provider_retry)
    end)

    policy =
      RetryHelper.policy(%LemonAi.Types.StreamOptions{
        provider_retry: %{alternate_available: true}
      })

    for headers <- [%{}, %{"retry-after" => "1"}, %{"retry-after" => "60"}] do
      delay =
        RetryHelper.http_retry_delay_ms(0, headers, policy, {:http_error, 429, "rate limited"})

      assert delay == :give_up
      if is_integer(delay), do: RetryHelper.sleep(delay)
    end

    refute_receive {:sleep, _}, 0

    assert RetryHelper.http_retry_delay_ms(
             0,
             %{"retry-after" => "2"},
             policy,
             {:http_error, 503, "unavailable"}
           ) == 2_000

    delay =
      RetryHelper.http_retry_delay_ms(
        0,
        %{"retry-after" => "2"},
        RetryHelper.policy(),
        {:http_error, 429, "rate limited"}
      )

    assert delay == 2_000
    RetryHelper.sleep(delay)
    assert_receive {:sleep, 2_000}
  end

  test "quota exhaustion classification remains rate_limit and exposes exhaustion" do
    for error <- [
          "insufficient_quota",
          {:http_error, 429,
           %{"error" => %{"code" => "insufficient_quota", "message" => "No credits"}}}
        ] do
      details = LemonAi.Error.to_error_details(error)
      assert details.category == :rate_limit
      assert LemonAi.Error.quota_exhausted?(details)
    end

    refute LemonAi.Error.quota_exhausted?({:http_error, 429, "requests per minute exceeded"})
  end

  describe "extract_retry_delay_ms/2" do
    test "extracts retry-after headers" do
      assert RetryHelper.extract_retry_delay_ms("some error", %{"retry-after" => "5.0"}) == 6000
    end

    test "extracts millisecond retry-after headers" do
      assert RetryHelper.extract_retry_delay_ms("some error", %{"retry-after-ms" => "1500"}) ==
               2500

      assert RetryHelper.extract_retry_delay_ms("some error", %{"x-ms-retry-after-ms" => "2000"}) ==
               3000
    end

    test "extracts x-ratelimit-reset-after headers case-insensitively" do
      delay =
        RetryHelper.extract_retry_delay_ms("some error", [
          {"X-RateLimit-Reset-After", ["10.0"]}
        ])

      assert delay == 11_000
    end

    test "extracts reset-after text durations" do
      assert RetryHelper.extract_retry_delay_ms("Your quota will reset after 1h2m3s") ==
               3_724_000
    end

    test "extracts retry-in hints" do
      assert RetryHelper.extract_retry_delay_ms("Please retry in 500ms") == 1500
      assert RetryHelper.extract_retry_delay_ms("Please retry in 5s") == 6000
    end

    test "extracts retryDelay JSON fields" do
      assert RetryHelper.extract_retry_delay_ms(~s("retryDelay": "34.074824224s")) == 35_075
    end

    test "headers take priority over body hints" do
      delay =
        RetryHelper.extract_retry_delay_ms("Please retry in 100s", %{"retry-after" => "5.0"})

      assert delay == 6000
    end

    test "returns nil when no retry delay exists" do
      assert RetryHelper.extract_retry_delay_ms("temporary overload") == nil

      assert RetryHelper.extract_retry_delay_ms("temporary overload", %{"retry-after" => "0"}) ==
               nil
    end
  end

  describe "retry_after_ms/2" do
    @now ~U[2026-09-27 12:00:00Z]

    test "reads delta-seconds and HTTP-date retry-after exactly (no buffer)" do
      assert RetryHelper.retry_after_ms(%{"retry-after" => ["7"]}, @now) == 7_000

      assert RetryHelper.retry_after_ms(
               %{"retry-after" => "Sun, 27 Sep 2026 12:00:30 GMT"},
               @now
             ) == 30_000
    end

    test "falls back to the latest exhausted anthropic rate-limit reset" do
      headers = %{
        "anthropic-ratelimit-requests-remaining" => "12",
        "anthropic-ratelimit-requests-reset" => "2026-09-27T12:05:00Z",
        "anthropic-ratelimit-input-tokens-remaining" => "0",
        "anthropic-ratelimit-input-tokens-reset" => "2026-09-27T12:00:20Z",
        "anthropic-ratelimit-output-tokens-remaining" => "0",
        "anthropic-ratelimit-output-tokens-reset" => "2026-09-27T12:00:45Z"
      }

      assert RetryHelper.retry_after_ms(headers, @now) == 45_000
    end

    test "past or missing hints yield nil" do
      past = %{"retry-after" => "Sun, 27 Sep 2026 11:00:00 GMT"}
      assert RetryHelper.retry_after_ms(past, @now) == nil
      assert RetryHelper.retry_after_ms(%{"x-request-id" => "abc"}, @now) == nil
    end

    test "invalid and expired preferred hints fall through instead of hiding valid delays" do
      for retry_after <- ["invalid", "0", "-1", "Sun, 27 Sep 2026 11:00:00 GMT"] do
        headers = %{"retry-after" => retry_after, "retry-after-ms" => ["1500.25"]}
        assert RetryHelper.retry_after_ms(headers, @now) == 1501
        assert LemonAi.Error.extract_rate_limit_info(headers).retry_after == 1501
      end

      headers = %{
        "retry-after" => "invalid",
        "retry-after-ms" => "-3",
        "x-ms-retry-after-ms" => "bad",
        "x-ratelimit-reset-after" => "2.5"
      }

      assert RetryHelper.retry_after_ms(headers, @now) == 2500
      assert LemonAi.Error.extract_rate_limit_info(headers).retry_after == 2500
    end

    test "invalid headers still allow the exhausted Anthropic reset hint" do
      headers = %{
        "retry-after" => "not a date",
        "anthropic-ratelimit-requests-remaining" => 0,
        "anthropic-ratelimit-requests-reset" => "2026-09-27T12:00:30Z"
      }

      assert RetryHelper.retry_after_ms(headers, @now) == 30_000
    end
  end

  describe "error_retry_after_ms/1" do
    test "structured timing retains priority and missing nested hints fall through" do
      message = %LemonAi.Types.AssistantMessage{
        error_details: %{rate_limit_info: %{retry_after: 1200}},
        retry_after_ms: 2300,
        error_message: "Please retry in 5s"
      }

      assert RetryHelper.error_retry_after_ms(message) == 1200

      assert RetryHelper.error_retry_after_ms(%{message | error_details: %{rate_limit_info: nil}}) ==
               2300

      assert RetryHelper.error_retry_after_ms(%{
               message
               | error_details: nil,
                 retry_after_ms: nil
             }) ==
               6000
    end

    test "explicit and rate-limit metadata handle zero and serialized maps" do
      assert RetryHelper.error_retry_after_ms(%{
               retry_after_ms: 0,
               error_message: "Please retry in 2s"
             }) == 0

      assert RetryHelper.error_retry_after_ms(%{
               "error_details" => %{"rate_limit_info" => %{"retry_after" => 17}},
               "retry_after_ms" => 42
             }) == 17

      assert RetryHelper.error_retry_after_ms(%{
               retry_after_ms: -1,
               rate_limit_info: %{retry_after: 42}
             }) == 42
    end

    test "HTTP headers win over body hints and preserve header precedence" do
      error =
        {:http_error, 429, %{"retry_after_ms" => 5000},
         [{"retry-after", "2"}, {"retry-after-ms", "3000"}]}

      assert RetryHelper.error_retry_after_ms(error) == 2000

      assert RetryHelper.error_retry_after_ms({:http_error, 429, %{"retry_after_ms" => 5000}, []}) ==
               5000
    end
  end

  describe "retry policy" do
    @policy %{
      max_attempts: 4,
      base_delay_ms: 1_000,
      max_delay_ms: 30_000,
      max_retry_after_ms: 60_000
    }

    test "allows four attempts in total" do
      assert Enum.map(0..3, &RetryHelper.retry_allowed?(&1, @policy)) == [true, true, true, false]
    end

    test "backoff doubles from ~1s with jitter and is capped" do
      for _ <- 1..50 do
        assert RetryHelper.backoff_delay_ms(0, @policy) in 501..1_000
        assert RetryHelper.backoff_delay_ms(2, @policy) in 2_001..4_000
        assert RetryHelper.backoff_delay_ms(10, @policy) in 15_001..30_000
      end
    end

    test "server hints win over backoff, and waits beyond the cap give up" do
      assert RetryHelper.http_retry_delay_ms(0, %{"retry-after" => "9"}, @policy) == 9_000
      assert RetryHelper.http_retry_delay_ms(0, %{"retry-after" => "61"}, @policy) == :give_up
      assert RetryHelper.http_retry_delay_ms(1, %{}, @policy) in 1_001..2_000
    end
  end

  describe "public retry classification" do
    test "status-only decisions agree with classification when no provider body is available" do
      for status <- [400, 401, 403, 404, 408, 409, 425, 429] ++ Enum.to_list(500..599) do
        retryable = LemonAi.Error.retryable?({:http_error, status, nil})
        assert RetryHelper.retryable_http_status?(status) == retryable
        assert RetryHelper.retryable_http_error?(status, nil) == retryable
      end
    end

    test "HTTP body evidence overrides retryable status codes" do
      for body <- [
            %{"error" => %{"code" => "context_length_exceeded"}},
            %{"error" => %{"type" => "invalid_request_error", "message" => "Bad request"}},
            %{"error" => %{"code" => "invalid_api_key", "message" => "Try again later"}},
            %{"error" => %{"code" => "insufficient_quota", "message" => "Try again later"}}
          ],
          status <- [429, 500, 503, 529] do
        refute RetryHelper.retryable_http_error?(status, body)
        refute RetryHelper.retryable_http_error?(status, Jason.encode!(body))
      end
    end

    test "text retry classification uses the public permanent-error exclusions" do
      for text <- [
            "Invalid request: connection timeout must be positive",
            "Authentication failed. Please try again later.",
            "prompt is too long. Service temporarily unavailable.",
            "Rate limit exceeded: usage_limit_reached",
            "This request would exceed your account's monthly spend limit. Please try again later."
          ] do
        refute RetryHelper.retryable_error_text?(text)
        refute LemonAi.Error.retryable?(text)
      end

      for text <- [
            "Rate limit exceeded",
            "Resource exhausted",
            "Internal Server Error",
            "Connection reset",
            "other side closed",
            "upstream connect error",
            "HTTP/1.1 503"
          ] do
        assert RetryHelper.retryable_error_text?(text)
        assert LemonAi.Error.retryable?(text)
      end
    end
  end
end
