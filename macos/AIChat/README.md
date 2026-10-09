# Ghostty AI conversation view

This local React view uses assistant-ui's `ExternalStoreRuntime`. Swift owns Pi
execution, message ordering, terminal context, configuration, and approvals.
The view consumes published snapshots; it does not execute tools or connect to
a model, service, or CDN.

## Build

From this directory:

```sh
npm ci
npm run typecheck
npm test
```

`npm run build` bundles `dist/AIChat/index.html`, `chat.js`, `chat.css`,
`chat.js.LEGAL.txt`, and `THIRD_PARTY_LICENSES.txt`. Keep these generated resources
in the repository so a normal macOS build does not require Node. The
`dist/AIChat` folder reference already included in the Xcode project preserves
its `AIChat` basename in the native bundle.

The bundle targets Safari 16 (macOS 13). It has no runtime HTTP server. Its CSP
blocks network requests and executable remote content. Inline styles are allowed
for assistant-ui layout. Markdown images are suppressed; only HTTP(S) links are
rendered. The native navigation delegate must open those externally.

## Panel layout

The initial placement is `Right`; an existing saved placement is preserved.
Use the position button beside AI settings in the native header to choose
`Bottom`, `Right`, or `Floating`. Drag the divider above a bottom panel or to the
left of a right panel to resize it. For a floating panel, drag its header to move
it and its bottom-right grip to resize it. The floating footer reserves space for
the grip so it does not cover the composer's controls.

Placement, bottom height, and right width are saved preferences. Floating size
and position belong to the current window and are not saved across app restarts.
Changing placement keeps the current conversation and draft. Floating panels are
clamped to the available window area.

Messages use the available width, with left-aligned text and a compact role
gutter. Run status, attached context, and follow-up/steer controls share the
composer's metadata row. The one-line composer grows with its draft up to 100px,
then scrolls. Native system fonts and light/dark colors remain in use.

Hiding the panel preserves the full terminal grid. Active work and pending
approval use a compact button in the terminal's upper-right corner; click it to
reopen the conversation or stop the task. A new completion notice disappears
after six seconds. Errors can be opened or dismissed. The `View > AI Panel`
menu and its configurable shortcut (default `Cmd+Shift+A`) always reopen the
conversation, including after a notice disappears.

## Conversation history

The clock button in the native header opens saved conversations, newest first.
Search by title, source directory or model; selecting a conversation restores its
messages and tool results. The plus button starts a new conversation. Switching
is disabled while an agent task is running; hiding the panel keeps that task alive.

Ghostty saves its own transcripts and Pi JSONL contexts under
`~/Library/Application Support/com.mitchellh.ghostty/ai/pi/conversations/`.
History remains available after restarting the app. Opening history is read-only
and starts neither Pi nor a terminal command. Sending a new request resumes Pi's
saved context, with the current terminal as the command target. The recorded
source directory describes where the conversation began; it does not reattach
an old terminal or restore command approvals, queued requests or control grants.
Interrupted tools are displayed as interrupted. A missing or damaged Pi context
leaves the transcript readable and requires a new conversation to send a request.

Each conversation permits one active writer. Another panel can read its history
but must wait for the owning panel to switch away or close before continuing it.
Ghostty does not import or modify the user's existing Pi conversation history.
Transcripts contain terminal text and tool results; connection credentials and
configuration are not included. Conversations created before this feature was
added cannot be recovered after their in-memory transcript has been cleared.

## Open the AI panel quickly

On macOS, `Command+Shift+A` toggles the AI panel and opens its composer. The native
`View > AI Panel` menu displays the currently configured shortcut, including when
the composer has keyboard focus. It uses the same `toggle_ai_panel` action as native terminal bindings and
configuration, rather than a separate JavaScript hotkey.

To change the default shortcut, unbind the original and bind the new one in the
Ghostty configuration, then reload configuration:

```ini
keybind = super+shift+a=unbind
keybind = super+shift+i=toggle_ai_panel
```

## Pi plugins

