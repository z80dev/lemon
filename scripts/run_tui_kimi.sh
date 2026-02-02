#!/bin/bash
# Run the Lemon TUI with Kimi API
# Usage: ./scripts/run_tui_kimi.sh [directory]
#
# The directory argument specifies the working directory for the agent.
# If not provided, uses the current directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load Kimi environment
source "$PROJECT_ROOT/.env.kimi"

# Set LEMON_PATH for the TUI to find the backend
export LEMON_PATH="$PROJECT_ROOT"

cd "$PROJECT_ROOT/clients/lemon-tui"

# Check if node_modules exists
if [ ! -d "node_modules" ]; then
    echo "Installing TUI dependencies..."
    npm install
fi

# Check if dist exists
if [ ! -f "dist/index.js" ]; then
    echo "Building TUI..."
    npm run build
fi

# Working directory (default to current directory before cd)
WORK_DIR="${1:-$(pwd)}"

echo "Starting Lemon TUI with Kimi API..."
echo "Working directory: $WORK_DIR"
echo "Model: kimi:kimi-for-coding"
echo ""

# Run the TUI
node dist/index.js --model kimi:kimi-for-coding --cwd "$WORK_DIR"
