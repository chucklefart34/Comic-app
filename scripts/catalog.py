#!/usr/bin/env python3
"""Builds and updates the app's offline comic catalog from the Grand Comics Database (comics.org).

  catalog.py run <catalog.sqlite> --budget 1800                     daily job: all of the steps below, in order,
                                                                    within one day's request budget
  catalog.py weekly <catalog.sqlite>                                add issues on sale in recent/coming weeks
  catalog.py discover <catalog.sqlite> --budget N                   page through comics.org's series list and add
                                                                    every series of the chosen publishers, with
                                                                    all their issues and variants
  catalog.py covers <catalog.sqlite> --budget N                     cover links for regular issues, per series
  catalog.py details <catalog.sqlite> --budget N                    barcodes + variant covers, issue by issue
  catalog.py full <gcd.sqlite> <catalog.sqlite> [--previous old]    (local use) rebuild from a GCD SQLite dump
  catalog.py pack <catalog.sqlite> <out_dir>                        compress + write catalog.json
  catalog.py unpack <catalog.sqlite.deflate> <catalog.sqlite>       the reverse (to continue last week's catalog)

API calls use the comics.org login in GCD_EMAIL / GCD_PASSWORD (HTTP basic auth) and stay inside the
published limits for registered accounts (25 a minute, 2,000 a day). Only cover *links* are stored; the app
downloads a cover image only when a scan needs it.

Data: Grand Comics Database (https://www.comics.org), CC BY-SA 4.0.
"""
import argparse
import base64
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
import zlib

API = os.environ.get("CATALOG_API", "https://www.comics.org/api")
USER_AGENT = "ComicScanner catalog builder (personal app)"
PUBLISHERS = [p.strip() for p in os.environ.get("CATALOG_PUBLISHERS", "Marvel,DC").split(",") if p.strip()]
# comics.org publisher ids (the API can't list series by publisher, so they're matched by id).
KNOWN_PUBLISHER_IDS = {"Marvel": 78, "DC": 54, "Image": 709, "Dark Horse": 512, "IDW": 4268, "BOOM! Studios": 2547}
CREDIT = "Catalog data from the Grand Comics Database (https://www.comics.org), licensed CC BY-SA 4.0."

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS series(id INTEGER PRIMARY KEY, name TEXT NOT NULL, norm TEXT NOT NULL,
    year_began INTEGER, year_ended INTEGER, publisher TEXT NOT NULL, issue_count INTEGER,
    covers_checked TEXT);
CREATE TABLE IF NOT EXISTS issue(id INTEGER PRIMARY KEY, series_id INTEGER NOT NULL, number TEXT NOT NULL, num INTEGER,
    variant TEXT NOT NULL DEFAULT '', parent_id INTEGER, barcode TEXT NOT NULL DEFAULT '',
    key_date TEXT NOT NULL DEFAULT '', price TEXT NOT NULL DEFAULT '', cover TEXT NOT NULL DEFAULT '');
