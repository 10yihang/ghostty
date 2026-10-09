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
for one stateless completion with no tools. It receives only the native review
request, not the executing agent's system prompt or conversation. It registers
the internal `_ghostty_guardian_review` command, never a model-callable tool.
The host correlates the assessment and remains responsible for execution.

This reviews Ghostty-managed terminal and local-file requests. It does not add
another approval layer to Pi MCP tools, constrain arbitrary trusted Node
extensions, or represent a filesystem sandbox. Errors, incomplete evidence,
cancellation, and malformed assessments return an error for native human review.
