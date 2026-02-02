# ============================================================================
# Test Configuration
# ============================================================================
#
# By default, integration tests are excluded. Integration tests make real API
# calls to LLM providers and may incur costs.
#
# To run integration tests:
#
#   # Run all integration tests (requires API keys to be set)
#   mix test --include integration
#
#   # Run tests for a specific provider
#   mix test --include integration --only provider:anthropic
#   mix test --include integration --only provider:openai
#   mix test --include integration --only provider:google
#
#   # Run only the error handling tests (no API keys required)
#   mix test --include integration --only provider:error_handling
#
#   # Run cross-provider consistency tests (requires 2+ API keys)
#   mix test --include integration --only provider:all
#
# Required environment variables for integration tests:
#   - ANTHROPIC_API_KEY     - For Anthropic/Claude tests
#   - OPENAI_API_KEY        - For OpenAI/GPT tests
#   - GEMINI_API_KEY        - For Google/Gemini tests
#     (or GOOGLE_API_KEY or GOOGLE_GENERATIVE_AI_API_KEY)
#
# Tests will be skipped automatically if the required API key is not set.
# ============================================================================

# Load support files
Code.compile_file("support/integration_config.ex", __DIR__)

ExUnit.configure(exclude: [:integration])
ExUnit.start()
