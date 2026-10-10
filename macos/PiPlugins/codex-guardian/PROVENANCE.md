# Codex Guardian policy provenance

The unmodified `policy_template.md`, `policy.md`, `LICENSE`, and `NOTICE` files
come from OpenAI Codex tag `rust-v0.153.4`, commit
`3d2ee51ca2d5db578f328aa75e20aa22c0197c9a`:

- https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/core/assets/guardian/policy_template.md
- https://github.com/openai/codex/blob/3d2ee51ca2d5db578f328aa75e20aa22c0197c9a/codex-rs/core/assets/guardian/policy.md

They are licensed under Apache License 2.0. The accompanying NOTICE is retained.
The local adapter supplies the policy configuration, replaces the template's
execution-environment section with Ghostty's actual environment, and requests
the four-field Codex assessment as JSON. The source policy files are unchanged.

The reviewer uses the current Pi model and its normal model-registry credentials
for stateless completion with no tools. A malformed, truncated or recognized
interrupted completion may retry once within the shared deadline. It receives
only the native review request, including original human history and bounded
non-authoritative assistant excerpts, not the executing agent's system prompt
or entire Pi conversation. It registers
the internal `_ghostty_guardian_review` command, never a model-callable tool.
The host correlates the assessment and remains responsible for execution.

This reviews Ghostty-managed terminal and local-file requests. It does not add
another approval layer to Pi MCP tools, constrain arbitrary trusted Node
extensions, or represent a filesystem sandbox. Errors, incomplete evidence,
cancellation, and malformed assessments never imply approval. Typed service
failures return to the main agent as non-executed tool failures with bounded
recovery; policy evidence and authorization issues retain individual review.

The recovery and context handling follow a source review of OpenAI Codex commit
`806d9732c974bc8a51b8317c1bd8985544fe627c`; the bundled policy files above retain
their original pinned provenance. See `docs/ai-codex-approval-source-review-2026-10-10.md`.
