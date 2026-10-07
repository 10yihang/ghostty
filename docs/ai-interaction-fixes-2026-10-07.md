# AI interaction fixes — 2026-10-07

This local delivery addresses the reported unintegrated SSH/root subshell,
persistent bottom status strip and missing macOS chat editing shortcuts.

## Current shell recovery

The native command gate still requires an integrated, empty prompt. A terminal
control grant changes approval only; it cannot make an unintegrated `su` / `sudo
su` / SSH child ready. The native error and actual registered Pi tool description
now explicitly explain that boundary instead of implying that a grant fixes it.

An unverified shell exposes **Connect shell…**, including before its remote host
is known or while an agent task is blocked. The dialog copies the bundled Bash
or zsh setup; the user pastes/enters it at that same idle shell prompt. It does
not automatically inject input into an unverified prompt. Setup is hidden while
an agent-owned command runs, and startup files remain unchanged. The same action
is available under **AI Settings → Connect current shell…**.

Real nested Bash/zsh PTY fixtures first enable a task grant and prove run remains
blocked without markers, with no terminal input. They then load the bundled
setup and execute an approved command in that same shell. The native read/run
results continue to report that shell's host and directory. Hosts are synthetic
fixture claims; this does not assert a connection to the user's remote machine.

## Hidden conversation feedback

The full-width bottom row is removed. A compact upper-right overlay shows
working/approval state and Open/Stop actions. New completion or stopped notices
expire after six seconds. Errors can be opened or dismissed; opening the panel
acknowledges a notice. The terminal keeps its full grid and keyboard focus.
The existing View menu and Command+Shift+A remain the durable open action.

Four native tests cover state visibility, acknowledgment, dimensions, prompt hit
testing and first responder preservation. Actual snapshots of approval,
completion and failure were inspected in one batch. Sidebar/bottom shell-recovery
layouts were inspected and confirmed after compacting the recovery row.

## Native chat editing

The focused `TerminalAIChatWebView` routes Command+C/V/X/A to AppKit's native
Copy/Paste/Cut/Select All actions. Other keys and other focused native views retain
their ordinary dispatch. No JavaScript clipboard/edit fallback was added.

The native regression uses actual bundled Markdown/chat editors, NSWindow key
equivalents and native Edit menu actions. Test-only WebKit Services route text
through private named pasteboards, preserving the user's general clipboard.
Tests wait for nonempty drafts and native selected-text readiness rather than
assuming that a DOM selection immediately updates the native cache. A real
Ghostty terminal sibling is laid out and settled before comparing screen state.
Chinese/emoji/multiline paste changes only the AI draft, with no terminal input,
command, approval or message submission.

## Verification

- Native regression: **358 passed, 0 failed, 1 existing benchmark skipped**.
  All new SSH, activity and three clipboard tests ran and passed.
  Log: `/private/tmp/ghostty-ai-tools-20261006/ssh-clipboard-status-native-final-3.log`.
  Result: `/Users/huangyihang1/Library/Developer/Xcode/DerivedData/Ghostty-dgdulmuaegdszxapcbpmgietzrip/Logs/Test/Test-Ghostty-2026.10.07_03-38-55-+0800.xcresult`.
  The standard CLI script excludes the separate `GhosttyUITests` target.
- Installed-Pi policy: **14/14 passed**, including the actual tool's grant and
  nested-shell guidance. Log: `/private/tmp/ghostty-ai-tools-20261006/ssh-recovery-policy-green.log`.
- TypeScript and **3/3** mounted DOM/packaged-resource tests passed. The running
  blocked task retains the recovery action; stale recovery actions cannot fire.
  Logs: `/private/tmp/ghostty-ai-tools-20261006/ssh-recovery-typecheck.log` and
  `/private/tmp/ghostty-ai-tools-20261006/ssh-recovery-renderer-green.log`.
- Strict SwiftLint: **0 violations in 27 files**; diff check passed.
  Log: `/private/tmp/ghostty-ai-tools-20261006/ssh-clipboard-status-swiftlint.log`.
- Normal Debug build passed, and its bundled JavaScript matches the current
  generated resources. Log: `/private/tmp/ghostty-ai-tools-20261006/ssh-clipboard-status-build.log`.

Output: `macos/build/Debug/Ghostty.app`. This is a local build, not an installed
or published release. Loading the new app is required for the native shortcut and
notification changes; the user's active terminal/SSH session was not operated.
