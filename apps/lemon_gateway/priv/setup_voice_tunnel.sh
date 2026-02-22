#!/bin/bash
#
# Setup localtunnel and configure Twilio webhook
#
# Usage: ./setup_voice_tunnel.sh [subdomain]
#
# This script ONLY sets up the tunnel and configures Twilio.
# It assumes the Lemon app is already running on port 4047.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    echo -e "${YELLOW}Shutting down tunnel...${NC}"
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

    export TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN
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
echo -e "${BLUE}  Voice Tunnel Setup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

check_tools
load_secrets

# Show loaded secrets (masked)
echo -e "${GREEN}Twilio credentials loaded:${NC}"
echo "  Account SID: ${TWILIO_ACCOUNT_SID:0:8}..."
echo ""

# Check that voice server is running
if ! curl -s -o /dev/null -w "" "http://localhost:4047" 2>/dev/null; then
    echo -e "${YELLOW}NOTE: Port 4047 doesn't appear to be listening yet.${NC}"
    echo "  Make sure Lemon is running with voice enabled."
    echo ""
fi

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

echo -e "${GREEN}Tunnel is running. Forwarding: $TUNNEL_URL -> localhost:4047${NC}"
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"

# Keep running until interrupted
wait "$LT_PID"
