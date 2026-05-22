#!/bin/bash

TOOL_IMAGE="oci-img-trim"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🛠️  Building $TOOL_IMAGE..."
docker build -t "$TOOL_IMAGE" . -q

echo "🚀 Launching interactive container..."
docker run -it --rm \
    -v "$HOME/.docker/config.json:/root/.docker/config.json:ro" \
    "$TOOL_IMAGE" "$@"

if [ $? -eq 0 ]; then
    echo "✨ Workflow finished successfully."
else
    echo "❌ Workflow failed. Check the logs above."
    exit 1
fi
