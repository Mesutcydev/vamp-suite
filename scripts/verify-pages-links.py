#!/usr/bin/env python3
"""Validate static site references and current release links; --online probes downloads."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import urlsplit, unquote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1] / "docs"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.refs, self.ids, self.downloads = [], set(), []
        self.feed(path.read_text())

    def handle_starttag(self, tag, pairs):
        attrs = dict(pairs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        for attr in ("href", "src"):
            if attrs.get(attr):
                self.refs.append(attrs[attr])
        for kind in ("link", "asset", "sha256"):
            if key := attrs.get(f"data-release-{kind}"):
                self.downloads.append((key, kind, attrs.get("href")))


def validate():
    pages = {path: Page(path) for path in ROOT.rglob("*.html")}
    assets = json.loads((ROOT / "release.json").read_text())["assets"]
    errors, urls = [], set()
    for path, page in pages.items():
        for key, label in re.findall(r'<span[^>]*data-release-version="([^"]+)"[^>]*>([^<]*)</span>', path.read_text()):
            if label != assets.get(key, {}).get("label"):
                errors.append(f"{path.relative_to(ROOT)}: stale version label for {key}")
        for key, kind, href in page.downloads:
            expected = assets.get(key, {}).get("sha256Url" if kind == "sha256" else "url")
            if href != expected or key not in assets:
                errors.append(f"{path.relative_to(ROOT)}: stale {kind} link for {key}")
        for ref in page.refs:
            url = urlsplit(ref)
            if url.netloc and url.netloc != "thevamp.app":
                if "/releases/download/" in ref:
                    urls.add(ref)
                    if not any(ref in (a["url"], a.get("sha256Url")) for a in assets.values()):
                        errors.append(f"{path.relative_to(ROOT)}: untracked download {ref}")
                continue
            if url.scheme and url.scheme not in ("http", "https"):
                continue
            target = (ROOT / unquote(url.path).lstrip("/") if url.path.startswith("/") or url.netloc
                      else path.parent / unquote(url.path)) if url.path else path
            if target.is_dir():
                target /= "index.html"
            target = target.resolve()
            if not target.exists():
                errors.append(f"{path.relative_to(ROOT)}: missing {ref}")
            elif url.fragment and target.suffix == ".html" and unquote(url.fragment) not in pages[target].ids:
                errors.append(f"{path.relative_to(ROOT)}: missing anchor {ref}")
    feed = json.loads((ROOT / "apps.json").read_text())
    for app in feed["apps"]:
        for version in app.get("versions", []):
            urls.add(version["downloadURL"])
        key = {"Vamp Stream": "vamp-stream-ios", "Vamp Assistant": "vamp-assistant-ios"}.get(app["name"])
        # ponytail: an iOS IPA absent from every release is optional, so its feed entry is not compared.
        if key in assets and app["versions"][0]["downloadURL"] != assets[key]["url"]:
            errors.append(f"apps.json: latest {app['name']} version needs updating")
    for asset in assets.values():
        urls.add(asset["url"])
        if asset.get("sha256Url"):
            urls.add(asset["sha256Url"])
    return errors, urls, len(pages)


def probe(url):
    try:
        checksum = url.endswith(".sha256")
        with urlopen(Request(url, method="GET" if checksum else "HEAD", headers={"User-Agent": "Vamp-link-audit"}), timeout=45) as response:
            if response.status != 200:
                return f"{response.status}: {url}"
            if checksum:
                value = response.read(4096).decode().strip()
                filename = unquote(urlsplit(url).path.rsplit("/", 1)[1][:-7])
                if not re.fullmatch(r"[a-fA-F0-9]{64}(?:\s+\*?" + re.escape(filename) + r")?", value):
                    return f"Invalid checksum document: {url}"
    except Exception as error:
        return f"{url}: {error}"
    return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--online", action="store_true")
    args = parser.parse_args()
    errors, urls, count = validate()
    if args.online:
        with ThreadPoolExecutor(max_workers=6) as pool:
            errors.extend(error for error in pool.map(probe, sorted(urls)) if error)
    for error in errors:
        print(error)
    print(f"Checked {count} pages, {len(urls)} unique download/checksum URLs; {len(errors)} errors.")
    raise SystemExit(bool(errors))
