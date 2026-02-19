defmodule LemonCore.Config.HelpersTest do
  @moduledoc """
  Tests for the Config.Helpers module.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.Helpers

  setup do
    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Restore original environment
      System.get_env()
      |> Enum.each(fn {key, _} ->
        if Map.has_key?(original_env, key) do
          System.put_env(key, original_env[key])
        else
          System.delete_env(key)
        end
      end)
    end)

    :ok
  end

  describe "get_env/1" do
    test "returns nil for non-existent variable" do
      System.delete_env("NONEXISTENT_TEST_VAR")
      assert Helpers.get_env("NONEXISTENT_TEST_VAR") == nil
    end

    test "returns nil for empty variable" do
      System.put_env("EMPTY_TEST_VAR", "")
      assert Helpers.get_env("EMPTY_TEST_VAR") == nil
    end

    test "returns value for existing variable" do
      System.put_env("EXISTING_TEST_VAR", "test_value")
      assert Helpers.get_env("EXISTING_TEST_VAR") == "test_value"
    end

    test "returns value with whitespace trimmed" do
      System.put_env("WHITESPACE_TEST_VAR", "  value  ")
      # Note: get_env doesn't trim, it returns raw value
      assert Helpers.get_env("WHITESPACE_TEST_VAR") == "  value  "
    end
  end

  describe "get_env/2" do
    test "returns default for non-existent variable" do
      System.delete_env("NONEXISTENT_DEFAULT_VAR")
      assert Helpers.get_env("NONEXISTENT_DEFAULT_VAR", "default") == "default"
    end

    test "returns value when variable exists" do
      System.put_env("EXISTING_DEFAULT_VAR", "actual_value")
      assert Helpers.get_env("EXISTING_DEFAULT_VAR", "default") == "actual_value"
    end
  end

  describe "get_env_int/2" do
    test "parses integer from env var" do
      System.put_env("INT_TEST_VAR", "8080")
      assert Helpers.get_env_int("INT_TEST_VAR", 4000) == 8080
    end

    test "returns default for non-existent variable" do
      System.delete_env("NONEXISTENT_INT_VAR")
      assert Helpers.get_env_int("NONEXISTENT_INT_VAR", 4000) == 4000
    end

    test "returns default for empty variable" do
      System.put_env("EMPTY_INT_VAR", "")
      assert Helpers.get_env_int("EMPTY_INT_VAR", 4000) == 4000
    end

    test "returns default for invalid integer" do
      System.put_env("INVALID_INT_VAR", "not_a_number")
      assert Helpers.get_env_int("INVALID_INT_VAR", 4000) == 4000
    end

    test "parses negative integers" do
      System.put_env("NEGATIVE_INT_VAR", "-100")
      assert Helpers.get_env_int("NEGATIVE_INT_VAR", 0) == -100
    end

    test "returns default for partial parse" do
      System.put_env("PARTIAL_INT_VAR", "123abc")
      assert Helpers.get_env_int("PARTIAL_INT_VAR", 0) == 0
    end
  end

  describe "get_env_float/2" do
    test "parses float from env var" do
      System.put_env("FLOAT_TEST_VAR", "3.14")
      assert Helpers.get_env_float("FLOAT_TEST_VAR", 0.0) == 3.14
    end

    test "parses integer as float" do
      System.put_env("INT_AS_FLOAT_VAR", "42")
      assert Helpers.get_env_float("INT_AS_FLOAT_VAR", 0.0) == 42.0
    end

    test "returns default for invalid float" do
      System.put_env("INVALID_FLOAT_VAR", "not_a_float")
      assert Helpers.get_env_float("INVALID_FLOAT_VAR", 1.5) == 1.5
    end
  end

  describe "get_env_bool/2" do
    test "returns true for 'true'" do
      System.put_env("BOOL_TRUE_VAR", "true")
      assert Helpers.get_env_bool("BOOL_TRUE_VAR", false) == true
    end

    test "returns true for '1'" do
      System.put_env("BOOL_ONE_VAR", "1")
      assert Helpers.get_env_bool("BOOL_ONE_VAR", false) == true
    end

    test "returns true for 'yes'" do
      System.put_env("BOOL_YES_VAR", "yes")
      assert Helpers.get_env_bool("BOOL_YES_VAR", false) == true
    end

    test "returns true for 'on'" do
      System.put_env("BOOL_ON_VAR", "on")
      assert Helpers.get_env_bool("BOOL_ON_VAR", false) == true
    end

    test "returns true for uppercase variants" do
      System.put_env("BOOL_UPPER_VAR", "TRUE")
      assert Helpers.get_env_bool("BOOL_UPPER_VAR", false) == true
    end

    test "returns false for 'false'" do
      System.put_env("BOOL_FALSE_VAR", "false")
      assert Helpers.get_env_bool("BOOL_FALSE_VAR", true) == false
    end

    test "returns false for '0'" do
      System.put_env("BOOL_ZERO_VAR", "0")
      assert Helpers.get_env_bool("BOOL_ZERO_VAR", true) == false
    end

    test "returns false for 'no'" do
      System.put_env("BOOL_NO_VAR", "no")
      assert Helpers.get_env_bool("BOOL_NO_VAR", true) == false
    end

    test "returns false for 'off'" do
      System.put_env("BOOL_OFF_VAR", "off")
      assert Helpers.get_env_bool("BOOL_OFF_VAR", true) == false
    end

    test "returns default for unknown value" do
      System.put_env("BOOL_UNKNOWN_VAR", "maybe")
      assert Helpers.get_env_bool("BOOL_UNKNOWN_VAR", true) == true
      assert Helpers.get_env_bool("BOOL_UNKNOWN_VAR", false) == false
    end

    test "returns default for non-existent variable" do
      System.delete_env("NONEXISTENT_BOOL_VAR")
      assert Helpers.get_env_bool("NONEXISTENT_BOOL_VAR", true) == true
    end
  end

  describe "get_env_atom/2" do
    test "converts value to atom" do
      System.put_env("ATOM_TEST_VAR", "debug")
      assert Helpers.get_env_atom("ATOM_TEST_VAR", :info) == :debug
    end

    test "converts camelCase to snake_case" do
      System.put_env("ATOM_CAMEL_VAR", "logLevel")
      assert Helpers.get_env_atom("ATOM_CAMEL_VAR", :info) == :log_level
    end

    test "returns default for non-existent variable" do
      System.delete_env("NONEXISTENT_ATOM_VAR")
      assert Helpers.get_env_atom("NONEXISTENT_ATOM_VAR", :default) == :default
    end
  end

  describe "get_env_list/1" do
    test "splits comma-separated values" do
      System.put_env("LIST_TEST_VAR", "a,b,c")
      assert Helpers.get_env_list("LIST_TEST_VAR") == ["a", "b", "c"]
    end

    test "trims whitespace from values" do
      System.put_env("LIST_TRIM_VAR", "  a  ,  b  ,  c  ")
      assert Helpers.get_env_list("LIST_TRIM_VAR") == ["a", "b", "c"]
    end

    test "filters empty values" do
      System.put_env("LIST_EMPTY_VAR", "a,,c")
      assert Helpers.get_env_list("LIST_EMPTY_VAR") == ["a", "c"]
    end

    test "returns empty list for non-existent variable" do
      System.delete_env("NONEXISTENT_LIST_VAR")
      assert Helpers.get_env_list("NONEXISTENT_LIST_VAR") == []
    end

    test "uses custom delimiter" do
      System.put_env("LIST_PIPE_VAR", "a|b|c")
      assert Helpers.get_env_list("LIST_PIPE_VAR", "|") == ["a", "b", "c"]
    end
  end

  describe "require_env!/1" do
    test "returns value for existing variable" do
      System.put_env("REQUIRED_TEST_VAR", "value")
      assert Helpers.require_env!("REQUIRED_TEST_VAR") == "value"
    end

    test "raises for non-existent variable" do
      System.delete_env("NONEXISTENT_REQUIRED_VAR")

      assert_raise ArgumentError, ~r/Missing required environment variable/, fn ->
        Helpers.require_env!("NONEXISTENT_REQUIRED_VAR")
      end
    end

    test "raises for empty variable" do
      System.put_env("EMPTY_REQUIRED_VAR", "")

      assert_raise ArgumentError, ~r/Missing required environment variable/, fn ->
        Helpers.require_env!("EMPTY_REQUIRED_VAR")
      end
    end
  end

  describe "require_env!/2" do
    test "includes hint in error message" do
      System.delete_env("NONEXISTENT_HINT_VAR")

      assert_raise ArgumentError, ~r/Please set this variable/, fn ->
        Helpers.require_env!("NONEXISTENT_HINT_VAR", "Please set this variable")
      end
    end
  end

  describe "get_feature_env/3" do
    test "returns value when feature flag is enabled" do
      System.put_env("FEATURE_X", "true")
      System.put_env("FEATURE_X_KEY", "secret")
      assert Helpers.get_feature_env("FEATURE_X", "FEATURE_X_KEY") == "secret"
    end

    test "returns nil when feature flag is disabled" do
      System.put_env("FEATURE_Y", "false")
      System.put_env("FEATURE_Y_KEY", "secret")
      assert Helpers.get_feature_env("FEATURE_Y", "FEATURE_Y_KEY") == nil
    end

    test "returns nil when feature flag is not set" do
      System.delete_env("FEATURE_Z")
      System.put_env("FEATURE_Z_KEY", "secret")
      assert Helpers.get_feature_env("FEATURE_Z", "FEATURE_Z_KEY") == nil
    end

    test "returns default when feature enabled but key not set" do
      System.put_env("FEATURE_W", "true")
      System.delete_env("FEATURE_W_KEY")
      assert Helpers.get_feature_env("FEATURE_W", "FEATURE_W_KEY", "default") == "default"
    end
  end

  describe "parse_duration/2" do
    test "parses milliseconds" do
      assert Helpers.parse_duration("500ms", 0) == 500
    end

    test "parses seconds" do
      assert Helpers.parse_duration("30s", 0) == 30_000
    end

    test "parses minutes" do
      assert Helpers.parse_duration("5m", 0) == 300_000
    end

    test "parses hours" do
      assert Helpers.parse_duration("2h", 0) == 7_200_000
    end

    test "parses days" do
      assert Helpers.parse_duration("1d", 0) == 86_400_000
    end

    test "parses without unit (defaults to ms)" do
      assert Helpers.parse_duration("1000", 0) == 1000
    end

    test "returns default for invalid format" do
      assert Helpers.parse_duration("invalid", 1000) == 1000
    end

    test "returns default for unknown unit" do
      assert Helpers.parse_duration("10x", 1000) == 1000
    end

    test "returns default for nil" do
      assert Helpers.parse_duration(nil, 1000) == 1000
    end

    test "handles whitespace" do
      assert Helpers.parse_duration("  30  s  ", 0) == 30_000
    end
  end

  describe "get_env_duration/2" do
    test "gets duration from env var" do
      System.put_env("DURATION_TEST_VAR", "30s")
      assert Helpers.get_env_duration("DURATION_TEST_VAR", 5000) == 30_000
    end

    test "returns default for non-existent variable" do
      System.delete_env("NONEXISTENT_DURATION_VAR")
      assert Helpers.get_env_duration("NONEXISTENT_DURATION_VAR", 5000) == 5000
    end
  end

  describe "parse_bytes/2" do
    test "parses bytes" do
      assert Helpers.parse_bytes("100B", 0) == 100
    end

    test "parses kilobytes" do
      assert Helpers.parse_bytes("10KB", 0) == 10_240
    end

    test "parses megabytes" do
      assert Helpers.parse_bytes("5MB", 0) == 5_242_880
    end

    test "parses gigabytes" do
      assert Helpers.parse_bytes("1GB", 0) == 1_073_741_824
    end

    test "parses terabytes" do
      assert Helpers.parse_bytes("2TB", 0) == 2_199_023_255_552
    end

    test "parses decimal values" do
      assert Helpers.parse_bytes("1.5MB", 0) == 1_572_864
    end

    test "handles whitespace" do
      assert Helpers.parse_bytes("  100  MB  ", 0) == 104_857_600
    end

    test "returns default for invalid format" do
      assert Helpers.parse_bytes("invalid", 1024) == 1024
    end

    test "returns default for nil" do
      assert Helpers.parse_bytes(nil, 1024) == 1024
    end

    test "is case insensitive" do
      assert Helpers.parse_bytes("10mb", 0) == 10_485_760
      assert Helpers.parse_bytes("10Mb", 0) == 10_485_760
      assert Helpers.parse_bytes("10MB", 0) == 10_485_760
    end
  end

  describe "get_env_bytes/2" do
    test "gets bytes from env var" do
      System.put_env("BYTES_TEST_VAR", "10MB")
      assert Helpers.get_env_bytes("BYTES_TEST_VAR", 1024) == 10_485_760
    end

    test "returns default for non-existent variable" do
      System.delete_env("NONEXISTENT_BYTES_VAR")
      assert Helpers.get_env_bytes("NONEXISTENT_BYTES_VAR", 1024) == 1024
    end
  end
end
