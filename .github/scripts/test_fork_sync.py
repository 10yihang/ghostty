"""Local git fixtures only: never push a real remote or change the user's checkout."""

from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("fork_sync", Path(__file__).with_name("fork-sync.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


def run(repo, *arguments):
    result = subprocess.run(["git", "-C", str(repo), *arguments], check=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.stdout.strip()


def seed_contract(repo):
    for name, marker in sync.CONTRACT.items():
        target = repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(marker + "\n")
    for name in ["release-tip.yml", "release-tag.yml", "publish-tag.yml"]:
        target = repo / ".github/workflows" / name
        target.write_text("jobs:\n  setup:\n    if: github.repository == 'ghostty-org/ghostty'\n    runs-on: fixture\n")
    (repo / "build.zig.zon").write_text('.{ .version = "1.3.2-dev" }\n')


class SyncFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ghostty-fork-sync-test-")
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        self.fork = self.root / "fork"
        self.remote = self.root / "origin.git"
        self.upstream.mkdir()
        run(self.upstream, "init", "-b", "main")
        run(self.upstream, "config", "user.name", "Fixture")
        run(self.upstream, "config", "user.email", "fixture@example.invalid")
        (self.upstream / "shared").write_text("original\n")
        run(self.upstream, "add", ".")
        run(self.upstream, "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "initial")
        run(self.root, "clone", str(self.upstream), str(self.fork))
        run(self.fork, "config", "user.name", "Fixture")
        run(self.fork, "config", "user.email", "fixture@example.invalid")
        seed_contract(self.fork)
        self.commit(self.fork, "AI fork")
        self.base = run(self.fork, "rev-parse", "HEAD")
        run(self.root, "init", "--bare", str(self.remote))
        run(self.fork, "remote", "set-url", "origin", str(self.remote))
        run(self.fork, "push", "origin", "main")
        (self.upstream / "upstream-update").write_text("official update\n")
        self.commit(self.upstream, "official stable update")
        run(self.upstream, "tag", "-a", "v1.3.1", "-m", "stable")

    def tearDown(self):
        self.temporary.cleanup()

    def commit(self, repo, message):
        run(repo, "add", ".")
        run(repo, "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", message)
        return run(repo, "rev-parse", "HEAD")

    def plan(self, **options):
        return sync.prepare(self.fork, "v1.3.1", upstream=str(self.upstream),
                            now=datetime(2026, 10, 7, 1, 2, 3, tzinfo=timezone.utc), **options)

    def promote(self, plan):
        sync.promote(self.fork, plan, plan["base"], plan["candidate"], plan["tag"])

    def test_candidate_merge_preserves_fork_and_does_not_move_main_or_remote(self):
        plan = self.plan()
        self.assertTrue(plan["changed"])
        self.assertTrue(plan["merged"])
        self.assertNotEqual(plan["candidate"], self.base)
        self.assertEqual(run(self.fork, "rev-parse", "main"), self.base)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), self.base)
        self.assertEqual(run(self.fork, "show", "HEAD:macos/Sources/Features/AI/TerminalAICommandPolicy.swift"), "TerminalAICommandPolicy")
        self.assertEqual(plan["source_version"], "1.3.2-dev")
        self.assertEqual(plan["upstream_sha"], run(self.upstream, "rev-parse", "v1.3.1^{commit}"))

    def test_verified_promotion_moves_main_and_immutable_tag_atomically(self):
        plan = self.plan()
        self.promote(plan)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), plan["candidate"])
        self.assertEqual(run(self.remote, "rev-parse", "refs/tags/" + plan["tag"]), plan["candidate"])
        self.promote(plan)  # Idempotent retry of this exact transaction.

    def test_bundle_transfers_only_candidate_objects_to_a_clean_publish_checkout(self):
        plan = self.plan()
        output = self.root / "artifacts"
        sync.save_plan(self.fork, plan, output)
        publisher = self.root / "publisher"
        run(self.root, "clone", "--branch", "main", str(self.remote), str(publisher))
        run(publisher, "bundle", "verify", str(output / "candidate.bundle"))
        run(publisher, "fetch", str(output / "candidate.bundle"), "refs/fork/candidate:refs/fork/candidate")
        sync.promote(publisher, json.loads((output / "plan.json").read_text()),
                     plan["base"], plan["candidate"], plan["tag"])
        self.assertEqual(run(publisher, "rev-parse", "HEAD"), self.base)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), plan["candidate"])

    def test_merge_conflict_leaves_main_and_remote_untouched(self):
        (self.fork / "shared").write_text("fork change\n")
        self.base = self.commit(self.fork, "fork conflict")
        run(self.fork, "push", "origin", "main")
        (self.upstream / "shared").write_text("official conflicting change\n")
        self.commit(self.upstream, "upstream conflict")
        run(self.upstream, "tag", "-d", "v1.3.1")
        run(self.upstream, "tag", "v1.3.1")
        with self.assertRaisesRegex(sync.SyncError, "Conflicts: shared"):
            self.plan()
        self.assertEqual(run(self.fork, "rev-parse", "main"), self.base)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), self.base)

    def test_upstream_workflow_conflicts_and_new_publishers_keep_the_entire_fork_baseline(self):
        workflows = self.upstream / ".github/workflows"
        workflows.mkdir(parents=True)
        (workflows / "release-tag.yml").write_text("upstream changed publisher\n")
        (workflows / "new-official-release.yml").write_text("unprotected new upstream publisher\n")
        self.commit(self.upstream, "official CI change")
        run(self.upstream, "tag", "-d", "v1.3.1")
        run(self.upstream, "tag", "v1.3.1")
        plan = self.plan()
        self.assertEqual(run(self.fork, "diff", "--name-only", self.base, plan["candidate"], "--", ".github/workflows"), "")
        self.assertEqual(sync.git(self.fork, "show", "HEAD:.github/workflows/new-official-release.yml", check=False).returncode, 128)
        self.assertEqual(run(self.fork, "status", "--porcelain"), "")
        self.assertEqual(run(self.fork, "rev-parse", "main"), self.base)
        self.promote(plan)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), plan["candidate"])

    def test_dirty_scope_is_rejected_before_fetch_or_checkout(self):
        (self.fork / "unsaved").write_text("keep me\n")
        with self.assertRaisesRegex(sync.SyncError, "clean CI checkout"):
            self.plan()
        self.assertEqual(run(self.fork, "symbolic-ref", "--short", "HEAD"), "main")
        self.assertEqual((self.fork / "unsaved").read_text(), "keep me\n")

    def test_remote_advance_is_rejected_even_when_it_is_a_candidate_ancestor(self):
        plan = self.plan()
        upstream_sha = plan["upstream_sha"]
        # Make a main value strictly between base and candidate: the candidate
        # has base and upstream as parents, so any base child can also be a parent.
        tree = run(self.fork, "rev-parse", self.base + "^{tree}")
        between = subprocess.run(["git", "-C", str(self.fork), "commit-tree", tree, "-p", self.base],
                                 input="intermediate\n", text=True, check=True, stdout=subprocess.PIPE).stdout.strip()
        candidate = subprocess.run(["git", "-C", str(self.fork), "commit-tree", run(self.fork, "rev-parse", "HEAD^{tree}"),
                                    "-p", between, "-p", upstream_sha], input="candidate\n", text=True,
                                   check=True, stdout=subprocess.PIPE).stdout.strip()
        plan["candidate"] = candidate
        run(self.fork, "push", "origin", between + ":refs/heads/main")
        with self.assertRaisesRegex(sync.SyncError, "main or the immutable tag changed"):
            self.promote(plan)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), between)
        self.assertEqual(run(self.remote, "tag", "--list", plan["tag"]), "")

    def test_independent_remote_advance_and_missing_base_are_rejected(self):
        plan = self.plan()
        other = self.root / "other"
        run(self.root, "clone", "--branch", "main", str(self.remote), str(other))
        run(other, "config", "user.name", "Fixture")
        run(other, "config", "user.email", "fixture@example.invalid")
        (other / "new-user-work").write_text("preserve this\n")
        advanced = self.commit(other, "independent user change")
        run(other, "push", "origin", "main")
        with self.assertRaisesRegex(sync.SyncError, "changed"):
            self.promote(plan)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), advanced)
        missing = dict(plan, base="0" * 40)
        with self.assertRaises(sync.SyncError):
            self.promote(missing)

    def test_push_time_race_fails_lease_and_never_creates_release_tag(self):
        plan = self.plan()
        real_git = sync.git
        changed = False

        def racing_git(repo, *arguments, **options):
            nonlocal changed
            if arguments[0] == "push" and not changed:
                changed = True
                # Another writer moves main after the script's ls-remote check.
                run(self.remote, "update-ref", "refs/heads/main", plan["upstream_sha"])
            return real_git(repo, *arguments, **options)

        # The remote also needs the upstream object's data for this fixture.
        run(self.fork, "push", "origin", plan["upstream_sha"] + ":refs/heads/fixture-upstream")
        with patch.object(sync, "git", side_effect=racing_git):
            with self.assertRaises(sync.SyncError):
                self.promote(plan)
        self.assertEqual(run(self.remote, "rev-parse", "refs/heads/main"), plan["upstream_sha"])
        self.assertEqual(run(self.remote, "tag", "--list", plan["tag"]), "")

    def test_stock_contract_and_forged_promotion_identity_are_rejected(self):
        plan = self.plan()
        with self.assertRaisesRegex(sync.SyncError, "trusted planning"):
            sync.promote(self.fork, dict(plan, candidate=self.base), plan["base"], plan["candidate"], plan["tag"])
        (self.fork / "macos/Sources/Features/AI/TerminalAICommandPolicy.swift").unlink()
        self.commit(self.fork, "invalid stock candidate")
        with self.assertRaises(sync.SyncError):
            sync.check_contract(self.fork)

    def test_published_source_is_skipped_and_rebuild_serial_remains_monotonic(self):
        plan = self.plan()
        previous = {"commit": plan["candidate"], "upstreamTag": "v1.3.1", "version": "20261007010204"}
        second = self.plan(previous=previous)
        self.assertFalse(second["changed"])
        self.assertFalse(second["merged"])
        self.assertEqual(second["version"], "20261007010205")
        self.assertTrue(self.plan(previous=previous, rebuild=True)["changed"])


class FeedTests(unittest.TestCase):
    def feed(self, versions):
        items = "".join(f'''<item><pubDate>Tue, 06 Oct 2026 12:00:00 +0000</pubDate>
          <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
          <enclosure url="https://release.files.ghostty.org/{version}/Ghostty.dmg" sparkle:edSignature="fixture"/>
          </item>''' for version in versions)
        return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{items}</channel></rss>'.encode()

    def test_published_stable_feed_chooses_numeric_version_and_ignores_tip(self):
        self.assertEqual(sync.stable_tag(self.feed(["1.3.1", "1.10.0", "1.9.9", "1.11.0-dev", "abc (tip)"])), "v1.10.0")

    def test_bad_external_or_unpublished_xml_has_no_candidate(self):
        for value in [b"<rss>", b'<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss>&x;</rss>',
                      self.feed(["1.3.1"]).replace(b"release.files.ghostty.org", b"tip.files.ghostty.org"),
                      self.feed(["1.3.1"]).replace(b"<pubDate>", b"<notPublished>").replace(b"</pubDate>", b"</notPublished>")]:
            with self.assertRaises(sync.SyncError):
                sync.stable_tag(value)


if __name__ == "__main__":
    unittest.main()
