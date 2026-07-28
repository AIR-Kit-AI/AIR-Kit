#!/usr/bin/env bash
# AIRKit installer state tracking.
#
# Records which install steps have completed to a JSON file so a failed
# or interrupted run can resume rather than restart from scratch — a
# `tofu apply` that already succeeded should not be re-run just because a
# later step (e.g. schema deployment) failed.
#
# This is deliberately simple (jq over a flat JSON file) rather than a
# real state machine library, matching the earlier Bash-first call: this
# covers the 80% case of "resume after failure," not arbitrary rollback
# or branching install paths.

set -euo pipefail

AIRKIT_STATE_FILE="${AIRKIT_STATE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state/.install-state.json}"

state_init() {
  if [ ! -f "$AIRKIT_STATE_FILE" ]; then
    mkdir -p "$(dirname "$AIRKIT_STATE_FILE")"
    echo '{"steps": {}}' > "$AIRKIT_STATE_FILE"
  fi
}

# state_is_complete <step_name>
# Returns 0 (true) if the step already succeeded in a prior run.
state_is_complete() {
  local step="$1"
  state_init
  jq -e --arg step "$step" '.steps[$step].status == "complete"' "$AIRKIT_STATE_FILE" > /dev/null 2>&1
}

# state_mark_complete <step_name>
state_mark_complete() {
  local step="$1"
  state_init
  local tmp
  tmp="$(mktemp)"
  jq --arg step "$step" --arg ts "$(date -u +%FT%TZ)" \
    '.steps[$step] = {status: "complete", completed_at: $ts}' \
    "$AIRKIT_STATE_FILE" > "$tmp"
  mv "$tmp" "$AIRKIT_STATE_FILE"
}

# state_mark_failed <step_name> <error_message>
state_mark_failed() {
  local step="$1"
  local error_message="$2"
  state_init
  local tmp
  tmp="$(mktemp)"
  jq --arg step "$step" --arg ts "$(date -u +%FT%TZ)" --arg err "$error_message" \
    '.steps[$step] = {status: "failed", failed_at: $ts, error: $err}' \
    "$AIRKIT_STATE_FILE" > "$tmp"
  mv "$tmp" "$AIRKIT_STATE_FILE"
}

# run_step <step_name> <function_to_call>
# Skips the step if already complete; on failure, records the failure and
# re-raises (via set -e) so install.sh halts rather than proceeding past
# a broken step.
run_step() {
  local step="$1"
  local fn="$2"

  if state_is_complete "$step"; then
    echo "[airkit] skipping '$step' (already complete)"
    return 0
  fi

  echo "[airkit] running '$step'..."
  if "$fn"; then
    state_mark_complete "$step"
    echo "[airkit] '$step' complete"
  else
    local exit_code=$?
    state_mark_failed "$step" "exited with code $exit_code"
    echo "[airkit] FATAL: '$step' failed. Re-run install.sh to resume from this step." >&2
    return "$exit_code"
  fi
}

# state_reset
# Wipes all recorded progress. Used by `install.sh --reset`.
state_reset() {
  rm -f "$AIRKIT_STATE_FILE"
  state_init
  echo "[airkit] install state reset"
}
