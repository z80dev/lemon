defmodule LemonCore.LoggerSetupTest do
  @moduledoc """
  Tests for the LoggerSetup module.
  """
  use ExUnit.Case, async: false

  alias LemonCore.LoggerSetup

  @handler_id :lemon_file

  setup do
    # Remove any existing handler before each test
    :logger.remove_handler(@handler_id)

    # Create temp directory for log files
    tmp_dir = Path.join(System.tmp_dir!(), "logger_setup_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Clean up handler
      :logger.remove_handler(@handler_id)

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "setup_from_config/1" do
    test "sets up file logging with valid config", %{tmp_dir: tmp_dir} do
      log_file = Path.join(tmp_dir, "test.log")

      config = %LemonCore.Config{
        logging: %{
          file_path: log_file,
          level: :info
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)

      # Verify handler was added
      assert {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config.config.file == to_charlist(log_file)
    end

    test "creates log directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      log_file = Path.join([tmp_dir, "nested", "deep", "test.log"])

      config = %LemonCore.Config{
        logging: %{
          file_path: log_file
        }
      }

      refute File.exists?(Path.dirname(log_file))

      assert :ok = LoggerSetup.setup_from_config(config)

      assert File.exists?(Path.dirname(log_file))
    end

    test "removes handler when file_path is nil" do
      # First set up a handler
      config_with_file = %LemonCore.Config{
        logging: %{
          file_path: "/tmp/test.log"
        }
      }

      LoggerSetup.setup_from_config(config_with_file)
      assert {:ok, _} = :logger.get_handler_config(@handler_id)

      # Now remove it
      config_without_file = %LemonCore.Config{
        logging: %{}
      }

      assert :ok = LoggerSetup.setup_from_config(config_without_file)
      assert {:error, _} = :logger.get_handler_config(@handler_id)
    end

    test "removes handler when file_path is empty string" do
      config = %LemonCore.Config{
        logging: %{
          file_path: ""
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)
      assert {:error, _} = :logger.get_handler_config(@handler_id)
    end

    test "removes handler when file_path is whitespace only" do
      config = %LemonCore.Config{
        logging: %{
          file_path: "   "
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)
      assert {:error, _} = :logger.get_handler_config(@handler_id)
    end

    test "handles missing logging section gracefully" do
      config = %LemonCore.Config{}

      assert :ok = LoggerSetup.setup_from_config(config)
      assert {:error, _} = :logger.get_handler_config(@handler_id)
    end

    test "sets log level when specified", %{tmp_dir: tmp_dir} do
      log_file = Path.join(tmp_dir, "level_test.log")

      config = %LemonCore.Config{
        logging: %{
          file_path: log_file,
          level: :warning
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)

      {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config.level == :warning
    end

    test "handles atom log levels" do
      config = %LemonCore.Config{
        logging: %{
          file_path: "/tmp/atom_level.log",
          level: :debug
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)

      {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config.level == :debug
    end

    test "handles string log levels" do
      config = %LemonCore.Config{
        logging: %{
          file_path: "/tmp/string_level.log",
          level: "error"
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)

      {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config.level == :error
    end

    test "handles uppercase string log levels" do
      config = %LemonCore.Config{
        logging: %{
          file_path: "/tmp/uppercase_level.log",
          level: "WARNING"
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)

      {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config.level == :warning
    end

    test "handles 'warn' as alias for 'warning'" do
      config = %LemonCore.Config{
        logging: %{
          file_path: "/tmp/warn_alias.log",
          level: "warn"
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config)

      {:ok, handler_config} = :logger.get_handler_config(@handler_id)
      assert handler_config.level == :warning
    end

    test "ignores invalid log levels" do
      config = %LemonCore.Config{
        logging: %{
          file_path: "/tmp/invalid_level.log",
          level: "invalid_level"
        }
      }

      # Should not crash
      assert :ok = LoggerSetup.setup_from_config(config)
    end

    test "updates handler when file path changes", %{tmp_dir: tmp_dir} do
      log_file1 = Path.join(tmp_dir, "first.log")
      log_file2 = Path.join(tmp_dir, "second.log")

      config1 = %LemonCore.Config{
        logging: %{
          file_path: log_file1
        }
      }

      config2 = %LemonCore.Config{
        logging: %{
          file_path: log_file2
        }
      }

      # Set up first file
      assert :ok = LoggerSetup.setup_from_config(config1)
      {:ok, handler1} = :logger.get_handler_config(@handler_id)
      assert handler1.config.file == to_charlist(log_file1)

      # Change to second file
      assert :ok = LoggerSetup.setup_from_config(config2)
      {:ok, handler2} = :logger.get_handler_config(@handler_id)
      assert handler2.config.file == to_charlist(log_file2)
    end

    test "keeps same handler when file path unchanged", %{tmp_dir: tmp_dir} do
      log_file = Path.join(tmp_dir, "same.log")

      config = %LemonCore.Config{
        logging: %{
          file_path: log_file,
          level: :info
        }
      }

      # Set up initially
      assert :ok = LoggerSetup.setup_from_config(config)
      {:ok, _handler1} = :logger.get_handler_config(@handler_id)

      # Call again with same file but different level
      config2 = %LemonCore.Config{
        logging: %{
          file_path: log_file,
          level: :debug
        }
      }

      assert :ok = LoggerSetup.setup_from_config(config2)
      {:ok, handler2} = :logger.get_handler_config(@handler_id)

      # Handler should be updated (same file, new level)
      assert handler2.config.file == to_charlist(log_file)
      assert handler2.level == :debug
    end

    test "gracefully handles errors without crashing", %{tmp_dir: tmp_dir} do
      # Create a read-only directory
      read_only_dir = Path.join(tmp_dir, "readonly")
      File.mkdir_p!(read_only_dir)
      File.chmod!(read_only_dir, 0o444)

      log_file = Path.join(read_only_dir, "test.log")

      config = %LemonCore.Config{
        logging: %{
          file_path: log_file
        }
      }

      # Should return :ok even though it can't create the file
      assert :ok = LoggerSetup.setup_from_config(config)

      # Restore permissions for cleanup
      File.chmod!(read_only_dir, 0o755)
    end
  end

  describe "path normalization" do
    test "expands relative paths", %{tmp_dir: _tmp_dir} do
      relative_path = "./relative/test.log"

      config = %LemonCore.Config{
        logging: %{
          file_path: relative_path
        }
      }

      # Should not crash - path will be expanded
      assert :ok = LoggerSetup.setup_from_config(config)
    end

    test "handles paths with tilde" do
      config = %LemonCore.Config{
        logging: %{
          file_path: "~/test.log"
        }
      }

      # Should not crash - path will be expanded
      assert :ok = LoggerSetup.setup_from_config(config)
    end
  end

  describe "all log levels" do
    test "handles all valid log levels", %{tmp_dir: tmp_dir} do
      levels = [
        {"debug", :debug},
        {"info", :info},
        {"notice", :notice},
        {"warning", :warning},
        {"warn", :warning},
        {"error", :error},
        {"critical", :critical},
        {"alert", :alert},
        {"emergency", :emergency}
      ]

      for {input, expected} <- levels do
        log_file = Path.join(tmp_dir, "level_#{input}.log")

        config = %LemonCore.Config{
          logging: %{
            file_path: log_file,
            level: input
          }
        }

        # Remove existing handler
        :logger.remove_handler(@handler_id)

        assert :ok = LoggerSetup.setup_from_config(config)

        {:ok, handler_config} = :logger.get_handler_config(@handler_id)
        assert handler_config.level == expected,
               "Expected level #{expected} for input '#{input}', got #{handler_config.level}"
      end
    end
  end
end
