# Ghostty AI workbench completion plan

The requested objective is all seven features below. Existing AI conversations,
Pi configuration reuse, terminal execution, Markdown, layouts and saved sessions
remain working. Commands execute visibly in the currently attached terminal.

| Requirement | Acceptance evidence |
| --- | --- |
| Command history and associated output | Two successive real PTY commands have distinct exact commands/output/exit/duration/cwd/host; empty output does not reuse older content; failed command explanation attaches only that record; records survive app/model restart. |
| Lightweight command entry | Configurable shortcut/native entry generates an editable command with execution tools unavailable; Fill preserves empty-prompt checks and does not submit; Run requests approval and executes in the same PTY. |
| Troubleshooting task panel | Agent can publish/update a plan; UI shows steps/evidence; success verification is tied to actual completed command records and cannot be fabricated solely by a model string. |
| Project context attachments | User can attach files/logs/project instructions/Git diff with preview/remove/source identity/bounds; attached data reaches Pi; unattached paths are not tools; remote context reads use the attached remote shell. |
| Reusable workflows | Save/edit/delete/search/use a workflow, fill parameters, persist across restart; selected workflow reaches the agent and its commands retain normal approval/terminal binding. |
| MCP integration | Configure/enable/test stdio and HTTP servers; discover tools/resources; call tools/read resources through a separately approved bridge; handle JSON/SSE/session/error/cancel/timeout; real local protocol fixtures prove behavior. |
| SSH experience | Show reported host/directory/readiness honestly; changed host cancels stale approvals/grants; remote integration setup is explicit and visible; SSH PTY fixture or equivalent authentic host/control evidence proves same-session execution. |

Implementation is split across core command records, native orchestration and
stores, compact renderer/native entry, and the native MCP client/Pi bridge.
Completion requires source audit, targeted core tests, frontend DOM tests, native
models/transport tests, real isolated terminal runs and native rendered artifacts.
No issue or PR is created. Current dirty work is preserved.

## Verification status

All seven requirements passed the source/caller audit and the scoped runtime
checks below on 2026-10-07. The generated local Debug app is
`macos/build/Debug/Ghostty.app`; an already running app needs a restart to load it.

| Requirement | Inspected implementation and passing evidence |
| --- | --- |
| Command history and output | `CommandHistory.zig` owns the OSC C/D record; the C API, native catalog and Commands browser consume its exact identity. `TerminalAICommandHistoryTests` executes three real PTY commands, checks separate outputs/empty output/exit/duration/host/cwd and compares actual command-finished callbacks with record sequences. `TerminalAIWorkbenchTests` proves private persistence/reload and bounds. The failed-command shortcut now uses the exact sequence carried at OSC D, including equal exit codes and a moved wall clock; it never guesses an older failure by exit code. |
| Lightweight command entry | The configurable `ai_command_entry` action, View menu and native popover route to a separate proposal-only Pi connection; the normal terminal bridge performs Fill/approved Run. Core binding tests prove Command+Shift+K and reconfiguration. Native generator/target-switch tests and installed-Pi policy tests prove proposal-only registration and stale-target rejection. Real PTY tests prove Fill sends no Enter and preserves a user draft; approved native operations execute in that same PTY. |
| Troubleshooting panel | Native plan bridge publishes steps/evidence to the task panel and persists them with the conversation. `TerminalAITaskExecutionTests` executes an approved real PTY command, passes its actual command ID into verification, and reloads saved native evidence. Data/model tests reject fabricated, stale, failed, running and other-terminal evidence, including wall-clock changes. |
| Project attachments | Native selection/read/capture produces source/host/scope-labeled attachments for the renderer and outbound Pi prompt; the context tool accepts only attached IDs. Native tests check explicit local files/project instructions, UTF-8/aggregate bounds and every attachment's text/source/host in the actual outbound prompt. The zsh remote-style PTY fixture approves file/log/project/Git reads, proves no dispatch before approval and checks captured data, including the newest line of a 46.5 KiB log. A private Git fixture proves the tracked diff contents. Remote capture uses the full native record rather than the short tool preview; a terminating newline prevents zsh's `%` decoration entering the context. Short previews and bounded source reads are explicitly labeled. |
| Workflows | The locked local catalog, native acknowledgment, parameter expansion and renderer editor/browser form the complete route. Data/model tests prove create/edit/delete/reload, concurrent stores, failed-save retention and literal parameter values. Mounted DOM tests prove search by name/description, no-match/clear recovery, editing, acknowledgment and use with parameters. Use creates a draft; Send follows the ordinary terminal approval route. |
| MCP | Native settings/manager connect explicitly configured stdio and Streamable HTTP servers, discover tools/resources and bridge them through separate approval. Ten native MCP tests plus workbench model tests exercise actual subprocess/localhost protocol peers, JSON/SSE/version/session headers, timeout/cancel, redirects/error handling, GET resumption without repeating a tool POST and resource attachment fencing. Configuration revisions, Keychain credentials and approved profile signatures are checked before launch. The installed-Pi suite proves the managed bridge and provider-visible native outputs. |
| SSH experience | The cheap core identity snapshot drives reported host/directory/readiness and invalidates grants/approvals after host changes. Read results, run results and approval dialogs use reported remote directories consistently. Both real unintegrated nested zsh and Bash shells recover with the bundled setup, then approved AI commands run in the same PTY and preserve startup files. Bash includes its required bash-preexec.sh. Host labels are synthetic shell claims: these fixtures verify terminal/control/integration behavior, not a connection to a user's remote host or SSH network transport. |

