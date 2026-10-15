defmodule LemonCore.ConfigCacheErrorTest do
  @moduledoc """
  Tests for the ConfigCacheError exception module.
  """
  use ExUnit.Case, async: true

  alias LemonCore.ConfigCacheError

  describe "exception/1" do
    test "creates exception with default message" do
      exception = ConfigCacheError.exception([])

      assert %ConfigCacheError{} = exception
      assert exception.message == "ConfigCache is not available"
    end

    test "creates exception with custom message" do
      custom_message = "Custom cache error message"
      exception = ConfigCacheError.exception(message: custom_message)

      assert exception.message == custom_message
    end

    test "creates exception with empty message" do
      exception = ConfigCacheError.exception(message: "")

      assert exception.message == ""
    end
  end

  describe "raise and rescue" do
    test "can be raised and rescued with custom message" do
      custom_message = "Cache table not found"

      exception =
        try do
          raise ConfigCacheError, message: custom_message
        rescue
          e in ConfigCacheError -> e
        end

      assert exception.message == custom_message
    end
  end

  describe "edge cases" do
    test "handles message with special characters" do
      message = "Error with special chars: <>&\"'"
      exception = ConfigCacheError.exception(message: message)

      assert exception.message == message
    end

    test "handles message with newlines" do
      message = "Error\nwith\nmultiple\nlines"
      exception = ConfigCacheError.exception(message: message)

      assert exception.message == message
    end

    test "handles very long message" do
      long_message = String.duplicate("a", 1000)
      exception = ConfigCacheError.exception(message: long_message)

      assert exception.message == long_message
    end

    test "handles message with unicode characters" do
      message = "Cache error: 缓存不可用 🚨"
      exception = ConfigCacheError.exception(message: message)

      assert exception.message == message
    end

    @tag invalid_opts: nil
    test "rejects nil opts", %{invalid_opts: opts} do
      assert_raise FunctionClauseError, fn ->
        ConfigCacheError.exception(opts)
      end
    end
  end
end
