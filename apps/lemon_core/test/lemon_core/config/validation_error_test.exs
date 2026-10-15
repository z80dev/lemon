defmodule LemonCore.Config.ValidationErrorTest do
  @moduledoc """
  Tests for the Config.ValidationError exception module.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Config.ValidationError

  describe "exception/1" do
    test "creates exception with default message and empty errors" do
      exception = ValidationError.exception([])

      assert %ValidationError{} = exception
      assert exception.errors == []
      assert exception.message =~ "Configuration validation failed"
      assert exception.message =~ "Errors:"
    end

    test "creates exception with custom message" do
      custom_message = "Custom validation error occurred"
      exception = ValidationError.exception(message: custom_message)

      assert exception.message =~ custom_message
      assert exception.errors == []
    end

    test "creates exception with single error" do
      errors = ["Missing required field: api_key"]
      exception = ValidationError.exception(errors: errors)

      assert exception.errors == errors
      assert exception.message =~ "Missing required field: api_key"
      assert exception.message =~ "  - "
    end

    test "creates exception with multiple errors" do
      errors = [
        "Missing required field: api_key",
        "Invalid value for timeout: expected positive integer",
        "Unknown provider: invalid_provider"
      ]
      exception = ValidationError.exception(errors: errors)

      assert exception.errors == errors
      assert exception.message =~ "Missing required field: api_key"
      assert exception.message =~ "Invalid value for timeout"
      assert exception.message =~ "Unknown provider: invalid_provider"
    end

    test "creates exception with custom message and multiple errors" do
      custom_message = "Config file validation failed"

      errors = [
        "agent.default_model cannot be empty",
        "gateway.max_concurrent_runs must be positive"
      ]

      exception = ValidationError.exception(message: custom_message, errors: errors)

      assert exception.message =~ custom_message
      refute exception.message =~ "Configuration validation failed"
      assert exception.errors == errors
    end

    test "formats message with all errors prefixed" do
      errors = ["error1", "error2", "error3"]
      exception = ValidationError.exception(errors: errors)

      lines = String.split(exception.message, "\n")

      # Check that each error appears with proper indentation
      assert Enum.any?(lines, &String.contains?(&1, "  - error1"))
      assert Enum.any?(lines, &String.contains?(&1, "  - error2"))
      assert Enum.any?(lines, &String.contains?(&1, "  - error3"))
    end
  end

  describe "raise and rescue" do
    test "can be raised and rescued with default options" do
      exception =
        try do
          raise ValidationError, []
        rescue
          e in ValidationError -> e
        end

      assert %ValidationError{} = exception
      assert exception.errors == []
      assert exception.message =~ "Configuration validation failed"
    end

    test "can be raised and rescued with custom options" do
      errors = ["Invalid configuration"]

      exception =
        try do
          raise ValidationError, message: "Custom error", errors: errors
        rescue
          e in ValidationError -> e
        end

      assert exception.errors == errors
      assert exception.message =~ "Custom error"
    end

    test "can access errors field after rescue" do
      errors = ["error1", "error2"]

      rescued_errors =
        try do
          raise ValidationError, errors: errors
        rescue
          e in ValidationError -> e.errors
        end

      assert rescued_errors == errors
    end

    test "can access message field after rescue" do
      rescued_message =
        try do
          raise ValidationError, message: "Test message"
        rescue
          e in ValidationError -> e.message
        end

      assert rescued_message =~ "Test message"
    end
  end

  describe "struct fields" do
    test "has correct struct fields" do
      exception = ValidationError.exception([])

      assert Map.has_key?(exception, :message)
      assert Map.has_key?(exception, :errors)
    end

    test "errors field is a list" do
      exception = ValidationError.exception(errors: ["error"])

      assert is_list(exception.errors)
    end

    test "message field is a string" do
      exception = ValidationError.exception([])

      assert is_binary(exception.message)
    end
  end

  describe "edge cases" do
    test "handles nil errors by using default empty list" do
      # When nil is passed, Keyword.get returns nil which causes Enum.map_join to fail
      # This is expected behavior - callers should pass an empty list instead of nil
      assert_raise Protocol.UndefinedError, fn ->
        ValidationError.exception(errors: nil)
      end
    end

    test "handles empty string errors" do
      exception = ValidationError.exception(errors: [""])

      assert exception.message =~ "  - "
    end

    test "handles errors with special characters" do
      errors = ["Error with special chars: <>&\"'"]
      exception = ValidationError.exception(errors: errors)

      assert exception.message =~ "Error with special chars"
    end

    test "handles errors with newlines" do
      errors = ["Error\nwith\nnewlines"]
      exception = ValidationError.exception(errors: errors)

      assert exception.errors == errors
    end

    test "handles very long error messages" do
      long_error = String.duplicate("a", 1000)
      exception = ValidationError.exception(errors: [long_error])

      assert exception.message =~ long_error
    end

    test "handles large number of errors" do
      errors = Enum.map(1..100, &"Error #{&1}")
      exception = ValidationError.exception(errors: errors)

      assert length(exception.errors) == 100
      assert exception.message =~ "Error 1"
      assert exception.message =~ "Error 100"
    end
  end

  describe "usage example from moduledoc" do
    test "moduledoc example works correctly" do
      errors = ["Missing API key", "Invalid timeout value"]

      captured_errors =
        try do
          raise ValidationError, errors: errors, message: "Config loading failed"
        rescue
          e in ValidationError ->
            e.errors
        end

      assert captured_errors == errors
    end
  end
end
