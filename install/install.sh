#!/usr/bin/env bash
# AIR-Kit installer.
#
# Deploys the Step 1 "Insulated SecOps Analysis Node" from the CTO Lunch
# NYC 30/60/90 playbook: a self-hosted, zero-egress GLM-5.2 inference node
# with SIEM/EDR telemetry ingestion, ClickHouse + Qdrant storage, and a
# read-only incident analysis agent. Nothing beyond that scope (RSA,
# circuit breakers, kill switch, reachability manifest) is built by this
# installer — those are later phases.
#
# Usage:
#   ./install.sh                 run (or resume) the install
#   ./install.sh --reset         wipe recorded progress and start fresh
#   ./install.sh --status        show which steps have completed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRKIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${AIRKIT_CONFIG_FILE:-$AIRKIT_ROOT/airkit.config.yaml}"

# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=lib/deploy_clickhouse_schema.sh
source "$SCRIPT_DIR/lib/deploy_clickhouse_schema.sh"
# shellcheck source=lib/deploy_qdrant_schema.sh
source "$SCRIPT_DIR/lib/deploy_qdrant_schema.sh"
# shellcheck source=lib/wire_adapters.sh
source "$SCRIPT_DIR/lib/wire_adapters.sh"

# --- CLI flags ---
case "${1:-}" in
  --reset)
    state_reset
    exit 0
    ;;
  --status)
    state_init
    jq '.' "$AIRKIT_STATE_FILE"
    exit 0
    ;;
esac

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[airkit] FATAL: $CONFIG_FILE not found." >&2
  echo "[airkit] copy airkit.config.yaml.example to airkit.config.yaml, edit it, and retry." >&2
  exit 1
fi

echo "[airkit] AIRKit installer starting"
echo "[airkit] config: $CONFIG_FILE"
echo "[airkit] state:  $AIRKIT_STATE_FILE"
echo

# ---------------------------------------------------------------------
# Step: preflight checks
# ---------------------------------------------------------------------
export AIRKIT_INSTANCE_TYPE
AIRKIT_INSTANCE_TYPE="$(yq eval '.aws.instance_type' "$CONFIG_FILE")"
export AIRKIT_WEIGHTS_S3_BUCKET
AIRKIT_WEIGHTS_S3_BUCKET="$(yq eval '.aws.weights_s3_bucket' "$CONFIG_FILE")"

run_step "preflight" preflight_run_all

# ---------------------------------------------------------------------
# Step: bootstrap KMS key for OpenTofu state encryption
#
# Runs as a separate, small tofu apply against only the state-encryption
# module, using local (unencrypted) state, since nothing sensitive exists
# yet at this point — see infra/modules/state-encryption/main.tf for the
# reasoning. The resulting key ARN feeds the main apply below.
# ---------------------------------------------------------------------
bootstrap_kms_key() {
  local aws_region
  aws_region="$(yq eval '.aws.region' "$CONFIG_FILE")"

  pushd "$AIRKIT_ROOT/infra/modules/state-encryption" > /dev/null
  tofu init -input=false
  tofu apply -auto-approve -input=false -var="aws_region=${aws_region}"
  export AIRKIT_KMS_KEY_ARN
  AIRKIT_KMS_KEY_ARN="$(tofu output -raw kms_key_arn)"
  popd > /dev/null

  echo "[airkit] KMS key provisioned: $AIRKIT_KMS_KEY_ARN"
  # Persist for later steps / resumed runs in a separate run, since this
  # exported var won't survive across separate invocations of install.sh.
  jq --arg arn "$AIRKIT_KMS_KEY_ARN" '.kms_key_arn = $arn' "$AIRKIT_STATE_FILE" > "${AIRKIT_STATE_FILE}.tmp"
  mv "${AIRKIT_STATE_FILE}.tmp" "$AIRKIT_STATE_FILE"
}

run_step "bootstrap_kms_key" bootstrap_kms_key

# Re-read the KMS key ARN from state in case this is a resumed run where
# bootstrap_kms_key's step was skipped (and thus its export never ran in
# this process).
export AIRKIT_KMS_KEY_ARN
AIRKIT_KMS_KEY_ARN="$(jq -r '.kms_key_arn // empty' "$AIRKIT_STATE_FILE")"
if [ -z "$AIRKIT_KMS_KEY_ARN" ]; then
  echo "[airkit] FATAL: no kms_key_arn recorded in state after bootstrap_kms_key step." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# Step: main infrastructure apply (network + compute)
