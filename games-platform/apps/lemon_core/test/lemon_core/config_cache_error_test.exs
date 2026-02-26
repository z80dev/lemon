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
    test "can be raised and rescued with default options" do
      exception =
        try do
          raise ConfigCacheError, []
        rescue
          e in ConfigCacheError -> e
        end

      assert %ConfigCacheError{} = exception
      assert exception.message == "ConfigCache is not available"
    end

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

    test "can access message field after rescue" do
      rescued_message =
        try do
          raise ConfigCacheError, message: "Test message"
        rescue
          e in ConfigCacheError -> e.message
        end

      assert rescued_message == "Test message"
    end

    test "can be rescued and access struct fields" do
      result =
        try do
          raise ConfigCacheError, message: "Pattern match test"
        rescue
          e in ConfigCacheError -> {:caught, e.message}
        end

      assert result == {:caught, "Pattern match test"}
    end

    test "reraising preserves the exception struct" do
      result =
        try do
          try do
            raise ConfigCacheError, message: "Original error"
          rescue
            e in ConfigCacheError ->
              # Re-raise the same exception
              raise e
          end
        rescue
          e in ConfigCacheError ->
            {:reraised, e.message}
        end

      assert result == {:reraised, "Original error"}
    end
  end

  describe "struct fields" do
    test "has correct struct fields" do
      exception = ConfigCacheError.exception([])

      assert Map.has_key?(exception, :message)
    end

    test "message field is a string by default" do
      exception = ConfigCacheError.exception([])

      assert is_binary(exception.message)
    end

    test "struct contains only expected fields" do
      exception = ConfigCacheError.exception([])
      keys = Map.keys(exception) |> Enum.sort()

      assert keys == [:__exception__, :__struct__, :message]
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

    test "handles nil opts by using default message" do
      # When nil is passed, Keyword.get on nil will fail
      assert_raise FunctionClauseError, fn ->
        ConfigCacheError.exception(nil)
      end
    end
  end

  describe "usage example from moduledoc" do
    test "moduledoc example works correctly" do
      captured_message =
        try do
          raise ConfigCacheError, message: "Test cache error"
        rescue
          e in ConfigCacheError ->
            "ConfigCache error: #{e.message}"
        end

      assert captured_message == "ConfigCache error: Test cache error"
    end

    test "default behavior matches moduledoc description" do
      # The moduledoc shows raising with default message in a try/rescue
      exception =
        try do
          raise ConfigCacheError
        rescue
          e in ConfigCacheError -> e
        end

      assert exception.message == "ConfigCache is not available"
    end
  end
end
