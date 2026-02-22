#!/bin/bash
#
# Start the Lemon voice server with localtunnel for Twilio webhooks
#
# Usage: ./start_voice_localtunnel.sh [subdomain]
#
# Starts:
#   1. localtunnel on port 4047
#   2. Configures Twilio webhook to the tunnel URL (requires TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN env vars)
#   3. Starts Lemon with voice enabled (loads secrets via LemonCore.Secrets)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEMON_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SUBDOMAIN="${1:-lemon-voice}"

# Load .env file if it exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
fi

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
# Check Twilio credentials (needed for the webhook API call)
# The app itself loads secrets via LemonCore.Secrets at runtime.
# ---------------------------------------------------------------------------
check_twilio_creds() {
    if [[ -z "$TWILIO_ACCOUNT_SID" || -z "$TWILIO_AUTH_TOKEN" ]]; then
        echo -e "${RED}ERROR: Twilio credentials not found${NC}"
        echo "  Set these env vars for the webhook API call:"
        echo "    export TWILIO_ACCOUNT_SID=your_account_sid"
        echo "    export TWILIO_AUTH_TOKEN=your_auth_token"
        echo ""
        echo "  The app loads its own secrets via LemonCore.Secrets."
        echo "  Store them with: mix lemon.voice.secrets"
        exit 1
    fi
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
check_twilio_creds

echo -e "${GREEN}Twilio credentials loaded (for webhook setup):${NC}"
echo "  Account SID: ${TWILIO_ACCOUNT_SID:0:8}..."
echo "  Voice secrets will be loaded by the app via LemonCore.Secrets"
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
