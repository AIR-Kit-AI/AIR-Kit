#!/usr/bin/env bash
# AIRKit adapter wiring.
# Reads enabled_adapters from airkit.config.yaml, validates each one's
# manifest against the contract schema, and copies its Vector config to
# the inference node, then (re)starts the Vector container so it picks
# up the merged config for every enabled source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRKIT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${AIRKIT_CONFIG_FILE:-$AIRKIT_ROOT/airkit.config.yaml}"

wire_adapters() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[airkit] FATAL: config file not found at $CONFIG_FILE" >&2
    echo "[airkit] copy airkit.config.yaml.example to airkit.config.yaml and edit it first." >&2
    return 1
  fi

  local instance_ip="${AIRKIT_INSTANCE_IP:?AIRKIT_INSTANCE_IP must be set}"
  local ssh_key="${AIRKIT_SSH_KEY_PATH:?AIRKIT_SSH_KEY_PATH must be set}"

  local enabled_adapters
  enabled_adapters="$(yq eval '.enabled_adapters[]' "$CONFIG_FILE")"

  if [ -z "$enabled_adapters" ]; then
    echo "[airkit] FATAL: no adapters enabled in $CONFIG_FILE (enabled_adapters is empty)" >&2
    echo "[airkit] at minimum, enable generic-syslog so ingestion isn't a no-op." >&2
    return 1
  fi

  echo "[airkit] validating enabled adapters..."
  local adapter
  while IFS= read -r adapter; do
    echo "[airkit]   validating '$adapter'"
    if ! python3 "$SCRIPT_DIR/validate_adapter.py" "$adapter"; then
      echo "[airkit] FATAL: adapter '$adapter' failed validation, aborting wiring." >&2
      return 1
    fi
  done <<< "$enabled_adapters"

  echo "[airkit] copying adapter configs to inference node ($instance_ip)..."
  local remote_adapter_dir="/opt/airkit/adapters"
  ssh -i "$ssh_key" -o StrictHostKeyChecking=accept-new "ec2-user@${instance_ip}" \
    "mkdir -p $remote_adapter_dir"

  while IFS= read -r adapter; do
    echo "[airkit]   deploying '$adapter'"
    scp -i "$ssh_key" -r "$AIRKIT_ROOT/adapters/$adapter" \
      "ec2-user@${instance_ip}:${remote_adapter_dir}/$adapter"
  done <<< "$enabled_adapters"

  echo "[airkit] restarting Vector container on inference node to pick up enabled adapters..."
  # Each enabled adapter's vector.toml is treated as an independent config
  # fragment; Vector supports loading multiple config files from a
  # directory and merges their sources/transforms/sinks by namespace, so
  # no single merged config file needs to be hand-assembled here.
  ssh -i "$ssh_key" -o StrictHostKeyChecking=accept-new "ec2-user@${instance_ip}" bash -s <<'REMOTE_SCRIPT'
    set -euo pipefail
    docker rm -f airkit-vector 2>/dev/null || true
    docker run -d \
      --name airkit-vector \
      --restart unless-stopped \
      --net=host \
      -v /opt/airkit/adapters:/etc/vector/adapters:ro \
      --env-file /opt/airkit/vector.env \
      timberio/vector:latest-alpine \
      --config-dir /etc/vector/adapters --config-dir-glob "*/vector.toml"
REMOTE_SCRIPT

  echo "[airkit] adapters wired: $(echo "$enabled_adapters" | tr '\n' ' ')"
}
