#!/usr/bin/env python3
"""Build a standalone reader-tabs.json from a read-only QA SQLite snapshot."""
from __future__ import annotations

import json
import sqlite3
import sys
import uuid
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit(f"usage: {sys.argv[0]} SOURCE_STORE.sqlite OUTPUT_reader-tabs.json")

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
if not source.is_file():
    raise SystemExit(f"missing source database: {source}")
if destination.exists():
    raise SystemExit(f"refusing to overwrite existing output: {destination}")

account = "00000000-0000-4000-8000-000000000002"
locator = "SU5CT1g"  # base64url("INBOX")
with sqlite3.connect(str(source)) as db:
    db.execute("PRAGMA query_only = ON")
    rows = db.execute(
        """
        SELECT generations.uid_validity, messages.uid
        FROM messages
        JOIN generations ON generations.id = messages.generation_id
        JOIN folders ON folders.id = generations.folder_id
        WHERE folders.path = 'INBOX' AND folders.retired = 0
        ORDER BY messages.internal_date DESC, messages.uid DESC
        LIMIT 103
        """
    ).fetchall()

if len(rows) != 103:
    raise SystemExit(f"expected 103 INBOX messages, found {len(rows)}")

entries = []
for uid_validity, uid in rows:
    tab_id = str(uuid.uuid4()).upper()
    link = (
        f"mailternal://open/v1/account/{account}/folder/path/{locator}"
        f"/message/{int(uid_validity)}/{int(uid)}"
    )
    entries.append(
        {
            "id": tab_id,
            "isTransient": False,
            "scrollOffset": 0,
            "link": link,
        }
    )

active_id = entries[-1]["id"]
state = {
    "activeID": active_id,
    "mruIDs": [entry["id"] for entry in reversed(entries)],
    "tabs": entries,
}
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(state, separators=(",", ":")) + "\n", encoding="utf-8")
print(f"tabs={len(entries)} active={active_id} output={destination}")
