import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import warnings
import xml.etree.ElementTree as ET
import zipfile

SPEC = importlib.util.spec_from_file_location("fork_package", Path(__file__).with_name("fork-package.py"))
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)
VERSION = "20261007123456"
PUBLIC = base64.b64encode(bytes(range(32))).decode("ascii")
SIGNATURE = base64.b64encode(bytes(range(64))).decode("ascii")


class ForkPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ghostty-fork-package-tests-")
        self.root = Path(self.temporary.name)
        self.app = self.root / "Ghostty.app"
        self.info_path = self.app / "Contents/Info.plist"
        self.info_path.parent.mkdir(parents=True)
        self.info = {"CFBundleIdentifier": PACKAGE.BUNDLE_ID, "CFBundleExecutable": "ghostty",
                     "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1", "Unrelated": [True, "keep"]}
        self.info_path.write_bytes(plistlib.dumps(self.info))
        required = ["Contents/MacOS/ghostty", "Contents/_CodeSignature/CodeResources",
                    "Contents/Frameworks/Sparkle.framework/Sparkle"]
        required += ["Contents/Resources/AIChat/" + name for name in PACKAGE.AI_ASSETS]
        for name in required:
            path = self.app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture-resource")
        (self.app / "Contents/MacOS/ghostty").chmod(0o755)
        self.entitlements = {"com.apple.security.cs.disable-library-validation": True,
                             "com.apple.security.automation.apple-events": True}
        self.output = self.root / "release"
        self.archive = self.root / "Ghostty.zip"
        self.archive.write_bytes(b"fixture update archive")
        self.signature_file = self.root / "signature.txt"
        self.signature_file.write_text(f'sparkle:edSignature="{SIGNATURE}" length="{self.archive.stat().st_size}"')
        self.commands = []
        self.archive_bytes = b"fixture prepared archive"

    def tearDown(self):
        self.temporary.cleanup()

    def prepare_args(self, **changes):
        values = {"app": self.app, "public_key": PUBLIC, "version": VERSION, "feed_url": PACKAGE.FEED_URL,
                  "output": self.output, "source_version": "1.3.2-dev"}
        values.update(changes)
        return argparse.Namespace(**values)

    def appcast_args(self, **changes):
        values = {"archive": self.archive, "signature_file": self.signature_file, "version": VERSION,
                  "commit": "a" * 40, "upstream_tag": "v1.3.1",
                  "download_url": PACKAGE.REPOSITORY + f"/releases/download/ai-{VERSION}/Ghostty.zip",
                  "output": self.output / "appcast.xml", "source_version": "1.3.2-dev"}
        values.update(changes)
        return argparse.Namespace(**values)

    def native_tool_fixture(self, arguments, **kwargs):
        self.commands.append(arguments)
        if arguments[0] == "/usr/bin/lipo":
            return b"arm64\n"
        if arguments[0] == "/usr/bin/codesign" and "-d" in arguments:
            return plistlib.dumps(self.entitlements)
        if arguments[0] == "/usr/bin/codesign" and "--force" in arguments:
            entitlement_path = Path(arguments[arguments.index("--entitlements") + 1])
            self.assertEqual(plistlib.loads(entitlement_path.read_bytes()), self.entitlements)
            staged = plistlib.loads(self.info_path.read_bytes())
            self.assertEqual(staged["SUPublicEDKey"], PUBLIC)
            self.assertEqual(staged["CFBundleVersion"], VERSION)
        if arguments[0] == "/usr/bin/ditto":
            Path(arguments[-1]).write_bytes(self.archive_bytes)
            self.assertEqual(kwargs["env"]["TZ"], "UTC")
        return b""

    def test_prepare_preserves_existing_preferences_and_entitlements_before_final_signing(self):
        internal_link = self.app / "Contents/Resources/fixture-link"
        internal_link.symlink_to("AIChat/chat.js")
        with patch.object(PACKAGE, "run_tool", side_effect=self.native_tool_fixture):
            manifest = PACKAGE.prepare(self.prepare_args())
        info = plistlib.loads(self.info_path.read_bytes())
        self.assertEqual(info["Unrelated"], [True, "keep"])
        self.assertEqual(info["CFBundleShortVersionString"], "1.3.2")
        self.assertTrue(info["SUEnableAutomaticChecks"])
        self.assertFalse(info["SUAutomaticallyUpdate"])
        self.assertEqual(info["SUFeedURL"], PACKAGE.FEED_URL)
        self.assertEqual(manifest["sourceVersion"], "1.3.2-dev")
        self.assertEqual(manifest["architecture"], "arm64")
        self.assertEqual(manifest["archiveSha256"], PACKAGE.sha256(self.output / "Ghostty.zip"))
        self.assertTrue(internal_link.is_symlink())
        self.assertEqual(os.lstat(internal_link).st_mtime, PACKAGE.publication_date(VERSION).timestamp())
        self.assertEqual(sum("--verify" in command for command in self.commands), 2)
        signing = next(command for command in self.commands if "--force" in command)
        self.assertIn("--timestamp=none", signing)

    def test_same_version_retry_is_idempotent_and_different_archive_cannot_replace_it(self):
        with patch.object(PACKAGE, "run_tool", side_effect=self.native_tool_fixture):
            PACKAGE.prepare(self.prepare_args())
            before = (self.output / "release.json").read_bytes()
            PACKAGE.prepare(self.prepare_args())
            self.assertEqual((self.output / "release.json").read_bytes(), before)
            self.archive_bytes = b"different binary for the same version"
            with self.assertRaises(PACKAGE.PackagingError):
                PACKAGE.prepare(self.prepare_args())
        self.assertEqual((self.output / "Ghostty.zip").read_bytes(), b"fixture prepared archive")

    def test_prepare_rejects_intel_universal_or_unknown_architectures_before_signing(self):
        for architecture in [b"x86_64\n", b"x86_64 arm64\n", b"arm64 x86_64\n", b"arm64e\n", b""]:
            with self.subTest(architecture=architecture), patch.object(PACKAGE, "run_tool", return_value=architecture) as runner:
                with self.assertRaises(PACKAGE.PackagingError):
                    PACKAGE.prepare(self.prepare_args())
                self.assertEqual(runner.call_count, 1)
                self.assertEqual(runner.call_args.args[0][0], "/usr/bin/lipo")
            self.assertEqual(plistlib.loads(self.info_path.read_bytes()), self.info)
            self.assertFalse(self.output.exists())

    def test_prepare_rejects_official_keys_wrong_identity_feed_missing_assets_and_escaping_links(self):
        with patch.object(PACKAGE, "run_tool") as runner:
            for change in [{"public_key": PACKAGE.OFFICIAL_PUBLIC_KEY}, {"public_key": "bad"},
                           {"feed_url": "https://tip.files.ghostty.org/appcast.xml"},
                           {"feed_url": PACKAGE.FEED_URL.replace("https:", "http:")},
                           {"source_version": "1.3.2\nmalicious"}]:
                with self.subTest(change=change), self.assertRaises(PACKAGE.PackagingError):
                    PACKAGE.prepare(self.prepare_args(**change))
            runner.assert_not_called()
            wrong = dict(self.info, CFBundleIdentifier="com.mitchellh.ghostty.debug")
            self.info_path.write_bytes(plistlib.dumps(wrong))
            with self.assertRaises(PACKAGE.PackagingError):
                PACKAGE.prepare(self.prepare_args())
            self.info_path.write_bytes(plistlib.dumps(self.info))
            asset = self.app / "Contents/Resources/AIChat/chat.js"
            asset.unlink()
            with self.assertRaises(PACKAGE.PackagingError):
                PACKAGE.prepare(self.prepare_args())
            asset.write_bytes(b"fixture")
            (self.app / "Contents/Resources/outside").symlink_to(self.root / "signature.txt")
            with self.assertRaises(PACKAGE.PackagingError):
                PACKAGE.prepare(self.prepare_args())
            runner.assert_not_called()

    def test_appcast_uses_candidate_source_version_distinct_from_upstream_tag(self):
        manifest = PACKAGE.appcast(self.appcast_args())
        tree = ET.parse(self.output / "appcast.xml")
        item = tree.find("channel/item")
        self.assertEqual(item.findtext(f"{{{PACKAGE.SPARKLE_NS}}}version"), VERSION)
        self.assertEqual(item.findtext(f"{{{PACKAGE.SPARKLE_NS}}}shortVersionString"), "1.3.2 AI (2026-10-07)")
        self.assertEqual(item.findtext(f"{{{PACKAGE.SPARKLE_NS}}}minimumSystemVersion"), "13.0.0")
        self.assertEqual(item.findtext(f"{{{PACKAGE.SPARKLE_NS}}}hardwareRequirements"), "arm64")
        self.assertEqual(item.findtext("pubDate"), "Wed, 07 Oct 2026 12:34:56 GMT")
        self.assertEqual(manifest["sourceVersion"], "1.3.2-dev")
        self.assertEqual(manifest["upstreamTag"], "v1.3.1")
        self.assertEqual(manifest["commit"], manifest["sourceCommit"])
        self.assertEqual(manifest["archiveSha256"], PACKAGE.sha256(self.archive))
        self.assertEqual(manifest["architecture"], "arm64")
        original_xml = (self.output / "appcast.xml").read_bytes()
        original_json = (self.output / "release.json").read_bytes()
        PACKAGE.appcast(self.appcast_args())
        self.assertEqual((self.output / "appcast.xml").read_bytes(), original_xml)
        self.assertEqual((self.output / "release.json").read_bytes(), original_json)

    def test_appcast_rejects_bad_signature_length_urls_dates_and_xml_injection(self):
        valid_text = self.signature_file.read_text()
        for invalid in [f'sparkle:edSignature="bad" length="{self.archive.stat().st_size}"',
                        f'sparkle:edSignature="{SIGNATURE}" length="1"',
                        f'sparkle:edSignature="{SIGNATURE}" length="001"',
                        valid_text + ' url="https://example.com"', valid_text + '/><item/>',
                        valid_text + ' sparkle:edSignature="duplicate"']:
            with self.subTest(invalid=invalid), self.assertRaises(PACKAGE.PackagingError):
                self.signature_file.write_text(invalid)
                PACKAGE.appcast(self.appcast_args())
        self.signature_file.write_text(valid_text)
        for change in [{"download_url": "https://release.files.ghostty.org/Ghostty.zip"},
                       {"download_url": PACKAGE.REPOSITORY.replace("10yihang", "other") + "/Ghostty.zip"},
                       {"download_url": self.appcast_args().download_url + "?token=x"},
                       {"version": "20260230120000"}, {"version": "20261007;rm"},
                       {"commit": "a" * 39}, {"commit": "../file"},
                       {"upstream_tag": "v1.3.1-dev"}, {"source_version": '1.3.2"><script>'}]:
            with self.subTest(change=change), self.assertRaises(PACKAGE.PackagingError):
                PACKAGE.appcast(self.appcast_args(**change))
        self.assertFalse((self.output / "appcast.xml").exists())

    def test_prepared_manifest_must_match_archive_and_source_version(self):
        manifest_path = self.root / "release.json"
        manifest = {"version": VERSION, "archiveSha256": PACKAGE.sha256(self.archive), "sourceVersion": "1.3.2-dev", "architecture": "arm64"}
        manifest_path.write_text(json.dumps(manifest))
        result = PACKAGE.appcast(self.appcast_args(source_version=None))
        self.assertEqual(result["sourceVersion"], "1.3.2-dev")
        with self.assertRaises(PACKAGE.PackagingError):
            PACKAGE.appcast(self.appcast_args(source_version="1.3.1"))
        manifest["archiveSha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(PACKAGE.PackagingError):
            PACKAGE.appcast(self.appcast_args(source_version=None))

    def zip_fixture(self, **changes):
        info = dict(self.info, SUPublicEDKey=PUBLIC, SUFeedURL=PACKAGE.FEED_URL, CFBundleVersion=VERSION)
        info.update(changes)
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Ghostty.app/Contents/Info.plist", plistlib.dumps(info))
        self.signature_file.write_text(f'sparkle:edSignature="{SIGNATURE}" length="{self.archive.stat().st_size}"')

    def test_verify_pins_zip_public_key_and_calls_only_static_crypto_code(self):
        self.zip_fixture()
        arguments = argparse.Namespace(public_key=PUBLIC, archive=self.archive, signature_file=self.signature_file)
        with patch.object(PACKAGE, "run_tool") as runner:
            PACKAGE.verify(arguments)
        self.assertEqual(runner.call_args.args[0][0], "/usr/bin/swift")
        self.assertEqual(runner.call_args.kwargs["input"], PACKAGE.VERIFY_SWIFT.encode("utf-8"))
        self.assertNotIn(b"PrivateKey", runner.call_args.kwargs["input"])
        for change in [{"SUPublicEDKey": PACKAGE.OFFICIAL_PUBLIC_KEY}, {"SUFeedURL": "https://tip.files.ghostty.org/appcast.xml"},
                       {"CFBundleIdentifier": "com.mitchellh.ghostty.debug"}, {"CFBundleVersion": 123}]:
            self.zip_fixture(**change)
            with patch.object(PACKAGE, "run_tool") as runner, self.assertRaises(PACKAGE.PackagingError):
                PACKAGE.verify(arguments)
            runner.assert_not_called()

    def test_verify_rejects_duplicate_info_plists_before_crypto(self):
        self.zip_fixture()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "a") as archive:
                archive.writestr("Ghostty.app/Contents/Info.plist", plistlib.dumps(self.info))
        self.signature_file.write_text(f'sparkle:edSignature="{SIGNATURE}" length="{self.archive.stat().st_size}"')
        args = argparse.Namespace(public_key=PUBLIC, archive=self.archive, signature_file=self.signature_file)
        with patch.object(PACKAGE, "run_tool") as runner, self.assertRaises(PACKAGE.PackagingError):
            PACKAGE.verify(args)
        runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
