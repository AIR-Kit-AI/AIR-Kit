"""
AIRKit ClickHouse MCP tool server.

Exposes read-only query access to the airkit ClickHouse database to the
incident analysis agent. The core safety property this file is responsible
for: no matter what the agent (or, worse, attacker-controlled text the
agent has ingested) requests, this server can never mutate the database.
That guard lives here, in code, rather than being left to prompt-level
instruction-following.
"""

import os
import re
from datetime import datetime
from typing import Any

import clickhouse_connect
from mcp.server.fastmcp import FastMCP

CLICKHOUSE_ENDPOINT = os.environ["AIRKIT_CLICKHOUSE_ENDPOINT"]
CLICKHOUSE_DATABASE = os.environ.get("AIRKIT_CLICKHOUSE_DATABASE", "airkit")
DEFAULT_MAX_ROWS = 500
HARD_MAX_ROWS = 5000

# Anything other than a single leading SELECT is rejected outright. This is
# intentionally conservative — it will also reject some legitimate-looking
# read-only constructs (e.g. WITH ... SELECT CTEs get special-cased below)
# rather than trying to be clever about parsing SQL. A false rejection is
# an inconvenience; a false acceptance of a mutating statement is a defect
# in the one thing this tool is not allowed to be wrong about.
_FORBIDDEN_KEYWORDS = re.compile(
    r"\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|RENAME|GRANT|REVOKE|"
    r"ATTACH|DETACH|OPTIMIZE|KILL|SYSTEM)\b",
    re.IGNORECASE,
)
_ALLOWED_LEADING = re.compile(r"^\s*(WITH\b.*\bSELECT\b|SELECT\b)", re.IGNORECASE | re.DOTALL)

mcp = FastMCP("airkit-clickhouse-tool")
_client = clickhouse_connect.get_client(dsn=CLICKHOUSE_ENDPOINT, database=CLICKHOUSE_DATABASE)


def _assert_read_only(sql_query: str) -> None:
    if ";" in sql_query.strip().rstrip(";"):
        raise ValueError("Multi-statement queries are not permitted. Submit exactly one SELECT statement.")
    if not _ALLOWED_LEADING.match(sql_query):
        raise ValueError("Query must be a single SELECT (or WITH ... SELECT) statement.")
    if _FORBIDDEN_KEYWORDS.search(sql_query):
        raise ValueError(
            "Query contains a keyword not permitted on this read-only tool. "
            "This tool cannot mutate data under any circumstances."
        )


def _run_query(sql_query: str, max_rows: int) -> list[dict[str, Any]]:
    _assert_read_only(sql_query)
    capped = min(max_rows, HARD_MAX_ROWS)
    # ClickHouse doesn't error on a missing LIMIT, so enforce the cap
    # ourselves rather than trusting the query to have one.
    wrapped = f"SELECT * FROM ({sql_query.rstrip(';')}) LIMIT {capped}"
    result = _client.query(wrapped)
    return [dict(zip(result.column_names, row)) for row in result.result_rows]


@mcp.tool()
def query_clickhouse_logs(sql_query: str, max_rows: int = DEFAULT_MAX_ROWS) -> list[dict[str, Any]]:
    """Execute a read-only SELECT against airkit.* ClickHouse tables."""
    return _run_query(sql_query, max_rows)


@mcp.tool()
def get_host_telemetry(hostname: str, time_window_start: str, time_window_end: str) -> dict[str, Any]:
    """Return all event classes for a host within a time window, time-ordered per class."""
    _validate_iso8601(time_window_start)
    _validate_iso8601(time_window_end)

    queries = {
        "alerts": f"""
            SELECT * FROM airkit.alerts
            WHERE hostname = {{hostname:String}}
              AND time BETWEEN {{start:DateTime64(3)}} AND {{end:DateTime64(3)}}
            ORDER BY time
        """,
        "process_events": f"""
            SELECT * FROM airkit.process_events
            WHERE hostname = {{hostname:String}}
              AND time BETWEEN {{start:DateTime64(3)}} AND {{end:DateTime64(3)}}
            ORDER BY time
        """,
        "network_events": f"""
            SELECT * FROM airkit.network_events
            WHERE (src_hostname = {{hostname:String}} OR dst_hostname = {{hostname:String}})
              AND time BETWEEN {{start:DateTime64(3)}} AND {{end:DateTime64(3)}}
            ORDER BY time
        """,
        "auth_events": f"""
            SELECT * FROM airkit.auth_events
            WHERE source_ip IN (
                SELECT DISTINCT src_ip FROM airkit.network_events WHERE src_hostname = {{hostname:String}}
            )
              AND time BETWEEN {{start:DateTime64(3)}} AND {{end:DateTime64(3)}}
            ORDER BY time
        """,
        "file_events": f"""
            SELECT * FROM airkit.file_events
            WHERE hostname = {{hostname:String}}
              AND time BETWEEN {{start:DateTime64(3)}} AND {{end:DateTime64(3)}}
            ORDER BY time
        """,
    }

    params = {"hostname": hostname, "start": time_window_start, "end": time_window_end}
    out: dict[str, Any] = {}
    for label, q in queries.items():
        result = _client.query(q, parameters=params)
        out[label] = [dict(zip(result.column_names, row)) for row in result.result_rows]
    return out


@mcp.tool()
def correlate_ip_pcap(source_ip: str, time_window_start: str, time_window_end: str) -> list[dict[str, Any]]:
    """Return network_events where source_ip appears as either src or dst, within a time window."""
    _validate_iso8601(time_window_start)
    _validate_iso8601(time_window_end)

    q = """
        SELECT * FROM airkit.network_events
        WHERE (src_ip = {ip:String} OR dst_ip = {ip:String})
          AND time BETWEEN {start:DateTime64(3)} AND {end:DateTime64(3)}
        ORDER BY time
    """
    result = _client.query(
        q,
        parameters={"ip": source_ip, "start": time_window_start, "end": time_window_end},
    )
    return [dict(zip(result.column_names, row)) for row in result.result_rows]


def _validate_iso8601(value: str) -> None:
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"Not a valid ISO8601 timestamp: {value!r}") from exc


if __name__ == "__main__":
    mcp.run()
