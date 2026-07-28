-- AIRKit ClickHouse schema, part 1: database + catch-all raw_events table.
--
-- Design note: every canonical event class also gets inserted into
-- raw_events as a JSON blob, IN ADDITION TO its own typed table below.
-- This gives the agent one universal fallback query path
-- ("search everything regardless of type") while the typed tables give
-- fast, indexed queries for the common cases. Storage cost of the
-- duplication is small relative to the query-flexibility win for a
-- forensic analysis tool where you often don't know the shape of what
-- you're looking for yet.

CREATE DATABASE IF NOT EXISTS airkit;

CREATE TABLE IF NOT EXISTS airkit.raw_events
(
    event_class   LowCardinality(String),
    uid           String,
    time          DateTime64(3, 'UTC'),
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    adapter       LowCardinality(String),
    vendor        LowCardinality(String),
    hostname      String DEFAULT '',
    payload       String  -- full canonical-schema JSON document, as text
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (event_class, time, uid)
TTL time + INTERVAL 90 DAY  -- adjust per retention policy; forensic data often needs longer
SETTINGS index_granularity = 8192;

-- Materialized column-level index to make "find everything touching this
-- host" fast without needing to know event_class ahead of time.
ALTER TABLE airkit.raw_events ADD INDEX IF NOT EXISTS idx_hostname hostname TYPE bloom_filter GRANULARITY 4;
ALTER TABLE airkit.raw_events ADD INDEX IF NOT EXISTS idx_uid uid TYPE bloom_filter GRANULARITY 4;
