import importlib.util
import unittest
import tempfile
from unittest.mock import patch
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "generate-pages-release.py"
SPEC = importlib.util.spec_from_file_location("pages_release", SCRIPT)
pages_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pages_release)


class PagesReleaseSelectionTests(unittest.TestCase):
    def test_assistant_platforms_are_selected_from_independent_releases(self):
        releases = [
            {
                "tag_name": "v0.10.21", "published_at": "2026-08-20T10:00:00Z",
                "html_url": "https://example.test/mac", "draft": False, "prerelease": False,
                "assets": [{"name": "Vamp-Assistant-0.10.21.dmg", "updated_at": "2026-08-20T10:01:00Z"}],
            },
            {
                "tag_name": "ios-v0.1.31", "published_at": "2026-08-24T10:00:00Z",
                "html_url": "https://example.test/ios", "draft": False, "prerelease": False,
                "assets": [{"name": "Vamp-Assistant-iOS-0.1.31-build-45-unsigned.ipa", "updated_at": "2026-08-24T10:01:00Z"}],
            },
        ]
        mac_release, mac_asset = pages_release.choose_release_asset(
            releases, pages_release.ASSISTANT_ASSET_PATTERNS["vamp-assistant-macos"]
        )
        ios_release, ios_asset = pages_release.choose_release_asset(
            releases, pages_release.ASSISTANT_ASSET_PATTERNS["vamp-assistant-ios"]
        )
        self.assertEqual(mac_release["tag_name"], "v0.10.21")
        self.assertEqual(mac_asset["name"], "Vamp-Assistant-0.10.21.dmg")
        self.assertEqual(ios_release["tag_name"], "ios-v0.1.31")
        self.assertIn("unsigned.ipa", ios_asset["name"])

    def test_drafts_and_prereleases_are_ignored(self):
        releases = [{
            "tag_name": "draft", "published_at": "2099-01-01T00:00:00Z",
            "html_url": "https://example.test/draft", "draft": True, "prerelease": False,
            "assets": [{"name": "Vamp-Assistant-99.0.0.dmg", "updated_at": "2099-01-01T00:00:00Z"}],
        }]
        self.assertIsNone(pages_release.choose_release_asset(
            releases, pages_release.ASSISTANT_ASSET_PATTERNS["vamp-assistant-macos"]
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

    def test_product_need_not_be_in_latest_release(self):
        desired = {"name": "VampStream-iOS-0.1.6-build-20-altstore-unsigned.ipa"}
        releases = [{"published_at": "2026-09-03", "assets": []},
                    {"published_at": "2026-09-02", "assets": [desired]}]
        self.assertEqual(pages_release.choose_release_asset(releases, pages_release.ASSET_PATTERNS["vamp-stream-ios"])[1], desired)

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
