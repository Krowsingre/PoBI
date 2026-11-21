# Data

`build_nj_places.py` builds the New Jersey food and drink catalogue that ships inside the iOS app
(`ios/PoBI/Resources/nj_places.tsv`) from Overture Maps Places. Rerun it with a newer release
name when Overture publishes one (monthly):

    pip install pyarrow
    python3 data/build_nj_places.py 2026-11-18.0

It keeps places whose address is in New Jersey, whose category is under `food_and_drink`, that
aren't marked permanently closed, and whose Overture confidence is at least 0.5.
