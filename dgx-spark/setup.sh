#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup.sh — GitHub Actions runner container for llama.cpp on Jetson Orin
#
# Usage:
#   ./setup.sh <GHA_URL> <GHA_TOKEN> <RUNNER_GROUP> <INSTANCE_NAME> [--cpu-range=RANGE] [--memory=SIZE] [--labels=LABELS]
#
# Example:
#   ./setup.sh https://github.com/ggml-org AAPGFACIPBXWA... self-hosted runner-1 --cpu-range=0-3 --memory=16g --labels=linux,gpu
#
# --cpu-range uses Docker's --cpuset-cpus, which pins the container to specific
# host cores.  Inside the container, nproc, lscpu, etc. will report only the
# allocated cores (e.g., `make -j$(nproc)` will use 4, not 20).
#
# This script creates a Docker container with:
#   - Ubuntu 24.04 (minimal)
#   - Build tools: gcc, cmake, make, git, curl, wget
#   - NVIDIA GPU access (CUDA 13.0 + Vulkan via host driver mount)
#   - Low-privilege user `ggml`
#   - GitHub Actions runner (registered on every boot)
#
# Prerequisites on host:
#   - Docker installed and running
#   - User in 'docker' group (no sudo needed)
#   - NVIDIA driver + CUDA toolkit installed (JetPack)
###############################################################################

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 <GHA_URL> <GHA_TOKEN> <RUNNER_GROUP> <INSTANCE_NAME> [--cpu-range=RANGE] [--memory=SIZE] [--labels=LABELS]"
  exit 1
}

if [[ $# -lt 4 ]]; then usage; fi

GHA_URL="$1"
GHA_TOKEN="$2"
GHA_RUNNER_GROUP="$3"
INSTANCE_NAME="$4"
shift 4

CONTAINER_NAME="llama.cpp-gha-dgx-${INSTANCE_NAME}"
IMAGE="ggml-org/llama.cpp-gha-dgx"
CUDA_HOST_DIR="/usr/local/cuda-13.0"
NVIDIA_LIB_DIR="/usr/lib/aarch64-linux-gnu"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Optional flags
RUNNER_CPU_RANGE=""
RUNNER_MEMORY=""
RUNNER_LABELS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpu-range=*) RUNNER_CPU_RANGE="${1#*=}" ;;
    --memory=*)    RUNNER_MEMORY="${1#*=}" ;;
    --labels=*)    RUNNER_LABELS="${1#*=}" ;;
    *)             echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Step 0 — Pre-flight checks
# ---------------------------------------------------------------------------
echo "=== Step 0: Pre-flight checks ==="

if ! docker info &>/dev/null; then
  echo "ERROR: Cannot access Docker. Are you in the 'docker' group?"
  echo "Fix: sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi

if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
  echo "ERROR: NVIDIA GPU/driver not found on host."
  exit 1
fi

if [ ! -d "$CUDA_HOST_DIR" ]; then
  echo "ERROR: CUDA toolkit not found at $CUDA_HOST_DIR"
  exit 1
fi

if [ ! -f "$NVIDIA_LIB_DIR/libGLX_nvidia.so.0" ]; then
  echo "ERROR: NVIDIA Vulkan/GL driver not found at $NVIDIA_LIB_DIR"
  exit 1
fi

echo "  Docker: OK"
echo "  NVIDIA GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader)"
echo "  CUDA: $(nvcc --version 2>/dev/null | head -1 || echo 'unknown')"
echo "  Instance: $INSTANCE_NAME"
echo "  GHA URL:  $GHA_URL"
[[ -n "$RUNNER_LABELS" ]] && echo "  Labels:   $RUNNER_LABELS"

# ---------------------------------------------------------------------------
# Step 1 — Build image from Dockerfile
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: Build Docker image ==="

docker build -t "${IMAGE}:latest" "$SCRIPT_DIR"

echo "  Image built: ${IMAGE}:latest"

# ---------------------------------------------------------------------------
# Step 2 — Start container
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Start container ==="

# Remove any previous container with the same name
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Build resource limit flags
RESOURCE_FLAGS=()
if [[ -n "$RUNNER_CPU_RANGE" ]]; then
  RESOURCE_FLAGS+=("--cpuset-cpus" "$RUNNER_CPU_RANGE")
