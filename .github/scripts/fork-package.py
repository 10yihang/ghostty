#!/usr/bin/env python3
"""Package and describe Ghostty AI fork updates without handling signing keys."""

import argparse
import base64
import datetime as dt
import email.utils
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

REPOSITORY = "https://github.com/10yihang/ghostty"
FEED_URL = REPOSITORY + "/releases/latest/download/appcast.xml"
BUNDLE_ID = "com.mitchellh.ghostty"
ARCHITECTURE = "arm64"
OFFICIAL_PUBLIC_KEY = "wsNcGf5hirwtdXMVnYoxRIX/SqZQLMOsYlD3q3imeok="
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
AI_ASSETS = ("index.html", "chat.js", "chat.css", "THIRD_PARTY_LICENSES.txt", "chat.js.LEGAL.txt")
ET.register_namespace("sparkle", SPARKLE_NS)


class PackagingError(Exception):
    pass


def publication_date(version):
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]{14}", version):
        raise PackagingError("The build version must be YYYYmmddHHMMSS in UTC.")
    try:
        value = dt.datetime.strptime(version, "%Y%m%d%H%M%S").replace(tzinfo=dt.timezone.utc)
    except ValueError as error:
        raise PackagingError("The build version is not a valid UTC date.") from error
    if value.year < 2000:
        raise PackagingError("The build version is outside the supported publication range.")
    return value


def source_version(value=None):
    if value is None:
        try:
            text = (Path.cwd() / "build.zig.zon").read_text(encoding="utf-8")
        except OSError as error:
            raise PackagingError("Pass --source-version or run prepare in the candidate checkout.") from error
        match = re.search(r'\.version\s*=\s*"([^"\n]+)"', text)
        if not match:
            raise PackagingError("The candidate build.zig.zon has no source version.")
        value = match.group(1)
    if not isinstance(value, str):
        raise PackagingError("The source version must be text.")
    match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", value)
    if not match or len(value) > 128:
        raise PackagingError("The source version must be a three-component semantic version.")
    return value, ".".join(match.group(1, 2, 3))


def decoded_base64(value, size, description):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise PackagingError(f"The {description} is not canonical base64.") from error
    if len(data) != size or base64.b64encode(data).decode("ascii") != value:
        raise PackagingError(f"The {description} must contain {size} bytes.")
    return data


def public_key(value):
    decoded_base64(value, 32, "fork public key")
    if value == OFFICIAL_PUBLIC_KEY:
        raise PackagingError("The fork must use its own Sparkle public key.")
    return value


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_tool(arguments, **kwargs):
    try:
        return subprocess.run(arguments, check=True, capture_output=True, **kwargs).stdout
    except subprocess.CalledProcessError as error:
        raise PackagingError(f"{Path(arguments[0]).name} failed with exit code {error.returncode}.") from error


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def require_bundle(app):
    if app.name != "Ghostty.app" or app.is_symlink() or not app.is_dir():
        raise PackagingError("The input must be a real Ghostty.app bundle.")
    root = app.resolve()
    for path in app.rglob("*"):
        if path.is_symlink():
            try:
                path.resolve(strict=True).relative_to(root)
            except (OSError, RuntimeError, ValueError) as error:
                raise PackagingError("An app symlink is broken or leaves the bundle.") from error
    required = [app / "Contents/MacOS/ghostty", app / "Contents/_CodeSignature/CodeResources"]
    required += [app / "Contents/Resources/AIChat" / name for name in AI_ASSETS]
    required += [app / "Contents/Frameworks/Sparkle.framework/Sparkle"]
    if any(not path.is_file() or path.stat().st_size == 0 for path in required):
        raise PackagingError("The app is missing its executable, signature, Sparkle, or bundled AI assets.")
    executable = app / "Contents/MacOS/ghostty"
    if not os.access(executable, os.X_OK):
        raise PackagingError("The Ghostty executable has lost its executable permission.")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != "ghostty":
        raise PackagingError("The app does not have Ghostty's stable bundle identifier.")
    return info


def normalize_times(app, date):
    timestamp = date.timestamp()
    for path in sorted(app.rglob("*"), reverse=True):
        os.utime(path, (timestamp, timestamp), follow_symlinks=False)
    os.utime(app, (timestamp, timestamp), follow_symlinks=False)


