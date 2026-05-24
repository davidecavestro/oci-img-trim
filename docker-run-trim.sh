#!/bin/bash

TOOL_IMAGE="oci-img-trim"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit

echo "🛠️  Building $TOOL_IMAGE..."
docker build -t "$TOOL_IMAGE" . -q

echo "🚀 Launching interactive container..."
DOCKER_OPTS=(-it --rm -v "$HOME/.docker/config.json:/root/.docker/config.json:ro")
if [ -S /var/run/docker.sock ]; then
    DOCKER_OPTS+=(-v "/var/run/docker.sock:/var/run/docker.sock")
fi
docker run "${DOCKER_OPTS[@]}" "$TOOL_IMAGE" "$@"

if [ $? -eq 0 ]; then
    echo "✨ Workflow finished successfully."
else
    echo "❌ Workflow failed. Check the logs above."
    exit 1
fi
