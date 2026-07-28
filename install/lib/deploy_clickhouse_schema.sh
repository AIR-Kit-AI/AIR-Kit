#!/usr/bin/env bash
# Applies schema/clickhouse/ddl/*.sql, in filename order, against the live
# ClickHouse endpoint. Idempotent — every statement in those files uses
# CREATE ... IF NOT EXISTS / ADD INDEX ... IF NOT EXISTS, so re-running
# this after a partial failure is safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRKIT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DDL_DIR="$AIRKIT_ROOT/schema/clickhouse/ddl"

deploy_clickhouse_schema() {
  local endpoint="${AIRKIT_CLICKHOUSE_ENDPOINT:?AIRKIT_CLICKHOUSE_ENDPOINT must be set}"

  if [ ! -d "$DDL_DIR" ]; then
    echo "[airkit] FATAL: DDL directory not found at $DDL_DIR" >&2
    return 1
  fi

  local ddl_file
  for ddl_file in "$DDL_DIR"/*.sql; do
    echo "[airkit] applying $(basename "$ddl_file")..."
    if ! curl --silent --show-error --fail \
      "${endpoint}/" \
      --data-binary @"$ddl_file" \
      --header "X-ClickHouse-Format: TabSeparated" > /dev/null; then
      echo "[airkit] FATAL: failed applying $(basename "$ddl_file")" >&2
      return 1
    fi
  done

  echo "[airkit] verifying airkit database and expected tables exist..."
  local expected_tables=(raw_events process_events file_events network_events auth_events alerts incidents)
  local table
  for table in "${expected_tables[@]}"; do
    local exists
    exists="$(curl --silent --fail "${endpoint}/" \
      --data-binary "EXISTS TABLE airkit.${table}")"
    if [ "$exists" != "1" ]; then
      echo "[airkit] FATAL: table airkit.${table} does not exist after DDL apply" >&2
      return 1
    fi
  done

  echo "[airkit] ClickHouse schema deployed: all expected tables present"
}
