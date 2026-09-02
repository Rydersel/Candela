-- Guide clicks get their own placement, counted apart from the landing's. SQLite
-- cannot widen a CHECK in place, so the table is rebuilt with its rows carried over.
CREATE TABLE unique_actions_next (
  window_key TEXT NOT NULL,
  action TEXT NOT NULL CHECK (action IN ('download', 'github')),
  first_placement TEXT NOT NULL CHECK (first_placement IN ('header', 'hero', 'footer', 'readme', 'guide')),
  first_at INTEGER NOT NULL,
  PRIMARY KEY (window_key, action),
  FOREIGN KEY (window_key) REFERENCES measurement_windows(window_key) ON DELETE CASCADE
);
INSERT INTO unique_actions_next SELECT window_key, action, first_placement, first_at FROM unique_actions;
DROP TABLE unique_actions;
ALTER TABLE unique_actions_next RENAME TO unique_actions;
CREATE INDEX IF NOT EXISTS unique_actions_action
  ON unique_actions(action, first_at);
