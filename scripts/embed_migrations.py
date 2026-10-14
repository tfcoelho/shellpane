#!/usr/bin/env python3
"""Embed db/schema.sql (migration v1) and db/migrations/v2.sql, v3.sql… into
Sources/ShellpaneCore/Migrations.swift."""
import pathlib
root = pathlib.Path(__file__).resolve().parent.parent
sources = [root / "db/schema.sql"] + sorted((root / "db/migrations").glob("v*.sql"),
                                                  key=lambda p: int(p.stem[1:]))
for n, path in enumerate(sources, start=1):
    assert path.name == "schema.sql" or path.stem == f"v{n}", f"migrations must be numbered v2, v3… without gaps: {path.name}"
sqls = [p.read_text() for p in sources]
for sql in sqls:
    assert '"""#' not in sql, "a migration can't contain the Swift raw-string terminator"
names = ", ".join(f"v{n}" for n in range(1, len(sqls) + 1))
body = "".join(f'''
    static let v{n} = #"""
{sql}
"""#  // Swift drops the newline right before the closing delimiter; the blank line above keeps the file's last newline
''' for n, sql in enumerate(sqls, start=1))
(root / "Sources/ShellpaneCore/Migrations.swift").write_text('''// Generated from db/schema.sql and db/migrations/. Do not edit here: edit the .sql files, then run
//   python3 scripts/embed_migrations.py
// MigrationTests fails if the two drift apart.

enum Migrations {
    /// Applied in order; PRAGMA user_version records how many have run.
    static let all: [String] = [''' + names + ''']
''' + body + '''}
''')
print("wrote Sources/ShellpaneCore/Migrations.swift")
