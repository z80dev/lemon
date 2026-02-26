defmodule LemonCore.Config.LoggingTest do
  @moduledoc """
  Tests for the Config.Logging module.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.Logging

  setup do
    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Clear test env vars
      [
        "LEMON_LOG_FILE",
        "LEMON_LOG_LEVEL",
        "LEMON_LOG_MAX_NO_BYTES",
        "LEMON_LOG_MAX_NO_FILES",
        "LEMON_LOG_COMPRESS_ON_ROTATE",
        "LEMON_LOG_FILESYNC_REPEAT_INTERVAL"
      ]
      |> Enum.each(&System.delete_env/1)

      # Restore original values
      original_env
      |> Enum.each(fn {key, value} ->
        System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "resolve/1" do
    test "uses defaults when no settings provided" do
      config = Logging.resolve(%{})

      assert config.file == nil
      assert config.level == nil
      assert config.max_no_bytes == nil
      assert config.max_no_files == nil
      assert config.compress_on_rotate == nil
      assert config.filesync_repeat_interval == nil
    end

    test "uses settings from config map" do
      settings = %{
        "logging" => %{
          "file" => "./logs/app.log",
          "level" => "debug",
          "max_no_bytes" => 10_485_760,
          "max_no_files" => 5,
          "compress_on_rotate" => true,
          "filesync_repeat_interval" => 5000
        }
      }

      config = Logging.resolve(settings)

      assert config.file == "./logs/app.log"
      assert config.level == :debug
      assert config.max_no_bytes == 10_485_760
      assert config.max_no_files == 5
      assert config.compress_on_rotate == true
      assert config.filesync_repeat_interval == 5000
    end

    test "environment variables override settings" do
      System.put_env("LEMON_LOG_FILE", "./logs/env.log")
      System.put_env("LEMON_LOG_LEVEL", "error")
      System.put_env("LEMON_LOG_MAX_NO_BYTES", "20971520")
      System.put_env("LEMON_LOG_MAX_NO_FILES", "10")
      System.put_env("LEMON_LOG_COMPRESS_ON_ROTATE", "false")
      System.put_env("LEMON_LOG_FILESYNC_REPEAT_INTERVAL", "10000")

      settings = %{
        "logging" => %{
          "file" => "./logs/file.log",
          "level" => "info",
          "max_no_bytes" => 5_242_880,
          "max_no_files" => 3,
          "compress_on_rotate" => true,
          "filesync_repeat_interval" => 2000
        }
      }

      config = Logging.resolve(settings)

      assert config.file == "./logs/env.log"
      assert config.level == :error
      assert config.max_no_bytes == 20_971_520
      assert config.max_no_files == 10
      assert config.compress_on_rotate == false
      assert config.filesync_repeat_interval == 10_000
    end
  end

  describe "log level parsing" do
    test "parses debug level" do
      config = Logging.resolve(%{"logging" => %{"level" => "debug"}})
      assert config.level == :debug
    end

    test "parses info level" do
      config = Logging.resolve(%{"logging" => %{"level" => "info"}})
      assert config.level == :info
    end

    test "parses warning level" do
      config = Logging.resolve(%{"logging" => %{"level" => "warning"}})
      assert config.level == :warning
    end

    test "parses warn as warning" do
      config = Logging.resolve(%{"logging" => %{"level" => "warn"}})
      assert config.level == :warning
    end

    test "parses error level" do
      config = Logging.resolve(%{"logging" => %{"level" => "error"}})
      assert config.level == :error
    end

    test "handles uppercase level" do
      config = Logging.resolve(%{"logging" => %{"level" => "DEBUG"}})
      assert config.level == :debug
    end

    test "returns nil for unknown level" do
      config = Logging.resolve(%{"logging" => %{"level" => "unknown"}})
      assert config.level == nil
    end

    test "returns nil when level not set" do
      config = Logging.resolve(%{})
      assert config.level == nil
    end
  end

  describe "file configuration" do
    test "uses file from config" do
      config = Logging.resolve(%{"logging" => %{"file" => "./logs/custom.log"}})
      assert config.file == "./logs/custom.log"
    end

    test "env var overrides file" do
      System.put_env("LEMON_LOG_FILE", "./logs/env.log")
      config = Logging.resolve(%{"logging" => %{"file" => "./logs/config.log"}})
      assert config.file == "./logs/env.log"
    end
  end

  describe "rotation configuration" do
    test "uses rotation settings from config" do
      settings = %{
        "logging" => %{
          "max_no_bytes" => 5_242_880,
          "max_no_files" => 3,
          "compress_on_rotate" => false
        }
      }

      config = Logging.resolve(settings)

      assert config.max_no_bytes == 5_242_880
      assert config.max_no_files == 3
      assert config.compress_on_rotate == false
    end

    test "env vars override rotation settings" do
      System.put_env("LEMON_LOG_MAX_NO_BYTES", "10485760")
      System.put_env("LEMON_LOG_MAX_NO_FILES", "7")
      System.put_env("LEMON_LOG_COMPRESS_ON_ROTATE", "true")

      settings = %{
        "logging" => %{
          "max_no_bytes" => 1_048_576,
          "max_no_files" => 2,
          "compress_on_rotate" => false
        }
      }

      config = Logging.resolve(settings)

      assert config.max_no_bytes == 10_485_760
      assert config.max_no_files == 7
      assert config.compress_on_rotate == true
    end

    test "ignores invalid integer env vars" do
      System.put_env("LEMON_LOG_MAX_NO_BYTES", "invalid")
      System.put_env("LEMON_LOG_MAX_NO_FILES", "not_a_number")

      settings = %{
        "logging" => %{
          "max_no_bytes" => 5_242_880,
          "max_no_files" => 3
        }
      }

      config = Logging.resolve(settings)

      assert config.max_no_bytes == 5_242_880
      assert config.max_no_files == 3
    end
  end

  describe "filesync configuration" do
    test "uses filesync interval from config" do
      config = Logging.resolve(%{"logging" => %{"filesync_repeat_interval" => 3000}})
      assert config.filesync_repeat_interval == 3000
    end

    test "env var overrides filesync interval" do
      System.put_env("LEMON_LOG_FILESYNC_REPEAT_INTERVAL", "15000")
      config = Logging.resolve(%{"logging" => %{"filesync_repeat_interval" => 5000}})
      assert config.filesync_repeat_interval == 15_000
    end
  end

  describe "defaults/0" do
    test "returns the default logging configuration" do
      defaults = Logging.defaults()

      assert defaults["file"] == nil
      assert defaults["level"] == nil
      assert defaults["max_no_bytes"] == nil
      assert defaults["max_no_files"] == nil
      assert defaults["compress_on_rotate"] == nil
      assert defaults["filesync_repeat_interval"] == nil
    end
  end

  describe "struct type" do
    test "returns a properly typed struct" do
      config = Logging.resolve(%{})

      assert %Logging{} = config
      assert config.file == nil or is_binary(config.file)
      assert config.level == nil or is_atom(config.level)
      assert config.max_no_bytes == nil or is_integer(config.max_no_bytes)
      assert config.max_no_files == nil or is_integer(config.max_no_files)
      assert config.compress_on_rotate == nil or is_boolean(config.compress_on_rotate)
      assert config.filesync_repeat_interval == nil or is_integer(config.filesync_repeat_interval)
    end
  end
end