Open **AI Settings → Pi plugins…** to choose installed personal Pi packages or
extensions. The list scans the configured Pi folder's `npm/node_modules` and
`extensions` directories without importing plugin code. It shows versions,
descriptions, entry counts, discovery warnings, and known interaction limitations.
Search filters the list; **Refresh** rescans after installing with Pi.

Plugins are off by default. Enabling one asks for trust once, saves the selection
in Ghostty preferences, and reconnects for the next task. Selections cannot change
while an agent or command-entry task is running. Changing the Pi folder clears
them. **Disable all** also clears selections whose package was uninstalled.
Ghostty does not modify Pi's package settings or enable project auto-discovery.

Selected extensions, skills, and prompt templates are passed explicitly to Pi.
The Ghostty extension loads first so its terminal and workspace tools keep their
definitions. Built-in `bash` and `powershell` stay excluded. The command-entry
assistant remains proposal-only and does not load selected plugins.
The assistant explicitly loads Pi's built-in MCP, codemode, and tool-search
extensions. Tool-selection modifiers add Ghostty's tools without overriding
Pi's direct/deferred/hidden exposure or enabling its local shell tools. Native
MCP is available independently of selected plugins; command entry disables it.

Plugins are trusted code running on **This Mac**, with the user's OS permissions;
they are not sandboxed by the tool allowlist. Their own process/file operations
do not use the attached SSH shell or Ghostty's native command approval.
Plugins intended to operate that shell should call `ghostty_terminal` instead.
The native terminal/file tools retain their existing approval and scope checks.

`pi-cc-extensions` changes Pi's terminal interface. Clicking its switch explains
that Ghostty uses its own AI panel and keeps it off. `pi-model-manager` similarly
needs Pi's interactive model-management UI. Other packages may load tools but
still need UI adaptation: Pi RPC cannot render `ctx.ui.custom()` terminal widgets.
The picker flags questionnaire, side-question, and session-import limitations.
Registered commands can report visible custom messages; a handled command that
leaves Pi idle completes without waiting for an agent event.
Slash commands are sent directly to Pi, and Pi notifications appear in the chat.

## Current terminal control

Pi's terminal tools are `ghostty_terminal` (`read` or `run`) and the nonexecuting
`ghostty_propose_command`. Its other managed tools handle task plans, explicit
attachments. Pi's native MCP tools use its configured servers. Terminal commands
and diagnostics intended for the attached shell use `ghostty_terminal`;
selected plugins and MCP servers run in their own environments.
`read` returns the attached
terminal's visible screen, explicitly marked as possibly including earlier or
remote output. `run` pastes one complete single-line command into that same shell,
then submits it and returns semantic command output and the shell's reported exit
code. Output is rendered terminal text, bounded by shell markers rather than raw
stdout/stderr; shell adornments can be included by those markers. Individually reviewed commands preserve its aliases, variables, directory, and shell environment.

Each terminal command is reviewed by default. The composer’s **Auto-approve
queries** button lets native-verified local read-only queries in a non-root shell
skip individual approval for the current task. It does not approve an already
pending action. Deletion, overwrites, privilege escalation, permission changes,
process signals, service restarts, database writes, scripts, complex or unknown
commands, SSH and root shells always need a separate decision. Approval shows the
reason for review, reported host/directory and complete command; **Allow this
action** approves that command only. The native execution gate decides eligibility,
without trusting the model's risk label or a dangerous-keyword blacklist.
Approving a reviewed shell command clears automatic query approval, because that
command may change shell configuration. Turn it on again to authorize later
verified queries; changing the toggle alone never answers a pending approval.

Automatically approved queries run in the same attached terminal through a fresh
private temporary directory containing a link to the verified system executable.
Arguments are passed as quoted literal values. This avoids pre-existing command aliases,
named functions and PATH overrides. Eligibility uses kernel process identity,
user ID, executable path, foreground process group and direct app/login ancestry,
and is checked again at dispatch along with the bound terminal, host and directory.
The initial allowlist covers literal non-recursive `ps`, `uname`, `id`, `whoami`,
`uptime`, `ls` and `df` metadata queries; unsupported flags and all shell
composition require review. `pwd` is reviewed because a physical directory name
can emit raw terminal controls; the read tool already reports directory context. The current user and shell hooks remain trusted;
this feature is an approval policy, not an execution sandbox. History displays the fixed executable and literal
arguments, and its details retain both the original **Requested command** and the
actual **Terminal input**. Copy and Fill use the displayed system command rather
than a temporary path.

