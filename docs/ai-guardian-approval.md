# AI automatic approval

Open **AI settings → Pi plugins**, enable the built-in **Codex Guardian**, and
confirm its authority. It is off by default. Changes apply to the next task;
plugin selection is locked while a task or command entry is active. The chat
footer shows **AI automatic approval on** and lets you turn it off when idle.

Guardian uses the current Pi model and its normal registry credentials for an
independent completion. Each review is another model request, so it adds latency
and token usage. It does not use OpenAI's private Guardian service. The bundled
policy comes from [OpenAI Codex rust-v0.153.4](https://github.com/openai/codex/tree/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/core/assets/guardian).
The policy's original files, Apache license, notice and exact provenance are
included in `macos/PiPlugins/codex-guardian` and the app bundle.

The native host freezes the full command or prepared file diff, target, original
human task messages, generation and a random review identity. The reviewer gets
no tools and does not inherit the executing agent's system prompt, conversation
or claimed approval flags. It returns Codex's risk, authorization, outcome and
rationale. Valid low/medium-risk allows proceed automatically. Critical risk is
denied. A high-risk allow additionally needs medium/high user authorization and
native evidence of narrow scope; without that evidence it falls back to human
review. The initial terminal adapter supplies no such high-risk scope evidence.
The file adapter verifies one local workspace file and its original contents.

The host consumes a matching result once, then rechecks the task and target.
Commands still execute visibly in the same bound terminal, including its SSH
session. Shell integration and an empty prompt remain required. File writes still
check the workspace, original content and fingerprint immediately before applying
the reviewed diff. Stop, manual terminal input, changed task instructions,
terminal changes and connection shutdown invalidate pending reviews. A timeout,
reviewer failure, malformed result or incomplete evidence uses the existing
manual approval dialog. The chat records allowed/denied risk and rationale, plus
the reason when automatic review falls back to manual approval. Completed reviews
also record their elapsed wait time using the native monotonic clock.

Each review has one 90-second deadline, including a single transport retry for
transient provider failures. The native host waits up to 105 seconds so it does
not discard a valid review while the plugin is still working. A slow provider can
therefore add waiting time before an action is approved. Authentication failures
and invalid assessments do not retry. Failure messages distinguish provider HTTP
errors, unavailable credentials, timeout/cancellation, invalid assessments and
insufficient policy evidence without exposing raw provider responses or credentials. A failed review
still requires manual approval.

This plugin covers Ghostty-managed terminal runs and local edit/write requests.
File reads retain their existing workspace checks. Pi's native MCP tools and
explicitly trusted extension code retain their own behavior; Guardian does not
sandbox Node extensions or add a new approval layer to MCP.

Verification uses synthetic review responses and credentials, temporary files,
private PTYs and the real installed Pi SDK. It does not execute the user's plugins
or operate their current terminal/SSH sessions. Model judgment quality remains
dependent on the selected Pi model.