fi
if [[ -n "$RUNNER_MEMORY" ]]; then
  RESOURCE_FLAGS+=("--memory" "$RUNNER_MEMORY")
fi

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --gpus all \
  --device /dev/dri/renderD128 \
  --device /dev/dri/card0 \
  --device /dev/nvidia0 \
  --device /dev/nvidiactl \
  --device /dev/nvidia-modeset \
  --device /dev/nvidia-uvm \
  --device /dev/nvidia-uvm-tools \
  "${RESOURCE_FLAGS[@]}" \
  -v "$CUDA_HOST_DIR:/usr/local/cuda:ro" \
  -v "$NVIDIA_LIB_DIR:$NVIDIA_LIB_DIR:ro" \
  -v /usr/share/vulkan/icd.d/nvidia_icd.json:/usr/share/vulkan/icd.d/nvidia_icd.json:ro \
  -v /usr/share/vulkan/implicit_layer.d/nvidia_layers.json:/usr/share/vulkan/implicit_layer.d/nvidia_layers.json:ro \
  -v /usr/share/glvnd:/usr/share/glvnd:ro \
  -e CUDA_HOME=/usr/local/cuda \
  -e PATH="/usr/local/cuda/bin:${PATH}" \
  -e GHA_TOKEN="${GHA_TOKEN}" \
  -e GHA_URL="${GHA_URL}" \
  -e GHA_RUNNER_GROUP="${GHA_RUNNER_GROUP}" \
  -e RUNNER_NAME="${INSTANCE_NAME}" \
  -e RUNNER_LABELS="${RUNNER_LABELS}" \
  "${IMAGE}:latest"

echo "  Container '$CONTAINER_NAME' started."
echo "  Restart policy: unless-stopped (auto-restarts on crash)"
[[ -n "$RUNNER_CPU_RANGE" ]] && echo "  CPU cores: $RUNNER_CPU_RANGE"
[[ -n "$RUNNER_MEMORY" ]] && echo "  Memory limit: $RUNNER_MEMORY"

# ---------------------------------------------------------------------------
# Step 3 — Verify
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Verification ==="

sleep 3  # give the runner time to download and configure

echo "  User:    $(docker exec "$CONTAINER_NAME" whoami)"
echo "  gcc:     $(docker exec "$CONTAINER_NAME" gcc --version | head -1)"
echo "  cmake:   $(docker exec "$CONTAINER_NAME" cmake --version | head -1)"
echo "  nvcc:    $(docker exec "$CONTAINER_NAME" nvcc --version | head -1)"
echo "  GPU:     $(docker exec "$CONTAINER_NAME" nvidia-smi --query-gpu=name --format=csv,noheader)"
echo "  Vulkan:  $(docker exec "$CONTAINER_NAME" vulkaninfo --summary 2>/dev/null | grep deviceName || echo 'FAILED')"
echo ""
echo "  Recent logs:"
docker logs --tail 10 "$CONTAINER_NAME" 2>&1 | sed 's/^/    /'

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Useful commands:"
echo "  Enter container:  docker exec -it $CONTAINER_NAME bash"
echo "  View logs:        docker logs -f $CONTAINER_NAME"
echo "  Stop:             docker stop $CONTAINER_NAME"
echo "  Remove:           docker rm -f $CONTAINER_NAME"
echo "  Save image:       docker save ${IMAGE}:latest -o llama.cpp-gha-dgx.tar"
echo "  Restore image:    docker load -i llama.cpp-gha-dgx.tar"
echo ""
RECREATE_ARGS=""
[[ -n "$RUNNER_CPU_RANGE" ]] && RECREATE_ARGS+=" --cpu-range=$RUNNER_CPU_RANGE"
[[ -n "$RUNNER_MEMORY" ]] && RECREATE_ARGS+=" --memory=$RUNNER_MEMORY"
[[ -n "$RUNNER_LABELS" ]] && RECREATE_ARGS+=" --labels=$RUNNER_LABELS"
echo "Re-create with new token:"
echo "  docker rm -f $CONTAINER_NAME && ./setup.sh <NEW_TOKEN> $GHA_URL $GHA_RUNNER_GROUP $INSTANCE_NAME$RECREATE_ARGS"
