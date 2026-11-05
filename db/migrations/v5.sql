-- Migration v5: the icon and colour of anything else in the sidebar (~/.ssh/config hosts, Mac Favorites, synclets,
-- groups, tags), by a key saying what it is. No row means its default look; only changes are stored.
CREATE TABLE appearances (
  key         TEXT PRIMARY KEY CHECK (length(key) BETWEEN 1 AND 1100),
  icon        TEXT CHECK (icon IS NULL OR (length(icon) BETWEEN 1 AND 64 AND icon NOT GLOB '*[^a-z0-9.]*')),
  colour      TEXT CHECK (colour IS NULL OR (length(colour) BETWEEN 1 AND 16 AND colour NOT GLOB '*[^a-z]*')),
  updated_at  INTEGER NOT NULL DEFAULT (unixepoch())
);
