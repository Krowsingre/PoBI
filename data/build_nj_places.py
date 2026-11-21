"""Build the New Jersey food and drink catalogue (including convenience stores like Wawa) bundled with the iOS app.

Reads Overture Maps Places (CDLA-Permissive-2.0 / ODbL sources, see
https://docs.overturemaps.org/attribution/) straight from Overture's public S3
bucket and writes ios/PoBI/Resources/nj_places.tsv.

    pip install pyarrow
    python3 data/build_nj_places.py 2026-11-18.0

Output columns (tab separated, no header):
    overture_id, name, category, town, latitude, longitude
"""
import os
import sys
from pathlib import Path

import pyarrow.dataset as ds
import pyarrow.fs as pafs

RELEASE = sys.argv[1] if len(sys.argv) > 1 else "2026-11-18.0"
MIN_CONFIDENCE = 0.5
# Bounding box around New Jersey. Rows are then narrowed to the NJ address region.
XMIN, XMAX, YMIN, YMAX = -75.6, -73.88, 38.92, 41.37
OUT = Path(__file__).resolve().parent.parent / "ios" / "PoBI" / "Resources" / "nj_places.tsv"


# Food-selling convenience chains that Overture sometimes files under gas stations.
FOOD_CHAINS = ("wawa", "quickchek", "quick chek", "7-eleven", "royal farms", "sheetz")


def counts_as_food_place(name: str, hierarchy: list) -> bool:
    """Food and drink places, plus convenience stores such as Wawa (embre, 2026-11-21)."""
    top = hierarchy[:1]
    if top == ["food_and_drink"]:
        return True
    if hierarchy[:2] == ["shopping", "convenience_store"]:
        return True
    if hierarchy[:2] == ["travel_and_transportation", "fueling_station"]:
        return any(chain in name.lower() for chain in FOOD_CHAINS)
    return False


def humanize(slug: str) -> str:
    text = slug.replace("_", " ").strip()
    return text[:1].upper() + text[1:]


def clean(text: str) -> str:
    return " ".join((text or "").replace("\t", " ").split())


def main() -> None:
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    fs = pafs.S3FileSystem(anonymous=True, region="us-west-2", proxy_options=proxy)
    path = f"overturemaps-us-west-2/release/{RELEASE}/theme=places/type=place/"
    dataset = ds.dataset(path, filesystem=fs, format="parquet")
    box = lambda k: ds.field("bbox", k)
    flt = (box("xmin") >= XMIN) & (box("xmax") <= XMAX) & (box("ymin") >= YMIN) & (box("ymax") <= YMAX)
    table = dataset.to_table(
        columns=["id", "names", "taxonomy", "addresses", "confidence", "operating_status", "bbox"],
        filter=flt,
    )

    rows = []
    seen = set()
    for r in table.to_pylist():
        address = (r["addresses"] or [{}])[0] or {}
        if address.get("region") not in ("NJ", "US-NJ"):
            continue
        taxonomy = r["taxonomy"] or {}
        name = clean((r["names"] or {}).get("primary"))
        if not counts_as_food_place(name, taxonomy.get("hierarchy") or []):
            continue
        if r["operating_status"] == "permanently_closed":
            continue
        if (r["confidence"] or 0) < MIN_CONFIDENCE:
            continue
        if not name or r["id"] in seen:
            continue
        seen.add(r["id"])
        b = r["bbox"]
        lat = (b["ymin"] + b["ymax"]) / 2
        lon = (b["xmin"] + b["xmax"]) / 2
        hierarchy = taxonomy.get("hierarchy") or []
        if hierarchy[:1] == ["travel_and_transportation"]:
            category = "Convenience store"  # a food chain filed as a gas station
        else:
            category = humanize(taxonomy.get("primary") or "restaurant")
        town = clean(address.get("locality")).title()
        rows.append((r["id"], name, category, town, f"{lat:.5f}", f"{lon:.5f}"))

    rows.sort(key=lambda row: row[0])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write("\t".join(row) + "\n")
    print(f"{len(rows)} places -> {OUT} ({OUT.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
