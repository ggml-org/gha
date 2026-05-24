#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# start.sh — Entrypoint for GHA runner container
#
# Runs as user `ggml`. Downloads, configures, and runs the GitHub Actions
# runner. Re-registers on every boot.
#
# Environment variables (passed at runtime via `docker run -e`):
#   GHA_TOKEN        — GitHub Actions org registration token
#   GHA_URL          — GitHub org/repo URL (e.g. https://github.com/ggml-org)
#   GHA_RUNNER_GROUP — Runner group name
#   RUNNER_NAME      — Unique runner name/label
###############################################################################

RUNNER_DIR="/home/ggml/runner"
MAX_AUTH_RETRIES=3
AUTH_FAIL_COUNT=0

echo "[start] Container started as $(whoami) at $(date)"
echo "[start] Runner: ${RUNNER_NAME:-unknown}"

# ---------------------------------------------------------------------------
# Download and extract the GHA runner
# ---------------------------------------------------------------------------
download_runner() {
  echo "[start] Downloading GitHub Actions runner..."

  local ARCH="arm64"
  local RELEASE_INFO VERSION DOWNLOAD_URL

  RELEASE_INFO=$(curl -sL "https://api.github.com/repos/actions/runner/releases/latest")
  VERSION=$(echo "$RELEASE_INFO" | grep -oP '"tag_name":\s*"\K[^"]+' )

  if [[ -z "$VERSION" ]]; then
    echo "[ERROR] Could not determine latest runner version."
    exit 1
  fi

  # Strip leading 'v' for the filename, keep it for the URL path
  local VER_NUM="${VERSION#v}"
  DOWNLOAD_URL="https://github.com/actions/runner/releases/download/${VERSION}/actions-runner-linux-${ARCH}-${VER_NUM}.tar.gz"

  echo "[start] Latest runner version: $VERSION"
  echo "[start] Downloading from: $DOWNLOAD_URL"

  cd /tmp
  curl -fSL -o runner.tar.gz "$DOWNLOAD_URL"
  mkdir -p "$RUNNER_DIR"
  tar xzf runner.tar.gz -C "$RUNNER_DIR" --strip-components=1
  rm -f runner.tar.gz

  echo "[start] Runner extracted to $RUNNER_DIR"
}

# ---------------------------------------------------------------------------
# Configure (register) the runner
# ---------------------------------------------------------------------------
configure_runner() {
  echo "[start] Configuring runner..."

  cd "$RUNNER_DIR"

  # Remove any partial/invalid .env from a previous failed attempt
  rm -f .env

  local CONFIG_ARGS=(--unattended \
    --url "${GHA_URL}" \
    --token "${GHA_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --runnergroup "${GHA_RUNNER_GROUP}" \
    --work "_work" \
    --replace \
    --runasservice false)

  # Add labels if specified
  if [[ -n "${RUNNER_LABELS:-}" ]]; then
    CONFIG_ARGS+=(--labels "${RUNNER_LABELS}")
  fi

  ./config.sh "${CONFIG_ARGS[@]}"

  local EXIT_CODE=$?

  # Restrict permissions on the .env file (contains runner auth token)
  if [[ $EXIT_CODE -eq 0 && -f ".env" ]]; then
    chmod 600 .env
    echo "[start] Runner configured. .env permissions set to 600."
  else
    echo "[ERROR] Runner configuration failed (exit code: $EXIT_CODE)."
    rm -f .env  # clean up partial .env so next restart retries
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Run the runner (with de-registration detection)
# ---------------------------------------------------------------------------
run_runner() {
  echo "[start] Starting runner..."

  cd "$RUNNER_DIR"

  # Run the runner and capture its exit
  ./run.sh 2>&1
  local EXIT_CODE=$?

  if [[ $EXIT_CODE -ne 0 ]]; then
    # Check if this looks like an authentication/registration failure
    local LOG_TAIL
    LOG_TAIL=$(tail -20 /home/ggml/runner/_diag/ls 2>/dev/null | tail -1 2>/dev/null || echo "")

    if echo "$LOG_TAIL" | grep -qiE "unauthorized|forbidden|not registered|invalid token|authentication"; then
      AUTH_FAIL_COUNT=$((AUTH_FAIL_COUNT + 1))
      echo "[ERROR] Runner authentication failed (attempt $AUTH_FAIL_COUNT/$MAX_AUTH_RETRIES)."
      echo "[ERROR] This runner may have been de-registered from the GitHub organization."
      echo "[ERROR] Re-create the container with a new token:"
      echo "[ERROR]   docker rm -f llama.cpp-gha-dgx-${RUNNER_NAME} && ./setup.sh <NEW_TOKEN> ${GHA_URL} ${GHA_RUNNER_GROUP} ${RUNNER_NAME}"

      if [[ $AUTH_FAIL_COUNT -ge $MAX_AUTH_RETRIES ]]; then
        echo "[ERROR] Max auth retries reached. Stopping container."
        exit 1
      fi
      echo "[start] Retrying in 30 seconds..."
      sleep 30
      run_runner  # retry
    else
      echo "[ERROR] Runner exited with code $EXIT_CODE."
      exit $EXIT_CODE
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Download runner if not present
if [[ ! -f "$RUNNER_DIR/run.sh" ]]; then
  download_runner
fi

# Configure only if not already configured
if [[ ! -f "$RUNNER_DIR/.env" ]]; then
  configure_runner
else
  echo "[start] Runner already configured, skipping registration."
fi

# Run the runner (loops on auth failure up to MAX_AUTH_RETRIES)
run_runner
