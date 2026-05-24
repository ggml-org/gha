#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# fleet.sh - Manage a fleet of GHA runner containers
#
# Usage:
#   ./fleet.sh create
#   ./fleet.sh destroy
#   ./fleet.sh start
#   ./fleet.sh stop
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Fleet configuration (edit these)
# ---------------------------------------------------------------------------
GHA_URL="https://github.com/ggml-org"
GHA_RUNNER_GROUP="ggml-ci"

# Runner instance names
RUNNER_NAMES=(
  "ggml-dgx-spark-2-runner-1"
  "ggml-dgx-spark-2-runner-2"
  "ggml-dgx-spark-2-runner-3"
  "ggml-dgx-spark-2-runner-4"
  "ggml-dgx-spark-2-runner-5"
)

# GHA registration tokens (read from tokens.txt, one per line)
mapfile -t RUNNER_TOKENS < "$SCRIPT_DIR/tokens.txt"

# Labels per runner (comma-separated, same order as RUNNER_NAMES)
# TODO: does the DGX Spark support coopmat2?
RUNNER_LABELS=(
  "fast"
  "CPU,NVIDIA,COOPMAT,llama-server,fast"
  "CPU,NVIDIA,COOPMAT,llama-server,fast"
  "CPU,NVIDIA,COOPMAT,llama-server,fast"
  "CPU,NVIDIA,COOPMAT,llama-server,fast"
)

# CPU ranges per runner (cpuset pins to specific host cores)
# nproc inside the container will report only these cores.
# Adjust ranges if you have fewer/more physical cores.
RUNNER_CPU_RANGES=(
  "0-3"
  "4-7"
  "8-11"
  "12-15"
  "16-19"
)

# Memory per runner (same order as RUNNER_NAMES)
RUNNER_MEMORY=(
  "16g"
  "16g"
  "16g"
  "16g"
  "16g"
)

N=${#RUNNER_NAMES[@]}

if [[ ${#RUNNER_TOKENS[@]} -ne $N ]]; then
  echo "ERROR: ${#RUNNER_TOKENS[@]} tokens in tokens.txt but $N runners defined."
  exit 1
fi

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: $0 {create|destroy|start|stop}"
  exit 1
}

[[ $# -lt 1 ]] && usage

cmd="$1"

# ---------------------------------------------------------------------------
# create - provision all runners
# ---------------------------------------------------------------------------
create_fleet() {
  echo "=== Creating fleet of $N runners ==="

  for (( i=0; i<N; i++ )); do
    name="${RUNNER_NAMES[$i]}"
    token="${RUNNER_TOKENS[$i]}"
    labels="${RUNNER_LABELS[$i]}"

    echo ""
    echo "--- Runner $((i+1))/$N: $name (labels: $labels) ---"

    "$SCRIPT_DIR/setup.sh" \
      "$GHA_URL" \
      "$token" \
      "$GHA_RUNNER_GROUP" \
      "$name" \
      --cpu-range="${RUNNER_CPU_RANGES[$i]}" \
      --memory="${RUNNER_MEMORY[$i]}" \
      --labels="$labels"
  done

  echo ""
  echo "=== Fleet created: $N runners ==="
}

# ---------------------------------------------------------------------------
# destroy - de-register and remove all runners
# ---------------------------------------------------------------------------
destroy_fleet() {
  echo "=== Destroying fleet of $N runners ==="

  for (( i=0; i<N; i++ )); do
    name="${RUNNER_NAMES[$i]}"
    token="${RUNNER_TOKENS[$i]}"
    container_name="gha-dgx-${name}"

    echo ""
    echo "--- Runner $((i+1))/$N: $name ---"

    # Check if container exists
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
      echo "  Container '$container_name' not found, skipping."
      continue
    fi

    # De-register the runner from GitHub
    echo "  De-registering runner from GitHub..."
    if docker exec "$container_name" bash -c \
      'cd /home/ggml/runner && [[ -f config.sh ]] && ./config.sh remove --token '"$token" 2>&1; then
      echo "  Runner de-registered."
    else
      echo "  Warning: De-registration may have failed (runner might not be configured)."
    fi

    # Stop and remove the container
    echo "  Removing container..."
    docker rm -f "$container_name" 2>/dev/null && echo "  Container removed." || echo "  Warning: Could not remove container."
  done

  echo ""
  echo "=== Fleet destroyed ==="
}

# ---------------------------------------------------------------------------
# start — start all runner containers
# ---------------------------------------------------------------------------
start_fleet() {
  echo "=== Starting fleet of $N runners ==="

  for (( i=0; i<N; i++ )); do
    name="${RUNNER_NAMES[$i]}"
    container_name="gha-dgx-${name}"

    echo ""
    echo "--- Runner $((i+1))/$N: $name ---"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
      echo "  Container '$container_name' not found, skipping."
      continue
    fi

    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
      echo "  Container '$container_name' is already running."
      continue
    fi

    echo "  Starting container..."
    docker start "$container_name" && echo "  Container started." || echo "  Warning: Could not start container."
  done

  echo ""
  echo "=== Fleet started ==="
}

# ---------------------------------------------------------------------------
# stop — stop all runner containers
# ---------------------------------------------------------------------------
stop_fleet() {
  echo "=== Stopping fleet of $N runners ==="

  for (( i=0; i<N; i++ )); do
    name="${RUNNER_NAMES[$i]}"
    container_name="gha-dgx-${name}"

    echo ""
    echo "--- Runner $((i+1))/$N: $name ---"

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
      echo "  Container '$container_name' not found, skipping."
      continue
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
      echo "  Container '$container_name' is not running, skipping."
      continue
    fi

    echo "  Stopping container..."
    docker stop "$container_name" && echo "  Container stopped." || echo "  Warning: Could not stop container."
  done

  echo ""
  echo "=== Fleet stopped ==="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$cmd" in
  create)  create_fleet ;;
  destroy) destroy_fleet ;;
  start)   start_fleet ;;
  stop)    stop_fleet ;;
  *)       usage ;;
esac
