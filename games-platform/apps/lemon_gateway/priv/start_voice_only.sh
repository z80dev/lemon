#!/bin/bash
#
# Start only the voice components (WebSocket server on port 4047)
#
# Usage: ./start_voice_only.sh
#
# Starts the Lemon application with voice enabled.
# API keys are loaded at runtime via LemonCore.Secrets.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEMON_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Check required tools
# ---------------------------------------------------------------------------
check_tools() {
    if ! command -v mix &>/dev/null; then
        echo "ERROR: mix (Elixir) not found"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Lemon Voice Server${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

check_tools

# Export voice config
export VOICE_ENABLED=true

echo -e "${BLUE}Starting voice WebSocket server on port 4047...${NC}"
echo -e "${GREEN}Voice secrets will be loaded via LemonCore.Secrets${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

cd "$LEMON_DIR"
mix run --no-halt
