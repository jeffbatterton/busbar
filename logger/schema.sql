-- One row per minute. `t` is the scheduled time in milliseconds since 1970.
CREATE TABLE IF NOT EXISTS readings (
  t INTEGER PRIMARY KEY,
  soc REAL NOT NULL,
  watts_in INTEGER NOT NULL,
  watts_out INTEGER NOT NULL,
  simulated INTEGER NOT NULL DEFAULT 0
);