Final checks:

- Targeted Zig history/identity/action checks: **86/86 passed**, **104/104 build
  steps**. Log: `/private/tmp/ghostty-ai-tools-20261006/command-finished-identity-zig-tests.log`.
- Native XCFramework: **244/244 build steps**; its generated header contains
  `ghostty_action_command_finished_s.record_sequence`. Log:
  `/private/tmp/ghostty-ai-tools-20261006/command-finished-identity-core-build.log`.
- `macos/build.nu --action test`: **351 passed, 0 failed, 1 benchmark skipped**.
  Every new AI workbench test ran and passed; the CLI script excludes the separate
  `GhosttyUITests` target. The actual native WKWebView and isolated PTY tests are
  included. Log: `/private/tmp/ghostty-ai-tools-20261006/ghostty-workbench-native-test-9.log`.
  Result: `/Users/huangyihang1/Library/Developer/Xcode/DerivedData/Ghostty-dgdulmuaegdszxapcbpmgietzrip/Logs/Test/Test-Ghostty-2026.10.07_02-53-49-+0800.xcresult`.
- Installed-Pi policy: **13/13 passed**, including normal managed tools,
  proposal-only mode, record IDs in provider-visible content and attachment
  list/read. Command: bundled Node `--test macos/Tests/AI/TerminalAIPolicy.test.mjs`.
- Renderer: TypeScript passed; **3/3 mounted DOM/packaged-resource tests passed**.
  Current packaged JavaScript matches the generated source bundle. Logs:
  `/private/tmp/ghostty-ai-tools-20261006/workbench-final-typecheck.log` and
  `/private/tmp/ghostty-ai-tools-20261006/workbench-final-renderer-tests.log`.
- Actual native WK snapshots and geometry passed for **380×650 sidebar** and
  **1200×360 bottom** layouts; both images were inspected. Images:
  `/var/folders/4d/v_q35js10cs034strf1721y40000gp/T/ghostty-ai-workbench-sidebar.png`
  and `/var/folders/4d/v_q35js10cs034strf1721y40000gp/T/ghostty-ai-workbench-bottom.png`.
- Strict SwiftLint passed for the AI source/tests; `git diff --check` passed.
  After removing one redundant optional `nil` initializer, the final normal
  native build also passed. Log:
  `/private/tmp/ghostty-ai-tools-20261006/ghostty-workbench-final-build.log`.

Capabilities and verification boundaries: MCP uses manually configured
Bearer/environment credentials in Keychain; automatic OAuth sign-in and legacy
HTTP+SSE are not provided. Model/provider responses in tests are isolated
fixtures; no production provider request, user terminal input, user startup-file
mutation or real remote-host connection was performed. This is a local Debug
delivery, not an installed or published release.
