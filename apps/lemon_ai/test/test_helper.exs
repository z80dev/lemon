# ============================================================================
# Test Configuration
# ============================================================================
#
# Integration tests are excluded by default. Select the credential-free
# loopback cases with:
#
#   scripts/test path apps/lemon_ai/test/integration_test.exs \
#     apps/lemon_ai/test/provider_integration_test.exs --only provider:error_handling
#
# Live cases may incur costs and fail setup if their credentials are missing.
# See docs/testing.md for provider-specific commands and credential opt-in.
# ============================================================================

# Load support files
Code.require_file("support/integration_config.ex", __DIR__)
Code.require_file("support/stream_server.ex", __DIR__)

# Provider retry backoff must not slow unit tests down; tests that assert on
# retry timing install their own `:sleep_fun`.
Application.put_env(:lemon_ai, :provider_retry, sleep_fun: fn _ms -> :ok end)

# Opt in with: mix test apps/lemon_ai/test/lemon_ai/stream_delta_benchmark_test.exs --include benchmark
ExUnit.configure(exclude: [:integration, :benchmark])
ExUnit.start(capture_log: true)
