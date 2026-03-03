#!/bin/bash
# Persistent local deployment with ngrok tunnel
# This keeps the games platform running locally with a public URL
# Run this on a machine that stays online (like a VPS or always-on Mac)

set -e

echo "=== Games Platform - Persistent Local Deployment ==="
echo ""

# Configuration
NGROK_DOMAIN="${NGROK_DOMAIN:-}"  # Set this for a custom domain
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="/tmp/games_platform.pid"
NGROK_PIDFILE="/tmp/games_platform_ngrok.pid"

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Shutting down..."
    if [ -f "$NGROK_PIDFILE" ]; then
        kill "$(cat "$NGROK_PIDFILE")" 2>/dev/null || true
        rm -f "$NGROK_PIDFILE"
    fi
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
    exit 0
}

trap cleanup INT TERM EXIT

cd "$PLATFORM_DIR"

# Build release if needed
if [ ! -d "_build/prod/rel/games_platform" ]; then
    echo "Building production release..."
    export MIX_ENV=prod
    mix release games_platform
fi

# Generate secret if not set
if [ -z "$LEMON_WEB_SECRET_KEY_BASE" ]; then
    export LEMON_WEB_SECRET_KEY_BASE=$(openssl rand -base64 48)
    echo "Generated LEMON_WEB_SECRET_KEY_BASE"
fi

# Set environment variables
export MIX_ENV=prod
export PHX_SERVER=true
export PHX_HOST=localhost
export PORT=8080
export LEMON_WEB_HOST=localhost
export LEMON_WEB_PORT=8080
export LEMON_STORE_PATH="./data/store"

# Create data directory
mkdir -p ./data

echo ""
echo "Starting games platform on port 8080..."
_build/prod/rel/games_platform/bin/games_platform start &
echo $! > "$PIDFILE"

# Wait for server to be ready
echo "Waiting for server to start..."
for i in {1..30}; do
    if curl -s http://localhost:8080/healthz >/dev/null 2>&1; then
        echo "✓ Server is ready!"
        break
    fi
    sleep 1
done

echo ""
echo "Starting ngrok tunnel..."
if [ -n "$NGROK_DOMAIN" ]; then
    echo "Using custom domain: $NGROK_DOMAIN"
    ngrok http --domain="$NGROK_DOMAIN" 8080 &
else
    echo "Using random ngrok subdomain (set NGROK_DOMAIN for custom domain)"
    ngrok http 8080 &
fi
echo $! > "$NGROK_PIDFILE"

# Wait for ngrok to start
sleep 3

# Get the public URL
NGROK_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"https://[^"]*"' | head -1 | cut -d'"' -f4)

echo ""
echo "========================================"
echo "🎮 Games Platform is LIVE!"
echo ""
if [ -n "$NGROK_URL" ]; then
    echo "Public URL: $NGROK_URL"
else
    echo "Public URL: Check https://dashboard.ngrok.com/endpoints"
fi
echo "Local URL:  http://localhost:8080"
echo ""
echo "Lobby:      ${NGROK_URL:-http://localhost:8080}/games"
echo "Health:     ${NGROK_URL:-http://localhost:8080}/healthz"
echo ""
echo "Press Ctrl+C to stop"
echo "========================================"

# Keep script running
wait
