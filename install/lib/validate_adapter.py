#!/usr/bin/env python3
"""
AIRKit adapter manifest validator.

Validates adapters/<name>/manifest.yaml against
adapters/contract/adapter.schema.json, and cross-checks that every
output_event_class the adapter claims actually has a corresponding
ClickHouse table (or is raw_telemetry, which always lands in raw_events).

Run standalone while authoring a new adapter, and also invoked by
install/lib/wire_adapters.sh during install for every adapter enabled in
airkit.config.yaml, so a malformed manifest fails at install time rather
than silently dropping data at ingestion time.
"""

import sys
from pathlib import Path

import jsonschema
import yaml

AIRKIT_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_SCHEMA_PATH = AIRKIT_ROOT / "adapters" / "contract" / "adapter.schema.json"
ADAPTERS_DIR = AIRKIT_ROOT / "adapters"

# event_class -> ClickHouse table it must land in, per schema/clickhouse/ddl/.
# raw_telemetry is deliberately absent here: every event class lands in
# raw_events in addition to its typed table, and raw_telemetry has no
# typed table of its own, so it needs no entry.
EVENT_CLASS_TABLE = {
    "alert": "alerts",
    "incident": "incidents",
    "process_event": "process_events",
    "network_event": "network_events",
    "auth_event": "auth_events",
    "file_event": "file_events",
}


def load_contract_schema() -> dict:
    import json

    with open(CONTRACT_SCHEMA_PATH) as f:
        return json.load(f)


def validate_adapter(adapter_name: str) -> list[str]:
    """Returns a list of problems found; empty list means the adapter is valid."""
    problems: list[str] = []
    adapter_dir = ADAPTERS_DIR / adapter_name
    manifest_path = adapter_dir / "manifest.yaml"

    if not manifest_path.exists():
        return [f"No manifest.yaml found at {manifest_path}"]

    with open(manifest_path) as f:
        manifest = yaml.safe_load(f)

    schema = load_contract_schema()
    try:
        jsonschema.validate(instance=manifest, schema=schema)
    except jsonschema.ValidationError as exc:
        problems.append(f"Schema validation failed: {exc.message} (at {'.'.join(str(p) for p in exc.path)})")
        return problems  # further checks assume a structurally valid manifest

    if manifest["adapter_name"] != adapter_name:
        problems.append(
            f"manifest adapter_name={manifest['adapter_name']!r} does not match "
            f"directory name {adapter_name!r}"
        )

    collector_config_path = adapter_dir / manifest["collector"]["config_path"]
    if not collector_config_path.exists():
        problems.append(f"collector.config_path points to {collector_config_path}, which does not exist")

    for event_class in manifest["output_event_classes"]:
        if event_class == "raw_telemetry":
            continue
        expected_table = EVENT_CLASS_TABLE.get(event_class)
        if expected_table is None:
            problems.append(f"Unknown event_class {event_class!r} — not in EVENT_CLASS_TABLE mapping")

    if not manifest.get("field_mapping_notes", "").strip():
        problems.append(
            "field_mapping_notes is empty. Not enforceable by the JSON schema, but required in "
            "practice — an undocumented lossy field mapping is exactly the kind of bug that "
            "surfaces mid-incident rather than at authoring time."
        )

    return problems


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: validate_adapter.py <adapter_name>", file=sys.stderr)
        raise SystemExit(1)

    adapter_name = sys.argv[1]
    problems = validate_adapter(adapter_name)

    if problems:
        print(f"[airkit] adapter '{adapter_name}' FAILED validation:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        raise SystemExit(1)

    print(f"[airkit] adapter '{adapter_name}' is valid")


if __name__ == "__main__":
    main()
