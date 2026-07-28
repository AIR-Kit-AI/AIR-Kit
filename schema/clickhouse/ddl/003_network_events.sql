-- AIRKit ClickHouse schema, part 3: network_events and auth_events.
-- Mirrors schema/ocsf/network_event.schema.json and auth_event.schema.json.

CREATE TABLE IF NOT EXISTS airkit.network_events
(
    uid             String,
    time            DateTime64(3, 'UTC'),
    ingested_at     DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    action          LowCardinality(String),   -- allowed | blocked | observed
    protocol        LowCardinality(String),   -- tcp | udp | icmp | other
    src_ip          String,
    src_port        Nullable(UInt16),
    src_hostname    String DEFAULT '',
    dst_ip          String,
    dst_port        Nullable(UInt16),
    dst_hostname    String DEFAULT '',
    bytes_sent      Nullable(UInt64),
    bytes_received  Nullable(UInt64),
    dns_query       String DEFAULT '',
    adapter         LowCardinality(String),
    vendor          LowCardinality(String),
    native_id       String DEFAULT '',
    raw             String DEFAULT ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (dst_ip, time, src_ip)
TTL time + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

ALTER TABLE airkit.network_events ADD INDEX IF NOT EXISTS idx_src_ip src_ip TYPE bloom_filter GRANULARITY 4;
ALTER TABLE airkit.network_events ADD INDEX IF NOT EXISTS idx_dns dns_query TYPE bloom_filter GRANULARITY 4;

CREATE TABLE IF NOT EXISTS airkit.auth_events
(
    uid             String,
    time            DateTime64(3, 'UTC'),
    ingested_at     DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    action          LowCardinality(String),  -- login | logout | privilege_escalation | token_issued | token_revoked | mfa_challenge
    outcome         LowCardinality(String),  -- success | failure | denied
    username        String,
    user_id         String DEFAULT '',
    source_ip       String DEFAULT '',
    target_resource String DEFAULT '',
    mfa_used        UInt8 DEFAULT 0,
    adapter         LowCardinality(String),
    vendor          LowCardinality(String),
    native_id       String DEFAULT '',
    raw             String DEFAULT ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (username, time)
TTL time + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

ALTER TABLE airkit.auth_events ADD INDEX IF NOT EXISTS idx_source_ip source_ip TYPE bloom_filter GRANULARITY 4;
