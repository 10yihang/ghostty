import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { ReadableStream, TransformStream, WritableStream } from "node:stream/web";
import { TextDecoder, TextEncoder } from "node:util";
import { JSDOM, VirtualConsole } from "jsdom";

const script = await readFile(new URL("../dist/AIChat/chat.js", import.meta.url), "utf8");
const html = await readFile(new URL("../dist/AIChat/index.html", import.meta.url), "utf8");
const tick = () => new Promise((resolve) => setTimeout(resolve, 15));
async function until(check) {
  for (let attempt = 0; attempt < 80; attempt++) {
    if (check()) return;
    await tick();
  }
  assert.ok(check(), "Renderer did not reach the requested state");
}

test("native snapshots render rich ordered content and preserve interaction during streaming", async () => {
  const actions = [];
  const errors = [];
  const console = new VirtualConsole();
  console.on("jsdomError", (error) => errors.push(error));
  const dom = new JSDOM(html, { runScripts: "outside-only", pretendToBeVisual: true, url: "file:///AIChat/index.html", virtualConsole: console });
  const { window } = dom;
  Object.assign(window, { ReadableStream, TransformStream, WritableStream, TextDecoder, TextEncoder });
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  window.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  window.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
  window.HTMLElement.prototype.scrollIntoView = function () {};
  window.HTMLElement.prototype.scrollTo = function (options) { this.scrollTop = options?.top ?? this.scrollTop; };
  window.webkit = { messageHandlers: { ghosttyAI: { postMessage: (value) => {
    if (value.type === "ready") assert.equal(typeof window.ghosttyAI.update, "function");
    actions.push(value);
  } } } };
  window.eval(script);
  const document = window.document;
  const button = (label) => [...document.querySelectorAll("button")].find((node) => node.getAttribute("aria-label") === label || node.textContent === label);
  const input = (node, value) => {
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value").set.call(node, value);
    node.dispatchEvent(new window.Event("input", { bubbles: true }));
  };
  const last = (type) => actions.filter((value) => value.type === type).at(-1);
  const update = (patch) => { snapshot = { ...snapshot, ...patch }; window.ghosttyAI.update(snapshot); };
  let snapshot = {
    messages: [{ id: "user-1", role: "user", content: [{ type: "text", text: "Investigate this failure" }] }, {
      id: "assistant-1", role: "assistant", content: [
        { type: "text", text: "## Diagnosis\n\nBefore check: **port conflict**.\n\n| Port | Status |\n| --- | --- |\n| 8080 | Busy |\n\n```sh\nlsof -i :8080\n```\n\n[Docs](https://example.com)\n\n[Unsafe](javascript:alert(1))\n\n![Hidden](https://example.com/image.png)" },
        { type: "tool-call", toolCallId: "check-1", toolName: "tcp_check", args: { port: 8080 }, result: { label: "Check port", detail: "localhost:8080", text: "Connection established", isRunning: true, isError: false } },
        { type: "text", text: "After check." },
      ],
    }],
    isRunning: true, phase: "executing", status: "Checking localhost:8080", startedAt: Date.now() - 3000,
    prompt: "", context: "Error one\nError two", contextTitle: "Selected text",
    suggestedCommand: "", suggestedExplanation: "", appearance: "dark",
  };
  try {
    await until(() => last("ready"));
    assert.equal(button("Auto-approve queries").getAttribute("aria-pressed"), "false", "Each task starts without terminal authorization");
    window.ghosttyAI.update(snapshot);
    await until(() => document.querySelector("h2")?.textContent === "Diagnosis");
    assert.equal(document.querySelectorAll("table").length, 1);
    assert.equal(document.querySelector("pre code").textContent.trim(), "lsof -i :8080");
    assert.equal(document.querySelectorAll("img").length, 0);
    assert.equal(document.querySelectorAll('a[href^="javascript:"]').length, 0);
    assert.equal(document.querySelectorAll('a[href^="https:"]').length, 1);
    const assistant = document.querySelector(".assistant-message");
    assert.ok(assistant.textContent.indexOf("Before check") < assistant.textContent.indexOf("Check port"));
    assert.ok(assistant.textContent.indexOf("Check port") < assistant.textContent.indexOf("After check"));
    assert.equal(document.querySelector(".tool-state").textContent, "Running");
    const runningMessages = snapshot.messages;
    const preparingMessages = structuredClone(runningMessages);
    delete preparingMessages[1].content[1].result;
    update({ messages: preparingMessages });
    await until(() => document.querySelector(".tool-state").textContent === "Preparing");
    assert.equal(document.querySelector(".tool-card summary > .icon:first-child"), null);
    update({ messages: runningMessages });
    await until(() => document.querySelector(".tool-state").textContent === "Running");
    assert.equal(document.querySelector(".run-label").textContent, "Checking localhost:8080");
    assert.match(document.querySelector(".elapsed").textContent, /^\d+s$/);
    const sendCountBeforeControl = actions.filter((value) => value.type === "send").length;
    button("Auto-approve queries").click();
    assert.equal(last("terminal_control").allow, true);
    assert.equal(actions.filter((value) => value.type === "send").length, sendCountBeforeControl, "Changing authorization does not submit the task");
    assert.equal(button("Auto-approve queries").getAttribute("aria-pressed"), "false", "The native snapshot owns authorization state");
    update({ terminalControlAllowed: true });
    await until(() => button("Auto-approve queries").getAttribute("aria-pressed") === "true");
    assert.equal(button("Auto-approve queries").textContent, "Auto-approve queries on");
    assert.match(button("Auto-approve queries").title, /only verified local read-only queries in a non-root shell for this task/);
    assert.match(button("Auto-approve queries").title, /integrated empty prompt is still required/);
    assert.match(button("Auto-approve queries").title, /Approving a reviewed shell command clears this setting; turn it on again/);
    assert.match(button("Auto-approve queries").title, /Changes, scripts, complex or unknown commands, SSH and root shells always need separate approval/);
    assert.equal(button("Auto-approve queries").classList.contains("active"), true);
    button("Auto-approve queries").click();
    assert.equal(last("terminal_control").allow, false, "Terminal permission can be revoked during a running task");
    update({ terminalControlAllowed: false });
    await until(() => button("Auto-approve queries").getAttribute("aria-pressed") === "false");
    assert.equal(button("Auto-approve queries").classList.contains("active"), false);
    button("Copy code").click();
    assert.equal(last("copy").text.trim(), "lsof -i :8080");
    button("Stop").click();
    assert.ok(last("stop"));
    assert.equal(button("Remove attached context").disabled, true);
    button("Remove attached context").click();
    assert.ok(!last("remove_context"));

    const selected = document.querySelector(".markdown p").firstChild;
    const range = document.createRange();
    range.setStart(selected, 0); range.setEnd(selected, 6);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
    assert.equal(window.getSelection().toString(), "Before", "Selection was created");
    document.dispatchEvent(new window.Event("selectionchange"));
    await tick();
    assert.equal(window.getSelection().toString(), "Before", "Selection survived its own state notification");
    const streamed = structuredClone(snapshot.messages);
    streamed[1].content[0].text += "\n\nStreamed continuation.";
    streamed[1].content[1].result.isRunning = false;
    update({ messages: streamed });
    await tick();
    assert.equal(window.getSelection().toString(), "Before");
    assert.ok(!document.querySelector(".transcript").textContent.includes("Streamed continuation."));
    window.getSelection().removeAllRanges();
    document.dispatchEvent(new window.Event("selectionchange"));
    await until(() => document.querySelector(".transcript").textContent.includes("Streamed continuation."));
    assert.equal(document.querySelector(".tool-state").textContent, "Done");

    const viewport = document.querySelector(".transcript");
    Object.defineProperty(viewport, "scrollHeight", { configurable: true, get: () => 1500 });
    Object.defineProperty(viewport, "clientHeight", { configurable: true, get: () => 100 });
    viewport.scrollTop = 500;
    viewport.dispatchEvent(new window.Event("scroll", { bubbles: true }));
    await tick();
    const next = structuredClone(snapshot.messages);
    next[1].content[2].text += " More output.";
    update({ messages: next });
    await until(() => viewport.textContent.includes("More output."));
    assert.equal(viewport.scrollTop, 500);
    assert.ok(button("Jump to latest"));

    const prompt = document.querySelector('[aria-label="Message AI"]');
    Object.defineProperty(prompt, "scrollHeight", { configurable: true, get: () => prompt.value.includes("\n") ? 210 : 32 });
    const longDraft = "line\n".repeat(20);
    input(prompt, longDraft);
    await until(() => prompt.style.height === "100px");
    assert.equal(prompt.style.overflowY, "auto", "Long drafts scroll inside the bounded composer");
    assert.equal(prompt.value, longDraft);
    input(prompt, "a");
    await tick();
    assert.equal(prompt.style.height, "32px", "Short drafts return to a single compact row");
    assert.equal(prompt.style.overflowY, "hidden");
    const revisionA = last("draft").revision;
    input(prompt, "ab");
    await tick();
    const revisionAB = last("draft").revision;
    assert.ok(revisionAB > revisionA);
    prompt.setSelectionRange(1, 1);
    update({ prompt: "a", draftRevision: revisionA });
    await tick();
    assert.equal(prompt.value, "ab", "A stale native echo must not replace a newer local draft");
    assert.equal(prompt.selectionStart, 1, "A stale echo must preserve the caret");
    update({ status: "Checking dependencies" });
    await tick();
    assert.equal(prompt.value, "ab", "Other model changes must not replay the stale prompt");
    update({ prompt: "ab", draftRevision: revisionAB });
    await tick();

    prompt.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
    update({ prompt: "Native preset", draftRevision: revisionAB + 5 });
    await tick();
    assert.equal(prompt.value, "ab", "Native text is deferred during IME composition");
    prompt.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true }));
    await until(() => prompt.value === "Native preset");
    prompt.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
    input(prompt, "Native presetx");
    await tick();
    const composingRevision = last("draft").revision;
    assert.ok(composingRevision > revisionAB + 5);
    update({ prompt: "Delayed preset", draftRevision: composingRevision + 4 });
    await tick();
    input(prompt, "Native presety");
    await tick();
    assert.ok(last("draft").revision > composingRevision + 4);
    prompt.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true }));
    await tick();
    assert.equal(prompt.value, "Native presety", "A later local edit invalidates the deferred native prompt");

    input(prompt, "Check the dependency next");
    await tick();
    assert.equal(last("draft").text, "Check the dependency next");
    button("Queue follow-up").click();
    assert.equal(last("send").mode, "follow_up");
    assert.equal(last("send").text, "Check the dependency next");
    const sendRevision = last("send").revision;
    input(prompt, "A new unsent question");
    await tick();
    assert.ok(last("draft").revision > sendRevision);
    prompt.setSelectionRange(2, 2);
    update({ prompt: "", draftRevision: sendRevision });
    await tick();
    assert.equal(prompt.value, "A new unsent question", "A delayed send-clear must not erase the next question");
    assert.equal(prompt.selectionStart, 2);
    update({ queuedInputs: [{ id: "queued-1", mode: "follow_up", text: "Check the dependency next" }] });
    await until(() => document.querySelector(".queued-input"));
    assert.match(document.querySelector(".queued-input").textContent, /Follow-up queued/);
    assert.equal(document.querySelectorAll(".user-message").length, 1);
    input(prompt, "Check the port instead");
    await tick();
    prompt.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", shiftKey: true, metaKey: true, bubbles: true }));
    assert.equal(last("send").mode, "steer");

    update({ terminalControlAllowed: false, approval: { id: "approval-1", title: "Run shell command", message: "Approval required: this command changes system state.\nHost: fixture-local\nDirectory: /fixture/work\nCommand:\nkill 123" }, phase: "awaitingApproval", status: "Waiting for approval" });
    await until(() => button("Allow this action"));
    const decisionsBeforeGrant = actions.filter((value) => value.type === "approval").length;
    assert.match(button("Auto-approve queries").title, /does not approve a pending action/);
    button("Auto-approve queries").click();
    assert.equal(last("terminal_control").allow, true);
    assert.equal(actions.filter((value) => value.type === "approval").length, decisionsBeforeGrant, "Enabling automatic queries never approves the pending mutation");
    update({ terminalControlAllowed: true });
    await until(() => button("Auto-approve queries").getAttribute("aria-pressed") === "true");
    assert.equal(button("Allow this action").disabled, false, "A reviewed mutation remains explicitly approvable while automatic queries are enabled");
    assert.match(document.querySelector(".approval pre").textContent, /Host: fixture-local\nDirectory: \/fixture\/work\nCommand:\nkill 123$/);
    assert.equal(actions.filter((value) => value.type === "approval").length, decisionsBeforeGrant);
    button("Allow this action").click();
    assert.equal(last("approval").id, "approval-1");
    assert.equal(last("approval").allow, true);
    await tick();
    assert.equal(button("Allow this action").disabled, true);

    update({ approval: undefined, queuedInputs: [], isRunning: false, phase: "completed", status: "Complete", terminalControlAllowed: false, appearance: "light", suggestedCommand: "lsof -i :8080", suggestedExplanation: "Inspect the owner before stopping it." });
    await until(() => document.querySelector('[aria-label="Edit suggested command"]'));
    assert.equal(document.documentElement.dataset.appearance, "light");
    assert.ok(!button("Stop"));
    assert.equal(button("Auto-approve queries").getAttribute("aria-pressed"), "false", "The native task completion snapshot revokes terminal authorization");
    assert.equal(button("Remove attached context").disabled, false);
    button("Remove attached context").click();
    assert.ok(last("remove_context"));
    const command = document.querySelector('[aria-label="Edit suggested command"]');
    input(command, "lsof -nP -i :8080");
    await tick();
    button("Copy command").click();
    assert.equal(last("copy").text, "lsof -nP -i :8080");

    update({ configurationIssue: "Pi needs a model", error: "Request failed" });
    await until(() => button("Open AI settings"));
    assert.equal(document.querySelector('[role="alert"]').textContent, "Request failed");
    button("Open AI settings").click();
    assert.ok(last("settings"));
    input(prompt, "Keep my draft");
    await tick();
    button("Open AI settings to send").click();
    assert.equal(prompt.value, "Keep my draft");
    const sentCount = actions.filter((value) => value.type === "send").length;
    update({ configurationIssue: undefined, error: undefined });
    await tick();
    prompt.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true }));
    assert.equal(actions.filter((value) => value.type === "send").length, sentCount);
    document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", isComposing: true, bubbles: true }));
    assert.ok(!last("hide"));
    document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    assert.ok(last("hide"));
    assert.equal(errors.length, 0, errors.map((error) => error.message).join("\n"));
    assert.equal(window.ghosttyAI.diagnostics().messageCount, 2);
  } finally { dom.window.close(); }
});