The button controls approval, not execution location: with it off, an approved
command still runs in this same terminal. Task completion/reset, Stop, or manual
takeover clears this grant; revocation interrupts an owned active command.
Commands require OSC 133 shell integration, a primary empty prompt, and no active
foreground program, read-only mode, or pending IME input. SSH sessions must satisfy
the same integration checks; arbitrary TUIs and credential prompts are not automated.

If a command cannot start, the native error distinguishes missing integration,
unmarked theme decoration, actual unsent input, an incomplete command, a running
program, read-only mode, and IME composition. The read tool includes that status
in its context. Powerlevel10k uses its supported integration rather than marks
that the theme would overwrite; the changed startup integration takes effect in
new shells, so reopen the terminal after updating the app.

The reserved Pi RPC UI input title `ghostty-terminal-v1` carries a validated JSON
request and receives JSON via `extension_ui_response.value`. No browser or
secondary shell executes this operation. Native synchronous OSC C/D counters
identify the expected command independently of delayed desktop notifications.
Completion requires its paired exit and a new empty prompt; captured output never
falls back to an older command. A native timeout starts after approval. Stop
requests Ctrl+C only for an identifiable active agent command; interrupted,
reset, closed, or taken-over terminals report incomplete/unknown results rather
than claiming that a process was killed or changes rolled back. Closing the
attached window stops the agent.

## AI workbench

`Command+Shift+K` opens the lightweight **Write Command with AI** composer. It
uses a separate Pi mode exposing only `ghostty_propose_command`. Generation never
executes a command. Review/edit its result, use **Fill terminal** to insert it
without Enter, or **Review & run** to open the normal native approval. A changed
terminal, reported host or directory invalidates the original target. Configure
the `ai_command_entry` binding just like `toggle_ai_panel`; its View menu shortcut
tracks the effective configuration.

The **Commands** browser records both manually typed and agent commands from shell
integration. It shows the command, reported host/directory, duration, exit status
and associated output; **Explain** and **Attach output** attach that exact record.
Each terminal retains 100 records, with up to 64 KiB of rendered output per record;
the browser loads the most recent 200 entries across recent terminal catalogs.
Unknown command text cannot be replayed, and truncated/interrupted output is
labeled. Archived unfinished records are unconfirmed rather than presumed live.
System queries show their original request and actual terminal input in the
expanded record, alongside the associated output.

The **Troubleshooting task** panel shows agent steps and evidence. The agent uses
`ghostty_task_plan` to set/update them. A passed verification requires actual
completed command IDs from this task's attached terminal and successful exits;
its evidence is derived from native records. Stopping or finishing without a
check leaves verification unconfirmed. Plans and explicit attachments are saved
with the conversation for later reading.

Use **@ / Attach context** to add text files, log tails, project instructions or
tracked Git changes. Local file selection reads explicitly chosen local files;
remote reads and Git commands are approved and run in the attached shell. Preview
and remove attachments before sending. Each source is labeled, excerpts are
marked, and context is bounded to 16 items / 256 KiB. `ghostty_context` reads only
these attached items. Remote readers identify whether they capture a file head,
log tail, project excerpts or tracked diff, and carry that scope into Pi. The
8,192-character preview is labeled when shortened; the complete bounded
attachment remains available to the agent. Loading a resource preserves the draft and pauses
submission until it finishes or is canceled.

**Workflows** saves task prompts with `{{parameter}}` placeholders. Create or edit
a workflow, fill its parameters and **Use as draft**; review/send that draft to
start it. Saving waits for native acknowledgment, so a failed save preserves the
form. Workflows persist locally and their terminal operations retain ordinary
approval and current-shell binding.

