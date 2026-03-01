#!/bin/bash
# Deploy games.zeebot.xyz to Fly.io

set -e

echo "=== Deploying games.zeebot.xyz ==="

# Check if fly CLI is installed
if ! command -v fly &> /dev/null; then
    echo "Error: fly CLI not found. Install from https://fly.io/docs/hands-on/install-flyctl/"
    exit 1
fi

# Check if logged in
if ! fly auth whoami &> /dev/null; then
    echo "Error: Not logged in to Fly.io. Run 'fly auth login' first."
    exit 1
fi

# Create the volume if it doesn't exist (only needed once)
if ! fly volumes list --app games-zeebot-xyz 2>/dev/null | grep -q "games_data"; then
    echo "Creating persistent volume..."
    fly volumes create games_data --app games-zeebot-xyz --size 1 --region iad
fi

# Deploy
echo "Building and deploying..."
fly deploy --app games-zeebot-xyz --config fly.toml --dockerfile Dockerfile --context .. --ha=false

echo "=== Deployment complete ==="
echo "Visit: https://games.zeebot.xyz"
