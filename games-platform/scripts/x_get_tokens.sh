#!/bin/bash
# X API OAuth 2.0 Token Helper
# 
# This script helps you get OAuth 2.0 tokens without needing the gateway.
# It generates the authorization URL and provides the curl command.

CLIENT_ID="RHozTWdxcjZoQ3E0em5JU0xYQTI6MTpjaQ"
CALLBACK_URL="http://localhost:4000/auth/x/callback"
STATE="setup$(date +%s)"

echo "🐦 X API OAuth 2.0 Token Helper"
echo "=================================================="
echo ""
echo "Step 1: Make sure your callback URL is set in X Developer Portal:"
echo "  $CALLBACK_URL"
echo ""
echo "Step 2: Visit this URL in your browser:"
echo ""
echo "https://twitter.com/i/oauth2/authorize?response_type=code&client_id=$CLIENT_ID&redirect_uri=$(printf '%s' "$CALLBACK_URL" | jq -sRr @uri)&scope=tweet.read%20tweet.write%20users.read%20offline.access&state=$STATE&code_challenge=challenge&code_challenge_method=plain"
echo ""
echo "Step 3: Authorize the app"
echo ""
echo "Step 4: You'll be redirected to localhost (it will fail - that's OK!)"
echo "    Copy the 'code' parameter from the URL"
echo ""
echo "Step 5: Run this curl command (replace PASTE_CODE_HERE with the code):"
echo ""
cat << 'CURL_CMD'
curl -X POST https://api.x.com/2/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "RHozTWdxcjZoQ3E0em5JU0xYQTI6MTpjaQ:IxhBE1Ssz5ADc9aPEL_j4i5BrNCBF5IufWjy5Mz_sNKb7_siku" \
  -d "grant_type=authorization_code" \
  -d "code=PASTE_CODE_HERE" \
  -d "redirect_uri=http://localhost:4000/auth/x/callback" \
  -d "code_verifier=challenge"
CURL_CMD
echo ""
echo "Step 6: Save the refresh_token from the response!"
echo ""
