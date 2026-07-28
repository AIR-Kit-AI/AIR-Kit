-- AIRKit ClickHouse schema, part 4: alerts and incidents.
-- Mirrors schema/ocsf/alert.schema.json and incident.schema.json.
--
-- Unlike the telemetry tables above, incidents are mutable (status changes,
-- notes get appended, linked_alert_uids grows) so this uses ReplacingMergeTree
-- keyed on uid rather than plain MergeTree, so `tofu apply`-style repeated
-- upserts converge instead of accumulating duplicate rows.

CREATE TABLE IF NOT EXISTS airkit.alerts
(
    uid                     String,
    time                    DateTime64(3, 'UTC'),
    ingested_at             DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    severity                LowCardinality(String),
    message                 String,
    category                String DEFAULT '',
    mitre_attack_techniques Array(String) DEFAULT [],
    hostname                String DEFAULT '',
    host_ip                 String DEFAULT '',
    adapter                 LowCardinality(String),
    vendor                  LowCardinality(String),
    native_id               String DEFAULT '',
    raw                     String DEFAULT ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (severity, time, uid)
TTL time + INTERVAL 180 DAY  -- alerts kept longer than raw telemetry; they're the triage record
SETTINGS index_granularity = 8192;

ALTER TABLE airkit.alerts ADD INDEX IF NOT EXISTS idx_category category TYPE bloom_filter GRANULARITY 4;
ALTER TABLE airkit.alerts ADD INDEX IF NOT EXISTS idx_mitre mitre_attack_techniques TYPE bloom_filter GRANULARITY 4;

CREATE TABLE IF NOT EXISTS airkit.incidents
(
    uid               String,
    time              DateTime64(3, 'UTC'),
    updated_time      DateTime64(3, 'UTC'),
    status            LowCardinality(String),
    title             String,
    severity          LowCardinality(String) DEFAULT '',
    linked_alert_uids Array(String) DEFAULT [],
    affected_hosts    Array(String) DEFAULT [],
    adapter           LowCardinality(String) DEFAULT '',
    vendor            LowCardinality(String) DEFAULT '',
    native_id         String DEFAULT '',
    notes             String DEFAULT '',
    version           UInt64 DEFAULT 1  -- ReplacingMergeTree version column
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(time)
ORDER BY uid
SETTINGS index_granularity = 8192;

-- Note: query this with `SELECT ... FROM airkit.incidents FINAL` (or rely on
-- background merges) to get de-duplicated latest-version rows.