test("packaged HTML allows local assets and blocks remote execution and connections", () => {
  assert.match(html, /script-src 'self'/);
  assert.match(html, /connect-src 'none'/);
  assert.match(html, /frame-src 'none'/);
  assert.match(html, /object-src 'none'/);
  assert.equal((html.match(/<script/g) || []).length, 1);
  assert.match(html, /<script src="chat.js"><\/script>/);
});

test("file tools remain local beside SSH and file changes require one reviewed decision", async () => {
  const actions = [];
  const errors = [];
  const console = new VirtualConsole();
  console.on("jsdomError", (error) => errors.push(error));
  const dom = new JSDOM(html, { runScripts: "outside-only", pretendToBeVisual: true, url: "file:///AIChat/index.html", virtualConsole: console });
  const { window } = dom;
  Object.assign(window, { ReadableStream, TransformStream, WritableStream, TextDecoder, TextEncoder });
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  window.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  window.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
  window.HTMLElement.prototype.scrollIntoView = function () {};
  window.HTMLElement.prototype.scrollTo = function (options) { this.scrollTop = options?.top ?? this.scrollTop; };
  window.webkit = { messageHandlers: { ghosttyAI: { postMessage: (value) => actions.push(value) } } };
  window.eval(script);
  const document = window.document;
  const button = (label) => [...document.querySelectorAll("button")].find((node) => node.getAttribute("aria-label") === label || node.textContent === label);
  let snapshot = {
    messages: [], isRunning: true, phase: "executing", status: "Reading local files", prompt: "",
    terminalIdentity: { host: "build-host", directory: "/srv/app", isRemote: true, canRun: true, readiness: "Ready" },
    fileWorkspace: "/Users/fixture/project",
  };
  const update = (patch) => { snapshot = { ...snapshot, ...patch }; window.ghosttyAI.update(snapshot); };
  try {
    await until(() => actions.some((value) => value.type === "ready"));
    window.ghosttyAI.update(snapshot);
    button("Show available tools").click();
    await until(() => document.querySelector('[aria-label="Available tools"]'));
    assert.match(document.querySelector('[aria-label="Available tools"]').textContent, /has not reported its available tools/);
    assert.equal(document.querySelectorAll(".available-tools li").length, 0, "The inventory must not advertise tools absent from the native snapshot");
    update({ availableTools: [
      { name: "ghostty_terminal", label: "Terminal", scope: "Current terminal · build-host", description: "Read and run in the attached terminal." },
      { name: "read", label: "Read file", scope: "This Mac", description: "Read files in the local workspace." },
      { name: "edit", label: "Edit file", scope: "This Mac · approval required", description: "Preview and approve changes before applying them." },
    ] });
    await until(() => document.querySelectorAll(".available-tools li").length === 3);
    assert.match(document.querySelector(".terminal-identity").textContent, /build-hostSSH/);
    assert.match(document.querySelector(".file-workspace").textContent, /This Mac\/Users\/fixture\/project/);
    assert.equal(document.querySelectorAll(".available-tools li")[0].querySelector(".tool-target").textContent, "Current terminal · build-host");
    assert.equal(document.querySelectorAll(".available-tools li")[1].querySelector(".tool-target").textContent, "This Mac");
    assert.ok(!document.querySelector(".available-tools").textContent.includes("write"));

    const fileNames = ["read", "ls", "find", "grep", "edit", "write"];
    update({ messages: [{ id: "file-assistant", role: "assistant", content: fileNames.map((name) => ({ type: "tool-call", toolCallId: `file-${name}`, toolName: name, args: { path: "/Users/fixture/project/config.txt" } })) }] });
    await until(() => document.querySelectorAll(".tool-card").length === fileNames.length);
    for (const card of document.querySelectorAll(".tool-card")) {
      assert.equal(card.querySelector(".tool-target").textContent, "This Mac", "An SSH terminal must not change a file tool's target");
      assert.equal(card.querySelector(".tool-detail").textContent, "/Users/fixture/project/config.txt");
      assert.equal(card.querySelector(".tool-state").textContent, "Preparing");
    }
    const preview = "--- config.txt\n+++ config.txt\n@@ -1 +1 @@\n-old\n+<new value>";
    update({ approval: { id: "file-review-1", title: "Edit local file", message: "Review this change before applying it.", target: "This Mac", path: "/Users/fixture/project/config.txt", preview }, phase: "waiting_approval" });
    await until(() => document.querySelector(".approval-preview"));
    assert.equal(document.querySelector(".approval").classList.contains("file-approval"), true);
    assert.equal(document.querySelector(".file-approval-body").contains(document.querySelector(".approval-target")), true);
    assert.equal(document.querySelector(".file-approval-body").contains(document.querySelector(".approval-preview")), true);
    assert.equal(document.querySelector(".file-approval-body").contains(button("Allow this action")), false, "Review actions stay outside the scrolling content");
    assert.equal(document.querySelector('[aria-label="File change preview"]').textContent, preview);
    assert.equal(document.querySelector(".approval-preview").children.length, 0, "Diff text is displayed without executing markup");
    assert.match(document.querySelector(".approval-target").textContent, /This Mac\/Users\/fixture\/project\/config.txt/);
    assert.equal(actions.filter((value) => value.type === "approval").length, 0, "Showing the preview never approves a file mutation");
    const allow = button("Allow this action");
    const decline = button("Decline");
    allow.click();
    allow.click();
    decline.click();
    assert.deepEqual(actions.filter((value) => value.type === "approval").map((value) => ({ id: value.id, allow: value.allow })), [{ id: "file-review-1", allow: true }], "Only the first decision is dispatched, including before React rerenders");
    await tick();
    assert.equal(button("Allow this action").disabled, true);
    update({ approval: { id: "file-review-2", title: "Write local file", message: "Create a new file?", target: "This Mac", path: "/Users/fixture/project/new.txt", preview: "+new file" } });
    await until(() => document.querySelector(".approval-preview").textContent === "+new file");
    allow.click();
    assert.equal(actions.filter((value) => value.type === "approval").length, 1, "An old review cannot approve a new request");
    button("Decline").click();
    assert.equal(actions.filter((value) => value.type === "approval").at(-1).id, "file-review-2");
    assert.equal(actions.filter((value) => value.type === "approval").at(-1).allow, false);
    button("Show available tools").click();
    await until(() => !document.querySelector('[aria-label="Available tools"]'));
    assert.equal(button("Show available tools").getAttribute("aria-expanded"), "false");
    assert.equal(errors.length, 0, errors.map((error) => error.message).join("\n"));
  } finally { dom.window.close(); }
});

