#!/bin/bash
set -euo pipefail

## Usage:
## chmod +x seccampi_rclone_finalize.sh
## ./seccampi_rclone_finalize.sh <remote_name> <token_json_path>

REMOTE_NAME="$1"
TOKEN_JSON_PATH="$2"

echo "🔐 Finalizing rclone setup for remote '$REMOTE_NAME'..."

### 1. Verify token file
if [[ ! -f "$TOKEN_JSON_PATH" ]]; then
  echo "❌ Token JSON file not found: $TOKEN_JSON_PATH"
  exit 1
fi

TOKEN_JSON=$(<"$TOKEN_JSON_PATH")

### 2. Inject token
echo "📦 Injecting token into rclone config..."
rclone config update "$REMOTE_NAME" token "$TOKEN_JSON"

### 3. Verify remote
echo "🧪 Verifying remote access..."
if rclone ls "$REMOTE_NAME:" &> /dev/null; then
  echo "✅ Remote '$REMOTE_NAME' is working."
else
  echo "❌ Remote '$REMOTE_NAME' failed to list contents."
  exit 1
fi

### 4. Optional test upload
TEST_FILE="/tmp/rclone_test_$(date +%s).txt"
echo "Test upload from $(hostname) at $(date)" > "$TEST_FILE"
rclone copy "$TEST_FILE" "$REMOTE_NAME:PiTestUpload" --log-level INFO
echo "✅ Test file uploaded to '$REMOTE_NAME:PiTestUpload'"