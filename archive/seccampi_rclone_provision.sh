#!/bin/bash
set -euo pipefail

## Usage:
## chmod +x seccampi_rclone_provision.sh
## ./seccampi_rclone_provision.sh <remote_name>

REMOTE_NAME="$1"

echo "🔧 Installing rclone and preparing remote '$REMOTE_NAME'..."

### 1. Install rclone if missing
if ! command -v rclone &> /dev/null; then
  echo "📦 Installing rclone..."
  curl -fsSL https://rclone.org/install.sh | sudo bash
else
  echo "✅ rclone already installed: $(rclone version | head -n 1)"
fi

### 2. Create remote skeleton
echo "📂 Creating remote '$REMOTE_NAME' (no token yet)..."
rclone config create "$REMOTE_NAME" onedrive config_is_local true

### 3. Prompt for manual OAuth
echo "🛑 Manual step required:"
echo "Run this on a browser-enabled machine:"
echo ""
echo "  rclone authorize onedrive"
echo ""
echo "Then copy the resulting token JSON and save it to:"
echo "  ~/rclone_token_${REMOTE_NAME}.json"
echo ""
echo "Once done, run:"
echo "  ./seccampi_rclone_finalize.sh $REMOTE_NAME ~/rclone_token_${REMOTE_NAME}.json"