"""
INDEXES = """
CREATE INDEX IF NOT EXISTS issue_barcode ON issue(barcode) WHERE barcode <> '';
CREATE INDEX IF NOT EXISTS issue_series_num ON issue(series_id, num);
CREATE INDEX IF NOT EXISTS series_norm ON series(norm);
"""


# ---------------------------------------------------------------- helpers

def norm(text):
    """Lowercase words, no punctuation: 'Superman/Wonder Woman' -> 'superman wonder woman'."""
    words = re.findall(r"[a-z0-9]+", (text or "").lower())
    return " ".join(w for w in words if w not in {"the", "a", "an"})


def leading_number(number):
    match = re.match(r"\s*\[?(\d{1,5})", number or "")
    return int(match.group(1)) if match else None


def digits(text):
    return re.sub(r"\D", "", text or "")


def set_meta(db, **values):
    db.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)",
                   [(k, v if isinstance(v, str) else json.dumps(v)) for k, v in values.items()])


def get_meta(db, key, default=None):
    row = db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else default


class BudgetSpent(Exception):
    pass


class Api:
    """comics.org API with basic auth, paced under 25 requests a minute, with a request budget per run."""

    def __init__(self, budget):
        email, password = os.environ.get("GCD_EMAIL"), os.environ.get("GCD_PASSWORD")
        if not email or not password:
            sys.exit("GCD_EMAIL / GCD_PASSWORD not set")
        self.auth = "Basic " + base64.b64encode(f"{email}:{password}".encode()).decode()
        self.budget = budget
        self.used = 0
        self.last = 0.0

    def get(self, url):
        for attempt in range(3):
            if self.used >= self.budget:
                raise BudgetSpent()
            wait = float(os.environ.get("CATALOG_PACE", "2.6")) - (time.time() - self.last)  # about 23 a minute
            if wait > 0:
                time.sleep(wait)
            self.last = time.time()
            self.used += 1
            request = urllib.request.Request(url, headers={
                "Authorization": self.auth, "Accept": "application/json", "User-Agent": USER_AGENT})
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    return json.load(response)
            except urllib.error.HTTPError as error:
                if error.code == 429:
                    pause = int(error.headers.get("Retry-After") or "60")
                    if pause > 600:
                        raise BudgetSpent()  # the daily limit: carry on next run
                    print(f"  rate limited, waiting {pause}s")
                    time.sleep(pause)
                    continue
                if error.code == 404:
                    return None
                if error.code in (401, 403):
                    sys.exit(f"comics.org refused the login ({error.code}). Check GCD_EMAIL / GCD_PASSWORD.")
                if attempt == 2:
                    raise
                time.sleep(10)
            except (urllib.error.URLError, TimeoutError):
                if attempt == 2:
                    raise
                time.sleep(10)
        return None

    def pages(self, url):
        while url:
            page = self.get(url)
            if not page:
                return
            yield from page.get("results", [])
            url = page.get("next")


def id_from(url):
    match = re.search(r"/(\d+)/?(?:\?.*)?$", url or "")
    return int(match.group(1)) if match else None


# ---------------------------------------------------------------- full build from the dump

def full(source, out_path, previous=None):
    gcd = sqlite3.connect(source)
    cols = lambda table: {row[1] for row in gcd.execute(f"PRAGMA table_info({table})")}
    issue_cols, series_cols = cols("gcd_issue"), cols("gcd_series")
    pubs = gcd.execute(
        f"SELECT id, name FROM gcd_publisher WHERE name IN ({','.join('?' * len(PUBLISHERS))})"
        + (" AND deleted = 0" if "deleted" in cols("gcd_publisher") else ""), PUBLISHERS).fetchall()
    if not pubs:
        sys.exit(f"No publishers named {PUBLISHERS} in the dump")
    pub_names = dict(pubs)
    print("Publishers:", pubs)

    where = [f"publisher_id IN ({','.join(map(str, pub_names))})"]
    if "deleted" in series_cols:
        where.append("deleted = 0")
    if "is_comics_publication" in series_cols:
        where.append("is_comics_publication = 1")
    series_rows = gcd.execute("SELECT id, name, year_began, year_ended, publisher_id FROM gcd_series WHERE "
                              + " AND ".join(where)).fetchall()

    if os.path.exists(out_path):
        os.remove(out_path)
    db = sqlite3.connect(out_path)
    db.executescript(SCHEMA)

    pick = ["id", "series_id", "number", "variant_name", "variant_of_id", "barcode", "key_date",
            "price" if "price" in issue_cols else "''"]
    deleted = "deleted = 0 AND " if "deleted" in issue_cols else ""
    counts = {}
    ids = [row[0] for row in series_rows]
    for start in range(0, len(ids), 500):
        chunk = ",".join(map(str, ids[start:start + 500]))
        rows = gcd.execute(f"SELECT {', '.join(pick)} FROM gcd_issue WHERE {deleted}series_id IN ({chunk})").fetchall()
        db.executemany("INSERT INTO issue VALUES (?,?,?,?,?,?,?,?,?,'')", [
            (iid, sid, (num or "").strip(), leading_number(num), (var or "").strip(), parent, digits(bc), kd or "",
             (price or "")[:40]) for iid, sid, num, var, parent, bc, kd, price in rows])
        for row in rows:
            counts[row[1]] = counts.get(row[1], 0) + 1
    db.executemany("INSERT INTO series VALUES (?,?,?,?,?,?,?,NULL)", [
        (sid, name, norm(name), began, ended, pub_names[pid], counts[sid])
        for sid, name, began, ended, pid in series_rows if counts.get(sid)])
    db.commit()

    # Keep cover links (and which series were already checked) from the previous catalog.
    if previous and os.path.exists(previous):
        db.execute("ATTACH ? AS old", (previous,))
        old_issue = {row[1] for row in db.execute("PRAGMA old.table_info(issue)")}
        old_series = {row[1] for row in db.execute("PRAGMA old.table_info(series)")}
        if "cover" in old_issue:
            db.execute("UPDATE issue SET cover = (SELECT o.cover FROM old.issue o WHERE o.id = issue.id) "
                       "WHERE id IN (SELECT id FROM old.issue WHERE cover <> '')")
            # Weekly additions newer than this dump.
            db.execute("INSERT OR IGNORE INTO series SELECT * FROM old.series WHERE id NOT IN (SELECT id FROM series)"
                       if "covers_checked" in old_series else "SELECT 1")
            db.execute("INSERT OR IGNORE INTO issue SELECT * FROM old.issue WHERE series_id IN (SELECT id FROM series)")
        if "covers_checked" in old_series:
            db.execute("UPDATE series SET covers_checked = (SELECT o.covers_checked FROM old.series o WHERE o.id = series.id)")
        db.commit()
        db.execute("DETACH old")
    db.executescript(INDEXES)
    today = dt.date.today().isoformat()
    set_meta(db, version="2", full_built=today, built=today)
    db.commit()
    print("Full build:", summary(db))


# ---------------------------------------------------------------- weekly new issues

def weekly(path, weeks_back=2, weeks_ahead=3, budget=400, api=None):
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    api = api or Api(budget)
    known_series = {row[0] for row in db.execute("SELECT id FROM series")}
    words = [p.lower() for p in PUBLISHERS]
    added = updated = 0
    complete = True
    today = dt.date.today()
    try:
        for offset in range(-weeks_back, weeks_ahead + 1):
            year, week, _ = (today + dt.timedelta(weeks=offset)).isocalendar()
            print(f"Week {year}-W{week:02d}")
            for item in api.pages(f"{API}/issue/on_sale_weekly/{year}/week/{week}/?format=json"):
                series_id, issue_id = id_from(item.get("series")), id_from(item.get("api_url"))
                if not series_id or not issue_id:
                    continue
                if series_id not in known_series:
                    text = f"{item.get('indicia_publisher') or ''} {item.get('brand_emblem') or ''}".lower()
                    publisher = next((p for p, w in zip(PUBLISHERS, words) if re.search(rf"\b{re.escape(w)}\b", text)), None)
                    if not publisher:
                        continue
                    name = re.sub(r"\s*\(\d{4} series\)\s*$", "", item.get("series_name") or "")
                    began = (item.get("key_date") or "")[:4]
                    db.execute("INSERT OR IGNORE INTO series VALUES (?,?,?,?,NULL,?,0,NULL)",
                               (series_id, name, norm(name), int(began) if began.isdigit() else None, publisher))
                    known_series.add(series_id)
                exists = db.execute("SELECT 1 FROM issue WHERE id = ?", (issue_id,)).fetchone()
                number = (item.get("number") or "").strip()
                db.execute("INSERT OR REPLACE INTO issue VALUES (?,?,?,?,?,?,?,?,?,?)", (
                    issue_id, series_id, number, leading_number(number), (item.get("variant_name") or "").strip(),
                    id_from(item.get("variant_of")), digits(item.get("barcode")), item.get("key_date") or "",
                    (item.get("price") or "")[:40], item.get("cover") or ""))
                added += 0 if exists else 1
                updated += 1 if exists else 0
            db.commit()
    except BudgetSpent:
        complete = False
        print("Request budget used up; the rest comes tomorrow.")
    db.execute("UPDATE series SET issue_count = (SELECT COUNT(*) FROM issue WHERE issue.series_id = series.id)")
    db.executescript(INDEXES)
    set_meta(db, built=today.isoformat(), weekly_added=str(added))
    if complete:
        set_meta(db, weekly_last=today.isoformat())
    db.commit()
    print(f"Weekly: {added} new, {updated} updated, {api.used} requests so far")
    return api


# ---------------------------------------------------------------- cover links for older series

def covers(path, budget, api=None):
    db = sqlite3.connect(path)
    api = api or Api(budget)
    # Never-checked series first, newest first; then the ones checked longest ago.
    # Only series not checked in the last 60 days; never-checked first, newest series first.
    cutoff = (dt.date.today() - dt.timedelta(days=60)).isoformat()
    todo = db.execute("""SELECT id FROM series WHERE covers_checked IS NULL OR covers_checked < ?
                         ORDER BY covers_checked IS NOT NULL, covers_checked, year_began DESC""", (cutoff,)).fetchall()
    found = checked = 0
    try:
        for (series_id,) in todo:
            for row in api.pages(f"{API}/series/{series_id}/overview/?format=json"):
                if row.get("cover_url") and row.get("issue_id"):
                    found += db.execute("UPDATE issue SET cover = ? WHERE id = ? AND cover <> ?",
                                        (row["cover_url"], row["issue_id"], row["cover_url"])).rowcount
            db.execute("UPDATE series SET covers_checked = ? WHERE id = ?", (dt.date.today().isoformat(), series_id))
            checked += 1
            if checked % 50 == 0:
                db.commit()
                print(f"  {checked} series checked, {found} cover links, {api.used} requests")
    except BudgetSpent:
        print("Request budget used up; more covers next week.")
    db.commit()
    print(f"Covers: {checked} series checked, {found} new cover links, {api.used} requests so far")
    return api



# ---------------------------------------------------------------- API-only building (daily job)

def parse_descriptor(text):
    """'300 [Newsstand] (75960...)' -> ('300', 'Newsstand')."""
    text = (text or "").strip()
    variant = ""
    match = re.search(r"\[([^\]]*)\]", text)
    if match:
        variant = match.group(1).strip()
        if variant.lower() == "unnamed variant":
            variant = "Variant"
    number = re.split(r"\s\[|\s\(", text, maxsplit=1)[0].strip()
    number = re.sub(r"^v\d+#", "", number)  # volume prefix
    number = number.split(" - ")[0].strip()  # issue title
    return number, variant


def publisher_ids(api, db):
    """Checks the known ids against comics.org once, and remembers them."""
    saved = get_meta(db, "publisher_ids")
    if saved:
        ids = {int(k): v for k, v in json.loads(saved).items()}
        if sorted(ids.values()) == sorted(PUBLISHERS):
            return ids
    ids = {}
    for name in PUBLISHERS:
        pid = KNOWN_PUBLISHER_IDS.get(name)
        if not pid:
            print(f"Unknown comics.org id for publisher {name!r}; add it to KNOWN_PUBLISHER_IDS")
            continue
        info = api.get(f"{API}/publisher/{pid}/?format=json") or {}
        print(f"Publisher {pid}: {info.get('name')!r} (for {name})")
        ids[pid] = name
    set_meta(db, publisher_ids=json.dumps({str(k): v for k, v in ids.items()}))
    db.commit()
    return ids


def discover(path, budget, api=None):
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    api = api or Api(budget)
    pubs = publisher_ids(api, db)
    if get_meta(db, "discover_done") == "1":
        print("Discover: already done")
        return api
    page = int(get_meta(db, "discover_page", "1"))
    series_added = issues_added = 0
    try:
        while True:
            data = api.get(f"{API}/series/?format=json&page={page}")
            if not data:
                set_meta(db, discover_done="1")
                break
            for item in data.get("results", []):
                pub = id_from(item.get("publisher"))
                if pub not in pubs:
                    continue
                if item.get("country") not in (None, "", "us"):
                    continue
                sid = id_from(item.get("api_url"))
                name = item.get("name") or ""
                db.execute("INSERT OR REPLACE INTO series VALUES (?,?,?,?,?,?,?, (SELECT covers_checked FROM series WHERE id = ?))",
                           (sid, name, norm(name), item.get("year_began"), item.get("year_ended"), pubs[pub],
                            len(item.get("active_issues") or []), sid))
                series_added += 1
                regular = {}
                rows = []
                for url, descriptor in zip(item.get("active_issues") or [], item.get("issue_descriptors") or []):
                    iid = id_from(url)
                    number, variant = parse_descriptor(descriptor)
                    if not variant:
                        regular.setdefault(number, iid)
                    rows.append((iid, number, variant))
                for iid, number, variant in rows:
                    parent = regular.get(number) if variant else None
                    issues_added += db.execute(
                        "INSERT OR IGNORE INTO issue (id, series_id, number, num, variant, parent_id) VALUES (?,?,?,?,?,?)",
                        (iid, sid, number, leading_number(number), variant, parent)).rowcount
            page += 1
            set_meta(db, discover_page=str(page))
            db.commit()
            if not data.get("next"):
                set_meta(db, discover_done="1")
                break
    except BudgetSpent:
        pass
    db.commit()
    print(f"Discover: page {page}, {series_added} series, {issues_added} new issues, {api.used} requests so far")
    return api


def details(path, budget, api=None):
    """Barcode, key date, price and cover for issues that don't have them yet: regular issues of
    recent series first, then variants."""
    db = sqlite3.connect(path)
    api = api or Api(budget)
    todo = db.execute("""
        SELECT i.id FROM issue i JOIN series s ON s.id = i.series_id
        WHERE i.key_date = ''
        ORDER BY (i.parent_id IS NOT NULL), s.year_began DESC, i.num DESC
        LIMIT 5000""").fetchall()
    done = 0
    try:
        for (iid,) in todo:
            item = api.get(f"{API}/issue/{iid}/?format=json")
            if not item:
                db.execute("UPDATE issue SET key_date = '?' WHERE id = ?", (iid,))  # gone: don't ask again
                continue
            db.execute("""UPDATE issue SET barcode = ?, key_date = ?, price = ?,
                          cover = CASE WHEN ? <> '' THEN ? ELSE cover END,
                          variant = CASE WHEN ? <> '' THEN ? ELSE variant END,
                          parent_id = COALESCE(?, parent_id) WHERE id = ?""",
                       (digits(item.get("barcode")), item.get("key_date") or "-", (item.get("price") or "")[:40],
                        item.get("cover") or "", item.get("cover") or "",
                        (item.get("variant_name") or "").strip(), (item.get("variant_name") or "").strip(),
                        id_from(item.get("variant_of")), iid))
            done += 1
            if done % 100 == 0:
                db.commit()
    except BudgetSpent:
        pass
    db.commit()
    print(f"Details: {done} issues filled in, {api.used} requests so far")
    return api


def run(path, budget):
    """The daily job: weekly releases (if due), then discovering series, then covers, then details."""
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    db.commit()
    api = Api(budget)
    last_weekly = get_meta(db, "weekly_last")
    db.close()
    if not last_weekly or (dt.date.today() - dt.date.fromisoformat(last_weekly)).days >= 6:
        weekly(path, api=api)
    for step in (discover, covers, details):
        if api.used >= api.budget:
            break
        step(path, budget, api=api)
    db = sqlite3.connect(path)
    set_meta(db, built=dt.date.today().isoformat())
    db.commit()
    print("Catalog:", summary(db), f"· {api.used} comics.org requests today")

# ---------------------------------------------------------------- packaging

def summary(db):
    one = lambda sql: db.execute(sql).fetchone()[0]
    return {
        "series": one("SELECT COUNT(*) FROM series"),
        "issues": one("SELECT COUNT(*) FROM issue"),
        "variants": one("SELECT COUNT(*) FROM issue WHERE parent_id IS NOT NULL"),
        "with_barcode": one("SELECT COUNT(*) FROM issue WHERE barcode <> ''"),
        "with_cover": one("SELECT COUNT(*) FROM issue WHERE cover <> ''"),
    }


def pack(path, out_dir):
    db = sqlite3.connect(path)
    db.executescript(INDEXES)
    info = summary(db)
    info.update({"version": 2, "built": get_meta(db, "built", dt.date.today().isoformat()),
                 "full_built": get_meta(db, "full_built"), "publishers": PUBLISHERS, "credit": CREDIT})
    set_meta(db, credit=CREDIT, publishers=PUBLISHERS)
    db.commit()
    db.execute("VACUUM")
    db.close()
    with open(path, "rb") as f:
        raw = f.read()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw deflate, as Apple's Compression .zlib expects
    packed = compressor.compress(raw) + compressor.flush()
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "catalog.sqlite.deflate"), "wb") as f:
        f.write(packed)
    info.update(bytes=len(raw), compressed_bytes=len(packed))
    with open(os.path.join(out_dir, "catalog.json"), "w") as f:
        json.dump(info, f, indent=2)
    print(json.dumps(info, indent=2))


def unpack(packed_path, out_path):
    with open(packed_path, "rb") as f:
        data = zlib.decompress(f.read(), -15)
    with open(out_path, "wb") as f:
        f.write(data)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("full"); p.add_argument("dump"); p.add_argument("catalog"); p.add_argument("--previous")
    p = sub.add_parser("run"); p.add_argument("catalog"); p.add_argument("--budget", type=int, default=1800)
    p = sub.add_parser("discover"); p.add_argument("catalog"); p.add_argument("--budget", type=int, default=1800)
    p = sub.add_parser("details"); p.add_argument("catalog"); p.add_argument("--budget", type=int, default=1800)
    p = sub.add_parser("weekly"); p.add_argument("catalog")
    p.add_argument("--weeks-back", type=int, default=2); p.add_argument("--weeks-ahead", type=int, default=2)
    p.add_argument("--budget", type=int, default=400)
    p = sub.add_parser("covers"); p.add_argument("catalog"); p.add_argument("--budget", type=int, default=1400)
    p = sub.add_parser("pack"); p.add_argument("catalog"); p.add_argument("out")
    p = sub.add_parser("unpack"); p.add_argument("packed"); p.add_argument("catalog")
    args = parser.parse_args()
    if args.command == "full":
        full(args.dump, args.catalog, args.previous)
    elif args.command == "run":
        run(args.catalog, args.budget)
    elif args.command == "discover":
        discover(args.catalog, args.budget)
    elif args.command == "details":
        details(args.catalog, args.budget)
    elif args.command == "weekly":
        weekly(args.catalog, args.weeks_back, args.weeks_ahead, args.budget)
    elif args.command == "covers":
        covers(args.catalog, args.budget)
    elif args.command == "pack":
        pack(args.catalog, args.out)
    elif args.command == "unpack":
        unpack(args.packed, args.catalog)


if __name__ == "__main__":
    main()
