# By default, exclude integration tests that require external CLIs/services.
ExUnit.configure(exclude: [:integration])
ExUnit.start(capture_log: true)

Code.require_file("../../lemon_platform_test/test_support.exs", __DIR__)

# Compile and load support files
Code.require_file("support/mocks.ex", __DIR__)
