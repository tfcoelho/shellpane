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
