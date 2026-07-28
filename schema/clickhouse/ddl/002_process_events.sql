-- AIRKit ClickHouse schema, part 2: process_events and file_events.
-- Mirrors schema/ocsf/process_event.schema.json and file_event.schema.json.

CREATE TABLE IF NOT EXISTS airkit.process_events
(
    uid                 String,
    time                DateTime64(3, 'UTC'),
    ingested_at         DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    action              LowCardinality(String),  -- create | terminate | image_load
    pid                 UInt32,
    process_name        String,
    command_line        String DEFAULT '',
    hash_sha256         String DEFAULT '',
    signed              UInt8 DEFAULT 0,
    process_user        String DEFAULT '',
    parent_pid          Nullable(UInt32),
    parent_name         String DEFAULT '',
    parent_command_line String DEFAULT '',
    hostname            String,
    host_ip             String DEFAULT '',
    adapter             LowCardinality(String),
    vendor              LowCardinality(String),
    native_id           String DEFAULT '',
    raw                 String DEFAULT ''  -- original vendor payload as JSON text
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (hostname, time, pid)
TTL time + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

ALTER TABLE airkit.process_events ADD INDEX IF NOT EXISTS idx_hash hash_sha256 TYPE bloom_filter GRANULARITY 4;
ALTER TABLE airkit.process_events ADD INDEX IF NOT EXISTS idx_cmdline command_line TYPE tokenbf_v1(4096, 3, 0) GRANULARITY 4;

CREATE TABLE IF NOT EXISTS airkit.file_events
(
    uid           String,
    time          DateTime64(3, 'UTC'),
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    action        LowCardinality(String),  -- create | modify | delete | rename | read
    file_path     String,
    previous_path String DEFAULT '',
    hash_sha256   String DEFAULT '',
    size_bytes    Nullable(UInt64),
    process_pid   Nullable(UInt32),
    process_name  String DEFAULT '',
    hostname      String,
    host_ip       String DEFAULT '',
    adapter       LowCardinality(String),
    vendor        LowCardinality(String),
    native_id     String DEFAULT '',
    raw           String DEFAULT ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (hostname, time, file_path)
TTL time + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

ALTER TABLE airkit.file_events ADD INDEX IF NOT EXISTS idx_file_hash hash_sha256 TYPE bloom_filter GRANULARITY 4;
