-- Migration v4: a favorite folder can have its own icon and colour, as a server does. NULL means the default:
-- a folder icon in its server's colour, so folders saved before this keep looking as they did.
ALTER TABLE bookmarks ADD COLUMN icon TEXT
  CHECK (icon IS NULL OR (length(icon) BETWEEN 1 AND 64 AND icon NOT GLOB '*[^a-z0-9.]*'));
ALTER TABLE bookmarks ADD COLUMN colour TEXT
  CHECK (colour IS NULL OR (length(colour) BETWEEN 1 AND 16 AND colour NOT GLOB '*[^a-z]*'));
