// Generated from db/schema.sql and db/migrations/. Do not edit here: edit the .sql files, then run
//   python3 scripts/embed_migrations.py
// MigrationTests fails if the two drift apart.

enum Migrations {
    /// Applied in order; PRAGMA user_version records how many have run.
    static let all: [String] = [v1, v2, v3]

    static let v1 = #"""
-- Shellpane local database (system SQLite, no ORM). Migration v1.
-- The app embeds this exact file (Sources/ShellpaneCore/Migrations.swift; a test keeps them identical)
-- and applies it once, tracked by PRAGMA user_version.
-- Single user, single Mac. No secrets in this file: passwords and key
-- passphrases live in the macOS Keychain, referenced by keychain_ref.
-- Times are INTEGER unix epoch seconds, UTC.
-- IDs are TEXT UUIDs so favorites can later sync through CloudKit without clashes.

-- foreign_keys = ON and journal_mode = WAL are set by the app on every open
-- (journal_mode can't change inside the migration's transaction).

CREATE TABLE favorite_groups (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 100),
  sort_order  INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at  INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE favorites (
  id            TEXT PRIMARY KEY,
  group_id      TEXT REFERENCES favorite_groups(id) ON DELETE SET NULL,  -- deleting a group keeps its favorites, ungrouped
  name          TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  protocol      TEXT NOT NULL DEFAULT 'sftp' CHECK (protocol IN ('sftp')),  -- 'ftp','webdav','s3' added by later migrations
  ssh_alias     TEXT,                       -- a Host from ~/.ssh/config; when set, ssh resolves host/port/user/keys itself
  host          TEXT,                       -- required when ssh_alias is null
  port          INTEGER CHECK (port IS NULL OR port BETWEEN 1 AND 65535),
  username      TEXT,
  auth          TEXT NOT NULL DEFAULT 'auto'
                CHECK (auth IN ('auto','password','key','agent')),  -- 'auto' = whatever ssh_config/agent says
  key_path      TEXT,                       -- IdentityFile override; only used when auth = 'key'
  keychain_ref  TEXT,                       -- account name of the Keychain item for password or passphrase
  initial_path  TEXT,                       -- null = server's home directory
  colour        TEXT CHECK (colour IS NULL OR colour IN ('none','red','orange','green','teal','blue','purple','pink')),  -- a role, not a hex: values differ in light and dark
  sort_order    INTEGER NOT NULL DEFAULT 0,
  last_used_at  INTEGER,
  created_at    INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at    INTEGER NOT NULL DEFAULT (unixepoch()),
  CHECK (ssh_alias IS NOT NULL OR host IS NOT NULL),
  CHECK (auth <> 'key' OR key_path IS NOT NULL OR ssh_alias IS NOT NULL)
);
CREATE INDEX favorites_group_idx     ON favorites (group_id, sort_order);
CREATE INDEX favorites_last_used_idx ON favorites (last_used_at DESC);

-- A location is either local (favorite_id null) or on a favorite's server.
CREATE TABLE synclets (
  id                TEXT PRIMARY KEY,
  name              TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  left_favorite_id  TEXT REFERENCES favorites(id) ON DELETE CASCADE,   -- a synclet pointing at a deleted server is useless
  left_path         TEXT NOT NULL,
  right_favorite_id TEXT REFERENCES favorites(id) ON DELETE CASCADE,
  right_path        TEXT NOT NULL,
  direction         TEXT NOT NULL DEFAULT 'left_to_right'
                    CHECK (direction IN ('left_to_right','right_to_left','both')),
  subfolders        INTEGER NOT NULL DEFAULT 1 CHECK (subfolders IN (0,1)),
  include_hidden    INTEGER NOT NULL DEFAULT 0 CHECK (include_hidden IN (0,1)),
  add_missing       INTEGER NOT NULL DEFAULT 1 CHECK (add_missing IN (0,1)),
  skip_empty_dirs   INTEGER NOT NULL DEFAULT 0 CHECK (skip_empty_dirs IN (0,1)),
  update_by         TEXT NOT NULL DEFAULT 'date' CHECK (update_by IN ('date','size','date_or_size','never')),
  delete_orphans    INTEGER NOT NULL DEFAULT 0 CHECK (delete_orphans IN (0,1)),   -- off by default: destructive
  time_offset_s     INTEGER NOT NULL DEFAULT 0,
  excludes          TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(excludes)),     -- glob patterns
  created_at        INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at        INTEGER NOT NULL DEFAULT (unixepoch()),
  CHECK (NOT (direction = 'both' AND delete_orphans = 1))  -- two-way + delete orphans is ambiguous; refuse it
);
CREATE INDEX synclets_left_idx  ON synclets (left_favorite_id);
CREATE INDEX synclets_right_idx ON synclets (right_favorite_id);

