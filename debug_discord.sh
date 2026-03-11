#!/usr/bin/env bash
# Debug Discord Bot Client
# Uses the Zeebot-Debug bot token to send messages to #general
# where Zeebot (main Lemon bot) is listening.
#
# Usage: ./debug_discord.sh
#   Then type messages interactively. Commands:
#     /recent [N]  - show recent N messages (default 5)
#     /quit        - exit

DEBUG_TOKEN="${DISCORD_DEBUG_TOKEN:?Set DISCORD_DEBUG_TOKEN env var}"
CHANNEL_ID="1475727417372049419"
MAIN_BOT_ID="1475926545154703532"
BASE_URL="https://discord.com/api/v10"

send_message() {
  local content="$1"
  local escaped
  escaped=$(python3 -c "import json; print(json.dumps(\"$content\"))")
  curl -s -X POST "${BASE_URL}/channels/${CHANNEL_ID}/messages" \
    -H "Authorization: Bot ${DEBUG_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"content\": ${escaped}}"
}

get_messages_after() {
  local after_id="$1"
  curl -s "${BASE_URL}/channels/${CHANNEL_ID}/messages?after=${after_id}&limit=10" \
    -H "Authorization: Bot ${DEBUG_TOKEN}"
}

show_recent() {
  local limit="${1:-5}"
  curl -s "${BASE_URL}/channels/${CHANNEL_ID}/messages?limit=${limit}" \
    -H "Authorization: Bot ${DEBUG_TOKEN}" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
for m in reversed(msgs):
    a = m.get('author', {})
    name = a.get('username', '?')
    bot = ' [BOT]' if a.get('bot') else ''
    content = m.get('content', '(no content)')
    print(f'  {name}{bot}: {content[:300]}')
"
}

wait_for_response() {
  local msg_id="$1"
  local max_wait=90

  for i in $(seq 1 $max_wait); do
    sleep 1

    local resp
    resp=$(get_messages_after "$msg_id")

    local bot_content
    bot_content=$(echo "$resp" | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
bot = [m for m in msgs if m.get('author',{}).get('id') == '${MAIN_BOT_ID}']
if bot:
    for m in reversed(bot):
        print(m.get('content','')[:2000])
" 2>/dev/null)

    if [ -n "$bot_content" ]; then
      echo ""
      echo "  Zeebot: $bot_content"
      echo ""
      return 0
    fi

    if [ $((i % 10)) -eq 0 ]; then
      echo "  ...waiting (${i}s)"
    fi
  done

  echo "  (timed out after ${max_wait}s)"
}

echo "=== Discord Debug Client (Zeebot-Debug) ==="
echo "Channel: #general (${CHANNEL_ID})"
echo "Target: Zeebot main bot (${MAIN_BOT_ID})"
echo ""
echo "--- Recent messages ---"
show_recent 5
echo ""
echo "Type a message, /recent [N], or /quit"
echo ""

while true; do
  read -r -p "debug> " input

  [ -z "$input" ] && continue

  case "$input" in
    /quit)
      echo "Bye!"
      exit 0
      ;;
    /recent*)
      n=$(echo "$input" | awk '{print $2}')
      show_recent "${n:-5}"
      ;;
    *)
      echo "Sending: $input"
      resp=$(send_message "$input")
      msg_id=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

      if [ -n "$msg_id" ] && [ "$msg_id" != "" ]; then
        echo "Sent (id: $msg_id). Waiting for response..."
        wait_for_response "$msg_id"
      else
        echo "Failed to send: $resp"
      fi
      ;;
  esac
done
