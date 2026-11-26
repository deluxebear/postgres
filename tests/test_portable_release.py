import copy
import importlib.util
import json
from pathlib import Path
import shutil
import io
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("portable_release", ROOT / "scripts/portable/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def item(tag, **kwargs):
    return {"tag_name": tag, "name": tag, "draft": False, "prerelease": False,
            "published_at": "2026-11-24T22:43:04Z", "html_url": "https://github.com/test/release", **kwargs}


def plan():
    source = {"url": "https://example.org/source.tar.gz", "hash": "sha256-test"}
    return {
        "has_work": True, "release_tag": "postgres-17.12.0.005-cli", "workflow_commit": "abc",
        "upstream": {"tag": "v17.12.0.005-cli", "commit": "def", "url": "https://github.com/upstream/release"},
        "extensions": {
            "pg_duckdb": {"version": "9.8.7", "tag": "v9.8.7", "url": "https://github.com/duckdb/release",
                          "source": source, "duckdb_source": source, "httpfs_source": source,
                          "httpfs_commit": "b" * 40},
            "pg_durable": {"version": "0.9.8", "tag": "v0.9.8", "url": "https://github.com/durable/release",
                           "source": source, "lock_source": source, "rust_version": "1.88.0", "pgrx_version": "0.16.1"},
        },
    }


class StableReleaseTests(unittest.TestCase):
    def test_excludes_other_flavors_and_unstable_releases(self):
        candidates = [item("v17.12.0.005-cli"), item("v17.12.0.006-cli", draft=True),
                      item("v17.13.0.000-cli", prerelease=True), item("17.99.0.999"),
                      item("v18.1.0.000-cli"), item("v17.14.0.000-cli", name="RC1 test"),
                      item("v17.12.0.005-cli-rc1")]
        self.assertEqual(release.latest_stable(candidates, release.CLI_TAG)["tag_name"], "v17.12.0.005-cli")

    def test_numeric_version_order(self):
        self.assertEqual(release.latest_stable([item("v1.9.9"), item("v1.10.0"), item("v2.0.0-rc1")],
                                              release.EXT_TAG)["tag_name"], "v1.10.0")

    def test_paginates_past_other_flavors(self):
        with patch.object(release, "api", side_effect=[[item("17.12.0.005")] * 100,
                                                      [item("v17.12.0.005-cli")]]) as api:
            self.assertEqual(len(release.releases("supabase/postgres", release.CLI_TAG)), 101)
            self.assertEqual(api.call_count, 2)

    def test_published_release_skips_extension_resolution(self):
        with patch.object(release, "releases", return_value=[item("v17.12.0.005-cli")]), \
             patch.object(release, "api", return_value={"draft": False}), \
             patch.object(release, "describe") as describe:
            self.assertFalse(release.discover("owner/repo")["has_work"])
            describe.assert_not_called()

    def test_api_errors_are_not_treated_as_missing_releases(self):
        with patch.object(release, "releases", return_value=[item("v17.12.0.005-cli")]), \
             patch.object(release, "api", side_effect=urllib.error.HTTPError("url", 403, "forbidden", {}, None)):
            with self.assertRaises(urllib.error.HTTPError):
                release.discover("owner/repo")

    def test_rejects_unstable_manual_ref(self):
        with patch.object(release, "api", return_value=item("v17.12.0.005-cli", prerelease=True)):
            with self.assertRaises(ValueError):
                release.discover("owner/repo", "v17.12.0.005-cli")

    def test_resolves_extensions_and_real_predecessor(self):
        old = item("postgres-17.12.0.004-cli", assets=[])
        absent = urllib.error.HTTPError("url", 404, "not found", {}, None)
        with patch.object(release, "releases", side_effect=[
                [item("v17.12.0.005-cli")], [old], [item("v1.2.2")], [item("v0.2.9")]]), \
             patch.object(release, "api", side_effect=absent), \
             patch.object(release, "describe", side_effect=lambda repo, r: {"tag": r["tag_name"]}):
            resolved = release.discover("owner/repo")
            self.assertEqual(resolved["predecessor"]["tag"], old["tag_name"])
            self.assertEqual(resolved["extensions"]["pg_duckdb"]["tag"], "v1.2.2")


class SourceTests(unittest.TestCase):
    def test_patches_only_cli_set_and_dynamic_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            for filename in ("nix/packages/postgres.nix", "nix/packages/postgres-portable.nix",
                             "nix/packages/cli-config/postgresql.conf.template"):
                target = checkout / filename
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / filename, target)
            (checkout / "nix/ext").mkdir()
            release.patch_checkout(plan(), checkout)
            packages = (checkout / "nix/packages/postgres.nix").read_text()
            self.assertIn("cliExtensions = [\n        ../ext/pg_duckdb.nix\n        ../ext/pg_durable.nix", packages)
            duck = (checkout / "nix/ext/pg_duckdb.nix").read_text()
            self.assertIn('version = "9.8.7";', duck)
            self.assertIn("GIT_TAG " + "b" * 40, duck)
            self.assertIn('url = "https://example.org/source.tar.gz";', duck)
            self.assertIn('version = "0.9.8";', (checkout / "nix/ext/pg_durable.nix").read_text())
            preload = (checkout / "nix/packages/cli-config/postgresql.conf.template").read_text()
            self.assertIn("pg_stat_statements, pg_cron, pg_net", preload)
            self.assertIn("pg_duckdb, pg_durable'", preload)
            self.assertEqual(json.loads((checkout / "portable-release.json").read_text()), plan())

    def test_packaging_drift_stops_preparation(self):
        with self.assertRaises(ValueError):
            release.replace_once("changed upstream", "cliExtensions = [", "replacement")

    def test_sql_versions_can_differ_from_release_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "source.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                for name, value in (("pg_duckdb", "1.1.0"), ("pg_durable", "@CARGO_VERSION@")):
                    data = f"default_version = '{value}'\n".encode()
                    entry = tarfile.TarInfo(f"source/{name}.control")
                    entry.size = len(data)
                    output.addfile(entry, io.BytesIO(data))
            self.assertEqual(release.sql_version(archive, "pg_duckdb", "1.1.1"), "1.1.0")
            self.assertEqual(release.sql_version(archive, "pg_durable", "0.2.9"), "0.2.9")


