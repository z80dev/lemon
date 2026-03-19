#!/usr/bin/env bash
#
# GitHub Copilot Provider - Live Integration Test
# Reads token from the running Lemon node via RPC (with auto-refresh), then tests each API backend.
#
set -e

COOKIE="lemon_gateway_dev_cookie"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Refresh copilot token via RPC ───────────────────────────────────────────

echo "Refreshing copilot token..."

erlc "$SCRIPT_DIR/copilot_check.erl" 2>/dev/null

TOKEN=$(erl -noshell -sname tmp_refresh_$$ -setcookie "$COOKIE" -eval "
  {ok, Raw, _} = rpc:call('lemon@newphy', 'Elixir.LemonCore.Secrets', resolve,
    [<<\"llm_github_copilot_api_key\">>, [[{env_fallback, true}]]]),
  case rpc:call('lemon@newphy', 'Elixir.Ai.Auth.GitHubCopilotOAuth', resolve_api_key_from_secret,
    [<<\"llm_github_copilot_api_key\">>, Raw]) of
    {ok, FreshToken} ->
      io:format(\"~s\", [FreshToken]);
    Other ->
      {ok, Map} = rpc:call('lemon@newphy', 'Elixir.Jason', decode, [Raw]),
      io:format(\"~s\", [maps:get(<<\"access_token\">>, Map)])
  end,
  halt().
" 2>&1 | grep -v "crash dump\|Crash dump")

if [ -z "$TOKEN" ] || [ ${#TOKEN} -lt 50 ]; then
  echo "❌ Could not get a valid copilot token (length: ${#TOKEN})"
  exit 1
fi

echo "✅ Token ready (${#TOKEN} chars)"
BASE_URL="https://api.individual.githubcopilot.com"

echo ""
echo "======================================================================="
echo "  GitHub Copilot Provider - Live Integration Test"
echo "======================================================================="

COPILOT_H=(
  -H "User-Agent: GitHubCopilotChat/0.35.0"
  -H "Editor-Version: vscode/1.107.0"
  -H "Editor-Plugin-Version: copilot-chat/0.35.0"
  -H "Copilot-Integration-Id: vscode-chat"
  -H "X-Initiator: user"
  -H "Openai-Intent: conversation-edits"
)
AUTH=(-H "Authorization: Bearer $TOKEN")

PASS=0; FAIL=0; WARN=0

# ── Helper: curl with proper HTTP code extraction ───────────────────────────

do_curl() {
  local url="$1"; shift
  local tmpfile=$(mktemp)
  local code
  code=$(curl -s -o "$tmpfile" -w "%{http_code}" --max-time 60 "$url" "$@")
  echo "$code" > "$tmpfile.code"
  echo "$tmpfile"
}

# ── Test 1: Claude Sonnet 4.6 (anthropic_messages) ─────────────────────────

echo ""
echo "── Test 1: Claude Sonnet 4.6 (anthropic_messages) ──"

TMPF=$(do_curl "$BASE_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Anthropic-Version: 2023-06-01" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{"model":"claude-sonnet-4.6","max_tokens":100,"messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}')

CODE=$(cat "$TMPF.code")
BODY=$(cat "$TMPF")
rm -f "$TMPF" "$TMPF.code"

if [ "$CODE" = "200" ]; then
  TEXT=$(echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['content'][0]['text'])" 2>/dev/null)
  echo "  ✅ HTTP 200 — Response: $(echo "$TEXT" | head -c 100)"
  PASS=$((PASS+1))
else
  echo "  ❌ HTTP $CODE — $(echo "$BODY" | head -c 200)"
  FAIL=$((FAIL+1))
fi

# ── Test 2: GPT-4o (openai_completions) ────────────────────────────────────

echo ""
echo "── Test 2: GPT-4o (openai_completions) ──"

TMPF=$(do_curl "$BASE_URL/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{"model":"gpt-4o","max_tokens":100,"messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}')

CODE=$(cat "$TMPF.code")
BODY=$(cat "$TMPF")
rm -f "$TMPF" "$TMPF.code"

if [ "$CODE" = "200" ]; then
  TEXT=$(echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)
  echo "  ✅ HTTP 200 — Response: $(echo "$TEXT" | head -c 100)"
  PASS=$((PASS+1))
else
  echo "  ❌ HTTP $CODE — $(echo "$BODY" | head -c 200)"
  FAIL=$((FAIL+1))
fi

# ── Test 3: GPT-5-mini (openai_responses) ──────────────────────────────────

echo ""
echo "── Test 3: GPT-5-mini (openai_responses) ──"

TMPF=$(do_curl "$BASE_URL/responses" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{"model":"gpt-5-mini","input":"What is 2+2? Reply with just the number."}')

CODE=$(cat "$TMPF.code")
BODY=$(cat "$TMPF")
rm -f "$TMPF" "$TMPF.code"

if [ "$CODE" = "200" ]; then
  TEXT=$(echo "$BODY" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for item in d.get('output',[]):
    if item.get('type') == 'message':
        for c in item.get('content', []):
            if c.get('type') == 'output_text':
                print(c['text'])
                break
" 2>/dev/null)
  echo "  ✅ HTTP 200 — Response: $(echo "$TEXT" | head -c 100)"
  PASS=$((PASS+1))
else
  echo "  ❌ HTTP $CODE — $(echo "$BODY" | head -c 200)"
  FAIL=$((FAIL+1))
fi

# ── Test 4: Gemini 3 Flash (openai_completions) ────────────────────────────

echo ""
echo "── Test 4: Gemini 3 Flash (openai_completions) ──"

TMPF=$(do_curl "$BASE_URL/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{"model":"gemini-3-flash-preview","max_tokens":100,"messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}')

CODE=$(cat "$TMPF.code")
BODY=$(cat "$TMPF")
rm -f "$TMPF" "$TMPF.code"

if [ "$CODE" = "200" ]; then
  TEXT=$(echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)
  echo "  ✅ HTTP 200 — Response: $(echo "$TEXT" | head -c 100)"
  PASS=$((PASS+1))
else
  echo "  ❌ HTTP $CODE — $(echo "$BODY" | head -c 200)"
  FAIL=$((FAIL+1))
fi

# ── Test 5: Claude Streaming (anthropic_messages SSE) ───────────────────────

echo ""
echo "── Test 5: Claude Sonnet 4.6 Streaming ──"

TMPF=$(mktemp)
STREAM_CODE=$(curl -s -o "$TMPF" -w "%{http_code}" -N --max-time 30 \
  "$BASE_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -H "Anthropic-Version: 2023-06-01" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{"model":"claude-sonnet-4.6","max_tokens":100,"stream":true,"messages":[{"role":"user","content":"Say hello world."}]}')

TEXT=$(grep "^data: " "$TMPF" | grep -v "message_stop\|message_start\|content_block_start\|content_block_stop\|ping" | while IFS= read -r line; do
  DATA="${line#data: }"
  echo "$DATA" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('delta',{}).get('text',''),end='')" 2>/dev/null || true
done)
EVENTS=$(grep -c "^data: " "$TMPF" || true)
rm -f "$TMPF"

if [ -n "$TEXT" ] && [ "$STREAM_CODE" = "200" ]; then
  echo "  ✅ Streamed $EVENTS events — Text: $(echo "$TEXT" | head -c 80)"
  PASS=$((PASS+1))
else
  echo "  ❌ HTTP $STREAM_CODE — $(cat "$TMPF" 2>/dev/null | head -c 200)"
  FAIL=$((FAIL+1))
fi

# ── Test 6: GPT-5-mini Streaming (openai_responses SSE) ────────────────────

echo ""
echo "── Test 6: GPT-5-mini Streaming (responses API) ──"

TMPF=$(mktemp)
STREAM_CODE=$(curl -s -o "$TMPF" -w "%{http_code}" -N --max-time 30 \
  "$BASE_URL/responses" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{"model":"gpt-5-mini","stream":true,"input":"Say hello world."}')

TEXT=$(grep "^data: " "$TMPF" | while IFS= read -r line; do
  echo "${line#data: }" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=d.get('type','')
if t=='response.output_text.delta':
    print(d.get('delta',''),end='')
" 2>/dev/null || true
done)
EVENTS=$(grep -c "^data: " "$TMPF" || true)
rm -f "$TMPF"

if [ -n "$TEXT" ] && [ "$STREAM_CODE" = "200" ]; then
  echo "  ✅ Streamed $EVENTS events — Text: $(echo "$TEXT" | head -c 80)"
  PASS=$((PASS+1))
else
  echo "  ❌ HTTP $STREAM_CODE"
  FAIL=$((FAIL+1))
fi

# ── Test 7: Claude Tool Calling ────────────────────────────────────────────

echo ""
echo "── Test 7: Claude Sonnet 4.6 Tool Calling ──"

TMPF=$(do_curl "$BASE_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Anthropic-Version: 2023-06-01" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{
    "model":"claude-sonnet-4.6",
    "max_tokens":200,
    "tools":[{"name":"get_weather","description":"Get weather for a location","input_schema":{"type":"object","properties":{"location":{"type":"string"}},"required":["location"]}}],
    "messages":[{"role":"user","content":"What is the weather in Tokyo?"}]
  }')

CODE=$(cat "$TMPF.code")
BODY=$(cat "$TMPF")
rm -f "$TMPF" "$TMPF.code"

if [ "$CODE" = "200" ]; then
  STOP=$(echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('stop_reason','unknown'))" 2>/dev/null)
  TOOL=$(echo "$BODY" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d.get('content',[]):
    if c.get('type')=='tool_use':
        print(f'tool={c[\"name\"]} args={c[\"input\"]}')
        break
" 2>/dev/null)
  if [ -n "$TOOL" ]; then
    echo "  ✅ HTTP 200 — stop_reason=$STOP — $TOOL"
    PASS=$((PASS+1))
  else
    echo "  ⚠️  HTTP 200 but no tool_use (stop_reason=$STOP)"
    echo "     Body: $(echo "$BODY" | head -c 200)"
    WARN=$((WARN+1))
  fi
else
  echo "  ❌ HTTP $CODE — $(echo "$BODY" | head -c 200)"
  FAIL=$((FAIL+1))
fi

# ── Test 8: Grok Code Fast 1 (openai_completions) ──────────────────────────

echo ""
echo "── Test 8: Grok Code Fast 1 (openai_completions) ──"

TMPF=$(do_curl "$BASE_URL/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  "${COPILOT_H[@]}" "${AUTH[@]}" \
  -d '{"model":"grok-code-fast-1","max_tokens":100,"messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}')

CODE=$(cat "$TMPF.code")
BODY=$(cat "$TMPF")
rm -f "$TMPF" "$TMPF.code"

if [ "$CODE" = "200" ]; then
  TEXT=$(echo "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null)
  echo "  ✅ HTTP 200 — Response: $(echo "$TEXT" | head -c 100)"
  PASS=$((PASS+1))
else
  echo "  ❌ HTTP $CODE — $(echo "$BODY" | head -c 200)"
  FAIL=$((FAIL+1))
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "======================================================================="
echo "  SUMMARY: ✅ $PASS passed  ⚠️  $WARN warnings  ❌ $FAIL failed"
echo "======================================================================="
echo ""

[ $FAIL -gt 0 ] && exit 1
