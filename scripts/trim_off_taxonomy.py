#!/usr/bin/env python3
"""Builds Longevity Compass/Resources/OFFIngredientTaxonomy.json from the
Open Food Facts ingredient and label taxonomies.

Keeps each ingredient's id, parents and English/German name, plus the child
labels of the four free-from labels the app understands. Standard library only.

Usage (from the repository root):
    python3 -I scripts/trim_off_taxonomy.py
    python3 -I scripts/trim_off_taxonomy.py --ingredients ingredients.json --labels labels.json
"""

import argparse
import datetime
import json
import os
import urllib.request

INGREDIENTS_URL = "https://static.openfoodfacts.org/data/taxonomies/ingredients.json"
LABELS_URL = "https://static.openfoodfacts.org/data/taxonomies/labels.json"
LICENSE = (
    "Open Database License (ODbL) 1.0, Open Food Facts contributors "
    "(https://world.openfoodfacts.org/data). Trimmed by scripts/trim_off_taxonomy.py; "
    "this adapted database is offered under the same licence."
)
USER_AGENT = "LongevityDirection/0.2 (https://github.com/fabian-kir/Longevity-Direction)"

# Raw values of `FreeFromLabel` in Longevity Compass/Models/IngredientProfile.swift.
FREE_FROM_LABELS = ["en:no-lactose", "en:no-gluten", "en:no-alcohol", "en:no-caffeine"]

OUTPUT = os.path.join("Longevity Compass", "Resources", "OFFIngredientTaxonomy.json")


def load(path, url):
    if path:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def trim_ingredients(raw):
    out = {}
    for ingredient_id, entry in raw.items():
        names = entry.get("name") or {}
        trimmed = {"parents": entry.get("parents") or []}
        for language in ("en", "de"):
            if names.get(language):
                trimmed[language] = names[language]
        out[ingredient_id] = trimmed
    return out


def ancestors(label_id, labels, seen=None):
    seen = set() if seen is None else seen
    for parent in (labels.get(label_id) or {}).get("parents") or []:
        if parent not in seen:
            seen.add(parent)
            ancestors(parent, labels, seen)
    return seen


def free_from_children(labels):
    children = {label: [] for label in FREE_FROM_LABELS}
    for label_id in sorted(labels):
        above = ancestors(label_id, labels)
        for label in FREE_FROM_LABELS:
            if label in above:
                children[label].append(label_id)
    return children


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ingredients", help="local copy of ingredients.json (default: download)")
    parser.add_argument("--labels", help="local copy of labels.json (default: download)")
    parser.add_argument("--output", default=OUTPUT)
    args = parser.parse_args()

    ingredients = load(args.ingredients, INGREDIENTS_URL)
    labels = load(args.labels, LABELS_URL)

    result = {
        "source": {"ingredients": INGREDIENTS_URL, "labels": LABELS_URL},
        "downloadedAt": datetime.date.today().isoformat(),
        "license": LICENSE,
        "ingredients": trim_ingredients(ingredients),
        "freeFromChildren": free_from_children(labels),
    }
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        f.write("\n")
    print(f"{len(result['ingredients'])} ingredients, "
          f"{sum(map(len, result['freeFromChildren'].values()))} free-from child labels -> {args.output}")


if __name__ == "__main__":
    main()