def prepare(args):
    date = publication_date(args.version)
    public_key(args.public_key)
    if args.feed_url != FEED_URL:
        raise PackagingError("The feed must be the fixed HTTPS appcast for this fork.")
    original, short = source_version(args.source_version)
    app = args.app.absolute()
    info = require_bundle(app)
    architectures = run_tool(["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/ghostty")]).decode("ascii").strip().split()
    if architectures != [ARCHITECTURE]:
        raise PackagingError("This release pipeline only publishes native ARM64 apps.")
    previous_version = str(info.get("CFBundleVersion", ""))
    if previous_version.isdecimal() and int(previous_version) > int(args.version):
        raise PackagingError("The build version would downgrade the existing bundle.")
    run_tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    entitlements = plistlib.loads(run_tool(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)]))
    if entitlements.get("com.apple.security.cs.disable-library-validation") is not True:
        raise PackagingError("ReleaseLocal ad-hoc signing requires its existing library-validation entitlement.")
    info.update(CFBundleVersion=args.version, CFBundleShortVersionString=short,
                SUFeedURL=FEED_URL, SUPublicEDKey=args.public_key,
                SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False)
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=True)
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ghostty-fork-package-") as temporary:
        entitlement_file = Path(temporary) / "entitlements.plist"
        entitlement_file.write_bytes(plistlib.dumps(entitlements, sort_keys=True))
        run_tool(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
                  "--entitlements", str(entitlement_file), str(app)])
        run_tool(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        normalize_times(app, date)
        archive = Path(temporary) / "Ghostty.zip"
        run_tool(["/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", str(app), str(archive)],
                 env=dict(os.environ, TZ="UTC", COPYFILE_DISABLE="1"))
        digest = sha256(archive)
        manifest_path = args.output / "release.json"
        if manifest_path.is_file():
            previous = json.loads(manifest_path.read_text(encoding="utf-8"))
            if previous.get("version") == args.version and previous.get("archiveSha256") != digest:
                raise PackagingError("This version already has a different archive; publish a new build version.")
        os.replace(archive, args.output / "Ghostty.zip")
    manifest = {"schemaVersion": 1, "version": args.version, "sourceVersion": original,
                "shortVersion": short, "bundleIdentifier": BUNDLE_ID, "feedURL": FEED_URL,
                "archiveSha256": digest, "archiveName": "Ghostty.zip", "architecture": ARCHITECTURE}
    write_json(manifest_path, manifest)
    return manifest


def signature(archive, signature_file):
    if not archive.is_file() or archive.is_symlink() or archive.stat().st_size == 0:
        raise PackagingError("The update archive must be a nonempty regular file.")
    if not signature_file.is_file() or signature_file.stat().st_size > 4096:
        raise PackagingError("The sign_update output is too large.")
    text = signature_file.read_text(encoding="utf-8").strip()
    try:
        entry = ET.fromstring(f'<enclosure xmlns:sparkle="{SPARKLE_NS}" {text}/>')
    except ET.ParseError as error:
        raise PackagingError("Expected only sign_update's signature and length attributes.") from error
    signature_key = f"{{{SPARKLE_NS}}}edSignature"
    if entry.tag != "enclosure" or len(entry) or set(entry.attrib) != {signature_key, "length"}:
        raise PackagingError("Unexpected data in sign_update output.")
    value = entry.attrib[signature_key]
    decoded_base64(value, 64, "EdDSA signature")
    length = entry.attrib["length"]
    if not re.fullmatch(r"[1-9][0-9]*", length) or int(length) != archive.stat().st_size:
        raise PackagingError("The signed length does not match the update archive.")
    return value, int(length)


VERIFY_SWIFT = """
import Foundation
import CryptoKit
do {
    guard CommandLine.arguments.count == 4,
          let rawKey = Data(base64Encoded: CommandLine.arguments[1]),
          let signature = Data(base64Encoded: CommandLine.arguments[3]) else { exit(1) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else { exit(1) }
} catch { exit(1) }
"""


def verify(args):
    public_key(args.public_key)
    value, _ = signature(args.archive, args.signature_file)
    with zipfile.ZipFile(args.archive) as archive:
        name = "Ghostty.app/Contents/Info.plist"
        matches = [item for item in archive.infolist() if item.filename == name]
        if len(matches) != 1 or matches[0].file_size > 1024 * 1024:
            raise PackagingError("The archive must contain one bounded Ghostty Info.plist.")
        info = plistlib.loads(archive.read(matches[0]))
    if (not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("SUFeedURL") != FEED_URL or
            info.get("SUPublicEDKey") != args.public_key):
        raise PackagingError("The archive's bundle, update feed, or public key does not match this fork.")
    publication_date(info.get("CFBundleVersion", ""))
    with tempfile.TemporaryDirectory(prefix="ghostty-fork-verify-") as cache:
        run_tool(["/usr/bin/swift", "-module-cache-path", cache, "-", args.public_key, str(args.archive.resolve()), value],
                 input=VERIFY_SWIFT.encode("utf-8"))


def appcast(args):
    date = publication_date(args.version)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.commit):
        raise PackagingError("The source commit must be a full 40-character Git SHA.")
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", args.upstream_tag):
        raise PackagingError("The upstream tag must be vMAJOR.MINOR.PATCH.")
    download = REPOSITORY + f"/releases/download/ai-{args.version}/Ghostty.zip"
    if args.download_url != download:
        raise PackagingError("The download must be this fork's immutable versioned release asset.")
    value, length = signature(args.archive, args.signature_file)
    digest = sha256(args.archive)
    prepared_path = args.archive.parent / "release.json"
    prepared = json.loads(prepared_path.read_text(encoding="utf-8")) if prepared_path.is_file() else {}
    if prepared and (prepared.get("version") != args.version or prepared.get("archiveSha256") != digest):
        raise PackagingError("The prepared manifest does not match this archive and build version.")
    if prepared and prepared.get("architecture") != ARCHITECTURE:
        raise PackagingError("The prepared manifest does not describe the ARM64 release pipeline.")
    version_source = args.source_version or prepared.get("sourceVersion")
    if version_source is None:
        raise PackagingError("Pass --source-version or supply the archive's prepared release.json.")
    if args.source_version and prepared.get("sourceVersion") not in (None, args.source_version):
        raise PackagingError("The supplied source version disagrees with the prepared archive.")
    original, short = source_version(version_source)
    marketing = f"{short} AI ({date:%Y-%m-%d})"
    feed = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(feed, "channel")
    ET.SubElement(channel, "title").text = "Ghostty AI fork updates"
    ET.SubElement(channel, "link").text = REPOSITORY
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = marketing
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = marketing
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "13.0.0"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}hardwareRequirements").text = ARCHITECTURE
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(date, usegmt=True)
    ET.SubElement(item, "description").text = f"Ghostty AI fork built from {args.commit.lower()}, including upstream {args.upstream_tag}."
    ET.SubElement(item, "link").text = REPOSITORY + "/releases/tag/ai-" + args.version
    ET.SubElement(item, "enclosure", {"url": download, f"{{{SPARKLE_NS}}}edSignature": value,
                                     "length": str(length), "type": "application/octet-stream"})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(feed)
    ET.ElementTree(feed).write(args.output, encoding="utf-8", xml_declaration=True)
    manifest = {"schemaVersion": 1, "version": args.version, "sourceVersion": original,
                "shortVersion": marketing, "sourceCommit": args.commit.lower(), "commit": args.commit.lower(),
                "upstreamTag": args.upstream_tag, "archiveSha256": digest, "archiveName": "Ghostty.zip",
                "archiveSize": length, "downloadURL": download, "feedURL": FEED_URL,
                "bundleIdentifier": BUNDLE_ID, "architecture": ARCHITECTURE}
    write_json(args.output.parent / "release.json", manifest)
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    build = commands.add_parser("prepare")
    build.add_argument("--app", type=Path, required=True)
    build.add_argument("--public-key", required=True)
    build.add_argument("--version", required=True)
    build.add_argument("--feed-url", required=True)
    build.add_argument("--output", type=Path, required=True)
    build.add_argument("--source-version")
    check = commands.add_parser("verify")
    check.add_argument("--public-key", required=True)
    check.add_argument("--archive", type=Path, required=True)
    check.add_argument("--signature-file", type=Path, required=True)
    publish = commands.add_parser("appcast")
    publish.add_argument("--archive", type=Path, required=True)
    publish.add_argument("--signature-file", type=Path, required=True)
    publish.add_argument("--version", required=True)
    publish.add_argument("--commit", required=True)
    publish.add_argument("--upstream-tag", required=True)
    publish.add_argument("--download-url", required=True)
    publish.add_argument("--output", type=Path, required=True)
    publish.add_argument("--source-version")
    args = parser.parse_args(argv)
    try:
        {"prepare": prepare, "verify": verify, "appcast": appcast}[args.operation](args)
    except (PackagingError, OSError, ValueError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        parser.exit(1, f"Packaging failed: {error}\n")
    print(f"{args.operation} succeeded")


if __name__ == "__main__":
    main()
