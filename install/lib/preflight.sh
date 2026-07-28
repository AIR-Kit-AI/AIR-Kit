#!/usr/bin/env bash
# AIRKit installer preflight checks.
# Validates the environment BEFORE any infrastructure is touched, so
# failures surface immediately rather than partway through a tofu apply.

set -euo pipefail

preflight_check_tools() {
  local missing=()
  for tool in tofu aws docker jq; do
    if ! command -v "$tool" > /dev/null 2>&1; then
      missing+=("$tool")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "[airkit] FATAL: missing required tools: ${missing[*]}" >&2
    echo "[airkit] install these before continuing." >&2
    return 1
  fi

  local tofu_version
  tofu_version="$(tofu version -json | jq -r '.terraform_version')"
  echo "[airkit] found OpenTofu $tofu_version"
}

preflight_check_aws_creds() {
  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "[airkit] FATAL: AWS credentials not configured or invalid." >&2
    echo "[airkit] run 'aws configure' or set AWS_PROFILE, then retry." >&2
    return 1
  fi
  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  echo "[airkit] AWS credentials valid (account: $account_id)"
}

preflight_check_instance_quota() {
  local instance_type="${AIRKIT_INSTANCE_TYPE:-p5e.48xlarge}"
  echo "[airkit] checking service quota for $instance_type instances..."
  # p5e instances fall under the "Running On-Demand P instances" vCPU-based
  # quota (L-417A185B). This is a best-effort check — quota codes can shift
  # between AWS quota reclassifications, so a failure here warns rather
  # than hard-blocks, since the actual authoritative check is the tofu
  # apply itself failing with an InstanceLimitExceeded error.
  local quota_value
  quota_value="$(aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-417A185B \
    --query 'Quota.Value' \
    --output text 2>/dev/null || echo "unknown")"

  if [ "$quota_value" = "unknown" ]; then
    echo "[airkit] WARNING: could not verify EC2 P-instance quota. If tofu apply fails with"
    echo "[airkit]          InstanceLimitExceeded, request a quota increase in the AWS console"
    echo "[airkit]          for 'Running On-Demand P instances' before retrying."
  else
    echo "[airkit] current P-instance vCPU quota: $quota_value"
  fi
}

preflight_check_weights_bucket() {
  local bucket="${AIRKIT_WEIGHTS_S3_BUCKET:?AIRKIT_WEIGHTS_S3_BUCKET must be set}"
  if ! aws s3api head-bucket --bucket "$bucket" > /dev/null 2>&1; then
    echo "[airkit] FATAL: S3 bucket '$bucket' (AIRKIT_WEIGHTS_S3_BUCKET) does not exist or is not accessible." >&2
    echo "[airkit] this bucket must already contain the GLM-5.2 weights under GLM-5.2/ before install," >&2
    echo "[airkit] since the compute node hydrates from it over the internal S3 Gateway Endpoint with no other path in." >&2
    return 1
  fi
  echo "[airkit] weights bucket '$bucket' is accessible"
}

preflight_run_all() {
  preflight_check_tools
  preflight_check_aws_creds
  preflight_check_instance_quota
  preflight_check_weights_bucket
}
