#!/bin/bash
set -e

# Deploy script for games.zeebot.xyz
# Usage: ./deploy.sh

echo "🎮 Deploying games platform to games.zeebot.xyz..."

# Check if flyctl is available
if ! command -v flyctl &> /dev/null; then
    echo "❌ flyctl not found. Install with:"
    echo "   curl -L https://fly.io/install.sh | sh"
    exit 1
fi

# Check authentication
if ! flyctl auth whoami &> /dev/null; then
    echo "❌ Not authenticated with Fly.io. Run:"
    echo "   flyctl auth login"
    exit 1
fi

# Create volume if it doesn't exist
echo "📦 Checking volume..."
if ! flyctl volumes list --app games-platform-zeebot 2>/dev/null | grep -q "games_data"; then
    echo "Creating volume games_data..."
    flyctl volumes create games_data --app games-platform-zeebot --size 1 --region iad
fi

# Deploy
echo "🚀 Deploying..."
flyctl deploy --app games-platform-zeebot

echo "✅ Deployment complete!"
echo ""
echo "🌐 Your app should be available at:"
echo "   https://games.zeebot.xyz"