test("workbench keeps command evidence, workflow parameters, attachments and remote readiness actionable", async () => {
  const actions = [];
  const errors = [];
  const console = new VirtualConsole();
  console.on("jsdomError", (error) => errors.push(error));
  const dom = new JSDOM(html, { runScripts: "outside-only", pretendToBeVisual: true, url: "file:///AIChat/index.html", virtualConsole: console });
  const { window } = dom;
  Object.assign(window, { ReadableStream, TransformStream, WritableStream, TextDecoder, TextEncoder });
  window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
  window.ResizeObserver = class { observe() {} disconnect() {} };
  window.IntersectionObserver = class { observe() {} disconnect() {} };
  window.HTMLElement.prototype.scrollIntoView = function () {};
  window.HTMLElement.prototype.scrollTo = function () {};
  window.webkit = { messageHandlers: { ghosttyAI: { postMessage: (value) => actions.push(value) } } };
  window.eval(script);
  const document = window.document;
  const button = (label) => [...document.querySelectorAll("button")].find((node) => node.getAttribute("aria-label") === label || node.textContent === label);
  const last = (type) => actions.filter((value) => value.type === type).at(-1);
  const input = (node, value) => {
    const prototype = node.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value").set.call(node, value);
    node.dispatchEvent(new window.Event("input", { bubbles: true }));
  };
  let snapshot = {
    messages: [], isRunning: false, phase: "completed", status: "Completed", prompt: "Inspect the CPU usage", draftRevision: 0,
    context: "", contextTitle: "Selected text", suggestedCommand: "ps -Ao pid,%cpu,comm -r | head", suggestedExplanation: "Shows CPU usage in descending order.", appearance: "dark", queuedInputs: [], terminalControlAllowed: false,
    commands: [
      { id: "success-1", command: "pwd", directory: "/srv/app", host: "build-host", startedAt: Date.now(), duration: 0.2, exitCode: 0, output: "/srv/app", state: "completed" },
      { id: "failed-1", command: "make test", directory: "/srv/app", host: "build-host", startedAt: Date.now(), duration: 2.1, exitCode: 2, output: "Missing dependency\nOnly this command's output", state: "completed" },
    ],
    attachments: [{ id: "attachment-1", name: "build.log", kind: "log", preview: "First failure\nStack frame", lineCount: 2, source: "/srv/app/build.log", host: "build-host", scope: "Last up to 64 KiB from the selected log.", truncated: true, previewTruncated: true }],
    terminalIdentity: { host: "build-host", directory: "/srv/app", isRemote: true, canRun: false, canSetupShell: true, readiness: "Remote shell integration is missing. Set it up to run commands." },
    task: { id: "task-1", title: "Investigate failed build", steps: [{ id: "step-1", title: "Read failure", status: "completed", evidence: "make test exited with code 2" }, { id: "step-2", title: "Verify repair", status: "pending", evidence: "" }], verification: { status: "unverified", summary: "No verification command has completed.", evidence: "" } },
    workflows: [{ id: "workflow-1", name: "Check port", description: "Inspect the process listening on a port", prompt: "Inspect port {{port}} on {{host}}", parameters: [{ name: "port", defaultValue: "8080" }, { name: "host", defaultValue: "localhost" }] }],
  };
  const update = (patch) => { snapshot = { ...snapshot, ...patch }; window.ghosttyAI.update(snapshot); };
  try {
    await until(() => last("ready"));
    update({});
    await until(() => button("Connect shell…"));
    assert.match(document.querySelector(".terminal-identity").textContent, /build-hostSSH/);
    assert.match(document.querySelector(".terminal-readiness").textContent, /Shell prompt not verified/);
    assert.match(document.querySelector(".terminal-readiness > span").title, /integration is missing/);
    assert.equal(button("Review & run").disabled, true, "A missing remote prompt prevents command execution");
    button("Connect shell…").click();
    assert.ok(last("ssh_setup"));
    update({ isRunning: true, phase: "thinking" });
    await tick();
    assert.equal(button("Connect shell…").disabled, false, "A blocked running task can still copy integration for the current shell");
    const recovery = button("Connect shell…");
    update({ terminalIdentity: { ...snapshot.terminalIdentity, canSetupShell: false } });
    recovery.click();
    assert.equal(actions.filter((item) => item.type === "ssh_setup").length, 1, "A stale recovery action cannot start after an agent command owns the shell");
    await until(() => !button("Connect shell…"));
    update({ terminalIdentity: { ...snapshot.terminalIdentity, isRemote: false, canSetupShell: true } });
    await until(() => button("Connect shell…"));
    assert.equal(button("Connect shell…").disabled, false, "An unintegrated nested shell is recoverable before it reports a remote host");
    update({ isRunning: false, phase: "completed" });
    await tick();
    assert.match(document.querySelector(".task-verification").textContent, /Not verified/);
    assert.match(document.querySelector(".task-steps").textContent, /make test exited with code 2/);
    assert.match(document.querySelector(".attachment-preview").textContent, /build-host.*\/srv\/app\/build.log/s);
    assert.match(document.querySelector(".attachment-preview").textContent, /Last up to 64 KiB/);
    assert.match(document.querySelector(".attachment-preview").textContent, /Preview shortened; the full attached text is sent to AI/);
    assert.match(document.querySelector(".attachment-preview pre").textContent, /First failure/);
    assert.match(document.querySelector(".attachment-preview").textContent, /contains an excerpt; the source or output is longer/);

    button("Show command history").click();
    await until(() => document.querySelectorAll(".command-record").length === 2);
    assert.match(document.querySelectorAll(".command-record")[1].textContent, /exit 2/);
    const failed = document.querySelector('.browser-filter input[type="checkbox"]');
    failed.click();
    await until(() => document.querySelectorAll(".command-record").length === 1);
    assert.equal(document.querySelector(".command-record summary code").textContent, "make test");
    button("Explain").click();
    assert.equal(last("command_explain").type, "command_explain");
    assert.equal(last("command_explain").id, "failed-1");
    button("Attach output").click();
    assert.equal(last("command_attach").id, "failed-1");
    const oldExplain = button("Explain");
    update({ commands: [] });
    oldExplain.click();
    assert.equal(actions.filter((item) => item.type === "command_explain").length, 1, "A stale command row cannot dispatch after its record disappeared");
    await until(() => !document.querySelector(".command-record"));
    update({ commands: [{ id: "unknown-command", command: "Command text unavailable", commandAvailable: false, directory: "/srv/app", host: "build-host", startedAt: Date.now(), duration: 1, exitCode: 2, output: "Captured failure", outputTruncated: true, state: "failed" }] });
    await until(() => document.querySelector(".command-record"));
    assert.match(document.querySelector(".command-record-body").textContent, /Captured output is truncated/);
    assert.equal([...document.querySelectorAll(".command-record button")].find((node) => node.textContent === "Fill terminal").disabled, true, "Unknown command text cannot be replayed as a display label");
    assert.equal([...document.querySelectorAll(".command-record button")].some((node) => node.textContent === "Copy"), false);

    failed.click();
    update({ terminalIdentity: { ...snapshot.terminalIdentity, canRun: true }, commands: [{ id: "system-query", command: "/bin/ps '-Ao' 'pid,%cpu,comm' '-r'", systemCommand: "/bin/ps '-Ao' 'pid,%cpu,comm' '-r'", requestedCommand: "ps -Ao pid,%cpu,comm -r", actualCommand: "'/private/tmp/ghostty-query-fixture/ps' '-Ao' 'pid,%cpu,comm' '-r'", directory: "/fixture/work", host: "fixture-local", startedAt: Date.now(), duration: 0.1, exitCode: 0, output: "PID %CPU COMM", state: "completed" }] });
    await until(() => document.querySelector(".command-record summary code")?.textContent === "/bin/ps '-Ao' 'pid,%cpu,comm' '-r'");
    assert.match(document.querySelector(".command-record-body").textContent, /System query · fixed executable and literal arguments/);
    assert.match(document.querySelector(".command-record-body").textContent, /Requested commandps -Ao pid,%cpu,comm -r/);
    assert.match(document.querySelector(".command-record-body").textContent, /Terminal input'\/private\/tmp\/ghostty-query-fixture\/ps'/);
    button("Fill terminal").click();
    assert.equal(last("command_fill").command, "/bin/ps '-Ao' 'pid,%cpu,comm' '-r'");
    assert.equal(last("command_fill").id, "system-query");
    button("Copy").click();
    assert.equal(last("copy").text, "/bin/ps '-Ao' 'pid,%cpu,comm' '-r'", "Copy preserves fixed system command instead of the temporary shim");
    input(document.querySelector('[aria-label="Search command history"]'), "ps -Ao");
    await tick();
    assert.equal(document.querySelectorAll(".command-record").length, 1, "The original requested command remains searchable");
    input(document.querySelector('[aria-label="Search command history"]'), "ghostty-query-fixture");
    await tick();
    assert.equal(document.querySelectorAll(".command-record").length, 1, "The actual terminal input remains searchable");

    button("Show workflows").click();
    await until(() => document.querySelector(".workflow-select"));
    const workflowSearch = document.querySelector('[aria-label="Search workflows"]');
    input(workflowSearch, "missing workflow");
    await until(() => !document.querySelector(".workflow-select"));
    assert.match(document.querySelector('[aria-label="Reusable workflows"]').textContent, /No workflows match this search/);
    input(workflowSearch, "CHECK PORT");
    await until(() => document.querySelector(".workflow-select"));
    assert.match(document.querySelector(".workflow-select").textContent, /Check port/);
    input(workflowSearch, "LISTENING");
    await until(() => document.querySelector(".workflow-select"));
    assert.match(document.querySelector(".workflow-select").textContent, /Check port/);
    input(workflowSearch, "");
    await tick();
    document.querySelector(".workflow-select").click();
    await until(() => button("Use as draft"));
    const port = document.querySelector('[aria-label="Workflow parameter port"]');
    assert.equal(port.value, "8080");
    input(port, "9000");
    await tick();
    button("Use as draft").click();
    assert.equal(last("workflow_use").id, "workflow-1");
    assert.equal(last("workflow_use").values.port, "9000");
    assert.equal(last("workflow_use").values.host, "localhost");
    assert.equal(actions.filter((item) => item.type === "send").length, 0, "Using a workflow requests a draft, never automatic execution");
    button("Edit Check port").click();
    await until(() => document.querySelector('[aria-label="Edit workflow"]'));
    const instructions = document.querySelector(".workflow-form textarea");
    input(instructions, "Inspect {{port}} and {{timeout}}");
    await tick();
    assert.match(document.querySelector(".workflow-form").textContent, /timeout default/);
    button("Save").click();
    assert.equal(last("workflow_save").id, "workflow-1");
    assert.deepEqual(Array.from(last("workflow_save").parameters, (item) => item.name), ["port", "timeout"]);
    const rejectedSave = last("workflow_save").requestID;
    assert.equal(typeof rejectedSave, "string");
    await until(() => button("Saving…")?.disabled);
    assert.ok(document.querySelector('[aria-label="Edit workflow"]'), "The form remains open until native saving is confirmed");
    update({ workflowSaveResult: { requestID: "unrelated-save", success: true } });
    await tick();
    assert.ok(button("Saving…"), "An unrelated save acknowledgement cannot close the current edit");
    update({ workflowSaveResult: { requestID: rejectedSave, success: false, error: "The workflow catalog is busy. Try again." } });
    await until(() => button("Save") && !button("Save").disabled);
    assert.match(document.querySelector(".workflow-form").textContent, /catalog is busy/);
    assert.equal(document.querySelector(".workflow-form textarea").value, "Inspect {{port}} and {{timeout}}", "A failed save preserves the instructions");
    button("Save").click();
    const acceptedSave = last("workflow_save").requestID;
    assert.notEqual(acceptedSave, rejectedSave, "Each retry has a fresh acknowledgement identity");
    update({ workflowSaveResult: { requestID: rejectedSave, success: true, workflowID: "workflow-1" } });
    await tick();
    assert.ok(document.querySelector('[aria-label="Edit workflow"]'), "A delayed prior save cannot close a later retry");
    update({ workflowSaveResult: { requestID: acceptedSave, success: true, workflowID: "workflow-1" } });
    await until(() => button("Use as draft"));
    button("Edit Check port").click();
    await until(() => button("Save"));
    button("Save").click();
    const canceledSave = last("workflow_save").requestID;
    await until(() => button("Saving…"));
    button("Cancel").click();
    await until(() => button("Edit Check port"));
    button("Edit Check port").click();
    await until(() => button("Save"));
    update({ workflowSaveResult: { requestID: canceledSave, success: true, workflowID: "workflow-1" } });
    await tick();
    assert.ok(document.querySelector('[aria-label="Edit workflow"]'), "Canceling an edit detaches its save acknowledgement from a newly opened form");
    button("Cancel").click();
    await until(() => button("Use as draft"));
    const oldUse = button("Use as draft");
    update({ workflows: [] });
    oldUse.click();
    assert.equal(actions.filter((item) => item.type === "workflow_use").length, 1, "A removed workflow cannot be continued by a stale control");
    await until(() => !button("Use as draft"));

    update({ terminalIdentity: { ...snapshot.terminalIdentity, canRun: true, canSetupShell: false, readiness: "Ready" } });
    await until(() => !button("Review & run").disabled);
    button("Review & run").click();
    assert.equal(last("command_run").command, snapshot.suggestedCommand);
    button("Fill terminal").click();
    assert.equal(last("command_fill").command, snapshot.suggestedCommand);
    button("Remove build.log").click();
    assert.equal(last("remove_attachment").id, "attachment-1");
    const composer = document.querySelector('[aria-label="Message AI"]');
    composer.setSelectionRange(0, 0);
    composer.dispatchEvent(new window.KeyboardEvent("keydown", { key: "@", bubbles: true }));
    await tick();
    assert.equal(document.querySelector(".attach-menu").open, true, "@ at a token boundary opens the context picker");
    button("Git diff").click();
    assert.equal(last("attach_context").kind, "git_diff");
    assert.equal(document.querySelector(".attach-menu").open, false);

    update({ contextLoading: true });
    await until(() => button("Cancel context load"));
    assert.equal(button("Remove build.log").disabled, true);
    assert.equal(button("Review & run").disabled, true);
    assert.equal(button("Save workflow").disabled, true);
    assert.equal(button("Send message").disabled, true);
    assert.equal(document.querySelector('[aria-label="Add project context"]').getAttribute("aria-disabled"), "true");
    input(composer, "Wait for the resource before sending");
    await tick();
    const sentWhileLoading = actions.filter((item) => item.type === "send").length;
    composer.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    assert.equal(actions.filter((item) => item.type === "send").length, sentWhileLoading, "Enter cannot submit a context-incomplete task");
    assert.equal(composer.value, "Wait for the resource before sending", "The waiting draft is preserved");
    button("Cancel context load").click();
    assert.ok(last("stop"));
    update({ contextLoading: false });
    await until(() => !button("Send message").disabled);

    update({ isRunning: true, phase: "executing", approval: { id: "approval-2", title: "Run command", message: "make test" } });
    await until(() => button("Review & run").disabled);
    assert.equal(button("Remove build.log").disabled, true);
    assert.equal(button("Save workflow").disabled, true);
    assert.equal(button("Allow this action").disabled, false, "Execution controls never block the native approval decision");
    button("Allow this action").click();
    assert.equal(last("approval").id, "approval-2");
    assert.equal(last("approval").allow, true);
    assert.equal(errors.length, 0, errors.map((error) => error.message).join("\n"));
  } finally { dom.window.close(); }
});
