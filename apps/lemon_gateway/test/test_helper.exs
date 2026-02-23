Application.put_env(:lemon_gateway, :web_port, 0)

# Avoid poller lock collisions with any local `lemon` process that might be running while
# developers execute tests, and prevent sticky locks between `Application.stop/1` restarts.
lock_dir =
  Path.join([
    System.tmp_dir!(),
    "lemon_test_locks_#{System.unique_integer([:positive])}"
  ])

_ = File.mkdir_p(lock_dir)
System.put_env("LEMON_LOCK_DIR", lock_dir)

Code.require_file("support/mock_telegram_api.ex", __DIR__)
Code.require_file("support/async_helpers.ex", __DIR__)

ExUnit.start()
