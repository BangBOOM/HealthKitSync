CREATE TABLE activities (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    healthkit_uuid TEXT NOT NULL UNIQUE,
    schema_version INTEGER NOT NULL DEFAULT 1,
    name TEXT NOT NULL,
    workout_type TEXT NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT NOT NULL,
    distance_m REAL,
    moving_time_s INTEGER NOT NULL,
    elevation_gain_m REAL,
    average_heart_rate REAL,
    average_speed_mps REAL,
    route_polyline TEXT,
    source_device TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX idx_activities_updated_at_id
ON activities(updated_at, id);

CREATE INDEX idx_activities_started_at
ON activities(started_at);

