#!/bin/bash
#
# Start the Lemon voice server with localtunnel for Twilio webhooks
#
# Usage: ./start_voice_localtunnel.sh [subdomain]
#
# Loads API keys from ~/.lemon/secrets/ and starts:
#   1. localtunnel on port 4047
#   2. Configures Twilio webhook to the tunnel URL
#   3. Starts Lemon with voice enabled
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEMON_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SUBDOMAIN="${1:-zeebot-voice}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Cleanup on exit
LT_PID=""
cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down...${NC}"
    if [[ -n "$LT_PID" ]]; then
        kill "$LT_PID" 2>/dev/null || true
        echo -e "${GREEN}localtunnel stopped${NC}"
    fi
    exit 0
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Load secrets from ~/.lemon/secrets/
# ---------------------------------------------------------------------------
load_secrets() {
    local secrets_dir="$HOME/.lemon/secrets"

    # Load Twilio credentials
    if [[ -f "$secrets_dir/twilio_account_sid" ]]; then
        TWILIO_ACCOUNT_SID=$(cat "$secrets_dir/twilio_account_sid" | tr -d '[:space:]')
    fi
    if [[ -f "$secrets_dir/twilio_auth_token" ]]; then
        TWILIO_AUTH_TOKEN=$(cat "$secrets_dir/twilio_auth_token" | tr -d '[:space:]')
    fi
    if [[ -z "$TWILIO_ACCOUNT_SID" || -z "$TWILIO_AUTH_TOKEN" ]]; then
        echo -e "${RED}ERROR: Twilio credentials not found${NC}"
        echo "  Run: mix lemon.secrets.init"
        echo "  Expected files: $secrets_dir/twilio_account_sid, $secrets_dir/twilio_auth_token"
        echo "  Or set TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN env vars"
        exit 1
    fi

    # Load Deepgram
    if [[ -f "$secrets_dir/deepgram_api_key" ]]; then
        DEEPGRAM_API_KEY=$(cat "$secrets_dir/deepgram_api_key" | tr -d '[:space:]')
    elif [[ -z "$DEEPGRAM_API_KEY" ]]; then
        echo -e "${RED}ERROR: Deepgram API key not found${NC}"
        echo "  Run: mix lemon.secrets.init"
        echo "  Expected file: $secrets_dir/deepgram_api_key"
        echo "  Or set DEEPGRAM_API_KEY env var"
        exit 1
    fi

    # Load ElevenLabs
    if [[ -f "$secrets_dir/elevenlabs_api_key" ]]; then
        ELEVENLABS_API_KEY=$(cat "$secrets_dir/elevenlabs_api_key" | tr -d '[:space:]')
    elif [[ -z "$ELEVENLABS_API_KEY" ]]; then
        echo -e "${RED}ERROR: ElevenLabs API key not found${NC}"
        echo "  Run: mix lemon.secrets.init"
        echo "  Expected file: $secrets_dir/elevenlabs_api_key"
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
    local missing=0

    if ! command -v lt &>/dev/null; then
        echo -e "${RED}ERROR: localtunnel (lt) not found${NC}"
        echo "  Install with: npm install -g localtunnel"
        missing=1
    fi

    if ! command -v curl &>/dev/null; then
        echo -e "${RED}ERROR: curl not found${NC}"
        missing=1
    fi

    if ! command -v mix &>/dev/null; then
        echo -e "${RED}ERROR: mix (Elixir) not found${NC}"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Configure Twilio webhook
# ---------------------------------------------------------------------------
configure_twilio_webhook() {
    local tunnel_url="$1"
    local webhook_url="${tunnel_url}/webhooks/twilio/voice"

    echo -e "${BLUE}Configuring Twilio webhook...${NC}"

    # Get the first incoming phone number
    local phone_sid
    phone_sid=$(curl -s -u "$TWILIO_ACCOUNT_SID:$TWILIO_AUTH_TOKEN" \
        "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/IncomingPhoneNumbers.json" \
        | python3 -c "import sys,json; nums=json.load(sys.stdin).get('incoming_phone_numbers',[]); print(nums[0]['sid'] if nums else '')" 2>/dev/null)

    if [[ -z "$phone_sid" ]]; then
        echo -e "${YELLOW}WARNING: No Twilio phone numbers found. Configure webhook manually:${NC}"
        echo "  $webhook_url"
        return
    fi

    # Update the voice webhook URL
    local result
    result=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/IncomingPhoneNumbers/$phone_sid.json" \
        -u "$TWILIO_ACCOUNT_SID:$TWILIO_AUTH_TOKEN" \
        --data-urlencode "VoiceUrl=$webhook_url" \
        --data-urlencode "VoiceMethod=POST" \
        --data-urlencode "StatusCallback=${tunnel_url}/webhooks/twilio/voice/status" \
        --data-urlencode "StatusCallbackMethod=POST")

    if [[ "$result" == "200" ]]; then
        echo -e "${GREEN}Twilio webhook configured: $webhook_url${NC}"
    else
        echo -e "${YELLOW}WARNING: Failed to configure Twilio webhook (HTTP $result)${NC}"
        echo "  Set manually: $webhook_url"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Lemon Voice Server + Localtunnel${NC}"
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

# Start localtunnel
echo -e "${BLUE}Starting localtunnel on port 4047 (subdomain: $SUBDOMAIN)...${NC}"
lt --port 4047 --subdomain "$SUBDOMAIN" &
LT_PID=$!

# Wait for tunnel to be ready
sleep 3

TUNNEL_URL="https://${SUBDOMAIN}.loca.lt"
echo -e "${GREEN}Tunnel URL: $TUNNEL_URL${NC}"
echo ""

# Configure Twilio webhook
configure_twilio_webhook "$TUNNEL_URL"
echo ""

# Export voice config
export VOICE_ENABLED=true
export VOICE_PUBLIC_URL="$TUNNEL_URL"

# Start Lemon
echo -e "${BLUE}Starting Lemon with voice enabled...${NC}"
echo -e "${GREEN}Voice WebSocket listening on port 4047${NC}"
echo -e "${GREEN}Tunnel forwarding: $TUNNEL_URL -> localhost:4047${NC}"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

cd "$LEMON_DIR"
mix run --no-halt
