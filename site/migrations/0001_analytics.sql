CREATE TABLE IF NOT EXISTS measurement_windows (
  window_key TEXT PRIMARY KEY,
  started_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  retention_until INTEGER NOT NULL,
  cohort_day TEXT NOT NULL,
  country_code TEXT NOT NULL DEFAULT 'unknown',
  device_category TEXT NOT NULL DEFAULT 'unknown'
    CHECK (device_category IN ('desktop', 'mobile', 'tablet', 'unknown')),
  referrer_host TEXT NOT NULL DEFAULT 'direct'
);

CREATE INDEX IF NOT EXISTS measurement_windows_expiry
  ON measurement_windows(retention_until);
CREATE INDEX IF NOT EXISTS measurement_windows_cohort
  ON measurement_windows(cohort_day);

CREATE TABLE IF NOT EXISTS unique_actions (
  window_key TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('download', 'github')),
  first_placement TEXT NOT NULL CHECK (first_placement IN ('header', 'hero', 'footer')),
  first_at INTEGER NOT NULL,
  PRIMARY KEY (window_key, action),
  FOREIGN KEY (window_key) REFERENCES measurement_windows(window_key) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS unique_actions_action
  ON unique_actions(action, first_at);

CREATE TABLE IF NOT EXISTS daily_counters (
  day TEXT NOT NULL,
  metric TEXT NOT NULL,
  placement TEXT NOT NULL DEFAULT 'all',
  value INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, metric, placement)
);

CREATE TABLE IF NOT EXISTS cohort_rollups (
  cohort_day TEXT NOT NULL,
  metric TEXT NOT NULL,
  dimension_name TEXT NOT NULL DEFAULT 'all',
  dimension_value TEXT NOT NULL DEFAULT 'all',
  value INTEGER NOT NULL,
  PRIMARY KEY (cohort_day, metric, dimension_name, dimension_value)
);
