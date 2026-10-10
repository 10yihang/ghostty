# AI conversation and investigation fixes

User messages use a full-width tinted card in both appearances. Assistant text
and tool results retain their existing layout. This separates question boundaries
while preserving the narrow sidebar's usable width, multiline text and selection.

Continuing an investigation in the same terminal and reported host preserves
its step IDs, evidence and original command boundary. The native host reloads
the saved plan after acquiring the conversation writer lease. A new conversation,
changed terminal or changed host starts a new plan; older plans without a host
binding are refreshed conservatively. Verification still requires real completed
command records from the bound terminal and host. Prior verification resets when
new work begins.

`ghostty_task_plan.get_plan` reads the current state without changing it. Plan
results include IDs and statuses in model-visible text, including with Pi's
OpenAI-compatible adapter. Invalid updates explain the accepted IDs/statuses.
`set_plan` replaces all steps; `update_step` accepts `pending`, `running`,
`completed` or `failed`; `verify` accepts `passed` or `failed` and real command IDs.

Diagnostic work retains a 40-tool-call allowance. Waiting for approval, model
responses or an admitted command no longer consumes a ten-minute wall-clock
limit. Reaching the allowance blocks further tools, permits one summary turn,
and shows a pause with a continuation hint. A new human message, including a
queued follow-up or steering message, renews the allowance at native acceptance.
The remaining current work and queued work share that renewed allowance.

The native host arms renewal with a short-lived, single-use hash of the exact
human wire message. Private Guardian requests and extension-generated input do
not renew it. Missing or conflicting private commands fail startup validation.
These changes do not grant execution approval or relax terminal/file checks.

Tests use isolated native models, Pi sessions, terminal fixtures and WebKit
rendering; they do not execute user plugins or contact production models/SSH hosts.
