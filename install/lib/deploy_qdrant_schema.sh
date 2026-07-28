#!/usr/bin/env bash
# Thin Bash wrapper around deploy_qdrant_schema.py. Kept as a separate
# function (rather than calling the Python script directly from
# install.sh) so the state.sh run_step convention — every step is a bash
# function — stays uniform across the whole installer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

deploy_qdrant_schema() {
  local endpoint="${AIRKIT_QDRANT_ENDPOINT:?AIRKIT_QDRANT_ENDPOINT must be set}"
  python3 "$SCRIPT_DIR/deploy_qdrant_schema.py" "$endpoint"
}
