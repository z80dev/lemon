defmodule MarketIntel.ErrorsTest do
  use ExUnit.Case
  alias MarketIntel.Errors

  describe "api_error/2" do
    test "creates an API error tuple" do
      assert {:error, %{type: :api_error, source: "TestAPI", reason: "HTTP 500"}} =
               Errors.api_error("TestAPI", "HTTP 500")
    end

    test "formats non-string reasons" do
      assert {:error, %{type: :api_error, reason: "timeout"}} =
               Errors.api_error("API", :timeout)
    end
  end

  describe "config_error/1" do
    test "creates a config error tuple" do
      assert {:error, %{type: :config_error, reason: "missing key"}} =
               Errors.config_error("missing key")
    end
  end

  describe "parse_error/1" do
    test "creates a parse error tuple" do
      assert {:error, %{type: :parse_error, reason: "invalid JSON"}} =
               Errors.parse_error("invalid JSON")
    end
  end

  describe "network_error/1" do
    test "creates a network error tuple" do
      assert {:error, %{type: :network_error, reason: "timeout"}} =
               Errors.network_error(:timeout)
    end
  end

  describe "format_for_log/1" do
    test "formats API errors with source" do
      error = Errors.api_error("Polymarket", "HTTP 500")
      assert "API error from Polymarket: HTTP 500" = Errors.format_for_log(error)
    end

    test "formats config errors" do
      error = Errors.config_error("missing key")
      assert "Configuration: missing key" = Errors.format_for_log(error)
    end

    test "formats plain string errors" do
      assert "something failed" = Errors.format_for_log({:error, "something failed"})
    end

    test "formats other errors with inspect" do
      assert "{:bad, :value}" = Errors.format_for_log({:error, {:bad, :value}})
    end
  end

  describe "type?/2" do
    test "returns true for matching type" do
      error = Errors.api_error("API", "fail")
      assert Errors.type?(error, :api_error)
    end

    test "returns false for non-matching type" do
      error = Errors.config_error("fail")
      refute Errors.type?(error, :api_error)
    end
  end

  describe "unwrap/1" do
    test "unwraps structured errors" do
      error = Errors.api_error("API", "fail")
      assert "fail" = Errors.unwrap(error)
    end

    test "unwraps plain errors" do
      assert "plain" = Errors.unwrap({:error, "plain"})
    end

    test "returns non-errors as-is" do
      assert :value = Errors.unwrap(:value)
    end
  end
end
