#!/usr/bin/env python3
"""Fetch OG/meta descriptions for all feeds in categories/."""

import json
import asyncio
import aiohttp
import re
from html import unescape
from typing import Optional
from pathlib import Path

TIMEOUT = aiohttp.ClientTimeout(total=10)
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"}
CONCURRENCY = 30

def extract_meta(html: str) -> Optional[str]:
    """Extract og:description or meta description from HTML."""
    # Try og:description first
    for pattern in [
        r'<meta[^>]+property=["\']og:description["\'][^>]+content=["\']([^"\']*)["\']',
        r'<meta[^>]+content=["\']([^"\']*)["\'][^>]+property=["\']og:description["\']',
        r'<meta[^>]+name=["\']description["\'][^>]+content=["\']([^"\']*)["\']',
        r'<meta[^>]+content=["\']([^"\']*)["\'][^>]+name=["\']description["\']',
    ]:
        m = re.search(pattern, html, re.IGNORECASE | re.DOTALL)
        if m and m.group(1).strip():
            return unescape(m.group(1).strip())
    return None


async def fetch_one(session: aiohttp.ClientSession, feed: dict) -> dict:
    url = feed.get("siteURL", "")
    name = feed["name"]
    result = {"name": name, "siteURL": url, "current": feed.get("description", ""), "og": None, "error": None}
    if not url:
        result["error"] = "no siteURL"
        return result
    try:
        async with session.get(url, timeout=TIMEOUT, allow_redirects=True, ssl=False) as resp:
            # Only read first 100KB
            body = await resp.content.read(100_000)
            html = body.decode("utf-8", errors="replace")
            result["og"] = extract_meta(html)
    except Exception as e:
        result["error"] = str(e)[:100]
    return result


async def main():
    cats_dir = Path(__file__).parent / "categories"
    feeds = []
    for fp in sorted(cats_dir.glob("*.json")):
        with open(fp) as f:
            feeds.extend(json.load(f))

    sem = asyncio.Semaphore(CONCURRENCY)
    connector = aiohttp.TCPConnector(limit=CONCURRENCY, ssl=False)

    async with aiohttp.ClientSession(headers=HEADERS, connector=connector) as session:
        async def bounded(feed):
            async with sem:
                return await fetch_one(session, feed)

        results = await asyncio.gather(*[bounded(f) for f in feeds])

    out = Path(__file__).parent / "descriptions_raw.json"
    with open(out, "w") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)

    # Summary
    found = sum(1 for r in results if r["og"])
    errors = sum(1 for r in results if r["error"])
    print(f"Done: {found} OG descriptions found, {errors} errors, {len(results)} total")

if __name__ == "__main__":
    asyncio.run(main())
