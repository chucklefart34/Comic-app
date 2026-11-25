#!/usr/bin/env python3
"""Builds the app's offline comic catalog from the Grand Comics Database SQLite dump.

Usage: build_catalog.py <gcd.sqlite> <out_dir> [publisher names, comma separated]

Output:
  catalog.sqlite          compact catalog (series + issues, variants, barcodes)
  catalog.sqlite.deflate  the same, raw-deflate compressed (what the app downloads)
  catalog.json            counts, date, and credit line

Data: Grand Comics Database (https://www.comics.org), CC BY-SA 4.0.
"""
import json
import os
import re
import sqlite3
import sys
import zlib
from datetime import datetime, timezone

DEFAULT_PUBLISHERS = ["Marvel", "DC"]


def columns(db, table):
    return {row[1] for row in db.execute(f"PRAGMA table_info({table})")}


def norm(text):
    """Lowercase words, no punctuation: 'Superman/Wonder Woman' -> 'superman wonder woman'."""
    words = re.findall(r"[a-z0-9]+", (text or "").lower())
    return " ".join(w for w in words if w not in {"the", "a", "an"})


def leading_number(number):
    match = re.match(r"\s*\[?(\d{1,5})", number or "")
    return int(match.group(1)) if match else None


def main():
    source, out_dir = sys.argv[1], sys.argv[2]
    publishers = [p.strip() for p in (sys.argv[3] if len(sys.argv) > 3 else ",".join(DEFAULT_PUBLISHERS)).split(",") if p.strip()]
    os.makedirs(out_dir, exist_ok=True)

    gcd = sqlite3.connect(source)
    for table in ("gcd_publisher", "gcd_series", "gcd_issue"):
        print(table, sorted(columns(gcd, table)))

    issue_cols = columns(gcd, "gcd_issue")
    series_cols = columns(gcd, "gcd_series")
    pub_rows = gcd.execute(
        f"SELECT id, name FROM gcd_publisher WHERE name IN ({','.join('?' * len(publishers))})"
        + (" AND deleted = 0" if "deleted" in columns(gcd, "gcd_publisher") else ""),
        publishers,
    ).fetchall()
    if not pub_rows:
        sys.exit(f"No publishers named {publishers} found")
    pub_names = {pid: name for pid, name in pub_rows}
    print("Publishers:", pub_rows)

    series_filter = [f"publisher_id IN ({','.join(str(p) for p in pub_names)})"]
    if "deleted" in series_cols:
        series_filter.append("deleted = 0")
    if "is_comics_publication" in series_cols:
        series_filter.append("is_comics_publication = 1")
    series_rows = gcd.execute(
        "SELECT id, name, year_began, year_ended, publisher_id FROM gcd_series WHERE " + " AND ".join(series_filter)
    ).fetchall()
    print("Series:", len(series_rows))

    out_path = os.path.join(out_dir, "catalog.sqlite")
    if os.path.exists(out_path):
        os.remove(out_path)
    out = sqlite3.connect(out_path)
    out.executescript(
        """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE series(id INTEGER PRIMARY KEY, name TEXT NOT NULL, norm TEXT NOT NULL,
                            year_began INTEGER, year_ended INTEGER, publisher TEXT NOT NULL, issue_count INTEGER);
        CREATE TABLE issue(id INTEGER PRIMARY KEY, series_id INTEGER NOT NULL, number TEXT NOT NULL, num INTEGER,
                           variant TEXT NOT NULL DEFAULT '', parent_id INTEGER, barcode TEXT NOT NULL DEFAULT '',
                           key_date TEXT NOT NULL DEFAULT '', price TEXT NOT NULL DEFAULT '');
        """
    )

    series_ids = [row[0] for row in series_rows]
    issue_filter = "deleted = 0 AND " if "deleted" in issue_cols else ""
    pick = ["id", "series_id", "number", "variant_name", "variant_of_id", "barcode", "key_date"]
    pick.append("price" if "price" in issue_cols else "'' AS price")
    issues = 0
    counts = {}
    for start in range(0, len(series_ids), 500):
        chunk = series_ids[start:start + 500]
        rows = gcd.execute(
            f"SELECT {', '.join(pick)} FROM gcd_issue WHERE {issue_filter}series_id IN ({','.join(map(str, chunk))})"
        ).fetchall()
        batch = []
        for iid, sid, number, variant, parent, barcode, key_date, price in rows:
            digits = re.sub(r"\D", "", barcode or "")
            batch.append((iid, sid, (number or "").strip(), leading_number(number), (variant or "").strip(), parent,
                          digits, key_date or "", (price or "")[:40]))
            counts[sid] = counts.get(sid, 0) + 1
        out.executemany("INSERT INTO issue VALUES (?,?,?,?,?,?,?,?,?)", batch)
        issues += len(batch)

    out.executemany(
        "INSERT INTO series VALUES (?,?,?,?,?,?,?)",
        [(sid, name, norm(name), began, ended, pub_names[pid], counts.get(sid, 0))
         for sid, name, began, ended, pid in series_rows if counts.get(sid)],
    )
    out.executescript(
        """
        CREATE INDEX issue_barcode ON issue(barcode) WHERE barcode <> '';
        CREATE INDEX issue_series_num ON issue(series_id, num);
        CREATE INDEX series_norm ON series(norm);
        """
    )
    built = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    with_barcode = out.execute("SELECT COUNT(*) FROM issue WHERE barcode <> ''").fetchone()[0]
    variants = out.execute("SELECT COUNT(*) FROM issue WHERE parent_id IS NOT NULL").fetchone()[0]
    series_count = out.execute("SELECT COUNT(*) FROM series").fetchone()[0]
    credit = "Catalog data from the Grand Comics Database (https://www.comics.org), licensed CC BY-SA 4.0."
    meta = {
        "version": 1,
        "built": built,
        "publishers": publishers,
        "series": series_count,
        "issues": issues,
        "variants": variants,
        "with_barcode": with_barcode,
        "credit": credit,
    }
    out.executemany("INSERT INTO meta VALUES (?,?)", [(k, json.dumps(v) if not isinstance(v, str) else v) for k, v in meta.items()])
    out.commit()
    out.execute("VACUUM")
    out.close()

    with open(out_path, "rb") as f:
        raw = f.read()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw deflate, as Apple's Compression .zlib expects
    packed = compressor.compress(raw) + compressor.flush()
    with open(out_path + ".deflate", "wb") as f:
        f.write(packed)
    meta["bytes"] = len(raw)
    meta["compressed_bytes"] = len(packed)
    with open(os.path.join(out_dir, "catalog.json"), "w") as f:
        json.dump(meta, f, indent=2)
    print(json.dumps(meta, indent=2))


if __name__ == "__main__":
    main()
