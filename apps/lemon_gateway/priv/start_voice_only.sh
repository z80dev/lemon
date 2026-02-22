#!/bin/bash
#
# Start only the voice components (WebSocket server on port 4047)
#
# Usage: ./start_voice_only.sh
#
# Loads API keys from ~/.zeebot/api_keys/ and starts the Lemon
# application with voice enabled. Useful for testing voice without
# the full Lemon stack or when running the tunnel separately.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEMON_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Load secrets from ~/.zeebot/api_keys/
# ---------------------------------------------------------------------------
load_secrets() {
    local keys_dir="$HOME/.zeebot/api_keys"

    # Load Twilio credentials
    if [[ -f "$keys_dir/twilio.txt" ]]; then
        TWILIO_ACCOUNT_SID=$(grep "Account SID" "$keys_dir/twilio.txt" | sed 's/Account SID //')
        TWILIO_AUTH_TOKEN=$(grep "Auth token" "$keys_dir/twilio.txt" | sed 's/Auth token //')
    elif [[ -z "$TWILIO_ACCOUNT_SID" || -z "$TWILIO_AUTH_TOKEN" ]]; then
        echo -e "${RED}ERROR: Twilio credentials not found${NC}"
        echo "  Expected file: $keys_dir/twilio.txt"
        echo "  Or set TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN env vars"
        exit 1
    fi

    # Load Deepgram
    if [[ -f "$keys_dir/deepgram.txt" ]]; then
        DEEPGRAM_API_KEY=$(tail -1 "$keys_dir/deepgram.txt" | tr -d '[:space:]')
    elif [[ -z "$DEEPGRAM_API_KEY" ]]; then
        echo -e "${RED}ERROR: Deepgram API key not found${NC}"
        echo "  Expected file: $keys_dir/deepgram.txt"
        echo "  Or set DEEPGRAM_API_KEY env var"
        exit 1
    fi

    # Load ElevenLabs
    if [[ -f "$keys_dir/elevenlabs.txt" ]]; then
        ELEVENLABS_API_KEY=$(tail -1 "$keys_dir/elevenlabs.txt" | tr -d '[:space:]')
    elif [[ -z "$ELEVENLABS_API_KEY" ]]; then
        echo -e "${RED}ERROR: ElevenLabs API key not found${NC}"
        echo "  Expected file: $keys_dir/elevenlabs.txt"
        echo "  Or set ELEVENLABS_API_KEY env var"
        exit 1
    fi

    # Export for Lemon to use
    export TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN DEEPGRAM_API_KEY ELEVENLABS_API_KEY
}

# ---------------------------------------------------------------------------
# Check required tools
# ---------------------------------------------------------------------------
check_tools() {
    if ! command -v mix &>/dev/null; then
        echo -e "${RED}ERROR: mix (Elixir) not found${NC}"
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
load_secrets

# Show loaded secrets (masked)
echo -e "${GREEN}Secrets loaded:${NC}"
echo "  Twilio SID:    ${TWILIO_ACCOUNT_SID:0:8}..."
echo "  Twilio Token:  ${TWILIO_AUTH_TOKEN:0:4}..."
echo "  Deepgram:      ${DEEPGRAM_API_KEY:0:8}..."
echo "  ElevenLabs:    ${ELEVENLABS_API_KEY:0:8}..."
echo ""

# Export voice config
export VOICE_ENABLED=true

echo -e "${BLUE}Starting voice WebSocket server on port 4047...${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

cd "$LEMON_DIR"
mix run --no-halt