**AI Settings → Pi MCP** reuses enabled servers from the existing Pi configuration
folder's `mcp.json` (Pi 1.1.0 or newer). **Show connection status** sends `/mcp`
without replacing an unsent draft; status and failures appear in the chat.
Manage servers and sign-in with `pi mcp add`, `pi mcp list`, and `pi mcp login`.
Pi owns stdio/Streamable HTTP connections, authentication, resources, and tool
exposure. MCP tool events use the same chat cards as other tools. Calls follow
Pi's configuration and selected permission extensions; Ghostty does not add its
old separate MCP approval prompt. Native terminal/file checks still apply when
those tools are called, including from codemode.
The previous Ghostty MCP settings and `ghostty_mcp` tool are no longer exposed.
Existing configurations and Keychain entries are retained, without automatic
credential migration. Enable **Use existing Pi configuration** to reuse personal
servers; project MCP configuration still follows Pi's project-trust rules.

The workbench shows the terminal's reported host, directory and readiness. These
are shell claims, not authenticated SSH identity. **Connect shell…** beside an
unverified prompt and **AI Settings → Connect current shell…** offer recovery
even before the shell reports a remote host. This also covers an idle root
subshell opened by `su` or `sudo su`; automatic query approval never bypasses
integration or an empty-prompt check and never skips review in SSH/root shells. Choose the actual Bash or zsh
shell, copy its setup and manually paste/Enter in that same idle shell. Finish
any foreground program first. Copying setup remains available during a blocked
agent task, but not while an agent-owned command runs. The setup loads integration
from a temporary directory and leaves startup files unchanged. A changed
reported host revokes grants and pending approvals; the
agent does not create another shell or silently switch hosts.

## Native bridge

The view defines `window.ghosttyAI` before posting `{type: "ready"}` to
`window.webkit.messageHandlers.ghosttyAI`. Swift calls
`window.ghosttyAI.update(snapshot)` after the ready event and on published model
updates. JSON must be passed as data, not interpolated into executable strings.

The snapshot shape is declared in `src/chat.tsx`. Messages have stable IDs and
chronological text/tool-call parts. Tool results include display text and live
running/error state. `startedAt` is Unix milliseconds. Credentials and raw Pi
events do not belong in a snapshot.

Actions are `send` (`text`, `revision`, `mode: prompt | follow_up | steer`), `stop`,
`approval` (`id`, `allow`), `terminal_control` (`allow`, Boolean), `settings`, `copy` (`text`), `remove_context`, and
`hide`, and `draft` (`text`, `revision`, for preserving an unsent question across
hide/reopen). Swift accepts bridge messages only from the bundled document's main
frame and validates action payloads against the current state.
Copy uses the native handler because browser clipboard APIs are unreliable on
local-file WKWebViews. When the chat owns keyboard focus, `Command+C/V/X/A` use
AppKit's native Copy/Paste/Cut/Select All actions for the transcript or active
editor. Multiline pasted text remains a draft; it is neither sent to AI nor
forwarded to the terminal. Other focused native views retain their shortcuts.
Escape hides the view without cancelling execution;
Escape first clears an active transcript selection. IME input is preserved.

During a run, Enter queues a follow-up by default; the mode selector can steer
instead. Command/Ctrl+Shift+Enter always steers. Shift+Enter inserts a line break.

The mounted DOM regression check exercises Markdown, tool ordering and streaming,
native actions, context, and selection/scroll preservation. Native WKWebView
verification remains necessary for appearance, layout, keyboard focus, and
resource/CSP loading. `window.ghosttyAI.diagnostics()` exposes only readiness,
message count, phase, and running state for those checks.

`draft` and `send` require an integer `revision`, increasing within each mounted
view. Native snapshots acknowledge it with `draftRevision` (initially zero).
Swift rejects older revisions. The view ignores older prompt echoes and defers
incoming text during IME composition; a newer local edit
invalidates deferred text. This keeps delayed snapshots from erasing a question
or disturbing its caret.