class NotesTests(unittest.TestCase):
    def inventories(self, resolved):
        return [{"platform": platform, "postgresql": "postgres (PostgreSQL) 17.12",
                 "extensions": {"pg_duckdb": "9.8.7", "pg_durable": "0.9.8", "pg_cron": "1.6"},
                 "release": copy.deepcopy(resolved)}
                for platform in ("linux-x64", "linux-arm64", "darwin-arm64")]

    def test_lists_all_versions_and_actual_source(self):
        resolved = plan()
        inventories = self.inventories(resolved)
        resolved["source_commit"] = "built-source"
        notes = release.notes(resolved, inventories)
        self.assertIn("| pg_cron | 1.6 |", notes)
        self.assertIn("built-source", notes)
        self.assertIn("9.8.7", notes)

    def test_mismatched_artifact_versions_block_release(self):
        resolved = plan()
        inventories = self.inventories(resolved)
        inventories[1]["extensions"]["pg_cron"] = "1.5"
        resolved["source_commit"] = "built-source"
        with self.assertRaises(ValueError):
            release.notes(resolved, inventories)

    def test_wrong_source_or_platform_blocks_release(self):
        resolved = plan()
        inventories = self.inventories(resolved)
        inventories[2]["release"]["workflow_commit"] = "unrelated"
        resolved["source_commit"] = "built-source"
        with self.assertRaises(ValueError):
            release.notes(resolved, inventories)
        with self.assertRaises(ValueError):
            release.notes(resolved, inventories[:2])


if __name__ == "__main__":
    unittest.main()