# ---------------------------------------------------------------------
apply_infra() {
  local aws_region internal_cidr weights_bucket instance_type

  aws_region="$(yq eval '.aws.region' "$CONFIG_FILE")"
  internal_cidr="$(yq eval '.aws.internal_corporate_cidr' "$CONFIG_FILE")"
  weights_bucket="$(yq eval '.aws.weights_s3_bucket' "$CONFIG_FILE")"
  instance_type="$(yq eval '.aws.instance_type' "$CONFIG_FILE")"

  pushd "$AIRKIT_ROOT/infra" > /dev/null
  tofu init -input=false
  tofu apply -auto-approve -input=false \
    -var="aws_region=${aws_region}" \
    -var="kms_key_arn=${AIRKIT_KMS_KEY_ARN}" \
    -var="internal_corporate_cidr=${internal_cidr}" \
    -var="weights_s3_bucket=${weights_bucket}" \
    -var="instance_type=${instance_type}" \
    -var="deep_learning_ami_id=${AIRKIT_DEEP_LEARNING_AMI_ID:?AIRKIT_DEEP_LEARNING_AMI_ID must be set — see docs/architecture.md for how to look up the current AMI ID for your region}"

  export AIRKIT_INSTANCE_ID AIRKIT_INSTANCE_IP AIRKIT_SGLANG_ENDPOINT
  AIRKIT_INSTANCE_ID="$(tofu output -raw instance_id)"
  AIRKIT_INSTANCE_IP="$(tofu output -raw instance_private_ip)"
  AIRKIT_SGLANG_ENDPOINT="$(tofu output -raw sglang_endpoint)"
  popd > /dev/null

  jq --arg id "$AIRKIT_INSTANCE_ID" --arg ip "$AIRKIT_INSTANCE_IP" --arg ep "$AIRKIT_SGLANG_ENDPOINT" \
    '.instance_id = $id | .instance_ip = $ip | .sglang_endpoint = $ep' \
    "$AIRKIT_STATE_FILE" > "${AIRKIT_STATE_FILE}.tmp"
  mv "${AIRKIT_STATE_FILE}.tmp" "$AIRKIT_STATE_FILE"

  echo "[airkit] infrastructure applied. instance: $AIRKIT_INSTANCE_ID ($AIRKIT_INSTANCE_IP)"
}

run_step "apply_infra" apply_infra

export AIRKIT_INSTANCE_ID AIRKIT_INSTANCE_IP AIRKIT_SGLANG_ENDPOINT
AIRKIT_INSTANCE_ID="$(jq -r '.instance_id // empty' "$AIRKIT_STATE_FILE")"
AIRKIT_INSTANCE_IP="$(jq -r '.instance_ip // empty' "$AIRKIT_STATE_FILE")"
AIRKIT_SGLANG_ENDPOINT="$(jq -r '.sglang_endpoint // empty' "$AIRKIT_STATE_FILE")"

# ---------------------------------------------------------------------
# Step: wait for the node to actually be ready to serve
#
# Deliberately NOT gated by state.sh's run_step / resume logic — health
# is a point-in-time fact, not a one-time action, so this always runs
# fresh even on a resumed install, in case the node rebooted or SGLang
# crashed between runs.
# ---------------------------------------------------------------------
echo "[airkit] running 'wait_for_node_ready' (always re-checked, not resumable)..."
wait_for_node_fully_ready "$AIRKIT_INSTANCE_ID" "$AIRKIT_SGLANG_ENDPOINT"

# ---------------------------------------------------------------------
# Step: deploy ClickHouse + Qdrant schema
# ---------------------------------------------------------------------
export AIRKIT_CLICKHOUSE_ENDPOINT="http://${AIRKIT_INSTANCE_IP}:8123"
export AIRKIT_QDRANT_ENDPOINT="http://${AIRKIT_INSTANCE_IP}:6333"

run_step "deploy_clickhouse_schema" deploy_clickhouse_schema
run_step "deploy_qdrant_schema" deploy_qdrant_schema

# ---------------------------------------------------------------------
# Step: validate and wire enabled adapters
# ---------------------------------------------------------------------
export AIRKIT_INSTANCE_IP
export AIRKIT_SSH_KEY_PATH="${AIRKIT_SSH_KEY_PATH:?AIRKIT_SSH_KEY_PATH must be set — path to the SSH key for the internal_corporate_cidr-restricted node}"

run_step "wire_adapters" wire_adapters

echo
echo "[airkit] install complete."
echo "[airkit]   SGLang endpoint:    $AIRKIT_SGLANG_ENDPOINT"
echo "[airkit]   ClickHouse:         $AIRKIT_CLICKHOUSE_ENDPOINT"
echo "[airkit]   Qdrant:             $AIRKIT_QDRANT_ENDPOINT"
echo "[airkit]"
echo "[airkit] Try the agent: AIRKIT_SGLANG_ENDPOINT=$AIRKIT_SGLANG_ENDPOINT/v1 \\"
echo "[airkit]   python3 agent/runtime/loop.py 'What alerts have fired in the last hour?'"