-- The transfer queue. Persisted so a quit or crash can resume.
CREATE TABLE transfer_jobs (
  id               TEXT PRIMARY KEY,
  batch_id         TEXT NOT NULL,           -- one drag/drop or one sync run = one batch
  kind             TEXT NOT NULL CHECK (kind IN ('upload','download','copy','move','delete')),
  src_favorite_id  TEXT REFERENCES favorites(id) ON DELETE SET NULL,  -- keep history if a favorite is deleted
  src_path         TEXT NOT NULL,
  dst_favorite_id  TEXT REFERENCES favorites(id) ON DELETE SET NULL,
  dst_path         TEXT,                    -- null for delete
  is_directory     INTEGER NOT NULL DEFAULT 0 CHECK (is_directory IN (0,1)),
  bytes_total      INTEGER NOT NULL DEFAULT 0 CHECK (bytes_total >= 0),
  bytes_done       INTEGER NOT NULL DEFAULT 0 CHECK (bytes_done >= 0),
  status           TEXT NOT NULL DEFAULT 'queued'
                   CHECK (status IN ('queued','running','paused','waiting_conflict','failed','done','cancelled')),
  conflict_rule    TEXT NOT NULL DEFAULT 'ask'
                   CHECK (conflict_rule IN ('ask','replace','skip','rename','newer','resume')),
  attempts         INTEGER NOT NULL DEFAULT 0,
  error            TEXT,
  queue_order      INTEGER NOT NULL,
  created_at       INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at       INTEGER NOT NULL DEFAULT (unixepoch()),
  finished_at      INTEGER,
  CHECK (bytes_done <= bytes_total OR bytes_total = 0),
  CHECK (kind = 'delete' OR dst_path IS NOT NULL)
);
CREATE INDEX transfer_jobs_status_order_idx ON transfer_jobs (status, queue_order);
CREATE INDEX transfer_jobs_batch_idx        ON transfer_jobs (batch_id);
CREATE INDEX transfer_jobs_src_fav_idx      ON transfer_jobs (src_favorite_id);
CREATE INDEX transfer_jobs_dst_fav_idx      ON transfer_jobs (dst_favorite_id);

CREATE TABLE log_entries (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id       TEXT REFERENCES transfer_jobs(id) ON DELETE SET NULL,
  favorite_id  TEXT REFERENCES favorites(id) ON DELETE SET NULL,
  at           INTEGER NOT NULL DEFAULT (unixepoch()),
  operation    TEXT NOT NULL CHECK (operation IN
               ('connect','disconnect','upload','download','copy','move','rename','mkdir','delete','chmod','sync','edit_upload')),
  path         TEXT,
  result       TEXT NOT NULL CHECK (result IN ('ok','skipped','failed')),
  message      TEXT                          -- never contains secrets
);
CREATE INDEX log_entries_at_idx       ON log_entries (at DESC);
CREATE INDEX log_entries_job_idx      ON log_entries (job_id);
CREATE INDEX log_entries_favorite_idx ON log_entries (favorite_id);

CREATE TABLE edit_sessions (
  id                 TEXT PRIMARY KEY,
  favorite_id        TEXT NOT NULL REFERENCES favorites(id) ON DELETE CASCADE,
  remote_path        TEXT NOT NULL,
  local_temp_path    TEXT NOT NULL UNIQUE,
  editor_bundle_id   TEXT,
  remote_mtime       INTEGER,               -- remote mtime at download, to detect someone else's change
  last_uploaded_hash TEXT,                  -- sha256 of what we last uploaded, to skip no-op saves
  status             TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','uploading','conflict','closed')),
  opened_at          INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at         INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE UNIQUE INDEX edit_sessions_open_uniq ON edit_sessions (favorite_id, remote_path) WHERE status <> 'closed';

CREATE TABLE settings (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL CHECK (json_valid(value))
);

INSERT INTO settings (key, value) VALUES
  ('terminal_app',          '"com.apple.Terminal"'),
  ('default_editor',        'null'),
  ('bandwidth_up_kbps',     '0'),
  ('bandwidth_down_kbps',   '0'),
  ('default_conflict_rule', '"ask"'),
  ('show_hidden',           'false'),
  ('parallel_per_session',  '3'),
  ('log_retention_days',    '30');

"""#  // Swift drops the newline right before the closing delimiter; the blank line above keeps the file's last newline

    static let v2 = #"""
-- Migration v2: favorite folders ("bookmarks"), on this Mac or on a server.
-- Embedded by scripts/embed_migrations.py like v1; a test keeps the copies identical.

-- Where a folder lives: favorite_id for a saved server, ssh_alias for a ~/.ssh/config host
-- that isn't saved, neither for this Mac.
CREATE TABLE bookmarks (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  favorite_id  TEXT REFERENCES favorites(id) ON DELETE CASCADE,  -- deleting a server removes its folders
  ssh_alias    TEXT,
  path         TEXT NOT NULL CHECK (substr(path, 1, 1) = '/'),
  sort_order   INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at   INTEGER NOT NULL DEFAULT (unixepoch()),
  CHECK (favorite_id IS NULL OR ssh_alias IS NULL)
);
CREATE INDEX bookmarks_order_idx ON bookmarks (sort_order);

"""#  // Swift drops the newline right before the closing delimiter; the blank line above keeps the file's last newline

    static let v3 = #"""
-- Migration v3: each saved server can have its own icon in the sidebar (an SF Symbol name, from the
-- form's picker). NULL is the default server icon, so servers saved before this keep looking as they did.
ALTER TABLE favorites ADD COLUMN icon TEXT
  CHECK (icon IS NULL OR (length(icon) BETWEEN 1 AND 64 AND icon NOT GLOB '*[^a-z0-9.]*'));

"""#  // Swift drops the newline right before the closing delimiter; the blank line above keeps the file's last newline
}
