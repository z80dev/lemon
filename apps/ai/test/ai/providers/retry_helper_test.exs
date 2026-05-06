defmodule Ai.Providers.RetryHelperTest do
  use ExUnit.Case, async: true

  alias Ai.Providers.RetryHelper

  describe "extract_retry_delay_ms/2" do
    test "extracts retry-after headers" do
      assert RetryHelper.extract_retry_delay_ms("some error", %{"retry-after" => "5.0"}) == 6000
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
end
