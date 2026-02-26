#!/bin/bash
#
# Diagnose voice setup issues
#

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Voice Diagnostics${NC}"
echo "================="
echo ""

# Check port 4047
echo -n "Port 4047 (voice server): "
if lsof -ti:4047 > /dev/null 2>&1; then
    echo -e "${GREEN}RUNNING${NC}"
    lsof -ti:4047 | xargs ps -o pid,command -p
else
    echo -e "${RED}NOT RUNNING${NC}"
fi
echo ""

# Check localtunnel
echo -n "Localtunnel (port 4047): "
if pgrep -f "lt --port 4047" > /dev/null; then
    echo -e "${GREEN}RUNNING${NC}"
    pgrep -f "lt --port 4047" | xargs ps -o pid,command -p
else
    echo -e "${RED}NOT RUNNING${NC}"
fi
echo ""

# Test tunnel endpoint
echo -n "Tunnel endpoint (lemon-voice.loca.lt): "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://lemon-voice.loca.lt/webhooks/twilio/voice 2>/dev/null)
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "404" ]; then
    echo -e "${GREEN}RESPONDING (HTTP $HTTP_CODE)${NC}"
elif [ "$HTTP_CODE" = "503" ]; then
    echo -e "${YELLOW}TUNNEL OK BUT BACKEND DOWN (HTTP 503)${NC}"
else
    echo -e "${RED}NOT RESPONDING (HTTP ${HTTP_CODE:-none})${NC}"
fi
echo ""

# Check Twilio webhook
echo -e "${BLUE}Twilio Webhook Configuration:${NC}"
TWILIO_ACCOUNT_SID="${TWILIO_ACCOUNT_SID:-""}"
TWILIO_AUTH_TOKEN="${TWILIO_AUTH_TOKEN:-""}"
PHONE_SID="${TWILIO_PHONE_SID:-""}"

curl -s "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/IncomingPhoneNumbers/$PHONE_SID.json" \
  -u "$TWILIO_ACCOUNT_SID:$TWILIO_AUTH_TOKEN" | jq -r '{voice_url: .voice_url, voice_method: .voice_method}'
echo ""

# Recent calls
echo -e "${BLUE}Recent Calls:${NC}"
curl -s "https://api.twilio.com/2010-04-01/Accounts/$TWILIO_ACCOUNT_SID/Calls.json?PageSize=3" \
  -u "$TWILIO_ACCOUNT_SID:$TWILIO_AUTH_TOKEN" | jq -r '.calls[] | "  \(.from) -> \(.to) | Status: \(.status) | Duration: \(.duration)s | Error: \(.error_message // "none")"'
echo ""

# Summary
echo -e "${BLUE}Summary:${NC}"
if ! lsof -ti:4047 > /dev/null 2>&1; then
    echo -e "${RED}PROBLEM: Voice server not running on port 4047${NC}"
    echo "The main Lemon Gateway needs to be restarted with voice_enabled: true"
    echo ""
    echo "To fix:"
    echo "1. Restart your main Lemon Gateway (it will pick up the new config)"
    echo "2. Run: ./setup_voice_tunnel.sh"
    echo "3. Call the number"
fi
