defmodule LemonCore.LoggingTest do
  use ExUnit.Case, async: false

  require Logger

  test "can write logs to a configured file" do
    tmp_dir = Path.join(System.tmp_dir!(), "lemon_logging_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    log_path = Path.join(tmp_dir, "lemon.log")
    handler_id = :"lemon_file_test_#{System.unique_integer([:positive])}"

    cfg = %LemonCore.Config{logging: %{file: log_path, level: :info}}

    on_exit(fn ->
      _ = :logger.remove_handler(handler_id)
      File.rm_rf!(tmp_dir)
    end)

    assert :ok = LemonCore.Logging.maybe_add_file_handler(cfg, handler_id: handler_id, force?: true)

    msg = "hello-from-test-#{System.unique_integer([:positive])}"
    Logger.info(msg)

    # Ensure the handler flushes buffered writes to disk.
    Logger.flush()
    assert :ok = :logger_std_h.filesync(handler_id)

    assert File.read!(log_path) =~ msg
  end
end

