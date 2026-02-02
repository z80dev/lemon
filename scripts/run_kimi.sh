#!/bin/bash
# Run Lemon with Kimi API
# Usage: ./scripts/run_kimi.sh [command] [args...]
#
# Commands:
#   test|smoke        Run smoke test (default)
#   integration       Run AI provider integration tests (Kimi)
#   integration-all   Run all integration tests (AI + Agent Loop)
#   agent-loop        Run agent loop integration tests only

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load Kimi environment
source "$PROJECT_ROOT/.env.kimi"

cd "$PROJECT_ROOT"

case "${1:-test}" in
    test|smoke)
        echo "Running smoke test with Kimi..."
        mix run scripts/hello_kimi.exs --model kimi:kimi-for-coding --debug
        ;;
    integration)
        echo "Running AI provider integration tests..."
        mix test apps/ai/test/provider_integration_test.exs --include integration
        ;;
    integration-all)
        echo "Running all integration tests..."
        echo ""
        echo "=== AI Provider Tests ==="
        mix test apps/ai/test/provider_integration_test.exs --include integration
        echo ""
        echo "=== Agent Loop Tests ==="
        mix test apps/coding_agent/test/coding_agent/agent_loop_integration_test.exs --include integration
        ;;
    agent-loop)
        echo "Running agent loop integration tests..."
        mix test apps/coding_agent/test/coding_agent/agent_loop_integration_test.exs --include integration
        ;;
    *)
        exec "$@"
        ;;
esac
