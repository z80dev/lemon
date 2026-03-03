#!/bin/bash
# Local deployment with ngrok tunnel for games.zeebot.xyz
# This is a temporary solution until Fly.io auth is completed

set -e

echo "=== Starting local games platform with ngrok tunnel ==="

# Check if release exists
if [ ! -d "_build/prod/rel/games_platform" ]; then
    echo "Building release..."
    export MIX_ENV=prod
    mix release games_platform
fi

# Generate secret if not set
if [ -z "$LEMON_WEB_SECRET_KEY_BASE" ]; then
    export LEMON_WEB_SECRET_KEY_BASE=$(openssl rand -base64 48)
    echo "Generated LEMON_WEB_SECRET_KEY_BASE"
fi

# Set required environment variables
export PHX_SERVER=true
export PHX_HOST=localhost
export PORT=8080
export LEMON_WEB_HOST=localhost
export LEMON_WEB_PORT=8080
export LEMON_STORE_PATH="./data/store"

# Create data directory
mkdir -p ./data

echo "Starting games platform on port 8080..."
echo ""
echo "To expose via ngrok, run in another terminal:"
echo "  ngrok http 8080"
echo ""
echo "Or for a custom domain (if configured in ngrok):"
echo "  ngrok http --domain=games.zeebot.xyz 8080"
echo ""

# Start the release
_build/prod/rel/games_platform/bin/games_platform start
