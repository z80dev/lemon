Code.require_file("support/app_isolation.ex", __DIR__)

ExUnit.start(capture_log: true)

Code.require_file("../../lemon_platform_test/test_support.exs", __DIR__)
