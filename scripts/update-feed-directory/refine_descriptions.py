#!/usr/bin/env python3
"""Generate refined descriptions by picking the best source and cleaning up."""

import json
from pathlib import Path

def refine(name, current, og, category, country=None):
    """Pick best description source and clean it up."""
    # Pick the better source
    raw = og or current or ""
    fallback = current or og or ""

    # Use OG if it's more descriptive, otherwise use current
    if og and len(og) > 10 and not og.lower().startswith("http"):
        raw = og
    elif current and len(current) > 10:
        raw = current

    # If both are very short or empty, use fallback
    if len(raw.strip()) < 5:
        raw = fallback

    # Clean up common junk
    raw = raw.strip()

    # Remove "RSS" / "feed" boilerplate
    for junk in [
        "This feed is for non commercial use.",
        "FOR PERSONAL USE ONLY",
        "Content Copyright",
        "Default RSS Feed",
        "RSS Feed",
        " - Medium",
        "Kinja RSS",
    ]:
        raw = raw.replace(junk, "").strip()

    # Remove trailing periods and clean whitespace
    raw = " ".join(raw.split())

    # Truncate to ~120 chars at word boundary
    if len(raw) > 120:
        truncated = raw[:120]
        last_space = truncated.rfind(" ")
        if last_space > 60:
            truncated = truncated[:last_space]
        # Remove trailing punctuation fragments
        raw = truncated.rstrip(".,;:- ")

    # Remove trailing period
    raw = raw.rstrip(".")

    return raw


def main():
    base = Path(__file__).parent

    cats_dir = base / "categories"
    feeds = []
    for fp in sorted(cats_dir.glob("*.json")):
        with open(fp) as f:
            feeds.extend(json.load(f))

    with open(base / "descriptions_raw.json") as f:
        fetched = json.load(f)

    # Build lookup by name
    og_map = {r["name"]: r.get("og") for r in fetched}

    results = []
    for feed in feeds:
        name = feed["name"]
        current = feed.get("description", "")
        og = og_map.get(name, "")
        category = feed.get("category", "")
        country = feed.get("country")

        refined = refine(name, current, og, category, country)

        results.append({
            "name": name,
            "current": current,
            "og": og or "",
            "refined": refined,
            "changed": refined != current.strip().rstrip(".")
        })

    # Write output for review
    with open(base / "descriptions_refined.json", "w") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    changed = sum(1 for r in results if r["changed"])
    print(f"Total: {len(results)}, Changed: {changed}")

    # Print changed ones for review
    for r in results:
        if r["changed"]:
            print(f"\n{r['name']}:")
            print(f"  OLD: {r['current'][:100]}")
            print(f"  NEW: {r['refined'][:100]}")


if __name__ == "__main__":
    main()
