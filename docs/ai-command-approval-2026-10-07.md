# Terminal AI command approval — 2026-10-07

The former Terminal control switch is now **Auto-approve queries**. Default
execution requires an explicit decision for each complete command in the bound
terminal. Enabling the switch never answers an existing approval.

Automatic execution is limited to the native argument allowlist for `ps`,
`uname`, `id`, `whoami`, `uptime`, non-recursive `ls` and `df`, in a verified direct
local non-root Bash/zsh (including the macOS login parent). Writes, deletion,
privilege changes, scripts, shell composition, unknown commands or flags, SSH,
root and nested shells remain individually reviewed. `pwd` and `ls -w` remain
reviewed because they can output raw terminal controls from directory/file names.

The native bridge rejects extra request fields; tool JSON cannot supply approval
or risk authority. Typed native authorization pins the terminal, reported host
and directory, foreground PID and available kernel process facts. Eligibility
and identity are checked again immediately before sending bytes. Integration,
an empty primary prompt, read-only mode and IME checks still apply.

Automatic queries enter that same PTY through a fresh private system-executable
link with literal quoted arguments, bypassing pre-existing aliases, named shell
functions and PATH replacements. The link is cleaned up afterward. History keeps
the exact input, original request and fixed system command; Copy/Fill use the
fixed command. Subsequent polling and persisted history preserve those fields.
The current user and shell hooks remain trusted; this is an approval policy,
not a sandbox. Approving a reviewed shell command, manual takeover, Stop or task
completion clears the automatic query grant. MCP keeps separate approval.

## Verification

- Native suite: **378 passed, 0 failed, 1 existing benchmark skipped**.
  Real private PTYs cover one-shot review, dangerous/compound command denial,
  forged authority fields, alias/function/PATH replacements, changed directories,
  nested-shell approval, stop/readiness and durable query history.
  Log: `/private/tmp/ghostty-ai-tools-20261006/risk-approval-native-final.log`.
  Result: `/Users/huangyihang1/Library/Developer/Xcode/DerivedData/Ghostty-dgdulmuaegdszxapcbpmgietzrip/Logs/Test/Test-Ghostty-2026.10.07_12-53-00-+0800.xcresult`.
  The CLI excludes the separate GhosttyUITests target. Root identity checks use
  synthetic kernel facts; remote-style fixtures use isolated nested shells,
  rather than the user's SSH machine.
- Strict SwiftLint: **0 violations in 33 files**; diff check passed.
  Log: `/private/tmp/ghostty-ai-tools-20261006/risk-approval-swiftlint.log`.
- Pure command-policy tests: **7/7 passed**. Installed-Pi policy: **15/15 passed**;
  TypeScript, renderer **3/3** and generated chat build passed.
- Normal Debug app build passed; bundled JS/CSS/HTML match the generated chat.
  Log: `/private/tmp/ghostty-ai-tools-20261006/risk-approval-build.log`.

Output: `macos/build/Debug/Ghostty.app`. This is a local build, not an installed
or published release. Open the rebuilt app to load the native changes. The
user's active terminal, SSH session and clipboard were not operated.
