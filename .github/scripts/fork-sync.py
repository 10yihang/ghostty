#!/usr/bin/env python3
"""Plan a stable-upstream merge without moving main; promote only tested SHAs.

Only CI's fresh checkout may run plan. Promotion reads a bundle but never checks
out or executes candidate code. All network destinations are fixed in this file.
"""

import argparse
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


FORK = "10yihang/ghostty"
UPSTREAM = "https://github.com/ghostty-org/ghostty.git"
OFFICIAL_FEED = "https://release.files.ghostty.org/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SHA = re.compile(r"^[0-9a-f]{40}$")
SERIAL = re.compile(r"^[0-9]{14}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SOURCE_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
CONTRACT = {
    "macos/Sources/Features/AI/TerminalAIModel.swift": "ghostty-terminal-v1",
    "macos/Sources/Features/AI/TerminalAICommandPolicy.swift": "TerminalAICommandPolicy",
    "macos/Sources/Features/AI/TerminalAIPolicy.swift": "ghostty_terminal",
    "macos/AIChat/package.json": "@assistant-ui/react",
    "src/terminal/CommandHistory.zig": "pub fn",
    "src/input/Binding.zig": "toggle_ai_panel",
    ".github/workflows/fork-release.yml": "Fork Release",
}


class SyncError(RuntimeError):
    pass


def git(repo, *arguments, check=True):
    command = ["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null",
               "-c", "commit.gpgSign=false", *arguments]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise SyncError(f"git {arguments[0]} failed: {result.stderr.strip()}")
    return result


def download(url, authenticated=False, missing_ok=False):
    headers = {"User-Agent": "Ghostty-Fork-Release", "Accept": "application/vnd.github+json"}
    if url == OFFICIAL_FEED:
        headers = {"User-Agent": "Ghostty/1.3.2 Sparkle/2.9.6", "Accept": "application/xml"}
    if authenticated and os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
            value = response.read(524_289)
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise SyncError(f"Unable to read {url}: HTTP {error.code}") from error
    if len(value) > 524_288:
        raise SyncError("The release metadata exceeds the size limit")
    return value


def stable_tag(feed):
    """The published stable appcast is authoritative; GitHub has only tip.

    An official tag can exist while a release is still staged. Never choose a
    tag from refs alone, a prerelease channel, or an unversioned tip enclosure.
    """
    if len(feed) > 524_288 or b"<!DOCTYPE" in feed.upper() or b"<!ENTITY" in feed.upper():
        raise SyncError("Unsafe or oversized official appcast")
    try:
        root = ET.fromstring(feed)
    except ET.ParseError as error:
        raise SyncError("Invalid official appcast XML") from error
    versions = []
    for item in root.findall("./channel/item"):
        version = item.findtext(SPARKLE + "shortVersionString", "").strip()
        enclosure = item.find("enclosure")
        channel = item.findtext(SPARKLE + "channel", "").strip()
        if not VERSION.fullmatch(version) or channel not in ("", "stable", "release") or enclosure is None:
            continue
        if enclosure.get("url") != f"https://release.files.ghostty.org/{version}/Ghostty.dmg":
            continue
        if not enclosure.get(SPARKLE + "edSignature"):
            continue
        try:
            date = parsedate_to_datetime(item.findtext("pubDate", ""))
        except (ValueError, TypeError):
            continue
        if date.tzinfo is None:
            continue
        versions.append(tuple(int(part) for part in version.split(".")))
    if not versions:
        raise SyncError("The official appcast has no published stable version")
    return "v" + ".".join(map(str, max(versions)))


def latest_manifest():
    response = download(f"https://api.github.com/repos/{FORK}/releases/latest", authenticated=True, missing_ok=True)
    if response is None:
        return None
    release = json.loads(response)
    if release.get("draft") or release.get("prerelease"):
        raise SyncError("The fork latest endpoint did not return a published stable release")
    if not re.fullmatch(r"ai-[0-9]{14}", release.get("tag_name", "")):
        return None
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == "release.json"]
    if len(matches) != 1:
        raise SyncError("The latest fork release has no unique release.json")
    url = matches[0].get("browser_download_url", "")
    expected = f"https://github.com/{FORK}/releases/download/{release['tag_name']}/release.json"
    if url != expected:
        raise SyncError("The latest manifest download does not belong to the fork release")
    manifest = json.loads(download(url))
    if not SHA.fullmatch(str(manifest.get("commit", ""))) or not SERIAL.fullmatch(str(manifest.get("version", ""))):
        raise SyncError("The latest fork manifest has invalid commit/version metadata")
    if release["tag_name"] != "ai-" + manifest["version"]:
        raise SyncError("The latest manifest version does not match its immutable tag")
    return manifest


