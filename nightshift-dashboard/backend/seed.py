"""
Fills the database with fake flags: some from tonight's shift, some from past
nights, so every dashboard screen has something to show.

Run:  python seed.py     (wipes the flags table first)

Photos: drop test images into backend/photos/ named after the flag id
(f_001.jpg, h_001.jpg, ...) and they'll show on the dashboard automatically.
"""

from datetime import timedelta

from main import db, init_db, shift_start

start = shift_start()

# (id, type, location, minutes after shift start, status, note)
TONIGHT = [
    ("f_001", "leak", "Pump 08", 75, "dismissed", "operator: rain puddle, not a leak"),
    ("f_002", "damage", "Separator 01", 110, "confirmed", "operator: cracked gauge cover"),
    ("f_003", "leak", "Well 12", 140, "pending", None),
    ("f_004", "damage", "Tank 03", 165, "dismissed", "operator: just a shadow on the ladder"),
    ("f_005", "leak", "Pump 04", 190, "confirmed", "operator: still dripping near the base"),
    ("f_006", "smoke", "Compressor 02", 220, "pending", None),
]

# (id, type, location, nights ago, status, note)
HISTORY = [
    ("h_001", "leak", "Pump 04", 1, "confirmed", "operator: small drip at the seal"),
    ("h_002", "leak", "Pump 04", 2, "confirmed", "operator: wet spot under the pump"),
    ("h_003", "smoke", "Compressor 02", 1, "pending", None),
    ("h_004", "leak", "Well 12", 2, "confirmed", "operator: residue near the wellhead"),
    ("h_005", "damage", "Tank 03", 3, "dismissed", None),
    ("h_006", "damage", "Separator 01", 3, "pending", None),
]


def iso(dt):
    return dt.isoformat(timespec="seconds")


def main():
    init_db()
    rows = []
    for fid, ftype, loc, mins, status, note in TONIGHT:
        rows.append((fid, ftype, loc, f"/photos/{fid}.jpg", iso(start + timedelta(minutes=mins)), status, note))
    for fid, ftype, loc, nights, status, note in HISTORY:
        ts = start - timedelta(days=nights) + timedelta(hours=8)  # ~2 AM that night
        rows.append((fid, ftype, loc, f"/photos/{fid}.jpg", iso(ts), status, note))

    with db() as c:
        c.execute("DELETE FROM flags")
        c.executemany("INSERT INTO flags VALUES (?, ?, ?, ?, ?, ?, ?)", rows)

    print(f"Seeded {len(TONIGHT)} flags for tonight and {len(HISTORY)} from past nights.")


if __name__ == "__main__":
    main()
