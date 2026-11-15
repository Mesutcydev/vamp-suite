#!/usr/bin/env python3
"""Resolve each product's latest stable artifact and update static Pages links."""
from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from urllib.request import Request, urlopen

REPOSITORY = "Mesutcydev/vamp-suite"
ASSET_PATTERNS = {
    # Keep the existing metadata key for cached clients and compatibility links.
    "vamp-mini-host-dmg": re.compile(r"^(?:VampSync|VampMiniHost)-macOS-.+-build-\d+-(?:adhoc|notarized)\.dmg$"),
    "vamp-control-macos": re.compile(r"^VampControl-macOS-.+-build-\d+-(?:adhoc|notarized)\.(?:zip|dmg)$"),
    "vamp-control-ios": re.compile(r"^VampControl-iOS-.+-build-\d+-altstore-unsigned(?:-r\d+)?\.ipa$"),
}
REQUIRED = {"vamp-mini-host-dmg", "vamp-control-macos"}


def fetch_json(url: str):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "vamp-suite-pages"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    with urlopen(Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


def fetch_releases(repository: str) -> list[dict]:
    releases = []
    page = 1
    while True:
        batch = fetch_json(f"https://api.github.com/repos/{repository}/releases?per_page=100&page={page}")
        releases.extend(batch)
        if len(batch) < 100:
            return releases
        page += 1


def asset_version(asset: dict) -> tuple:
    """Monotonic build numbers survive marketing-version resets (Control 3.7 → 2.3)."""
    name = asset["name"]
    version = re.search(r"-(\d+)\.(\d+)\.(\d+)(?=[-.])", name)
    build = re.search(r"-build-(\d+)", name)
    revision = re.search(r"-r(\d+)\.", name)
    return (
        int(build[1]) if build else 0,
        tuple(map(int, version.groups())) if version else (0, 0, 0),
        int(revision[1]) if revision else 0,
        "-notarized." in name,
        name.startswith("VampSync-"),
        name.endswith(".dmg"),
    )


def choose_release_asset(releases: list[dict], pattern: re.Pattern[str]) -> tuple[dict, dict] | None:
    """Shared selector: platforms and products can ship in independent release tags."""
    candidates = [
        (release, asset)
        for release in releases if not release.get("draft") and not release.get("prerelease")
        for asset in release.get("assets", []) if pattern.fullmatch(asset["name"])
    ]
    return max(candidates, key=lambda pair: (
        asset_version(pair[1]), pair[0].get("published_at", ""), pair[1].get("updated_at", "")
    ), default=None)


def checksum_url(raw_assets: list[dict], asset: dict) -> str | None:
    return next((other["browser_download_url"] for other in raw_assets
                 if other["name"] == asset["name"] + ".sha256"), None)


def asset_label(name: str) -> str:
    match = re.search(r"-(\d+\.\d+\.\d+)(?:-build-(\d+))?", name)
    if not match:
        return name
    label = match[1] + (f" · build {match[2]}" if match[2] else "")
    revision = re.search(r"-r(\d+)\.", name)
    return label + (f" · revision {revision[1]}" if revision else "")


def resolve_assets(releases: list[dict], products: set[str] | None = None) -> dict:
    assets = {}
    for key, pattern in ASSET_PATTERNS.items():
        if products is not None and key not in products:
            continue
        selected = choose_release_asset(releases, pattern)
        if not selected:
            continue
        release, asset = selected
        entry = {"name": asset["name"], "url": asset["browser_download_url"],
                 "label": asset_label(asset["name"]), "releaseUrl": release["html_url"],
                 "tag": release["tag_name"]}
        if sha := checksum_url(release.get("assets", []), asset):
            entry["sha256Url"] = sha
        assets[key] = entry
    missing = (REQUIRED if products is None else products) - assets.keys()
    if missing:
        raise ValueError(f"Missing expected release assets: {', '.join(sorted(missing))}")
    return assets


def rewrite_static_links(path: Path, assets: dict) -> None:
    """Keep no-JS downloads, checksums and labels identical to release.json."""
    html = path.read_text(encoding="utf-8")

    def rewrite_anchor(match):
        tag, kind, key = match[0], match[1], match[2]
        if key not in ASSET_PATTERNS and key not in assets:
            raise ValueError(f"{path}: unknown release key {key}")
        url = assets.get(key, {}).get("sha256Url" if kind == "sha256" else "url")
        tag = re.sub(r'\s(?:href="[^"]*"|hidden(?:="[^"]*")?)', '', tag)
        return tag[:-1] + (f' href="{url}">' if url else ' hidden>')

    html = re.sub(r'<a\b[^>]*\bdata-release-(link|asset|sha256)="([^"]+)"[^>]*>', rewrite_anchor, html)
    def rewrite_label(match):
        return match[1] + assets.get(match[2], {}).get("label", "") + match[3]
    html = re.sub(r'(<span\b[^>]*\bdata-release-version="([^"]+)"[^>]*>)[^<]*(</span>)', rewrite_label, html)
    # Repository release/history links intentionally retain their own repository.
    path.write_text(html, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-dir", type=Path, required=True, help="Staged Pages directory")
    parser.add_argument("--product", action="append", choices=sorted(ASSET_PATTERNS),
                        help="Refresh only this download, preserving other published download metadata")
    args = parser.parse_args(argv)
    products = set(args.product) if args.product else None
    updates = resolve_assets(fetch_releases(REPOSITORY), products)
    manifest = args.site_dir / "release.json"
    assets = json.loads(manifest.read_text())["assets"] if products is not None else {}
    assets.update(updates)
    payload = {"repository": REPOSITORY, "assets": assets}
    for path in args.site_dir.rglob("*.html"):
        rewrite_static_links(path, assets)
    manifest.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    for key, asset in updates.items():
        print(f"{key}: {asset['label']} ({asset['tag']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
