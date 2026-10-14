-- Migration v3: each saved server can have its own icon in the sidebar (an SF Symbol name, from the
-- form's picker). NULL is the default server icon, so servers saved before this keep looking as they did.
ALTER TABLE favorites ADD COLUMN icon TEXT
  CHECK (icon IS NULL OR (length(icon) BETWEEN 1 AND 64 AND icon NOT GLOB '*[^a-z0-9.]*'));
