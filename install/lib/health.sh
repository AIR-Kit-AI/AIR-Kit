#!/usr/bin/env bash
# AIRKit installer health checks.
# Polls infrastructure and services until they're actually usable, rather
# than trusting `tofu apply` exit 0 to mean "ready to serve traffic" —
# an EC2 instance can be "running" long before Docker, GPU drivers, weight
# hydration, and SGLang startup have all finished inside it.

set -euo pipefail

# poll_until <description> <max_attempts> <sleep_seconds> <check_function> [args-for-check-function...]
# check_function is invoked with any trailing args passed to poll_until,
# so callers can do: poll_until "desc" 30 10 health_check_instance_running "$instance_id"
poll_until() {
  local description="$1"
  local max_attempts="$2"
  local sleep_seconds="$3"
  local check_fn="$4"
  shift 4
  local check_args=("$@")

  echo "[airkit] waiting for: $description"
  for attempt in $(seq 1 "$max_attempts"); do
    if "$check_fn" "${check_args[@]}"; then
      echo "[airkit] ready: $description"
      return 0
    fi
    echo "[airkit]   attempt $attempt/$max_attempts — not ready yet, retrying in ${sleep_seconds}s"
    sleep "$sleep_seconds"
  done

  echo "[airkit] FATAL: timed out waiting for: $description" >&2
  return 1
}

health_check_instance_running() {
  local instance_id="$1"
  local status
  status="$(aws ec2 describe-instance-status \
    --instance-ids "$instance_id" \
    --query 'InstanceStatuses[0].InstanceState.Name' \
    --output text 2>/dev/null || echo "unknown")"
  [ "$status" = "running" ]
}

health_check_sglang_endpoint() {
  local endpoint="$1"
  curl --silent --fail --max-time 5 "${endpoint}/models" > /dev/null 2>&1
}

health_check_clickhouse() {
  local endpoint="$1"
  curl --silent --fail --max-time 5 "${endpoint}/ping" > /dev/null 2>&1
}

health_check_qdrant() {
  local endpoint="$1"
  curl --silent --fail --max-time 5 "${endpoint}/readyz" > /dev/null 2>&1
}

# wait_for_instance <instance_id>
# The instance can report "running" well before bootstrap.sh.tftpl has
# finished mounting the weights volume and starting SGLang, so this
# doesn't return until the SGLang endpoint itself answers, not just until
# the instance state says "running."
wait_for_node_fully_ready() {
  local instance_id="$1"
  local sglang_endpoint="$2"

  poll_until "EC2 instance $instance_id running" 30 10 \
    health_check_instance_running "$instance_id"

  # Weight hydration for a ~1.5TB model can legitimately take a long time
  # depending on S3 throughput, hence the generous attempt count here
  # relative to the instance-running check above.
  poll_until "SGLang serving GLM-5.2 at $sglang_endpoint" 180 30 \
    health_check_sglang_endpoint "$sglang_endpoint"
}
