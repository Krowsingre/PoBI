"""Loads the app's place catalogue into the game server's `places` table.

Each place gets its area: the H3 cell (resolution 8, about 0.7 km²) that holds it.
Run by .github/workflows/supabase.yml when the catalogue changes.

Usage: python data/load_places.py <project url> <service role key>
"""
import json
import sys
import urllib.request
from pathlib import Path

import h3

TSV = Path(__file__).resolve().parent.parent / "ios" / "PoBI" / "Resources" / "nj_places.tsv"
RESOLUTION = 8
BATCH = 2000


def rows():
    for line in TSV.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) < 6:
            continue
        lat, lon = float(fields[4]), float(fields[5])
        yield {"id": fields[0], "latitude": lat, "longitude": lon, "area": h3.latlng_to_cell(lat, lon, RESOLUTION)}


def post(base, key, batch):
    request = urllib.request.Request(
        f"{base}/rest/v1/places?on_conflict=id",
        data=json.dumps(batch).encode(),
        method="POST",
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates,return=minimal",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status not in (200, 201, 204):
            raise SystemExit(f"Upload failed: HTTP {response.status}")


def main():
    base, key = sys.argv[1].rstrip("/"), sys.argv[2]
    places = list(rows())
    for start in range(0, len(places), BATCH):
        post(base, key, places[start:start + BATCH])
    areas = len({p["area"] for p in places})
    print(f"Loaded {len(places)} places in {areas} areas.")


if __name__ == "__main__":
    main()
