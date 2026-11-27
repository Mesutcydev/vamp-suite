import importlib.util
import json
import unittest
import tempfile
from unittest.mock import patch
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "generate-pages-release.py"
SPEC = importlib.util.spec_from_file_location("pages_release", SCRIPT)
pages_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pages_release)


class PagesReleaseSelectionTests(unittest.TestCase):
    def test_drafts_and_prereleases_are_ignored(self):
        releases = [{
            "tag_name": "draft", "published_at": "2099-01-01T00:00:00Z",
            "html_url": "https://example.test/draft", "draft": True, "prerelease": False,
            "assets": [{"name": "VampSync-macOS-99.0.0-build-99-notarized.dmg", "updated_at": "2099-01-01T00:00:00Z"}],
        }]
        self.assertIsNone(pages_release.choose_release_asset(
            releases, pages_release.ASSET_PATTERNS["vamp-mini-host-dmg"]
        ))


    def select(self, names, key="vamp-control-ios"):
        releases = [{"tag_name": str(i), "published_at": f"2026-09-{i+1:02}",
                     "assets": [{"name": name}]} for i, name in enumerate(names)]
        return pages_release.choose_release_asset(releases, pages_release.ASSET_PATTERNS[key])[1]["name"]

    def test_marketing_version_reset_keeps_newest_build(self):
        old = "VampControl-iOS-3.7.5-build-40-altstore-unsigned.ipa"
        new = "VampControl-iOS-2.3.0-build-47-altstore-unsigned.ipa"
        self.assertEqual(self.select([new, old]), new)

    def test_reuploading_older_build_does_not_make_it_latest(self):
        new = "VampControl-iOS-2.3.0-build-47-altstore-unsigned.ipa"
        old = "VampControl-iOS-2.3.0-build-46-altstore-unsigned.ipa"
        self.assertEqual(self.select([new, old]), new)

    def test_revision_and_sync_public_name_break_ties(self):
        revised = "VampControl-iOS-2.3.0-build-47-altstore-unsigned-r2.ipa"
        self.assertEqual(self.select([revised, revised.replace("-r2", "")]), revised)
        sync = "VampSync-macOS-2.3.0-build-54-adhoc.dmg"
        self.assertEqual(self.select([sync, sync.replace("VampSync", "VampMiniHost")], "vamp-mini-host-dmg"), sync)

    def test_control_mac_prefers_dmg_for_same_build(self):
        dmg = "VampControl-macOS-2.3.0-build-55-adhoc.dmg"
        self.assertEqual(self.select([dmg.replace(".dmg", ".zip"), dmg], "vamp-control-macos"), dmg)

    def test_sync_selects_notarized_release_and_prefers_it_for_same_build(self):
        signed = "VampSync-macOS-2.3.1-build-72-notarized.dmg"
        old = "VampSync-macOS-2.3.0-build-71-adhoc.dmg"
        adhoc = signed.replace("-notarized", "-adhoc")
        self.assertEqual(self.select([signed, old], "vamp-mini-host-dmg"), signed)
        self.assertEqual(self.select([signed, adhoc], "vamp-mini-host-dmg"), signed)

    def test_product_need_not_be_in_latest_release(self):
        desired = {"name": "VampControl-iOS-2.3.0-build-47-altstore-unsigned.ipa"}
        releases = [{"published_at": "2026-09-03", "assets": []},
                    {"published_at": "2026-09-02", "assets": [desired]}]
        self.assertEqual(pages_release.choose_release_asset(releases, pages_release.ASSET_PATTERNS["vamp-control-ios"])[1], desired)

    def test_sync_only_refresh_preserves_other_products_when_ios_assets_are_missing(self):
        key = "vamp-mini-host-dmg"
        releases = [{"tag_name": "vamp-sync-2.3.1-build-72", "html_url": "https://example.test/release",
                     "assets": [{"name": "VampSync-macOS-2.3.1-build-72-notarized.dmg",
                                 "browser_download_url": "https://example.test/sync.dmg"}]}]
        with tempfile.TemporaryDirectory() as tmp:
            docs = Path(tmp)
            other = {"url": "https://example.test/control.ipa", "label": "existing", "tag": "existing"}
            payload = {"assets": {key: {}, "vamp-control-ios": other}}
            (docs / "release.json").write_text(json.dumps(payload))
            (docs / "index.html").write_text(f'<a data-release-link="{key}" href="old">Sync</a>')
            with patch.object(pages_release, "fetch_releases", return_value=releases) as fetch:
                self.assertEqual(pages_release.main(["--site-dir", str(docs), "--product", key]), 0)
            fetch.assert_called_once_with(pages_release.REPOSITORY)
            result = json.loads((docs / "release.json").read_text())
            self.assertEqual(result["assets"]["vamp-control-ios"], other)
            self.assertEqual(result["assets"][key]["label"], "2.3.1 · build 72")
            self.assertIn('href="https://example.test/sync.dmg"', (docs / "index.html").read_text())

    def test_product_refresh_still_requires_its_requested_asset(self):
        with self.assertRaisesRegex(ValueError, "vamp-mini-host-dmg"):
            pages_release.resolve_assets([], {"vamp-mini-host-dmg"})

    def test_full_refresh_succeeds_without_ios_ipas_but_requires_mac_downloads(self):
        def release(*names):
            return [{"tag_name": "t", "html_url": "https://example.test/r",
                     "assets": [{"name": n, "browser_download_url": f"https://example.test/{n}"} for n in names]}]
        sync = "VampSync-macOS-4.0.0-build-80-notarized.dmg"
        control = "VampControl-macOS-2.3.0-build-57-adhoc.dmg"
        suite = release(sync, control, "VampStream-iOS-0.1.8-build-21-altstore-unsigned.ipa")
        self.assertEqual(set(pages_release.resolve_assets(suite)), {"vamp-mini-host-dmg", "vamp-control-macos"})
        with self.assertRaisesRegex(ValueError, "vamp-control-macos"):
            pages_release.resolve_assets(release(sync))

    def test_missing_optional_control_download_hides_stale_link_and_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "index.html"
            path.write_text('<a data-release-link="vamp-control-ios" href="old">Download</a>'
                            '<span data-release-version="vamp-control-ios">old version</span>')
            pages_release.rewrite_static_links(path, {})
            result = path.read_text()
            self.assertIn('data-release-link="vamp-control-ios" hidden', result)
            self.assertNotIn('href="old"', result)
            self.assertNotIn('old version', result)
            pages_release.rewrite_static_links(path, {"vamp-control-ios": {"url": "new", "label": "build 2"}})
            result = path.read_text()
            self.assertIn('data-release-link="vamp-control-ios" href="new"', result)
            self.assertIn('>build 2</span>', result)

    def test_retired_download_keys_are_left_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "index.html"
            markup = '<a data-release-link="vamp-assistant-macos" href="old">Download</a>'
            path.write_text(markup)
            pages_release.rewrite_static_links(path, {"vamp-control-macos": {"url": "new"}})
            self.assertEqual(path.read_text(), markup)

    def test_pagination_reads_beyond_first_hundred_releases(self):
        with patch.object(pages_release, "fetch_json", side_effect=[[{}] * 100, [{"tag_name": "older"}]]):
            self.assertEqual(len(pages_release.fetch_releases("example/repo")), 101)

    def test_static_download_checksum_and_label_stay_together(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "index.html"
            path.write_text('<a href="old" data-release-link="app">Download</a>'
                            '<a data-release-sha256="app" href="old-sha">SHA</a>'
                            '<span data-release-version="app">old</span>'
                            '<a href="https://github.com/other/repo/releases/latest">Other</a>')
            pages_release.rewrite_static_links(path, {"app": {"url": "new", "label": "build 2", "sha256Url": "new-sha"}})
            result = path.read_text()
            self.assertIn('href="new"', result)
            self.assertIn('href="new-sha"', result)
            self.assertIn('>build 2</span>', result)
            self.assertIn('https://github.com/other/repo/releases/latest', result)
            pages_release.rewrite_static_links(path, {"app": {"url": "new", "label": "build 2"}})
            self.assertIn('data-release-sha256="app" hidden', path.read_text())
            self.assertNotIn('href="new-sha"', path.read_text())


if __name__ == "__main__":
    unittest.main()
