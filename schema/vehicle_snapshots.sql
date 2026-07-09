CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE vehicle_snapshots (
    captured_at         TIMESTAMPTZ NOT NULL,   -- = envelope.eventOccurTimeStamp
    vin                 TEXT        NOT NULL,
    envelope            JSONB,                  -- per-event metadata
    location            JSONB,
    cockpit_data        JSONB,
    tire_pressure_data  JSONB,
    health_status_data  JSONB,
    body_control        JSONB,
    driver_behavior     JSONB,
    adas_context        JSONB,
    cabin_status        JSONB,
    lighting_visibility JSONB,
    PRIMARY KEY (vin, captured_at)
);

SELECT create_hypertable('vehicle_snapshots', by_range('captured_at', INTERVAL '1 day'));

ALTER TABLE vehicle_snapshots SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'vin',
    timescaledb.compress_orderby   = 'captured_at DESC'
);

-- add_columnstore_policy is a PROCEDURE on current TimescaleDB -> use CALL.
-- Older TimescaleDB versions instead use: SELECT add_compression_policy('vehicle_snapshots', INTERVAL '7 days');
CALL add_columnstore_policy('vehicle_snapshots', after => INTERVAL '7 days');