def check_contract(repo, commit="HEAD"):
    for path, marker in CONTRACT.items():
        source = git(repo, "show", f"{commit}:{path}").stdout
        if marker not in source:
            raise SyncError(f"The candidate is missing the fork feature contract: {path}")
    # Inherited release jobs must remain isolated after every upstream merge.
    for path in ("release-tip.yml", "release-tag.yml", "publish-tag.yml"):
        source = git(repo, "show", f"{commit}:.github/workflows/{path}").stdout
        setup = re.search(r"^  setup:\n(.*?)(?=^  [a-zA-Z_-]+:|\Z)", source, re.MULTILINE | re.DOTALL)
        guard = r"^    if:\s*(?:\|\n      )?github\.repository == 'ghostty-org/ghostty'"
        if setup is None or re.search(guard, setup.group(1), re.MULTILINE) is None:
            raise SyncError(f"The inherited upstream publisher is not isolated: {path}")


def prepare(repo, tag, previous=None, rebuild=False, upstream=UPSTREAM, now=None):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise SyncError("Invalid published stable upstream tag")
    if git(repo, "status", "--porcelain", "--untracked-files=all").stdout:
        raise SyncError("Plan requires a clean CI checkout; local changes were preserved")
    base = git(repo, "rev-parse", "HEAD").stdout.strip()
    check_contract(repo, base)
    git(repo, "checkout", "--detach", base)
    ref = "refs/fork/upstream/" + tag
    git(repo, "fetch", "--no-tags", upstream, f"refs/tags/{tag}:{ref}")
    upstream_sha = git(repo, "rev-parse", ref + "^{commit}").stdout.strip()
    if not SHA.fullmatch(base) or not SHA.fullmatch(upstream_sha):
        raise SyncError("Unable to resolve immutable source commits")
    merged = git(repo, "merge-base", "--is-ancestor", upstream_sha, base, check=False).returncode != 0
    if merged:
        result = git(repo, "-c", "user.name=Ghostty Fork CI", "-c", "user.email=ghostty-fork-ci@users.noreply.github.com",
                     "merge", "--no-ff", "--no-commit", upstream_sha, check=False)
        if result.returncode:
            conflicts = git(repo, "diff", "--name-only", "--diff-filter=U").stdout.splitlines()
            if not conflicts or any(not path.startswith(".github/workflows/") for path in conflicts):
                raise SyncError(f"Upstream merge failed; main and latest release were not changed. Conflicts: {', '.join(conflicts) or result.stderr.strip()}")
        # Deployment workflows belong to this fork. Preserve the whole baseline
        # tree, including resolving workflow-only conflicts and removing newly
        # inherited publishers. This also avoids granting workflow-write access
        # to the sync token just to import upstream's unrelated release system.
        git(repo, "restore", "--source", base, "--staged", "--worktree", "--", ".github/workflows")
        if git(repo, "diff", "--name-only", "--diff-filter=U").stdout.strip():
            raise SyncError("Unresolved source conflicts remain; main and latest release were not changed")
        git(repo, "-c", "user.name=Ghostty Fork CI", "-c", "user.email=ghostty-fork-ci@users.noreply.github.com",
            "commit", "-m", f"Merge official stable {tag} into AI fork (retain fork deployment workflows)")
    candidate = git(repo, "rev-parse", "HEAD").stdout.strip()
    check_contract(repo, candidate)
    version_source = git(repo, "show", f"{candidate}:build.zig.zon").stdout
    match = re.search(r'\.version\s*=\s*"([^"]+)"', version_source)
    if match is None or not SOURCE_VERSION.fullmatch(match.group(1)):
        raise SyncError("The candidate has no valid source version")
    timestamp = now or datetime.now(timezone.utc)
    if previous:
        try:
            old = datetime.strptime(str(previous["version"]), "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
        except (KeyError, ValueError) as error:
            raise SyncError("The prior release has no monotonic UTC version") from error
        timestamp = max(timestamp, old + timedelta(seconds=1))
    version = timestamp.astimezone(timezone.utc).strftime("%Y%m%d%H%M%S")
    changed = rebuild or previous is None or previous.get("commit") != candidate or previous.get("upstreamTag") != tag
    return {"schema": 1, "base": base, "candidate": candidate, "upstream_sha": upstream_sha,
            "upstream_tag": tag, "source_version": match.group(1), "merged": merged,
            "version": version, "tag": "ai-" + version, "changed": bool(changed)}


def save_plan(repo, plan, output):
    output.mkdir(parents=True, exist_ok=True)
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    if plan["changed"] and plan["merged"]:
        git(repo, "update-ref", "refs/fork/candidate", plan["candidate"])
        git(repo, "bundle", "create", str(output / "candidate.bundle"), "refs/fork/candidate", "^" + plan["base"])
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            for key, value in plan.items():
                if key != "schema":
                    stream.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")


def remote_refs(repo, tag):
    result = git(repo, "ls-remote", "--refs", "origin", "refs/heads/main", "refs/tags/" + tag)
    refs = {}
    for line in result.stdout.splitlines():
        sha, ref = line.split("\t", 1)
        refs[ref] = sha
    return refs


def promote(repo, plan, expected_base, expected_candidate, expected_tag):
    if plan.get("schema") != 1 or not plan.get("changed"):
        raise SyncError("Only a changed, validated plan can be promoted")
    if (plan.get("base"), plan.get("candidate"), plan.get("tag")) != (expected_base, expected_candidate, expected_tag):
        raise SyncError("The artifact does not match the trusted planning job outputs")
    if not SHA.fullmatch(expected_base) or not SHA.fullmatch(expected_candidate) or not re.fullmatch(r"ai-[0-9]{14}", expected_tag):
        raise SyncError("Invalid promotion identity")
    if not SHA.fullmatch(plan.get("upstream_sha", "")):
        raise SyncError("Invalid upstream identity")
    for sha in (expected_base, expected_candidate, plan["upstream_sha"]):
        git(repo, "cat-file", "-e", sha + "^{commit}")
    if git(repo, "merge-base", "--is-ancestor", expected_base, expected_candidate, check=False).returncode:
        raise SyncError("The candidate would discard fork history")
    if git(repo, "merge-base", "--is-ancestor", plan["upstream_sha"], expected_candidate, check=False).returncode:
        raise SyncError("The candidate does not contain the planned official release")
    check_contract(repo, expected_candidate)
    tag_ref = "refs/tags/" + expected_tag
    refs = remote_refs(repo, expected_tag)
    if refs.get("refs/heads/main") == expected_candidate and refs.get(tag_ref) == expected_candidate:
        return  # Retry of this exact already-promoted transaction, not a new target.
    if refs.get("refs/heads/main") != expected_base or tag_ref in refs:
        raise SyncError("main or the immutable tag changed; latest release was not published")
    # The ancestry checks above forbid all history rewrites. force-with-lease
    # supplies the exact-base CAS, not permission to discard independent work.
    # --atomic also refuses the tag if another writer advances main meanwhile.
    git(repo, "push", "--atomic", f"--force-with-lease=refs/heads/main:{expected_base}", "origin",
        f"{expected_candidate}:refs/heads/main", f"{expected_candidate}:{tag_ref}")
    refs = remote_refs(repo, expected_tag)
    if refs.get("refs/heads/main") != expected_candidate or refs.get(tag_ref) != expected_candidate:
        raise SyncError("Promotion readback changed; latest release must remain unpublished")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--repo", type=Path, default=Path.cwd())
    plan_parser.add_argument("--output", type=Path, required=True)
    plan_parser.add_argument("--rebuild", action="store_true")
    promote_parser = subparsers.add_parser("promote")
    promote_parser.add_argument("--repo", type=Path, default=Path.cwd())
    promote_parser.add_argument("--plan", type=Path, required=True)
    promote_parser.add_argument("--base", required=True)
    promote_parser.add_argument("--candidate", required=True)
    promote_parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    if os.environ.get("GITHUB_REPOSITORY") != FORK or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise SyncError("Only the configured fork's main workflow may sync or promote")
    if args.action == "plan":
        plan = prepare(args.repo, stable_tag(download(OFFICIAL_FEED)), latest_manifest(), args.rebuild)
        save_plan(args.repo, plan, args.output)
        print(json.dumps(plan, indent=2))
    else:
        plan = json.loads(args.plan.read_text())
        bundle = args.plan.parent / "candidate.bundle"
        if plan.get("merged"):
            git(args.repo, "bundle", "verify", str(bundle))
            git(args.repo, "fetch", str(bundle), "refs/fork/candidate:refs/fork/candidate")
        promote(args.repo, plan, args.base, args.candidate, args.tag)


if __name__ == "__main__":
    try:
        main()
    except (SyncError, OSError, ValueError, urllib.error.URLError) as error:
        raise SystemExit(str(error)) from error
